import Foundation
import Network
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MirrorRecents")

/// Another Mac's closed sessions and recent folders, as its `MirrorServer`
/// answers a `list_recents` line. What lets this Mac start a session over
/// there without anyone touching that Mac: the row feeds `attach` an `open`
/// request, and the server spawns the shim with no pane (see
/// `SessionStore.startHeadlessSession`).
///
/// Travels over the paired mirror socket rather than the relay's roster: it
/// needs the same password an attach needs, and it names every project folder
/// on the machine, which the roster deliberately never carries.
struct MirrorRecents: Equatable {
    struct Session: Equatable, Hashable, Identifiable {
        let id: String
        let title: String
        let project: String
        let timestamp: Date
    }

    var sessions: [Session]
    /// Absolute paths on the other Mac, most recent first.
    var folders: [String]

    static let listType = "list_recents"
    static let replyType = "recents"
    static let maxSessions = 20
    static let maxFolders = 10

    /// The server's reply line. Sessions already open over there, hidden
    /// rows and sessions whose folder is gone are the caller's to drop before
    /// this — the wire only caps the counts.
    static func replyPayload(sessions: [SessionEntry], folders: [URL]) -> [String: Any] {
        [
            "type": replyType,
            "sessions": sessions.prefix(maxSessions).map {
                ["id": $0.id, "title": $0.title, "project": $0.projectName,
                 "timestamp": $0.timestamp.timeIntervalSince1970] as [String: Any]
            },
            "folders": folders.prefix(maxFolders).map(\.path),
        ]
    }

    /// Nil for anything that is not a `recents` reply. A malformed session
    /// entry is skipped rather than failing the whole list.
    static func parse(_ dict: [String: Any]) -> MirrorRecents? {
        guard dict["type"] as? String == replyType else { return nil }
        let sessions = (dict["sessions"] as? [[String: Any]] ?? []).compactMap { raw -> Session? in
            guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
            return Session(
                id: id,
                title: raw["title"] as? String ?? "Untitled",
                project: raw["project"] as? String ?? "",
                timestamp: Date(timeIntervalSince1970: raw["timestamp"] as? Double ?? 0)
            )
        }
        let folders = (dict["folders"] as? [String] ?? []).filter { $0.hasPrefix("/") }
        return MirrorRecents(sessions: sessions, folders: folders)
    }
}

/// What an `attach` asks the server to start when no shim is running for its
/// session id. Sent until an attach succeeds (`OpenSession.pendingMirrorOpen`).
enum MirrorOpenRequest: Equatable {
    /// Resume a closed session; the server takes its folder from its own Recents.
    case resume
    /// A new session in `cwd` on the other Mac, under the attach's session id
    /// as a placeholder the CLI's own id later replaces.
    case new(cwd: String)

    /// `attach_error` messages for an open the server refused or could not start.
    static let notOpenable = "cannot open"
    static let startFailed = "start failed"

    var wire: [String: Any] {
        switch self {
        case .resume: ["kind": "resume"]
        case .new(let cwd): ["kind": "new", "cwd": cwd]
        }
    }

    init?(wire: [String: Any]?) {
        switch wire?["kind"] as? String {
        case "resume": self = .resume
        case "new":
            guard let cwd = wire?["cwd"] as? String, cwd.hasPrefix("/") else { return nil }
            self = .new(cwd: cwd)
        default: return nil
        }
    }
}

/// One `list_recents` round trip: connect, send, read one line, close.
/// Runs its connection on the main queue, so every callback may assume the main actor.
@MainActor
final class MirrorRecentsClient {
    enum Failure: Error, Equatable { case refused(String), unreachable }

    /// Live fetches, so one outlives the call that started it.
    private static var inFlight: [ObjectIdentifier: MirrorRecentsClient] = [:]

    private let connection: NWConnection
    private let buffer = NDJSONLineBuffer(acceptsCompressed: false)
    private let token: String
    private var completion: ((Result<MirrorRecents, Failure>) -> Void)?

    static func fetch(host: String, port: UInt16, token: String,
                      completion: @escaping (Result<MirrorRecents, Failure>) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(.failure(.unreachable))
            return
        }
        let client = MirrorRecentsClient(host: host, port: nwPort, token: token, completion: completion)
        inFlight[ObjectIdentifier(client)] = client
        client.start()
    }

    private init(host: String, port: NWEndpoint.Port, token: String,
                 completion: @escaping (Result<MirrorRecents, Failure>) -> Void) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.token = token
        self.completion = completion
    }

    private func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    var payload = (try? JSONSerialization.data(withJSONObject: ["type": MirrorRecents.listType, "token": self.token])) ?? Data()
                    payload.append(0x0A)
                    self.connection.send(content: payload, completion: .contentProcessed { _ in })
                    self.receive()
                case .failed(let error), .waiting(let error):
                    logger.error("list_recents: \(error.localizedDescription, privacy: .public)")
                    self.finish(.failure(.unreachable))
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated { self?.finish(.failure(.unreachable)) }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty, let frames = self.buffer.append(data),
                   let line = NDJSONLineBuffer.lines(from: frames)?.first {
                    let dict = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                    if let recents = MirrorRecents.parse(dict) {
                        self.finish(.success(recents))
                    } else {
                        let message = dict["message"] as? String ?? "unexpected reply"
                        logger.error("list_recents refused: \(message, privacy: .public)")
                        self.finish(.failure(.refused(message)))
                    }
                } else if isComplete || error != nil {
                    self.finish(.failure(.unreachable))
                } else {
                    self.receive()
                }
            }
        }
    }

    private func finish(_ result: Result<MirrorRecents, Failure>) {
        guard let completion else { return }
        self.completion = nil
        connection.cancel()
        Self.inFlight[ObjectIdentifier(self)] = nil
        completion(result)
    }
}
