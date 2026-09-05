/**
 * Frame layer for the CJK emphasis repair: applies `cjk-emphasis.js` to the
 * messages the extension sends the webview, and keeps the tally that answers
 * "how much is this actually fixing".
 *
 * Everything bound for the webview passes through `webview.postMessage`, which
 * makes it the single place both delivery paths can be covered at once. The
 * measured wire (CANOPY_CJK_DEBUG=1 on a real session) is:
 *
 *   live      {type:"from-extension", message:{type:"io_message", message:<CLI frame>}}
 *   replay    {type:"from-extension", message:{type:"response", response:{messages:[…]}}}
 *
 * Live text arrives as `stream_event` / `content_block_delta` / `text_delta`
 * chunks, so a streaming rewriter is held per text block. Replay arrives as
 * whole `assistant` frames and is repaired in one call.
 *
 * A block's rewriter holds back a few characters that a later chunk could still
 * change (see the streaming contract in cjk-emphasis.js), so every path that
 * ends a block has to release that tail. There is no field on a stop event to
 * carry text, so the tail goes out as one synthetic `content_block_delta` ahead
 * of it: the webview's assembler does `$.text += delta.text` (read out of the
 * extension's bundle), which makes an extra delta indistinguishable from a
 * slower stream.
 *
 * Frames are never mutated. The extension keeps its own references to what it
 * posted, so a repaired frame is a shallow copy down the path that changed.
 */

'use strict';

const { CJKEmphasisRewriter, repairCounted } = require('./cjk-emphasis.js');

function createEmphasisRepairer(options) {
    const opts = options || {};
    const write = opts.write || ((line) => process.stderr.write(line + '\n'));

    // key -> { rewriter, index, outer, frame }. The originating frames are kept
    // so a tail released at `result` — a frame that carries no block index and
    // is not even a stream_event — can still be shaped as a delta for the block
    // it belongs to.
    const open = new Map();
    const live = { closer: 0, opener: 0, blocks: 0 };
    const replay = { closer: 0, opener: 0, blocks: 0 };
    const turn = { closer: 0, opener: 0, blocks: 0 };
    // The CLI emits BOTH the stream deltas and a whole `assistant` frame for the
    // same reply, and both reach this function. Counting both reported one
    // repaired span as two — a systematic 2x on the only number this feature
    // exists to produce. The batch frame is still repaired (it is what renders
    // if a reply ever arrives unstreamed); it is only counted when that stream
    // did not already account for it.
    //
    // Per stream, not one flag for the process: a subagent's text arrives ONLY
    // as batch frames, so a single flag set by the main agent's stream left
    // every subagent repair uncounted while the log said `no repairs` — the tally
    // contradicting the text it had just rewritten.
    const streamed = new Set();
    const streamKey = (frame) => frame.parent_tool_use_id || 'main';

    // `parent_tool_use_id` is measured to be hardcoded null on every
    // `stream_event` (ShimProcess.swift records this against CLI 2.1.217), so
    // today every stream keys to `main` and a subagent's text — which arrives as
    // batch `assistant` frames, repaired whole — never reaches this map. The
    // field is in the key so that a CLI which starts stamping it partitions
    // correctly rather than silently interleaving two scanners.
    const keyOf = (frame, index) => `${frame.parent_tool_use_id || 'main'}#${index}`;

    // CANOPY_CJK_DEBUG=1 names every distinct message shape that reaches
    // `repairOutbound`, once each. The envelope the extension posts is
    // documented nowhere, and reading it wrong turns the whole repair into a
    // silent pass-through — which is exactly what happened the first time this
    // shipped. One line per shape is bounded no matter how long a session runs.
    const debugShapes = process.env.CANOPY_CJK_DEBUG === '1';
    const seenShapes = new Set();

    function noteShape(outer) {
        // Resolve down to the CLI frame before describing it. Reading only one
        // layer collapses every stream event into a single `stream_event` line
        // and never reports `delta.type` — so a `text_delta` rename, the most
        // likely silent-no-op trigger, would be invisible to the tool written
        // to catch exactly that.
        const parts = [`outer=${outer && outer.type}`];
        let node = outer;
        if (node && node.type === 'from-extension' && node.message && typeof node.message === 'object') {
            node = node.message;
            parts.push(`inner=${node.type}`);
        }
        if (node && node.type === 'io_message' && node.message && typeof node.message === 'object') {
            node = node.message;
            parts.push(`frame=${node.type}`);
        }
        if (node && node.event && typeof node.event === 'object') {
            parts.push(`event=${node.event.type}`);
            if (node.event.delta && node.event.delta.type) parts.push(`delta=${node.event.delta.type}`);
        }
        const shape = parts.join(' ');
        if (seenShapes.has(shape)) return;
        seenShapes.add(shape);
        write(`[cjk-emphasis] shape: ${shape}`);
    }

    function noteBlock(target, closer, opener) {
        if (closer === 0 && opener === 0) return;
        target.closer += closer;
        target.opener += opener;
        target.blocks++;
    }

    // Every turn is reported, a clean one included. Staying quiet was the first
    // design and it makes silence ambiguous between "nothing needed repairing"
    // and "this never ran at all" — which is the failure this feature is most
    // likely to have and least able to notice. What the line does NOT prove is
    // that the scanner saw any text: a build whose delta predicate had drifted
    // would report `no repairs` too. A turn is one user message, so the line is
    // not on a hot path, and the running totals ride along so the most recent
    // line always carries the whole answer.
    function reportTurn() {
        const repairs = turn.closer + turn.opener;
        const what = repairs === 0
            ? 'no repairs'
            : `repaired ${repairs} (${turn.closer} closer, ${turn.opener} opener) in ${turn.blocks} blocks`;
        write(
            `[cjk-emphasis] turn: ${what}; ` +
            `session live ${live.closer + live.opener} / ${live.blocks} blocks, ` +
            `replay ${replay.closer + replay.opener} / ${replay.blocks} blocks`,
        );
        turn.closer = 0;
        turn.opener = 0;
        turn.blocks = 0;
        streamed.clear();
    }

    /** A `content_block_delta` frame carrying `text`, copied off `outer`. */
    function deltaFrame(outer, frame, index, text) {
        return {
            ...outer,
            message: {
                ...frame,
                event: { type: 'content_block_delta', index, delta: { type: 'text_delta', text } },
            },
        };
    }

    /** Close one entry, tally it, and return its tail delta if it held one. */
    function closeEntry(key, entry) {
        open.delete(key);
        const tail = entry.rewriter.end();
        noteBlock(live, entry.rewriter.repairs.closer, entry.rewriter.repairs.opener);
        noteBlock(turn, entry.rewriter.repairs.closer, entry.rewriter.repairs.opener);
        return tail ? deltaFrame(entry.outer, entry.frame, entry.index, tail) : null;
    }

    /**
     * Release blocks still open. `prefix` scopes it to one stream, which is what
     * `message_stop` means; `result` passes none, because it is the only frame
     * guaranteed to end a turn and an entry surviving it would lose its held
     * tail and then splice it into the next turn's first delta.
     */
    function flushOpen(prefix) {
        const extra = [];
        for (const [key, entry] of [...open.entries()]) {
            if (prefix !== undefined && !key.startsWith(prefix)) continue;
            const frame = closeEntry(key, entry);
            if (frame) extra.push(frame);
        }
        return extra;
    }

    function repairAssistantFrame(frame, target, count) {
        const msg = frame.message;
        if (!msg || !Array.isArray(msg.content)) return frame;
        let changed = false;
        let closer = 0;
        let opener = 0;
        const content = msg.content.map((block) => {
            if (!block || block.type !== 'text' || typeof block.text !== 'string') return block;
            const r = repairCounted(block.text);
            if (r.text === block.text) return block;
            // Keyed on the text, not on the counters: a future repair that
            // rewrote without incrementing would otherwise have its work
            // silently discarded here, with the tally reporting nothing.
            changed = true;
            closer += r.closer;
            opener += r.opener;
            return { ...block, text: r.text };
        });
        if (!changed) return frame;
        if (count) {
            noteBlock(target, closer, opener);
            // The per-turn accumulator belongs to the live path only; a replay
            // reports its own line and must not resegment a turn in flight.
            if (target === live) noteBlock(turn, closer, opener);
        }
        return { ...frame, message: { ...msg, content } };
    }

    function handleStreamEvent(outer, frame) {
        const event = frame.event;
        const index = event.index;

        if (event.type === 'content_block_start') {
            if (event.content_block && event.content_block.type === 'text') {
                const key = keyOf(frame, index);
                const stale = open.get(key);
                // A reused index means the previous block never got a stop.
                // Overwriting it would drop its held tail with no trace.
                const extra = stale ? closeEntry(key, stale) : null;
                open.set(key, { rewriter: new CJKEmphasisRewriter(), index, outer, frame });
                return extra ? [extra, outer] : [outer];
            }
            return [outer];
        }

        if (event.type === 'content_block_delta') {
            const delta = event.delta;
            if (!delta || delta.type !== 'text_delta' || typeof delta.text !== 'string') return [outer];
            // A `text_delta` can only belong to a text block — thinking sends
            // `thinking_delta` and a tool call sends `input_json_delta` — so the
            // block is opened here if its `content_block_start` never arrived.
            // Requiring the start would make a change in what the extension
            // forwards degrade into silently repairing nothing, which is the
            // one failure this feature must not have.
            const key = keyOf(frame, index);
            let entry = open.get(key);
            if (!entry) {
                entry = { rewriter: new CJKEmphasisRewriter(), index, outer, frame };
                open.set(key, entry);
            }
            streamed.add(streamKey(frame));
            const emitted = entry.rewriter.feed(delta.text);
            if (emitted === delta.text) return [outer];
            return [deltaFrame(outer, frame, index, emitted)];
        }

        if (event.type === 'content_block_stop') {
            const key = keyOf(frame, index);
            const entry = open.get(key);
            if (!entry) return [outer];
            const extra = closeEntry(key, entry);
            return extra ? [extra, outer] : [outer];
        }

        if (event.type === 'message_stop') {
            return [...flushOpen(`${frame.parent_tool_use_id || 'main'}#`), outer];
        }

        return [outer];
    }

    /**
     * Repair one outbound webview message.
     *
     * The extension posts unsolicited traffic inside a `from-extension`
     * envelope — measured, `outer=from-extension inner=io_message frame=result`
     * and friends. Reading the shape off the webview's own handler instead is
     * one layer short: that handler destructures the envelope (`var m =
     * d.message`) before its `m.type === 'io_message'` test, so copying that
     * test here made every frame pass through untouched. Both spellings are
     * accepted; the bare form is what the tests drive.
     *
     * @returns {Array} the messages to write, in order — never empty.
     */
    function repairOutbound(outer) {
        if (!outer || typeof outer !== 'object') return [outer];
        if (debugShapes) noteShape(outer);

        if (outer.type === 'from-extension' && outer.message && typeof outer.message === 'object') {
            const inners = repairEnvelope(outer.message);
            if (inners.length === 1 && inners[0] === outer.message) return [outer];
            return inners.map((inner) => ({ ...outer, message: inner }));
        }
        return repairEnvelope(outer);
    }

    /** Repair one message in its unwrapped `io_message` / `response` form. */
    function repairEnvelope(outer) {
        if (!outer || typeof outer !== 'object') return [outer];

        if (outer.type === 'io_message') {
            const frame = outer.message;
            if (!frame || typeof frame !== 'object') return [outer];
            if (frame.type === 'stream_event' && frame.event) return handleStreamEvent(outer, frame);
            if (frame.type === 'assistant') {
                const repaired = repairAssistantFrame(frame, live, !streamed.has(streamKey(frame)));
                return [repaired === frame ? outer : { ...outer, message: repaired }];
            }
            if (frame.type === 'result') {
                const extra = flushOpen();
                if (extra.length) {
                    write(`[cjk-emphasis] WARN: ${extra.length} block(s) ended without a stop; tail released at result`);
                }
                reportTurn();
                return [...extra, outer];
            }
            return [outer];
        }

        if (outer.type === 'response' && outer.response && Array.isArray(outer.response.messages)) {
            let changed = false;
            let frames = 0;
            const before = replay.closer + replay.opener;
            const messages = outer.response.messages.map((frame) => {
                if (!frame || typeof frame !== 'object' || frame.type !== 'assistant') return frame;
                frames++;
                const repaired = repairAssistantFrame(frame, replay, true);
                if (repaired !== frame) changed = true;
                return repaired;
            });
            // A replay gets its own line rather than going through reportTurn().
            // It is not a turn — one `get_session` response can carry a whole
            // session's history — and it arrives whenever the webview mounts or
            // reloads, which can be in the middle of a live turn. Sharing
            // reportTurn() meant a replay landing there zeroed the live turn's
            // counters and its stream bookkeeping, so the live repairs were
            // attributed to the replay's line and then counted a second time off
            // the batch frame: the 2x this file already closed once, back through
            // a different door.
            //
            // Reported whether or not anything changed, for the same reason the
            // live path is: a replay that silently stops being repaired would
            // otherwise look exactly like a replay that needed nothing.
            if (frames > 0) {
                const repairs = replay.closer + replay.opener - before;
                write(
                    `[cjk-emphasis] replay: ${repairs === 0 ? 'no repairs' : `repaired ${repairs}`} ` +
                    `over ${frames} assistant frames; ` +
                    `session live ${live.closer + live.opener} / ${live.blocks} blocks, ` +
                    `replay ${replay.closer + replay.opener} / ${replay.blocks} blocks`,
                );
            }
            if (!changed) return [outer];
            return [{ ...outer, response: { ...outer.response, messages } }];
        }

        return [outer];
    }

    return { repairOutbound, stats: () => ({ live: { ...live }, replay: { ...replay } }) };
}

module.exports = { createEmphasisRepairer };
