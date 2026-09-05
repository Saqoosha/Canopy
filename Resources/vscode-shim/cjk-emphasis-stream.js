/**
 * Frame layer for the CJK emphasis repair: applies `cjk-emphasis.js` to the
 * messages the extension sends the webview, and keeps the tally that answers
 * "how much is this actually fixing".
 *
 * Everything bound for the webview passes through `webview.postMessage`, which
 * makes it the single place both delivery paths can be covered at once:
 *
 *   live      { type: "io_message", message: <CLI frame> }
 *   replay    { type: "response", response: { messages: [<CLI frame>, ...] } }
 *
 * Live text arrives as `stream_event` / `content_block_delta` / `text_delta`
 * chunks, so a streaming rewriter is held per text block, keyed by
 * `parent_tool_use_id` and the block index — a subagent's stream interleaves
 * with the main one and the two must not share a scanner. Replay arrives as
 * whole `assistant` frames and is repaired in one call.
 *
 * A block's rewriter holds back a few characters that a later chunk could still
 * change (see the streaming contract in cjk-emphasis.js), so `content_block_stop`
 * has to release that tail. There is no field on the stop event to carry text,
 * so the tail goes out as one synthetic `content_block_delta` ahead of the stop:
 * the webview's assembler appends delta text to the block it is building, which
 * makes an extra delta indistinguishable from a slower stream.
 *
 * Frames are never mutated. The extension keeps its own references to what it
 * posted, so a repaired frame is a shallow copy down the path that changed.
 */

'use strict';

const { CJKEmphasisRewriter, repairCounted } = require('./cjk-emphasis.js');

function createEmphasisRepairer(options) {
    const opts = options || {};
    const write = opts.write || ((line) => process.stderr.write(line + '\n'));

    // key -> rewriter, for text blocks currently streaming.
    const open = new Map();
    const live = { closer: 0, opener: 0, blocks: 0 };
    const replay = { closer: 0, opener: 0, blocks: 0 };
    const turn = { closer: 0, opener: 0, blocks: 0 };

    const keyOf = (frame, index) => `${frame.parent_tool_use_id || 'main'}#${index}`;

    // CANOPY_CJK_DEBUG=1 names every distinct message shape that reaches this
    // function, once each. The envelope the extension actually posts is
    // documented nowhere, and reading it wrong turns the whole repair into a
    // silent pass-through — which is exactly what happened the first time this
    // shipped. One line per shape is bounded no matter how long a session runs.
    const debugShapes = process.env.CANOPY_CJK_DEBUG === '1';
    const seenShapes = new Set();

    function noteShape(outer) {
        const inner = outer.message && typeof outer.message === 'object' ? outer.message : null;
        const deeper = inner && inner.message && typeof inner.message === 'object' ? inner.message : null;
        const shape = [
            `outer=${outer.type}`,
            inner ? `inner=${inner.type}` : 'inner=-',
            inner && inner.event ? `event=${inner.event.type}` : '',
            deeper && deeper.type ? `deeper=${deeper.type}` : '',
        ].filter(Boolean).join(' ');
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
    // likely to have and least able to notice. A turn is one user message, so
    // the line is not on a hot path, and the running totals ride along so the
    // most recent line always carries the whole answer.
    function reportTurn() {
        const spans = turn.closer + turn.opener;
        const what = spans === 0
            ? 'no repairs'
            : `repaired ${spans} spans (${turn.closer} closer, ${turn.opener} opener) in ${turn.blocks} blocks`;
        write(
            `[cjk-emphasis] turn: ${what}; ` +
            `session live ${live.closer + live.opener} spans / ${live.blocks} blocks, ` +
            `replay ${replay.closer + replay.opener} spans / ${replay.blocks} blocks`,
        );
        turn.closer = 0;
        turn.opener = 0;
        turn.blocks = 0;
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

    function repairAssistantFrame(frame, target) {
        const msg = frame.message;
        if (!msg || !Array.isArray(msg.content)) return frame;
        let closer = 0;
        let opener = 0;
        const content = msg.content.map((block) => {
            if (!block || block.type !== 'text' || typeof block.text !== 'string') return block;
            const r = repairCounted(block.text);
            if (r.text === block.text) return block;
            closer += r.closer;
            opener += r.opener;
            return { ...block, text: r.text };
        });
        if (closer === 0 && opener === 0) return frame;
        noteBlock(target, closer, opener);
        noteBlock(turn, closer, opener);
        return { ...frame, message: { ...msg, content } };
    }

    /** Release every still-open block for this frame's stream, newest state first. */
    function flushOpen(outer, frame) {
        const prefix = `${frame.parent_tool_use_id || 'main'}#`;
        const extra = [];
        for (const [key, rewriter] of [...open.entries()]) {
            if (!key.startsWith(prefix)) continue;
            open.delete(key);
            const tail = rewriter.end();
            noteBlock(live, rewriter.repairs.closer, rewriter.repairs.opener);
            noteBlock(turn, rewriter.repairs.closer, rewriter.repairs.opener);
            if (tail) extra.push(deltaFrame(outer, frame, Number(key.slice(prefix.length)), tail));
        }
        return extra;
    }

    function handleStreamEvent(outer, frame) {
        const event = frame.event;
        const index = event.index;

        if (event.type === 'content_block_start') {
            if (event.content_block && event.content_block.type === 'text') {
                open.set(keyOf(frame, index), new CJKEmphasisRewriter());
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
            let rewriter = open.get(key);
            if (!rewriter) {
                rewriter = new CJKEmphasisRewriter();
                open.set(key, rewriter);
            }
            const emitted = rewriter.feed(delta.text);
            if (emitted === delta.text) return [outer];
            return [deltaFrame(outer, frame, index, emitted)];
        }

        if (event.type === 'content_block_stop') {
            const key = keyOf(frame, index);
            const rewriter = open.get(key);
            if (!rewriter) return [outer];
            open.delete(key);
            const tail = rewriter.end();
            noteBlock(live, rewriter.repairs.closer, rewriter.repairs.opener);
            noteBlock(turn, rewriter.repairs.closer, rewriter.repairs.opener);
            return tail ? [deltaFrame(outer, frame, index, tail), outer] : [outer];
        }

        if (event.type === 'message_stop') {
            // Defensive: a block that never got its stop would strand its tail.
            return [...flushOpen(outer, frame), outer];
        }

        return [outer];
    }

    /**
     * Repair one outbound webview message.
     *
     * The extension posts unsolicited traffic inside a `from-extension`
     * envelope — measured, `outer=from-extension inner=io_message deeper=result`
     * and friends. The webview sees a bare `io_message` because ShimProcess
     * strips that layer on the way through, so reading the shape off the
     * webview's own code (which is where this was first derived) is one layer
     * short and makes every frame pass through untouched. Both spellings are
     * accepted: the bare form is what the tests drive and what a future
     * unwrapped post would look like.
     *
     * @returns {Array} the messages to write, in order — usually just the input.
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
                const repaired = repairAssistantFrame(frame, live);
                return [repaired === frame ? outer : { ...outer, message: repaired }];
            }
            if (frame.type === 'result') {
                reportTurn();
                return [outer];
            }
            return [outer];
        }

        if (outer.type === 'response' && outer.response && Array.isArray(outer.response.messages)) {
            let changed = false;
            const messages = outer.response.messages.map((frame) => {
                if (!frame || typeof frame !== 'object' || frame.type !== 'assistant') return frame;
                const repaired = repairAssistantFrame(frame, replay);
                if (repaired !== frame) changed = true;
                return repaired;
            });
            if (!changed) return [outer];
            reportTurn(); // replay is a turn's worth of history in one message
            return [{ ...outer, response: { ...outer.response, messages } }];
        }

        return [outer];
    }

    return { repairOutbound, stats: () => ({ live: { ...live }, replay: { ...replay } }) };
}

module.exports = { createEmphasisRepairer };
