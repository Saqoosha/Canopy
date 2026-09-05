'use strict';

// End-to-end through the real shim module. The two suites either side of this
// one prove the algorithm and the frame layer in isolation; neither would
// notice if `window.js` stopped calling the repairer, or called it and dropped
// the extra frame it can return. This drives the actual
// `webview.postMessage` and reads what would have gone down the pipe to Canopy.

const { test } = require('node:test');
const assert = require('node:assert');

const protocol = require('../Resources/vscode-shim/protocol.js');
const { createWindow } = require('../Resources/vscode-shim/window.js');

/** Resolve a provider so `activeView` exists, and capture its webview. */
function bootWebview() {
    const window = createWindow();
    let webview = null;
    window.registerWebviewViewProvider('claude.chat', {
        resolveWebviewView(view) { webview = view.webview; },
    });
    window._activateFirstProvider();
    assert.ok(webview, 'provider did not receive a view');
    return webview;
}

/** Everything written to stdout while `fn` runs, parsed back out of NDJSON. */
function captureStdout(fn) {
    const lines = [];
    protocol._setWriter((data) => lines.push(data));
    try {
        fn();
    } finally {
        protocol._setWriter((data) => process.stdout.write(data));
    }
    return lines.map((line) => JSON.parse(line));
}

// The real, measured envelope. Driving the bare `io_message` form here would
// leave `repairOutbound`'s `from-extension` branch unpinned by the only suite
// that exercises `window.js` — deleting that branch would keep every wiring
// test green while production went back to forwarding frames untouched.
const streamEvent = (event) => ({
    type: 'from-extension',
    message: {
        type: 'io_message',
        message: { type: 'stream_event', parent_tool_use_id: null, session_id: 's1', event },
    },
});

/** The CLI frame inside a written `webview_message`, past both envelopes. */
const frameOf = (written) => written.message.message.message;

test('the shim repairs a streamed reply on its way to the webview', () => {
    const webview = bootWebview();
    const written = captureStdout(() => {
        webview.postMessage(streamEvent({
            type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' },
        }));
        webview.postMessage(streamEvent({
            type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'これは**注意。' },
        }));
        webview.postMessage(streamEvent({
            type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '**次の文です。' },
        }));
        webview.postMessage(streamEvent({ type: 'content_block_stop', index: 0 }));
    });

    for (const msg of written) {
        assert.strictEqual(msg.type, 'webview_message', 'wrong envelope on the wire');
    }

    // Reassemble the way the webview's own assembler does.
    let text = '';
    for (const msg of written) {
        const event = frameOf(msg).event;
        if (event.type === 'content_block_delta' && event.delta.type === 'text_delta') {
            text += event.delta.text;
        }
    }
    assert.strictEqual(text, 'これは**注意**。次の文です。');
});

test('a block whose tail is still held gets an extra frame on the wire', () => {
    const webview = bootWebview();
    const written = captureStdout(() => {
        webview.postMessage(streamEvent({
            type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' },
        }));
        // The trailing 。 cannot be released until the stream proves nothing
        // follows it, so the stop must be preceded by a synthetic delta.
        webview.postMessage(streamEvent({
            type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '**注意。' },
        }));
        webview.postMessage(streamEvent({ type: 'content_block_stop', index: 0 }));
    });

    assert.strictEqual(written.length, 4, 'three posts must produce four frames');
    assert.deepStrictEqual(
        written.map((m) => frameOf(m).event.type),
        ['content_block_start', 'content_block_delta', 'content_block_delta', 'content_block_stop'],
    );
    assert.strictEqual(frameOf(written[2]).event.delta.text, '。');
});

test('a message the repairer has no opinion about is written unchanged', () => {
    const webview = bootWebview();
    const message = { type: 'init_response', response: { authStatus: null } };
    const written = captureStdout(() => webview.postMessage(message));
    assert.deepStrictEqual(written, [{ type: 'webview_message', message }]);
});

test('CANOPY_DISABLE_CJK_EMPHASIS_REPAIR=1 forwards frames untouched', () => {
    const previous = process.env.CANOPY_DISABLE_CJK_EMPHASIS_REPAIR;
    process.env.CANOPY_DISABLE_CJK_EMPHASIS_REPAIR = '1';
    try {
        const webview = bootWebview(); // the flag is read each time a view asks for the repairer
        const broken = streamEvent({
            type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '**注意。**次' },
        });
        const written = captureStdout(() => {
            webview.postMessage(streamEvent({
                type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' },
            }));
            webview.postMessage(broken);
        });
        assert.strictEqual(frameOf(written[1]).event.delta.text, '**注意。**次');
    } finally {
        if (previous === undefined) delete process.env.CANOPY_DISABLE_CJK_EMPHASIS_REPAIR;
        else process.env.CANOPY_DISABLE_CJK_EMPHASIS_REPAIR = previous;
    }
});
