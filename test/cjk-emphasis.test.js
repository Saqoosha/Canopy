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

const sortedCodePoints = (s) => [...s].sort().join('');

// ---------------------------------------------------------------------------
// The shapes the checker's own corpus reports, in their real proportions: the
// preceding character was 。 in 5129 cases, then 、 335 / — 222 / 」 131 / ） 63,
// plus a `：` case that is the same defect with a different mark. Every one of
// these renders as a literal ** today.
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

test('repairs the closer CommonMark refuses to accept', () => {
    for (const [input, expected] of BROKEN) {
        assert.strictEqual(repairMarkdown(input), expected, `input: ${input}`);
    }
});

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
    assert.strictEqual(
        repairMarkdown('その話は**「引用」**を含む'),
        'その話は「**引用**」を含む',
    );
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
    // A well-formed CLOSER followed by a full stop. Locally identical to a
    // failed opener, which is why the opener repair is restricted to opening
    // brackets — relax that and this paragraph is destroyed.
    'これは強調**。続き',
    '見出し**：本文',
    '結果**、そして',
    // An emoji is category So, so CommonMark 0.31 counts it as punctuation and
    // the closer here is already right-flanking. The scanner walks UTF-16 code
    // units, so this only holds because it reassembles surrogate pairs before
    // classifying them.
    '**注意。**🎉',
    '**注意。**➕',                          // the same case inside the BMP
];

test('leaves already-rendering text byte-identical', () => {
    for (const input of UNTOUCHED) {
        assert.strictEqual(repairMarkdown(input), input, `input: ${input}`);
    }
});

// ---------------------------------------------------------------------------
// Only NON-ASCII punctuation is movable, which is what keeps a repair from
// dragging structure out of the span it is fixing.
// ---------------------------------------------------------------------------
test('never moves ASCII punctuation that carries structure', () => {
    // Moving the `)` would produce a working link to a 404 — strictly worse
    // than the literal ** it was fixing.
    assert.strictEqual(
        repairMarkdown('**[リンク](https://example.com)。**次の文'),
        '**[リンク](https://example.com)**。次の文',
    );
    assert.strictEqual(
        repairMarkdown('**HTML <b>tag</b>。**次'),
        '**HTML <b>tag</b>**。次',
    );
    // `[` is category Ps, so an opener repair unrestricted by ASCII would pull
    // it out of the link. Restricted, neither end is repaired and the text is
    // left alone: the opener cannot open whatever happens to the closer, so a
    // closer-only move would rearrange the sentence and still render a literal
    // `**`. Declining is the conservative outcome, not a missed case.
    const linkBoth = '詳細は**[ドキュメント](./doc.md)、**および';
    assert.strictEqual(repairMarkdown(linkBoth), linkBoth);
});

test('never rewrites inside a link destination', () => {
    // A URL is not prose. Repairing inside the parentheses leaves the label
    // unchanged and silently points it somewhere else.
    const url = '[参照](https://example.com/**注意。**次)';
    assert.strictEqual(repairMarkdown(url), url);
    // The suppression ends at the `)`, so prose after it is still repaired —
    // and a `](` that is not a link (an index followed by a call) costs only
    // the few characters up to its own `)`.
    assert.strictEqual(
        repairMarkdown('配列は a[i](値)。**注意。**次'),
        '配列は a[i](値)。**注意**。次',
    );
});

// ---------------------------------------------------------------------------
// Code is the one thing a text rewrite must never reach.
// ---------------------------------------------------------------------------
const CODE = [
    '```python\ndef f(**kwargs):\n    pass\n```\n',
    '```\n**注意。**次\n```\n',
    'インラインの `**注意。**次` はそのまま',
    // The one entry with prose OUTSIDE the code span, so it is not identity —
    // marked rather than skipped by index, which silently moves if an entry is
    // inserted above it.
    { text: 'まず **説明。**続けて `**kwargs` を渡す', repaired: 'まず **説明**。続けて `**kwargs` を渡す' },
    '~~~\n**注意。**次\n~~~\n',
    '````\n```\n**注意。**次\n```\n````\n',
    // A closing fence with trailing whitespace. A chunk boundary landing in
    // those spaces used to desynchronise `inFence` for the rest of the block.
    '```\ncode\n``` \n```\n**注意。**次\n```\n',
    '~~~\ncode\n~~~\t\n~~~\n**注意。**次\n~~~\n',
    // A fence indented up to three spaces is still a fence, and a chunk
    // boundary inside that indent must not make the line stop being a line
    // start.
    '  ```js\nconst x = 1;\n\n**注意。**次\n  ```\n',
    // CommonMark does not let ``` ~ close a backtick fence. A mixed-run pattern
    // accepted it as a four-character close and rewrote the code that followed.
    '```\ncode\n```~\n**注意。**次\n```\n',
    '~~~\ncode\n~~~`\n**注意。**次\n~~~\n',
    // A link destination, which is not prose either.
    '[参照](https://example.com/**注意。**次)',
];

test('never rewrites inside fenced or inline code', () => {
    for (const entry of CODE) {
        const input = typeof entry === 'string' ? entry : entry.text;
        const expected = typeof entry === 'string' ? entry : entry.repaired;
        assert.strictEqual(repairMarkdown(input), expected, `input: ${JSON.stringify(input)}`);
    }
});

// ---------------------------------------------------------------------------
// The streaming contract. This is the property the whole design exists to buy:
// a delta boundary may fall anywhere, including between the two asterisks of a
// closer, between a 。 and the ** that follows it, or inside a surrogate pair.
// ---------------------------------------------------------------------------
const CORPUS = [
    ...BROKEN.map(([input]) => input),
    ...BROKEN_OPENER.map(([input]) => input),
    'その話は**「引用」**を含む',
    ...UNTOUCHED,
    ...CODE.map((entry) => (typeof entry === 'string' ? entry : entry.text)),
    // Both repairs firing on one span: the opener repair rewrites the stream,
    // so the closer's flanking context is no longer the input character before
    // the cursor. Reading it there collapsed this into `これは（****※）の扱い`
    // — and only when the whole text arrived in one chunk.
    'これは**（※）**の扱い',
    '**[リンク](https://example.com)。**次の文',
    '**注意。**🎉と**続き。**🎉',
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

// The cut-position sweep above only varies WHERE a fixed corpus is split. The
// invariance break that shipped needed a text nobody had written down — an
// opener repair immediately followed by a punctuation-only span — so the corpus
// was the blind spot, not the cut positions. Generating the text as well is what
// found it.
test('fuzz: generated texts are split-invariant and preserve every character', () => {
    // Weighted by token CLASS, not a uniform alphabet. A flat 32-symbol
    // alphabet needs ~20,000 trials to land the one shape that matters —
    // [plain] ** [bracket] [movable] ** [plain] — so the first version was
    // decorative for the `****` collapse it was written to catch, and missed the
    // surrogate defect entirely. `**` and the brackets carry most of the weight
    // because every interesting branch needs at least one of each.
    const CLASSES = [
        [10, ['**']],
        [6, ['「', '」', '（', '）', '【', '】']],
        [6, ['。', '、', '：', '—', '…', '※']],
        [8, ['あ', '注', '意', 'x', '5']],
        [3, ['🎉', '😀', '➕', '＝']],
        [3, [' ', '\n']],
        [2, ['*', '***', '`', '``', '```', '~~~']],
        [2, ['[', ']', '(', ')', '<', '>']],
    ];
    const BAG = CLASSES.flatMap(([weight, tokens]) => tokens.flatMap((t) => Array(weight).fill(t)));
    const rand = mulberry32(0xc0ffee);
    for (let trial = 0; trial < 20000; trial++) {
        let text = '';
        const len = 4 + Math.floor(rand() * 14);
        for (let k = 0; k < len; k++) text += BAG[Math.floor(rand() * BAG.length)];

        const whole = repairMarkdown(text);
        assert.strictEqual(
            sortedCodePoints(whole),
            sortedCodePoints(text),
            `characters added or dropped: ${JSON.stringify(text)} -> ${JSON.stringify(whole)}`,
        );
        // A `****` run is never an improvement on whatever it replaced.
        if (!text.includes('****')) {
            assert.ok(
                !whole.includes('****'),
                `produced a four-asterisk run: ${JSON.stringify(text)} -> ${JSON.stringify(whole)}`,
            );
        }
        for (let cut = 1; cut < text.length; cut++) {
            assert.strictEqual(
                repairChunked(text, [cut]),
                whole,
                `split-dependent: ${JSON.stringify(text)} cut=${cut}`,
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
    // The opener repair fires first here; the closer must then see the `*` it
    // emitted, not the `（` that precedes the cursor in the input.
    assert.strictEqual(repairMarkdown('これは**（※）**の扱い'), 'これは（**※）**の扱い');
});

test('treats Unicode symbols as punctuation, the way CommonMark 0.31 does', () => {
    // Regression, found by rendering 26,963 real transcript blocks: `＝` is
    // category Sm. Under the pre-0.31 definition (\p{P} only) the opener here
    // looks like it never opened, and the opener repair then fires on the real
    // closer and destroys a paragraph that rendered perfectly.
    const text = 'その値は＝**.5 の余白**（既定）。';
    assert.strictEqual(repairMarkdown(text), text);
});

test('an astral character is flanking context, not two lone surrogates', () => {
    // The scanner walks UTF-16 code units. Emitting them one at a time left
    // `lastChar` holding a lone low surrogate — category Cs, which reads as
    // plain — so the opener repair fired on text that renders correctly, and
    // could produce a `****` run. `➕` is the control: same Unicode category
    // (So), inside the BMP, so only astrality differs.
    assert.strictEqual(repairMarkdown('あ🎉**「引用」**を'), 'あ🎉**「引用**」を');
    assert.strictEqual(repairMarkdown('あ➕**「引用」**を'), 'あ➕**「引用**」を');
    assert.strictEqual(repairMarkdown('🎉**「**x'), '🎉**「**x');
    const emojiSpan = '😀**.5 の余白**（既定）';
    assert.strictEqual(repairMarkdown(emojiSpan), emojiSpan);
});

test('the opener repair declines moves that gain nothing or collapse markers', () => {
    // `next !== '*'`: mirror of the closer's `safe` guard. Without it the
    // bracket lands in front of another `**` run and makes `****`.
    assert.strictEqual(repairMarkdown('注**【**次'), '注**【**次');
    assert.strictEqual(repairMarkdown('これは**（**続き'), 'これは**（**続き');
    // `!isWS(next)`: a bracket run with nothing after it, or whitespace after
    // it, cannot open whatever is done to it.
    assert.strictEqual(repairMarkdown('注意**「'), '注意**「');
    assert.strictEqual(repairMarkdown('これは**「 内容'), 'これは**「 内容');
    assert.strictEqual(repairMarkdown('これは**「\n次'), 'これは**「\n次');
});

test('an inline code span closes only on a backtick run of its own length', () => {
    const three = '`code```**注意。**次';
    assert.strictEqual(repairMarkdown(three), three);
    const mixed = 'a`x``` **注意。**次';
    assert.strictEqual(repairMarkdown(mixed), mixed);
});

test('an unclosed link destination stops suppressing at the end of the line', () => {
    // Without the newline terminator the suppression runs to the end of the
    // document and every later repair is silently declined.
    assert.strictEqual(repairMarkdown('[参照](\n**注意。**次'), '[参照](\n**注意**。次');
    assert.strictEqual(
        repairMarkdown('[参照](http://a\n**注意。**次'),
        '[参照](http://a\n**注意**。次',
    );
});

test('an open span is dropped at a fence and at an ambiguous asterisk run', () => {
    // A fence opening while a span is open clears it; otherwise the span
    // survives the code block and repairs the prose after it.
    const acrossFence = '**注意\n```\ncode\n```\n続き。**次';
    assert.strictEqual(repairMarkdown(acrossFence), acrossFence);
    // `***` and longer mix strong with emphasis, so the scanner drops out.
    const tripled = '**~~~*```注```「**注';
    assert.strictEqual(repairMarkdown(tripled), tripled);
});

test('a soft line break inside a paragraph does not end the span', () => {
    // Two fields once held the same fact — `atLineStart` and `prevWasNewline` —
    // and the punctuation-run branch updated only one, so the second newline
    // here read as a blank line and closed the span.
    assert.strictEqual(repairMarkdown('**注意\n、\n続き。**次'), '**注意\n、\n続き**。次');
    assert.strictEqual(repairMarkdown('**注意\n続き。**次'), '**注意\n続き**。次');
});

test('a whitespace-only line ends the paragraph, not just an empty one', () => {
    // CommonMark ends a paragraph on a line that is empty OR all whitespace.
    // Testing only for two newlines in a row let the span survive `\n \n` and
    // fire in the next paragraph, whose `**強調**` renders bold today — so the
    // repair turned correct output into two literal markers.
    const spaced = '**a\n \n注意。**強調**です';
    assert.strictEqual(repairMarkdown(spaced), spaced);
    const tabbed = '**a\n\t\n注意。**強調**です';
    assert.strictEqual(repairMarkdown(tabbed), tabbed);
    // An unterminated backtick inside the span reaches the blank line through
    // the inline-code branch, which has its own reset and has to clear `bold`
    // too — otherwise the span leaks through the one door the ordinary-character
    // branch does not cover.
    const backticked = '**a`未終了\n\n注意。**強調**です';
    assert.strictEqual(repairMarkdown(backticked), backticked);
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

test('holds back half a surrogate pair until its partner arrives', () => {
    const rewriter = new CJKEmphasisRewriter();
    const emoji = '🎉';
    assert.strictEqual(rewriter.feed('**注意。' + emoji[0]), '**注意');
    assert.strictEqual(rewriter.feed(emoji[1] + 'あと'), '。🎉あと');
});
