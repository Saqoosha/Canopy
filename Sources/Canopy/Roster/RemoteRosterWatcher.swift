import Foundation
import Observation
import os.log

/// Watches the relay for the OTHER Macs' rosters, the way the phone does.
///
/// One `/watch` socket per machine, re-listed from `/machines` every
/// `listInterval`. Gated on the same two things as `RosterPublisher`:
/// `settings.rosterEnabled` and a relay secret in the Keychain. The tracked
/// pass reads `rosterEnabled` and `rosterEndpoint` unconditionally so the
/// toggle and an endpoint edit both wake it.
@MainActor
final class RemoteRosterWatcher {
    private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "RemoteRoster")
    private let store: SessionStore
    private let settings: CanopySettings
    private var running = false
    private var sockets: [String: URLSessionWebSocketTask] = [:]
    private var pingTimers: [String: DispatchSourceTimer] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var listTimer: DispatchSourceTimer?
    private var connectedEndpoint: String?

    // nonisolated because isStale, itself nonisolated, reads it.
    nonisolated static let staleThreshold: TimeInterval = 5 * 60
    static let listInterval: TimeInterval = 5 * 60
    private static let pingInterval: TimeInterval = 30
    private static let reconnectFloor: TimeInterval = 5

    init(store: SessionStore, settings: CanopySettings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        guard !running else { return }
        running = true
        observe()
    }

    func stop() {
        running = false
        tearDown()
    }

    /// Stops listing and watching and clears what the sidebar shows; used when the toggle goes off and on stop().
    private func tearDown() {
        disconnectAll()
        listTimer?.cancel()
        listTimer = nil
        connectedEndpoint = nil
        store.remoteMachineIds = []
        store.remoteRosters = [:]
    }

    // MARK: Pure

    /// A snapshot carries no `type`; an event or an ack does. Same rule as
    /// the phone's `RosterSocket.decode`, so an event can never be read as an
    /// empty roster.
    nonisolated static func decodeFrame(_ data: Data) -> RosterSnapshot? {
        struct TypeTag: Decodable { let type: String? }
        guard let tag = try? JSONDecoder().decode(TypeTag.self, from: data), tag.type == nil else { return nil }
        return try? JSONDecoder().decode(RosterSnapshot.self, from: data)
    }

    nonisolated static func peersToWatch(machines: [String], selfId: String?) -> [String] {
        machines.filter { $0 != selfId }
    }

    nonisolated static func isStale(_ snapshot: RosterSnapshot, now: Date) -> Bool {
        now.timeIntervalSince1970 - Double(snapshot.publishedAt) >= staleThreshold
    }

    // MARK: Tracking

    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.observe()
            }
        }
    }

    private func sync() {
        let enabled = settings.rosterEnabled
        let endpoint = settings.rosterEndpoint
        guard enabled, !endpoint.isEmpty else {
            if connectedEndpoint != nil { tearDown() }
            return
        }
        if connectedEndpoint != endpoint {
            tearDown()
            connectedEndpoint = endpoint
            startListing()
        }
    }

    // MARK: /machines

    private func startListing() {
        listTimer?.cancel()
        let timer = Self.makeListTimer(interval: Self.listInterval) { [weak self] in
            Task { @MainActor in self?.refreshMachineList() }
        }
        listTimer = timer
        timer.resume()
        refreshMachineList()
    }

    private nonisolated static func makeListTimer(interval: TimeInterval, tick: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: tick)
        return timer
    }

    private func refreshMachineList() {
        guard let base = relayURL(path: "/machines"), let secret = RosterPublisher.sharedSecret() else { return }
        let endpoint = settings.rosterEndpoint
        var request = URLRequest(url: base)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        Task { @MainActor [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    self?.logger.error("remote roster: /machines returned \((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public)")
                    return
                }
                let ids = try JSONDecoder().decode([String].self, from: data)
                self?.applyMachineList(ids, endpoint: endpoint)
            } catch {
                self?.logger.error("remote roster: /machines failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applyMachineList(_ ids: [String], endpoint: String) {
        guard running, settings.rosterEnabled, connectedEndpoint == endpoint else { return }
        let peers = Self.peersToWatch(machines: ids, selfId: MachineIdentity.stableId())
        store.remoteMachineIds = peers
        for gone in sockets.keys where !peers.contains(gone) { disconnect(machine: gone) }
        for id in peers where sockets[id] == nil { connect(machine: id) }
    }

    // MARK: /watch

    private func relayURL(path: String, machine: String? = nil, scheme: String? = nil) -> URL? {
        guard var components = URLComponents(string: settings.rosterEndpoint), components.scheme == "https" else {
            logger.error("remote roster: endpoint must be https")
            return nil
        }
        components.path = path
        if let machine { components.queryItems = [URLQueryItem(name: "machine", value: machine)] }
        if let scheme { components.scheme = scheme }
        return components.url
    }

    private func connect(machine: String) {
        guard let url = relayURL(path: "/watch", machine: machine, scheme: "wss"),
              let secret = RosterPublisher.sharedSecret() else { return }
        lastAttempt[machine] = Date()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        sockets[machine] = task
        task.resume()
        startPinging(machine: machine, task: task)
        receive(machine: machine, on: task)
        logger.notice("remote roster: watching \(machine, privacy: .public)")
    }

    private func receive(machine: String, on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.sockets[machine] === task else { return }
                switch result {
                case .success(let message):
                    let data: Data? = switch message {
                    case .data(let d): d
                    case .string(let s): Data(s.utf8)
                    @unknown default: nil
                    }
                    if let data, let snapshot = Self.decodeFrame(data) {
                        if self.running && self.store.remoteMachineIds.contains(machine) {
                            self.store.remoteRosters[machine] = snapshot
                        }
                    }
                    self.receive(machine: machine, on: task)
                case .failure(let error):
                    self.logger.error("remote roster: \(machine, privacy: .public) socket lost: \(error.localizedDescription, privacy: .public)")
                    self.disconnect(machine: machine)
                    self.scheduleReconnect(machine: machine)
                }
            }
        }
    }

    private func scheduleReconnect(machine: String) {
        guard running, store.remoteMachineIds.contains(machine) else { return }
        switch RosterReconnectFloor.decide(last: lastAttempt[machine], now: Date(), floor: Self.reconnectFloor) {
        case .now:
            connect(machine: machine)
        case .after(let delay):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.store.remoteMachineIds.contains(machine), self.sockets[machine] == nil else { return }
                    self.connect(machine: machine)
                }
            }
        }
    }

    private func startPinging(machine: String, task: URLSessionWebSocketTask) {
        pingTimers[machine]?.cancel()
        let timer = Self.makePingTimer(for: task, interval: Self.pingInterval) { [weak self] failed, error in
            Task { @MainActor in
                guard let self, self.sockets[machine] === failed else { return }
                self.logger.error("remote roster: ping to \(machine, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                self.disconnect(machine: machine)
                self.scheduleReconnect(machine: machine)
            }
        }
        pingTimers[machine] = timer
        timer.resume()
    }

    /// `nonisolated` for the reason `RosterPublisher.makePingTimer` records:
    /// the handler is not `@Sendable`, so a literal written inside this actor
    /// would abort on the timer's queue.
    private nonisolated static func makePingTimer(
        for task: URLSessionWebSocketTask, interval: TimeInterval,
        onFailure: @escaping @Sendable (URLSessionWebSocketTask, Error) -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak task] in
            guard let task else { return }
            task.sendPing { error in
                guard let error else { return }
                onFailure(task, error)
            }
        }
        return timer
    }

    private func disconnect(machine: String) {
        pingTimers[machine]?.cancel()
        pingTimers[machine] = nil
        sockets[machine]?.cancel(with: .goingAway, reason: nil)
        sockets[machine] = nil
    }

    private func disconnectAll() {
        for machine in Array(sockets.keys) { disconnect(machine: machine) }
    }
}
