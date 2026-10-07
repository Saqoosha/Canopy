import Foundation

/// The frames a shim broadcast to its webviews, kept so a phone that iOS disconnected
/// can re-attach with `since: {epoch, seq}` and get only what it missed instead of a
/// full transcript replay (#320).
///
/// Bounded by bytes and by count, oldest dropped first. `floor` is the highest seq no
/// longer held: every frame stamped after it is here, which is the whole contract a
/// resume needs. A frame larger than `maxBytes` on its own evicts itself and raises
/// `floor` to it, so a cursor from before it falls back to the full replay.
struct MirrorFrameRing {
    struct Frame {
        let seq: Int
        /// The stamped `from-extension` payload, before any client's channel rewrite.
        let payload: [String: Any]
        /// The live channel when it was sent, which `retargeted` rewrites from.
        let liveChannel: String?
        let bytes: Int
    }

    static let defaultMaxBytes = 4 << 20
    static let defaultMaxFrames = 20_000

    let maxBytes: Int
    let maxFrames: Int
    private(set) var floor: Int
    /// Evicted slots are nilled at once, so their payloads are freed before the lazy compaction.
    private var storage: [Frame?] = []
    /// Index of the oldest live frame in `storage`; the prefix is compacted lazily.
    private var head = 0
    private(set) var totalBytes = 0

    init(floor: Int, maxBytes: Int = defaultMaxBytes, maxFrames: Int = defaultMaxFrames) {
        self.floor = floor
        self.maxBytes = maxBytes
        self.maxFrames = maxFrames
    }

    var count: Int { storage.count - head }
    /// Payloads still referenced, evicted slots included; equals `count` when eviction frees them.
    var retainedPayloads: Int { storage.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }

    /// `seq` must be greater than every seq appended before it.
    mutating func append(seq: Int, payload: [String: Any], liveChannel: String?, bytes: Int) {
        storage.append(Frame(seq: seq, payload: payload, liveChannel: liveChannel, bytes: bytes))
        totalBytes += bytes
        while head < storage.count, totalBytes > maxBytes || count > maxFrames, let evicted = storage[head] {
            totalBytes -= evicted.bytes
            floor = evicted.seq
            storage[head] = nil
            head += 1
        }
        if head > 1024, head * 2 > storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }

    /// Every held frame with a seq above `since`, oldest first, or nil when the ring
    /// cannot prove it holds all of them: `since` below `floor` (evicted) or above
    /// `latest` (a cursor this shim never issued).
    func frames(after since: Int, latest: Int) -> [Frame]? {
        guard since >= floor, since <= latest else { return nil }
        return storage[head...].compactMap { $0 }.filter { $0.seq > since }
    }

    /// Every refusal falls back to the full replay, so its reason is for the log, not an error.
    enum Resume {
        case frames([Frame])
        case refused(String)
    }

    /// Whether a re-attach may resume, and with which frames.
    static func resume(ring: MirrorFrameRing?, epoch: String, currentEpoch: String, since: Int,
                       latest: Int, liveChannelOpen: Bool) -> Resume {
        guard epoch == currentEpoch else { return .refused("epoch changed") }
        // The kept page will not send `launch_claude`, so it needs a channel to map onto.
        guard liveChannelOpen else { return .refused("no live channel") }
        guard let ring else { return .refused("no frames buffered") }
        guard let frames = ring.frames(after: since, latest: latest) else {
            return .refused("cursor \(since) is outside \(ring.floor)...\(latest)")
        }
        return .frames(frames)
    }
}

/// The `since` and `channelId` a re-attaching client sends, or nil when it sent no
/// usable cursor (an older client, or a fresh page).
struct MirrorResumeCursor: Equatable {
    let epoch: String
    let seq: Int
    /// The kept page's own channel, from its latest `launch_claude`.
    let channelId: String

    init?(attach dict: [String: Any]) {
        guard let since = dict["since"] as? [String: Any],
              let epoch = since["epoch"] as? String, !epoch.isEmpty,
              let number = since["seq"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let channelId = dict["channelId"] as? String, !channelId.isEmpty
        else { return nil }
        let seq = number.intValue
        guard seq >= 0, Double(seq) == number.doubleValue else { return nil }
        self.epoch = epoch
        self.seq = seq
        self.channelId = channelId
    }
}
