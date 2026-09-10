import Foundation

/// One thing that happened in a session, on its way to the phone.
///
/// **Carrying `type` is the only thing that distinguishes this from a roster
/// snapshot on the wire.** A snapshot has no `type` field at all, so both the
/// Durable Object and the phone tell the two apart by that field's presence
/// alone. Remove it and an event is parsed as a malformed snapshot and
/// dropped in silence on both sides.
struct SessionEvent: Codable, Equatable, Sendable {
    /// Always `"event"`. A constant for the reason above.
    let type: String
    /// Minted by Canopy. **Not the same thing as the DO's `seq`** — this one
    /// also rides on the `completed` push, and is what lets the phone tell
    /// that a notification and an event are the same turn. The `seq` is
    /// assigned by the relay and cannot be known here.
    let eventId: String
    let sessionId: String
    let resumeId: String?
    let kind: Kind
    let text: String
    let at: Date
    /// 画像 Read の行だけが持つ。**`kind` は `tool` のまま。**
    ///
    /// 新しい `kind` にしないのは互換のため —— 古い電話は知らない `kind` を
    /// `.other` に落として「image: Read: shot.png」という意味不明の行を描く。
    /// 未知のフィールドは Codable が黙って無視するので、古い電話はいつもの
    /// レンチ行のままになる。
    let image: ImageInfo?

    enum Kind: String, Codable, Sendable {
        case assistant
        case user
        case tool
        case turnStart
        case turnEnd
    }

    /// 画像を運んでよいツールの名前。
    ///
    /// **`toolLabel` の switch と同じ向きの判断で、同じ理由で狭い。** あちらは
    /// 80 文字の要約について「デフォルトは名前だけ、列挙したものだけが中身を
    /// 出す」と決めている。こちらが運ぶのは数百 KB の画像なので、同じ慎重さが
    /// 要る。**削除は常に安全、追加だけが判断を要する。**
    ///
    /// 広げる先は chrome-devtools の `take_screenshot` などだが、**電話側には
    /// この判定が無い** —— 届いたものを描くだけなので、広げるのは Mac の変更
    /// だけで済み、App Store のリリースを待たない。もう 1 箇所は
    /// `ImagePreviewScript` の `IMG_EXT`。
    static let imageToolAllowlist: Set<String> = ["Read"]

    /// 画像として扱う拡張子。`ImagePreviewScript` の `IMG_EXT` と同じ集合。
    /// 片方だけ広げると、Mac の webview には出るのに電話には出ない（あるいは
    /// その逆）という、どちらもエラーを出さない形のずれになる。
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "avif"]

    /// 画像 Read なら最後のパス要素、そうでなければ nil。
    ///
    /// `toolLabel` が `Read` に対して出すのと同じ最後のパス要素を返す ——
    /// ディレクトリは機械の説明であって、作業対象の名前ではない。
    static func imageReadFileName(name: String, input: [String: Any]?) -> String? {
        guard imageToolAllowlist.contains(name),
              let path = input?["file_path"] as? String
        else { return nil }
        let url = URL(fileURLWithPath: path)
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let component = url.lastPathComponent
        return component.isEmpty ? nil : component
    }

    /// フレーム内の全 `tool_result` を、画像用にデコードして返す。
    ///
    /// **呼び出し側には 2 つとも要る。** `resultIds` はこのフレームに載った
    /// 全 `tool_result` の `tool_use_id` —— 画像が無いものも、失敗した Read
    /// （`content` が配列ではなく文字列）も含む。呼び出し側はこの集合を見て
    /// 「このフレームがどの pending read を解決したか」を知り、画像が無かった
    /// ものにも素の行を出せる。相関を持つのは呼び出し側で、ここはフレームの
    /// 中身をそのまま報告するだけ。
    ///
    /// `images` は 1 つの `tool_result` につき最大 1 枚。1 回の Read が複数枚
    /// 返すことはあり（`ImagePreviewScript` は配列で持っている）、そのときは
    /// 1 行 1 枚という前提を守って残りを捨てる。**フレームに複数の `tool_result`
    /// が載れば、画像を持つブロックの数だけ返す** —— 最初の 1 件で止めない。
    ///
    /// 失敗した Read は `content` が配列ではなく文字列で来る —— これも
    /// `ImagePreviewScript` の実測。
    static func imageResults(inFrame message: [String: Any])
        -> (resultIds: Set<String>, images: [(toolUseId: String, mediaType: String, data: Data)]) {
        guard message["type"] as? String == "user",
              let blocks = (message["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return ([], []) }
        var resultIds: Set<String> = []
        var images: [(toolUseId: String, mediaType: String, data: Data)] = []
        for block in blocks where block["type"] as? String == "tool_result" {
            guard let toolUseId = block["tool_use_id"] as? String else { continue }
            resultIds.insert(toolUseId)
            guard let items = block["content"] as? [[String: Any]] else { continue }
            for item in items where item["type"] as? String == "image" {
                guard let source = item["source"] as? [String: Any],
                      source["type"] as? String == "base64",
                      let mediaType = source["media_type"] as? String,
                      let encoded = source["data"] as? String,
                      let data = Data(base64Encoded: encoded)
                else { continue }
                images.append((toolUseId, mediaType, data))
                break
            }
        }
        return (resultIds, images)
    }

    /// 1 枚の画像について電話が知る必要のあること。**バイトは含まない** ——
    /// R2 にあり、`GET /image` で取る。この値の存在が「この行には画像がある」。
    ///
    /// `width` / `height` は原寸のピクセル数で、行が絵を読み込む前に正しい
    /// 縦横比の場所を確保するためにある。`bytes` は原寸のバイト数で、タップ
    /// する前に大きさを見せるため。
    struct ImageInfo: Codable, Equatable, Sendable {
        let width: Int
        let height: Int
        let bytes: Int
    }

    /// Upper bound on one event's text, in BYTES. Keeps a single row in the
    /// relay's SQLite from growing without limit.
    static let maxTextBytes = 8 * 1024

    /// Upper bound on a tool's one-line summary, in characters. Separate from
    /// `maxTextBytes` because it is a legibility limit, not a storage one — a
    /// 4000-character command line is not more informative than its first 80.
    static let maxToolSummaryLength = 80

    init(eventId: String, sessionId: String, resumeId: String?, kind: Kind, text: String,
         at: Date, image: ImageInfo? = nil) {
        self.type = "event"
        self.eventId = eventId
        self.sessionId = sessionId
        self.resumeId = resumeId
        self.kind = kind
        self.text = text
        self.at = at
        self.image = image
    }

    /// Peel the two envelopes off an unsolicited extension message and return
    /// the CLI frame inside, or nil when this is not one — or when it belongs
    /// to a subagent rather than to this conversation.
    ///
    /// **Measured on device, after the first version read the outermost
    /// `type` and produced nothing for a whole session.** The shape is
    /// `{type:"from-extension", message:{type:"io_message", message:<frame>}}`
    /// — three envelopes deep, which is exactly what `trackWorkingState`
    /// unwraps. A response (as opposed to an unsolicited message) is NOT
    /// wrapped, and is not a stream frame either, so it correctly falls out
    /// here.
    static func ioFrame(in message: [String: Any]) -> [String: Any]? {
        guard message["type"] as? String == "from-extension",
              let nested = message["message"] as? [String: Any],
              nested["type"] as? String == "io_message",
              let frame = nested["message"] as? [String: Any]
        else { return nil }
        // **A subagent's turns are not this conversation.** The CLI re-emits
        // them as ordinary `assistant` / `user` frames carrying a
        // `parent_tool_use_id` — the property `ShimProcess`'s own
        // `isMainConversationMessage` was written against. Without this, one
        // Agent call streams its dozens of tool lines and its assistant text
        // into a 200-event ring buffer as if they were the main session, and
        // the Agent's own prompt arrives drawn as something the human typed.
        // The turn boundaries were withdrawn for costing a fifth of that
        // buffer; a subagent costs far more.
        let parent = frame["parent_tool_use_id"]
        guard parent == nil || parent is NSNull else { return nil }
        return frame
    }

    /// Convenience over `events(fromFrame:…)` that unwraps first. Callers on
    /// the io_message path hand in the whole envelope.
    /// - Parameter stampUser: given a `user` turn's text, the id that turn
    ///   should carry instead of a fresh one, or nil. This is how a reply
    ///   typed on the PHONE gets the id the phone already stored it under:
    ///   the phone mints `replyId`, the Mac injects the text and remembers
    ///   the pair, and the CLI's echo of that text comes back through here
    ///   carrying the phone's own id — so the phone can tell its local
    ///   "sent" record and the streamed event are one thing and draw one.
    ///   Matched on text rather than on the injected frame's `uuid` because
    ///   whether the echo preserves that field is unmeasured; text is what
    ///   `isKeepAliveEcho` and `isRecapEcho` already match on.
    static func events(from message: [String: Any],
                       sessionId: String,
                       resumeId: String?,
                       at: Date,
                       nextId: () -> String,
                       stampUser: ((String) -> String?)? = nil,
                       onImageRead: ((_ toolUseId: String, _ fileName: String, _ at: Date) -> Void)? = nil)
        -> [SessionEvent] {
        guard let frame = ioFrame(in: message) else { return [] }
        return events(fromFrame: frame, sessionId: sessionId, resumeId: resumeId,
                      at: at, nextId: nextId, stampUser: stampUser, onImageRead: onImageRead)
    }

    /// Turn one CLI frame into zero or more events. Pure.
    ///
    /// **Most `user` frames are tool results, not conversation.** A frame
    /// whose content holds any `tool_result` block is dropped. Losing that
    /// filter fills the phone's conversation with tool output, which is the
    /// single most likely regression in this file.
    ///
    /// A bulk history replay never reaches here: the CLI delivers it as ONE
    /// message carrying a `response.messages` array, and `ioFrame` only reads
    /// the top-level `type`. Measured on CLI 2.1.258 with Canopy's own flags
    /// — a `--resume` does not re-emit historical `assistant` frames
    /// individually.
    static func events(fromFrame message: [String: Any],
                       sessionId: String,
                       resumeId: String?,
                       at: Date,
                       nextId: () -> String,
                       stampUser: ((String) -> String?)? = nil,
                       onImageRead: ((_ toolUseId: String, _ fileName: String, _ at: Date) -> Void)? = nil)
        -> [SessionEvent] {
        func make(_ kind: Kind, _ text: String, id: String? = nil) -> SessionEvent? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return SessionEvent(eventId: id ?? nextId(), sessionId: sessionId, resumeId: resumeId,
                                kind: kind, text: capped(trimmed), at: at)
        }

        /// The text blocks of a `message.content`, whichever of its two wire
        /// shapes it takes. **A `user` echo can carry `content` as a plain
        /// string**, not only as an array of blocks — both existing echo
        /// matchers accept both forms, and the first version here read only
        /// the array, which would have dropped every string-form turn.
        func joinedText(of content: Any?) -> String {
            if let blocks = content as? [[String: Any]] {
                return blocks
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
            }
            return content as? String ?? ""
        }

        switch message["type"] as? String {
        case "assistant":
            let blocks = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            var out: [SessionEvent] = []
            let text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            if let event = make(.assistant, text) { out.append(event) }
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String else { continue }
                // 画像 Read は、結果が来るまで行を出さない。画像はこのフレーム
                // ではなく次の `tool_result` に来るので、行と絵を 1 行にする
                // には結果まで待つしかない。**`onImageRead` が nil のときは
                // 今と同じ挙動** —— 画像を扱わない呼び出し側が行を失わない。
                if let onImageRead,
                   let fileName = imageReadFileName(name: name, input: block["input"] as? [String: Any]),
                   let toolUseId = block["id"] as? String {
                    onImageRead(toolUseId, fileName, at)
                    continue
                }
                guard let event = make(.tool, toolLabel(name: name, input: block["input"] as? [String: Any]))
                else { continue }
                out.append(event)
            }
            return out

        case "user":
            let content = (message["message"] as? [String: Any])?["content"]
            if let blocks = content as? [[String: Any]],
               blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                return []
            }
            let text = joinedText(of: content).trimmingCharacters(in: .whitespacesAndNewlines)
            return [make(.user, text, id: stampUser?(text))].compactMap { $0 }

        // `system/init` and `result` — the turn boundaries — are deliberately
        // NOT emitted. They were, at first: two events per turn into a
        // 200-event ring buffer the phone never drew (`SessionEventBlock`
        // renders them as nothing), so roughly a fifth of a session's recent
        // history was spent on rows nobody could see. "Is it still working"
        // is answered by the roster's state dot, not by an event. The enum
        // cases stay so an older relay's stored rows still decode.
        default:
            return []
        }
    }

    /// The display label for one tool call.
    ///
    /// **The default is the name alone, and only the tools listed here get a
    /// summary.** Never invert this into "show `input` unless the tool is
    /// dangerous": every tool added upstream would then start sending its
    /// arguments through the relay, with nobody deciding that it should.
    /// Removing a case from this switch is always safe; adding one is the
    /// only direction that needs a judgement about what may leave the Mac.
    ///
    /// `Read`/`Edit`/`Write` deliberately send the file's LAST PATH COMPONENT
    /// and not the path: the name says what is being worked on, while the
    /// directories describe the machine itself.
    static func toolLabel(name: String, input: [String: Any]?) -> String {
        func short(_ value: String?) -> String? {
            guard let value, let line = value.split(separator: "\n").first else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.count > maxToolSummaryLength
                ? String(trimmed.prefix(maxToolSummaryLength)) + "…"
                : trimmed
        }
        let summary: String?
        switch name {
        case "Bash":
            summary = short(input?["command"] as? String)
        case "Read", "Edit", "Write":
            summary = short((input?["file_path"] as? String).map {
                URL(fileURLWithPath: $0).lastPathComponent
            })
        case "Glob", "Grep":
            summary = short(input?["pattern"] as? String)
        case "Task", "Agent":
            summary = short(input?["description"] as? String)
        default:
            summary = nil
        }
        guard let summary else { return name }
        return "\(name): \(summary)"
    }

    /// Cut to `maxTextBytes` measured in UTF-8 BYTES, not characters. What
    /// reaches the relay is bytes, and one Japanese character is three of
    /// them — a character limit is not a limit on what is stored. Trimming
    /// whole `Character`s means a surrogate pair is never split.
    private static func capped(_ text: String) -> String {
        guard text.utf8.count > maxTextBytes else { return text }
        var out = text
        while out.utf8.count > maxTextBytes - 3, !out.isEmpty {
            out.removeLast()
        }
        return out + "…"
    }
}
