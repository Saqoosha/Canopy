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

test('a subagent stream and the main stream do not share a scanner', () => {
    const r = makeRepairer();
    const outputs = [];
    const push = (m) => outputs.push(...r.repairOutbound(m));
    push(start(0, null));
    push(start(0, 'toolu_sub'));
    // Interleaved: the main block opens a span, the subagent's text must not
    // be read as being inside it.
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

test('message_stop releases a block that never got its own stop', () => {
    const r = makeRepairer();
    const outputs = [];
    const push = (m) => outputs.push(...r.repairOutbound(m));
    push(start(0, null));
    push(delta(0, '**注意。', null));
    push(streamEvent({ type: 'message_stop' }, null));
    assert.strictEqual(assembled(outputs, 0), '**注意。');
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
    const thinking = streamEvent({
        type: 'content_block_delta',
        index: 0,
        delta: { type: 'thinking_delta', thinking: '**考え。**次' },
    }, null);
    assert.deepStrictEqual(r.repairOutbound(thinking), [thinking]);

    const toolUse = streamEvent({ type: 'content_block_start', index: 1, content_block: { type: 'tool_use' } }, null);
    assert.deepStrictEqual(r.repairOutbound(toolUse), [toolUse]);
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
});

test('history replay is repaired through the response envelope', () => {
    const r = makeRepairer();
    const response = {
        type: 'response',
        response: {
            messages: [
                { type: 'user', message: { content: '**そのまま。**触らない' } },
                { type: 'assistant', message: { content: [{ type: 'text', text: '**注意。**次' }] } },
            ],
        },
    };
    const [out] = r.repairOutbound(response);
    assert.strictEqual(out.response.messages[1].message.content[0].text, '**注意**。次');
    // A user frame is the human's own text and is never rewritten.
    assert.strictEqual(out.response.messages[0].message.content, '**そのまま。**触らない');
});

test('the turn tally logs once per result', () => {
    const r = makeRepairer();
    stream(r, ['**注意。**次と**「引用」**を含む']);
    assert.deepStrictEqual(r.logs, [], 'nothing is logged before the turn ends');

    r.repairOutbound(io({ type: 'result', subtype: 'success' }));
    assert.strictEqual(r.logs.length, 1);
    assert.match(r.logs[0], /^\[cjk-emphasis\] turn: repaired 3 spans \(2 closer, 1 opener\) in 1 blocks;/);
    assert.match(r.logs[0], /session live 3 spans \/ 1 blocks, replay 0 spans \/ 0 blocks$/);
});

test('a clean turn still reports, so silence can only mean "never ran"', () => {
    const r = makeRepairer();
    stream(r, ['**正しい**：壊れない']);
    r.repairOutbound(io({ type: 'result', subtype: 'success' }));
    assert.strictEqual(r.logs.length, 1);
    assert.match(r.logs[0], /^\[cjk-emphasis\] turn: no repairs; session live 0 spans \/ 0 blocks/);
});

test('the session total accumulates across turns', () => {
    const r = makeRepairer();
    stream(r, ['**注意。**次'], 0);
    r.repairOutbound(io({ type: 'result', subtype: 'success' }));
    stream(r, ['**結論、**そして'], 1);
    r.repairOutbound(io({ type: 'result', subtype: 'success' }));

    assert.match(r.logs[1], /turn: repaired 1 spans \(1 closer, 0 opener\) in 1 blocks/);
    assert.match(r.logs[1], /session live 2 spans \/ 2 blocks/);
    assert.deepStrictEqual(r.stats().live, { closer: 2, opener: 0, blocks: 2 });
});

// The shapes below are transcribed from a real session's dump
// (CANOPY_CJK_DEBUG=1): `outer=from-extension inner=io_message deeper=result`
// and its siblings. Deriving the envelope from the webview's own code instead
// is one layer short — ShimProcess strips `from-extension` on the way through —
// and that mistake made the repair a silent no-op on the first build that
// shipped it, with the arm line still saying everything was fine.
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
    r.repairOutbound(fromExtension(io({ type: 'result', subtype: 'success' })));
    assert.strictEqual(r.logs.length, 1);
    assert.match(r.logs[0], /turn: repaired 1 spans/);
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

test('unrelated messages are forwarded by identity', () => {
    const r = makeRepairer();
    for (const m of [null, 'text', { type: 'init_response' }, { type: 'io_message' }]) {
        assert.deepStrictEqual(r.repairOutbound(m), [m]);
    }
});
