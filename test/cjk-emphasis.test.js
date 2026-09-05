'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const {
    CJKEmphasisRewriter,
    repairMarkdown,
} = require('../Resources/vscode-shim/cjk-emphasis.js');

/** Feed `text` through the rewriter split at the given absolute offsets. */
function repairChunked(text, cuts) {
    const rewriter = new CJKEmphasisRewriter();
    let out = '';
    let prev = 0;
    for (const cut of cuts) {
        out += rewriter.feed(text.slice(prev, cut));
        prev = cut;
    }
    out += rewriter.feed(text.slice(prev));
    return out + rewriter.end();
}

// A deterministic PRNG so a fuzz failure is reproducible from its seed alone.
function mulberry32(seed) {
    return function next() {
        seed |= 0;
        seed = (seed + 0x6d2b79f5) | 0;
        let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

// ---------------------------------------------------------------------------
// The five shapes the checker's own corpus reports, in their real proportions:
// the preceding character was 。 in 5129 cases, then 、 335 / — 222 / 」 131 /
// ） 63. Every one of these renders as a literal ** today.
// ---------------------------------------------------------------------------
const BROKEN = [
    ['**注意。**次の文が続く', '**注意**。次の文が続く'],
    ['**結論、**そして先へ', '**結論**、そして先へ'],
    ['**設計—**その理由', '**設計**—その理由'],
    // A span ending in a closing bracket is the one shape where the repair is a
    // visible compromise: the bracket lands outside the bold. Pulling the
    // matching opener out with it (「**引用**」) would read better but needs the
    // span's start, which streaming has already emitted by then — buying it back
    // means holding every bold span until it closes. 131 of 5880 measured cases.
    ['**「引用」**を含む場合', '**「引用**」を含む場合'],
    ['**（補足）**のあとに続く', '**（補足**）のあとに続く'],
    ['**結論：**これは壊れる', '**結論**：これは壊れる'],
];

// The mirror defect. An OPENER dies the same way a closer does: left-flanking
// needs the following character not to be punctuation unless the preceding one
// is, so `は**「` cannot open. At the start of a line the preceding boundary
// counts as whitespace, which is why the same span opens fine there — the bug
// only shows mid-sentence.
const BROKEN_OPENER = [
    ['いまの掃除は**「仕上げる」動作**に紐づく', 'いまの掃除は「**仕上げる」動作**に紐づく'],
    // Both ends fail here, so both repairs fire and the parentheses end up
    // outside the bold — where a human would have typed them.
    ['結果は**（未定）**のまま', '結果は（**未定**）のまま'],
];

test('repairs the opener CommonMark refuses to accept', () => {
    for (const [input, expected] of BROKEN_OPENER) {
        assert.strictEqual(repairMarkdown(input), expected, `input: ${input}`);
    }
});

test('repairs both ends of a span that fails on each', () => {
    // Both repairs firing on one span is what puts the brackets where a human
    // would have typed them.
    assert.strictEqual(
        repairMarkdown('その話は**「引用」**を含む'),
        'その話は「**引用**」を含む',
    );
});

test('repairs the closer CommonMark refuses to accept', () => {
    for (const [input, expected] of BROKEN) {
        assert.strictEqual(repairMarkdown(input), expected, `input: ${input}`);
    }
});

// ---------------------------------------------------------------------------
// The rewrite is meaning-preserving only because it never fires on text that
// already renders. Anything here must come back byte-identical.
// ---------------------------------------------------------------------------
const UNTOUCHED = [
    '**正しい書き方**：これは壊れない',
    '**行末なら。**',                       // followed by end of text -> right-flanking
    '**段落末なら。**\n\n次の段落',          // followed by a newline -> right-flanking
    '**Note:** English keeps its space',    // followed by a space -> right-flanking
    'これは**太字**です。',
    '（**太字**）を囲む',                    // the OPENER is preceded by punctuation
    '**A**と**B**と**C**を並べる',
    'グロブは **/*.swift と書く',
    '素の * と ** は触らない',
    '***三重***は避ける',
    '**空**',
    '2 ** 8 は 256',
];

test('leaves already-rendering text byte-identical', () => {
    for (const input of UNTOUCHED) {
        assert.strictEqual(repairMarkdown(input), input, `input: ${input}`);
    }
});

// ---------------------------------------------------------------------------
// Code is the one thing a text rewrite must never reach.
// ---------------------------------------------------------------------------
const CODE = [
    '```python\ndef f(**kwargs):\n    pass\n```\n',
    '```\n**注意。**次\n```\n',
    'インラインの `**注意。**次` はそのまま',
    'まず **説明。**続けて `**kwargs` を渡す',
    '~~~\n**注意。**次\n~~~\n',
    '````\n```\n**注意。**次\n```\n````\n',
];

test('never rewrites inside fenced or inline code', () => {
    assert.strictEqual(repairMarkdown(CODE[0]), CODE[0]);
    assert.strictEqual(repairMarkdown(CODE[1]), CODE[1]);
    assert.strictEqual(repairMarkdown(CODE[2]), CODE[2]);
    assert.strictEqual(repairMarkdown(CODE[4]), CODE[4]);
    assert.strictEqual(repairMarkdown(CODE[5]), CODE[5]);
    // Prose outside the span is still repaired, and the backticked text is not.
    assert.strictEqual(
        repairMarkdown(CODE[3]),
        'まず **説明**。続けて `**kwargs` を渡す',
    );
});

// ---------------------------------------------------------------------------
// The streaming contract. This is the property the whole design exists to buy:
// a delta boundary may fall anywhere, including between the two asterisks of a
// closer or between a 。 and the ** that follows it.
// ---------------------------------------------------------------------------
const CORPUS = [
    ...BROKEN.map(([input]) => input),
    ...BROKEN_OPENER.map(([input]) => input),
    'その話は**「引用」**を含む',
    ...UNTOUCHED,
    ...CODE,
    '**手順。**まず `npm test` を実行する。**次に。**ビルドする。\n\n' +
        '```sh\nnpm test  # **kwargs ではない\n```\n\n' +
        '結果は**成功**。**注意：**この行だけ壊れる。',
];

test('output does not depend on where the chunk boundaries fall', () => {
    for (const text of CORPUS) {
        const whole = repairMarkdown(text);
        // Every single-cut split, including the two halves of a `**` run.
        for (let cut = 0; cut <= text.length; cut++) {
            assert.strictEqual(
                repairChunked(text, [cut]),
                whole,
                `text=${JSON.stringify(text)} cut=${cut}`,
            );
        }
        // One character at a time — the worst case a slow stream can produce.
        const perChar = Array.from({ length: text.length }, (_, k) => k);
        assert.strictEqual(repairChunked(text, perChar), whole, `text=${JSON.stringify(text)} per-char`);
    }
});

test('fuzz: random multi-cut splits agree with the whole-string result', () => {
    const rand = mulberry32(0x5eed);
    for (const text of CORPUS) {
        const whole = repairMarkdown(text);
        for (let trial = 0; trial < 200; trial++) {
            const cuts = [];
            for (let k = 1; k < text.length; k++) {
                if (rand() < 0.25) cuts.push(k);
            }
            assert.strictEqual(
                repairChunked(text, cuts),
                whole,
                `text=${JSON.stringify(text)} cuts=${cuts}`,
            );
        }
    }
});

// ---------------------------------------------------------------------------
// Guards against a repair that would be worse than the defect.
// ---------------------------------------------------------------------------
test('declines a rewrite that would produce a worse marker', () => {
    // An all-punctuation span would collapse into a four-asterisk run.
    assert.strictEqual(repairMarkdown('**。**次'), '**。**次');
    // Moving the run would leave the closer preceded by a space, still unclosable.
    assert.strictEqual(repairMarkdown('**注意 。**次'), '**注意 。**次');
});

test('treats Unicode symbols as punctuation, the way CommonMark 0.31 does', () => {
    // Regression, found by rendering 26,855 real transcript blocks: `＝` is
    // category Sm. Under the pre-0.31 definition (\p{P} only) the opener here
    // looks like it never opened, and the opener repair then fires on the real
    // closer and destroys a paragraph that rendered perfectly.
    const text = 'その値は＝**.5 の余白**（既定）。';
    assert.strictEqual(repairMarkdown(text), text);
});

test('a blank line ends the span rather than carrying it into the next paragraph', () => {
    const text = '**開いたまま\n\n次の段落。**続き';
    assert.strictEqual(repairMarkdown(text), text);
});

test('holds back only a short tail while streaming', () => {
    const rewriter = new CJKEmphasisRewriter();
    const emitted = rewriter.feed('これは長い前置きの文章で、**注意。');
    // Everything up to the span's trailing punctuation is already out.
    assert.strictEqual(emitted, 'これは長い前置きの文章で、**注意');
    assert.strictEqual(rewriter.buf, '。');
    assert.strictEqual(rewriter.feed('**次'), '**。次');
});
