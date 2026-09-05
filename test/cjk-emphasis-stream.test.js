'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const { createEmphasisRepairer } = require('../Resources/vscode-shim/cjk-emphasis-stream.js');
const { repairMarkdown } = require('../Resources/vscode-shim/cjk-emphasis.js');

function makeRepairer() {
    const logs = [];
    const r = createEmphasisRepairer({ write: (line) => logs.push(line) });
    return { ...r, logs };
}

const io = (frame) => ({ type: 'io_message', message: frame });
const streamEvent = (event, parent) => io({
    type: 'stream_event',
    parent_tool_use_id: parent === undefined ? null : parent,
    session_id: 's1',
    event,
});
const start = (index, parent) => streamEvent({ type: 'content_block_start', index, content_block: { type: 'text', text: '' } }, parent);
const delta = (index, text, parent) => streamEvent({ type: 'content_block_delta', index, delta: { type: 'text_delta', text } }, parent);
const stop = (index, parent) => streamEvent({ type: 'content_block_stop', index }, parent);
const result = () => io({ type: 'result', subtype: 'success' });

/** Everything the webview's assembler would append for block `index`. */
function assembled(outputs, index) {
    let text = '';
    for (const out of outputs) {
        const ev = out.message && out.message.event;
        if (!ev || ev.type !== 'content_block_delta' || ev.index !== index) continue;
        if (ev.delta && ev.delta.type === 'text_delta') text += ev.delta.text;
    }
    return text;
}

/** Drive one text block through the repairer with the given chunking. */
function stream(repairer, chunks, index = 0, parent = null) {
    const outputs = [];
    const push = (m) => outputs.push(...repairer.repairOutbound(m));
    push(start(index, parent));
    for (const chunk of chunks) push(delta(index, chunk, parent));
    push(stop(index, parent));
    return outputs;
}

test('a streamed block assembles to the repaired text', () => {
    const r = makeRepairer();
    const outputs = stream(r, ['これは**注意。', '**次の文です。']);
    assert.strictEqual(assembled(outputs, 0), 'これは**注意**。次の文です。');
});

test('the held-back tail is released as a delta ahead of content_block_stop', () => {
    const r = makeRepairer();
    // The trailing 。 cannot be emitted until the stream proves nothing follows.
    const outputs = stream(r, ['**注意。']);
    const kinds = outputs.map((o) => o.message.event.type);
    assert.deepStrictEqual(kinds, [
        'content_block_start',
        'content_block_delta', // "**注意"
        'content_block_delta', // "。" — synthetic, carries the tail
        'content_block_stop',
    ]);
    assert.strictEqual(assembled(outputs, 0), '**注意。');
});

test('the assembled text does not depend on the delta boundaries', () => {
    const text = 'まず**手順。**次に`code`を実行。**「引用」**を含む段落。';
    const expected = repairMarkdown(text);
    for (let cut = 0; cut <= text.length; cut++) {
        const r = makeRepairer();
        const outputs = stream(r, [text.slice(0, cut), text.slice(cut)]);
        assert.strictEqual(assembled(outputs, 0), expected, `cut=${cut}`);
    }
    const perChar = makeRepairer();
    const outputs = stream(perChar, [...text]);
    assert.strictEqual(assembled(outputs, 0), expected, 'per-character');
});

test('two blocks of one message do not share a scanner', () => {
    // The shape a multi-block reply takes. With one scanner across both, block
    // 0's held 。 is released into block 1's frame.
    const r = makeRepairer();
    const outputs = [];
    const push = (m) => outputs.push(...r.repairOutbound(m));
    push(start(0, null));
    push(start(1, null));
    push(delta(0, 'ひとつ目の**注意。', null));
    push(delta(1, 'ふたつ目の文。', null));
    push(delta(0, '**続き', null));
    push(stop(1, null));
    push(stop(0, null));
    assert.strictEqual(assembled(outputs, 0), 'ひとつ目の**注意**。続き');
    assert.strictEqual(assembled(outputs, 1), 'ふたつ目の文。');
});

test('a subagent stream and the main stream do not share a scanner', () => {
    // NOTE: `parent_tool_use_id` is measured to be hardcoded null on every
    // `stream_event` the CLI emits, so this fixture drives a shape the wire does
    // not currently produce. It pins the KEY, not the wire: if a future CLI
    // starts stamping the field, two interleaved scanners must not merge.
    const r = makeRepairer();
    const outputs = [];
    const push = (m) => outputs.push(...r.repairOutbound(m));
    push(start(0, null));
    push(start(0, 'toolu_sub'));
    push(delta(0, '本文の**強調。', null));
    push(delta(0, '子の文。', 'toolu_sub'));
    push(delta(0, '**続き', null));
    push(stop(0, 'toolu_sub'));
    push(stop(0, null));

    const main = outputs.filter((o) => o.message.parent_tool_use_id === null);
    const sub = outputs.filter((o) => o.message.parent_tool_use_id === 'toolu_sub');
    assert.strictEqual(assembled(main, 0), '本文の**強調**。続き');
    assert.strictEqual(assembled(sub, 0), '子の文。');
});

test('message_stop releases only its own stream', () => {
    const r = makeRepairer();
    const outputs = [];
    const push = (m) => outputs.push(...r.repairOutbound(m));
    push(start(0, null));
    push(delta(0, '主**注意。', null));
    push(start(0, 'toolu_sub'));
    push(delta(0, '子**注意。', 'toolu_sub'));
    push(streamEvent({ type: 'message_stop' }, 'toolu_sub'));

    const sub = outputs.filter((o) => o.message.parent_tool_use_id === 'toolu_sub');
    const main = outputs.filter((o) => o.message.parent_tool_use_id === null);
    assert.strictEqual(assembled(sub, 0), '子**注意。', 'the ended stream is released');
    assert.strictEqual(assembled(main, 0), '主**注意', 'the still-running stream keeps its tail');
});

test('a turn ending at `result` releases every block still open', () => {
    // An interrupted reply gets no content_block_stop and no message_stop.
    // Without a drain here the held tail is dropped from the user's transcript.
    const r = makeRepairer();
    const outputs = [];
    const push = (m) => outputs.push(...r.repairOutbound(m));
    push(start(0, null));
    push(delta(0, 'これは**注意。', null));
    push(result());
    assert.strictEqual(assembled(outputs, 0), 'これは**注意。');
    assert.ok(r.logs.some((l) => l.includes('WARN')), 'the anomaly is logged');
});

test('a stale block does not leak into the next turn', () => {
    const r = makeRepairer();
    const first = [];
    const pushFirst = (m) => first.push(...r.repairOutbound(m));
    pushFirst(start(0, null));
    pushFirst(delta(0, 'ターン1**注意。', null));
    pushFirst(result());

    const second = [];
    const pushSecond = (m) => second.push(...r.repairOutbound(m));
    pushSecond(delta(0, '新しい話です', null)); // no start: the lazy-create path
    pushSecond(stop(0, null));
    assert.strictEqual(assembled(first, 0), 'ターン1**注意。');
    assert.strictEqual(assembled(second, 0), '新しい話です');
});

test('a reused block index releases the block it replaces', () => {
    const r = makeRepairer();
    const outputs = [];
    const push = (m) => outputs.push(...r.repairOutbound(m));
    push(start(0, null));
    push(delta(0, '前の**注意。', null));
    push(start(0, null)); // same index again, previous block never stopped
    push(delta(0, 'あたらしい文', null));
    push(stop(0, null));
    assert.strictEqual(assembled(outputs, 0), '前の**注意。あたらしい文');
});

test('a text block with no content_block_start is still repaired', () => {
    // Guards the one failure mode that would be invisible: if the repairer
    // required a start event it had never seen, a change in what the extension
    // forwards would turn the whole feature into a silent no-op.
    const r = makeRepairer();
    const outputs = [];
    const push = (m) => outputs.push(...r.repairOutbound(m));
    push(delta(0, '**注意。', null));
    push(delta(0, '**次', null));
    push(stop(0, null));
    assert.strictEqual(assembled(outputs, 0), '**注意**。次');
});

test('thinking deltas and non-text blocks pass through untouched', () => {
    const r = makeRepairer();
    // A `text` payload on a foreign delta type: only the type check saves it.
    const thinking = streamEvent({
        type: 'content_block_delta',
        index: 0,
        delta: { type: 'thinking_delta', type_is_not_text: true, text: '**考え。**次', thinking: '**考え。**次' },
    }, null);
    assert.deepStrictEqual(r.repairOutbound(thinking), [thinking]);

    const toolUse = streamEvent({ type: 'content_block_start', index: 1, content_block: { type: 'tool_use' } }, null);
    assert.deepStrictEqual(r.repairOutbound(toolUse), [toolUse]);
    // What this pins is that the frames pass through by identity. It does NOT
    // pin the `content_block.type === 'text'` guard: a freshly created rewriter
    // is empty, so a tool_use block acquiring one is indistinguishable from the
    // lazy creation the delta path already does. Measured — deleting that guard
    // leaves the whole suite green.
    const toolDelta = streamEvent({
        type: 'content_block_delta',
        index: 1,
        delta: { type: 'input_json_delta', partial_json: '{"a":"**注意。**次"}' },
    }, null);
    assert.deepStrictEqual(r.repairOutbound(toolDelta), [toolDelta]);
});

test('a batch assistant frame is repaired without being mutated', () => {
    const r = makeRepairer();
    const frame = io({
        type: 'assistant',
        parent_tool_use_id: null,
        message: { id: 'm1', content: [{ type: 'text', text: '**注意。**次' }] },
    });
    const [out] = r.repairOutbound(frame);
    assert.strictEqual(out.message.message.content[0].text, '**注意**。次');
    // The extension keeps its own reference to what it posted.
    assert.strictEqual(frame.message.message.content[0].text, '**注意。**次');
    // Nothing streamed this turn, so the batch frame is what renders and counts.
    assert.deepStrictEqual(r.stats().live, { closer: 1, opener: 0, blocks: 1 });
});

test('the batch assistant frame is not counted twice when the same text streamed', () => {
    // The CLI emits both the deltas and a whole assistant frame for one reply.
    // Counting both reported one repair as two.
    const r = makeRepairer();
    stream(r, ['**注意。**次']);
    r.repairOutbound(io({
        type: 'assistant',
        parent_tool_use_id: null,
        message: { id: 'm1', content: [{ type: 'text', text: '**注意。**次' }] },
    }));
    r.repairOutbound(result());
    assert.deepStrictEqual(r.stats().live, { closer: 1, opener: 0, blocks: 1 });
    assert.match(r.logs.at(-1), /turn: repaired 1 \(1 closer, 0 opener\) in 1 blocks/);
});

test('history replay is repaired through the response envelope', () => {
    const r = makeRepairer();
    const response = {
        type: 'response',
        response: {
            messages: [
                { type: 'user', message: { content: [{ type: 'text', text: '**そのまま。**触らない' }] } },
                { type: 'assistant', message: { content: [{ type: 'text', text: '**注意。**次' }] } },
            ],
        },
    };
    const [out] = r.repairOutbound(response);
    assert.strictEqual(out.response.messages[1].message.content[0].text, '**注意**。次');
    // A user frame is the human's own text and is never rewritten — and the
    // fixture uses the real array-shaped content, so the type check is what
    // saves it rather than the shape check bailing out first.
    assert.strictEqual(out.response.messages[0].message.content[0].text, '**そのまま。**触らない');
    // Tallied into `replay`, not `live` — the two are reported separately
    // because a replay covers a whole history and a turn covers one message.
    assert.deepStrictEqual(r.stats().replay, { closer: 1, opener: 0, blocks: 1 });
    assert.deepStrictEqual(r.stats().live, { closer: 0, opener: 0, blocks: 0 });
});

test('a clean replay still reports, so silence can only mean "never ran"', () => {
    const r = makeRepairer();
    r.repairOutbound({
        type: 'response',
        response: { messages: [{ type: 'assistant', message: { content: [{ type: 'text', text: '**正しい**：壊れない' }] } }] },
    });
    assert.strictEqual(r.logs.length, 1);
    assert.match(r.logs[0], /^\[cjk-emphasis\] replay: no repairs over 1 assistant frames;/);
});

test('a replay landing mid-turn does not resegment or double-count the live turn', () => {
    // `get_session` arrives whenever the webview mounts or reloads, which can be
    // in the middle of a live turn. Sharing the turn accumulator meant the live
    // repairs were attributed to the replay's line and then counted a second
    // time off the batch frame.
    const r = makeRepairer();
    const push = (m) => r.repairOutbound(m);
    push(start(0, null));
    push(delta(0, '**注意。**次', null));
    push(fromExtension({
        type: 'response',
        response: { messages: [{ type: 'assistant', message: { content: [{ type: 'text', text: '過去の**記録。**あと' }] } }] },
    }));
    push(stop(0, null));
    push(io({
        type: 'assistant',
        parent_tool_use_id: null,
        message: { id: 'm1', content: [{ type: 'text', text: '**注意。**次' }] },
    }));
    push(result());

    assert.deepStrictEqual(r.stats().live, { closer: 1, opener: 0, blocks: 1 }, 'the live span is counted once');
    assert.deepStrictEqual(r.stats().replay, { closer: 1, opener: 0, blocks: 1 });
    assert.match(r.logs[0], /^\[cjk-emphasis\] replay: repaired 1 over 1 assistant frames;/);
    assert.match(r.logs[1], /^\[cjk-emphasis\] turn: repaired 1 \(1 closer, 0 opener\) in 1 blocks;/);
});

test('a subagent batch frame is counted even while the main stream is running', () => {
    // Subagent text arrives ONLY as batch frames. A single "did anything stream"
    // flag for the whole process left every subagent repair uncounted while the
    // log said `no repairs` — the tally contradicting the text it had rewritten.
    const r = makeRepairer();
    r.repairOutbound(start(0, null));
    r.repairOutbound(delta(0, '本文です', null));
    r.repairOutbound(io({
        type: 'assistant',
        parent_tool_use_id: 'toolu_sub',
        message: { id: 'm2', content: [{ type: 'text', text: '子の**注意。**次' }] },
    }));
    r.repairOutbound(stop(0, null));
    r.repairOutbound(result());
    assert.deepStrictEqual(r.stats().live, { closer: 1, opener: 0, blocks: 1 });
    assert.match(r.logs[0], /turn: repaired 1 /);
});

test('the turn tally logs once per result', () => {
    const r = makeRepairer();
    stream(r, ['**注意。**次と**「引用」**を含む']);
    assert.deepStrictEqual(r.logs, [], 'nothing is logged before the turn ends');

    r.repairOutbound(result());
    assert.strictEqual(r.logs.length, 1);
    // Repairs, not spans: a span that fails at both ends increments both counters.
    assert.match(r.logs[0], /^\[cjk-emphasis\] turn: repaired 3 \(2 closer, 1 opener\) in 1 blocks;/);
    assert.match(r.logs[0], /session live 3 \/ 1 blocks, replay 0 \/ 0 blocks$/);
});

test('a clean turn still reports', () => {
    const r = makeRepairer();
    stream(r, ['**正しい**：壊れない']);
    r.repairOutbound(result());
    assert.strictEqual(r.logs.length, 1);
    assert.match(r.logs[0], /^\[cjk-emphasis\] turn: no repairs; session live 0 \/ 0 blocks/);
});

test('the session total accumulates across turns', () => {
    const r = makeRepairer();
    stream(r, ['**注意。**次'], 0);
    r.repairOutbound(result());
    stream(r, ['**結論、**そして'], 1);
    r.repairOutbound(result());

    assert.match(r.logs[1], /turn: repaired 1 \(1 closer, 0 opener\) in 1 blocks/);
    assert.match(r.logs[1], /session live 2 \/ 2 blocks/);
    assert.deepStrictEqual(r.stats().live, { closer: 2, opener: 0, blocks: 2 });
});

// The shapes below are transcribed from a real session's dump
// (CANOPY_CJK_DEBUG=1): `outer=from-extension inner=io_message frame=result` and
// its siblings. Deriving the envelope from the webview's own handler instead is
// one layer short — that handler destructures `from-extension` before its
// `m.type === 'io_message'` test — and that mistake made the repair a silent
// no-op on the first build that shipped it, with the arm line still saying
// everything was fine.
const fromExtension = (inner) => ({ type: 'from-extension', message: inner });

test('the real from-extension envelope is unwrapped and rewrapped', () => {
    const r = makeRepairer();
    const outputs = [];
    const push = (m) => outputs.push(...r.repairOutbound(m));
    push(fromExtension(start(0, null)));
    push(fromExtension(delta(0, 'これは**注意。', null)));
    push(fromExtension(delta(0, '**次', null)));
    push(fromExtension(stop(0, null)));

    for (const out of outputs) {
        assert.strictEqual(out.type, 'from-extension', 'the envelope must survive');
    }
    const inner = outputs.map((o) => o.message);
    assert.strictEqual(assembled(inner, 0), 'これは**注意**。次');
});

test('a result inside the envelope still ends the turn', () => {
    const r = makeRepairer();
    for (const m of [start(0, null), delta(0, '**注意。**次', null), stop(0, null)]) {
        r.repairOutbound(fromExtension(m));
    }
    r.repairOutbound(fromExtension(result()));
    assert.strictEqual(r.logs.length, 1);
    assert.match(r.logs[0], /turn: repaired 1 /);
});

test('replay inside the envelope is repaired', () => {
    const r = makeRepairer();
    const [out] = r.repairOutbound(fromExtension({
        type: 'response',
        response: { messages: [{ type: 'assistant', message: { content: [{ type: 'text', text: '**注意。**次' }] } }] },
    }));
    assert.strictEqual(out.type, 'from-extension');
    assert.strictEqual(out.message.response.messages[0].message.content[0].text, '**注意**。次');
});

test('CANOPY_CJK_DEBUG names the CLI frame, not just the envelope', () => {
    const previous = process.env.CANOPY_CJK_DEBUG;
    process.env.CANOPY_CJK_DEBUG = '1';
    try {
        const r = makeRepairer();
        r.repairOutbound(fromExtension(delta(0, 'x', null)));
        r.repairOutbound(fromExtension(stop(0, null)));
        assert.match(r.logs[0], /outer=from-extension inner=io_message frame=stream_event event=content_block_delta delta=text_delta/);
        assert.match(r.logs[1], /event=content_block_stop$/);
    } finally {
        if (previous === undefined) delete process.env.CANOPY_CJK_DEBUG;
        else process.env.CANOPY_CJK_DEBUG = previous;
    }
});

test('unrelated messages are forwarded by identity', () => {
    const r = makeRepairer();
    for (const m of [null, 'text', { type: 'init_response' }, { type: 'io_message' }]) {
        assert.deepStrictEqual(r.repairOutbound(m), [m]);
    }
});
