/**
 * Streaming repair for CJK strong-emphasis that CommonMark refuses to close.
 *
 * CommonMark only lets a `**` run CLOSE a span when the run is right-flanking:
 *
 *     !isWS(before) && (!isPunct(before) || isWS(after) || isPunct(after))
 *
 * Japanese prose has no inter-word spaces, so `**注意。**次` has before='。'
 * (punctuation) and after='次' (neither space nor punctuation). The run cannot
 * close, the opener is left unpaired, and both markers render literally. The
 * same text with a space after the closer renders correctly, which is why this
 * is effectively a CJK-only defect.
 *
 * The repair moves the trailing punctuation run outside the span:
 *
 *     **注意。**次   ->   **注意**。次
 *
 * The opener fails the mirror way — `は**「引用」**を` dies at BOTH ends — and
 * the leading bracket moves out too, landing the pair as `は「**引用**」を`.
 *
 * It fires only where the LOCAL flanking test fails, so text that renders today
 * comes through byte-identical except where KNOWN LIMITS says otherwise — the
 * local test and CommonMark's paragraph-wide pairing can disagree, and this
 * scanner does not see every construct that ends a paragraph.
 *
 * MEASURED against 25,285 Japanese assistant text blocks from ~/.claude
 * transcripts, judged by rendering each with micromark (the engine behind the
 * webview's renderer) and counting the ** that survive into the HTML outside
 * <code>: 1,696 blocks showed a literal ** and 37 still do, 5,247 stray runs
 * down to 77, 1,667 blocks improved, 0 made worse, and every block came back
 * with the same multiset of characters it went in with. The corpus is a live
 * directory that grows between runs, so the totals drift by a few blocks and
 * the harness is not committed — it reads the user's own transcripts — so
 * these figures cannot be re-derived from the repo. What IS re-derivable is in
 * `test/cjk-emphasis.test.js`, which pins the multiset and split-invariance
 * properties over generated text.
 *
 * STREAMING CONTRACT: feed() accepts arbitrary chunk splits, and the
 * concatenation of every feed() plus the final end() does not depend on where
 * those splits fell. That is bought by refusing to emit any suffix whose
 * meaning a later character could still change — a `*` run that may still be
 * growing, a punctuation run that may turn out to precede a closer, an
 * unresolved backtick run, a fence line whose end has not arrived, half a
 * surrogate pair. Everything else is emitted immediately, so the held-back tail
 * is short: bounded by the current line, and in prose by a few characters.
 *
 * WHAT IS NOT TOUCHED: fenced blocks (``` and ~~~) at the start of a line, up
 * to three spaces of indent; inline code spans; and link destinations between a
 * `](` and its `)`. All three pass through verbatim and suppress emphasis
 * bookkeeping. Only NON-ASCII punctuation is ever moved, so ASCII structure — a
 * link's `)`, an HTML tag's `>`, a `]` — stays where the model put it even when
 * it sits inside a repaired span.
 *
 * KNOWN LIMITS, none fixed:
 *  - CommonMark pairs delimiters with a stack over the whole paragraph, and a
 *    streaming rewriter cannot see the rest of the paragraph. This scanner
 *    pairs naively instead, so where the two disagree a repair can fire in the
 *    wrong place. Two classes were found and closed — one pairing ambiguity
 *    (OPENING_BRACKET) and one classification mismatch with micromark (PUNCT);
 *    zero measured is not zero possible. A DOM pass over the rendered output
 *    cannot have this failure mode at all, because it only ever touches the **
 *    a renderer has already refused to consume.
 *  - The only paragraph boundary this scanner sees is a blank line. An ATX
 *    heading, a thematic break, a list marker or a blockquote also end one, and
 *    an open span survives them — so a repair can fire in a following paragraph
 *    that renders correctly. Derived from the code, not observed in the corpus
 *    (0 regressions over 26,983 blocks). Recognising them needs a block parser,
 *    which is a different piece of software from this one.
 *  - A fence indented four or more spaces (one inside a list item) is not a
 *    fence to this scanner, and neither is an indented code block. Their
 *    contents can be rewritten. Same reason.
 *  - A repair can fire without making anything render: on an unpaired `**`
 *    (`章**「補足」だけ` -> `章「**補足」だけ`), or on a paired span whose other
 *    end the guards then refuse to move (`これは**（※）**の扱い` ->
 *    `これは（**※）**の扱い`). Characters move, the markers stay literal.
 */

'use strict';

// CommonMark "Unicode whitespace" is space, tab, newline, form feed, carriage
// return plus the Zs category. JavaScript's own `\s` is that set plus U+FEFF,
// U+000B and the Zl/Zp line separators — none of which appear in assistant
// text. Spelling the class out by hand is a trap: U+2028 and U+2029 are line
// terminators in JavaScript source, so a literal one inside a regex literal is
// a syntax error rather than a class member.
const WS = /\s/;

// CommonMark 0.31 widened "Unicode punctuation" to include the SYMBOL
// categories, and micromark — the engine behind the webview's renderer —
// follows it. Testing \p{P} alone is the older definition and it is not a
// harmless approximation: it makes `＝**.x y**（z）` look like a span that never
// opened, which then invites the opener repair to fire on the real closer and
// break a paragraph that rendered perfectly. Measured, once, on the same corpus
// as the MEASURED paragraph above, counted unfiltered by language: 26,983 blocks
// against its 25,285 Japanese ones. The class subsumes every ASCII punctuation
// character (measured), so no separate ASCII test is needed.
const PUNCT = /[\p{P}\p{S}]/u;

// Only NON-ASCII punctuation is ever moved out of a span. Every preceding
// character measured in the corpus is non-ASCII (。 5129, 、 335, — 222, 」 131,
// ） 63), and the restriction is what keeps a repair from dragging structure
// out with it: `**[リンク](https://example.com)。**次` would otherwise become
// `**[リンク](https://example.com**)。次`, a working link to a 404 — strictly
// worse than the literal ** it was fixing.
const ASCII = /[\x00-\x7F]/;

// Opening brackets and initial quotes (Ps, Pi), non-ASCII only: 「『（【〈《〔
// 〖〘〚［｛ and friends. Two restrictions, each closing a measured failure.
// Punctuation at large is wrong because `強調**。続き` is a well-formed CLOSER
// followed by a full stop and is locally indistinguishable from a failed
// opener; nothing in real prose starts a bold span with 。 or 、 , so declining
// them costs nothing. ASCII is wrong because `[` is also Ps, and moving it out
// of `これは**[ドキュメント](./doc.md)**を` breaks the link. What the ASCII half
// does decline is `**"引用"**` — ASCII quotes are Po, so they were never in this
// class anyway, but `**(補足)**` mid-sentence now goes unrepaired.
const OPENING_BRACKET = /[\p{Ps}\p{Pi}]/u;

const isWS = (c) => c === undefined || WS.test(c);
const isPunct = (c) => c !== undefined && PUNCT.test(c);
const isPlain = (c) => c !== undefined && !isWS(c) && !isPunct(c);
const isMovable = (c) => c !== undefined && !ASCII.test(c) && PUNCT.test(c);
const isOpeningBracket = (c) => c !== undefined && !ASCII.test(c) && OPENING_BRACKET.test(c);

const isHighSurrogate = (code) => code >= 0xd800 && code <= 0xdbff;

/**
 * The whole code point at `k`, so an astral character (an emoji is category So,
 * and therefore punctuation under CommonMark 0.31) is classified as itself
 * rather than as two lone surrogates — which are category Cs and would read as
 * plain, firing a repair on text that renders correctly.
 */
function codePointAt(s, k) {
    if (k < 0 || k >= s.length) return undefined;
    if (isHighSurrogate(s.charCodeAt(k)) && k + 1 < s.length) {
        const next = s.charCodeAt(k + 1);
        if (next >= 0xdc00 && next <= 0xdfff) return s.slice(k, k + 2);
    }
    return s[k];
}

/** The last whole code point of `s`, for the same reason. */
function lastCodePoint(s) {
    if (!s) return undefined;
    const last = s.charCodeAt(s.length - 1);
    if (last >= 0xdc00 && last <= 0xdfff && s.length >= 2 && isHighSurrogate(s.charCodeAt(s.length - 2))) {
        return s.slice(-2);
    }
    return s[s.length - 1];
}

class CJKEmphasisRewriter {
    constructor() {
        this.buf = '';
        // The last code point actually EMITTED — which is the flanking context,
        // and is not the same thing as the character before the cursor in the
        // input. A repair reorders characters without going through `take`, so
        // after one has fired `buf[i - 1]` is a character the reader will never
        // see in that position. Reading it there let a closer repair fire
        // straight after an opener repair and collapse `これは**（※）**の扱い`
        // into `これは（****※）の扱い` — and, because the two disagree only
        // when a repair has already fired in the same drain, the result depended
        // on where the chunk boundary fell, which is the one property this file
        // exists to hold. Found independently by a fuzz over 60,000 texts and by
        // a hand trace; pinned by `test/cjk-emphasis.test.js`.
        this.lastChar = undefined;
        // Whether the line being emitted has held nothing but whitespace so far.
        // CommonMark ends a paragraph on a line that is EMPTY OR ALL WHITESPACE,
        // and testing only for two newlines in a row let an open span survive
        // `\n \n` and fire a repair in the next paragraph — turning
        // `**a\n \n注意。**強調**です`, whose second paragraph renders bold today,
        // into one with two literal markers. Maintained in `_emit` with
        // `lastChar`, so the two cannot disagree the way two stored flags did.
        this.lineIsBlank = true;
        this.inFence = false;
        this.fenceChar = '';
        this.fenceLen = 0;
        this.codeTicks = 0;         // backtick-run length while inside inline code
        this.inLinkDest = false;    // between a `](` and its `)`
        this.bold = false;
        // Repairs applied, for the per-turn tally. A span that fails at both
        // ends increments BOTH, so these are repair counts, not span counts.
        this.repairs = { closer: 0, opener: 0 };
    }

    // Derived from `lastChar` rather than stored, because two fields holding one
    // fact drift: the punctuation-run and backtick branches used to update
    // `atLineStart` and leave `prevWasNewline` stale, so `**注意\n、\n続き。**次`
    // read the second newline as a blank line, closed the span, and lost the
    // repair that the same text on one line receives.
    get atLineStart() { return this.lastChar === undefined || this.lastChar === '\n'; }

    /** Consume a chunk; returns the text that is safe to forward now. */
    feed(text) {
        this.buf += text;
        return this._drain(false);
    }

    /** End of the content block: nothing more can arrive, so release the tail. */
    end() {
        const out = this._drain(true);
        this.buf = '';
        return out;
    }

    _emit(s) {
        if (!s) return s;
        for (let k = 0; k < s.length; k++) {
            const c = s[k];
            if (c === '\n') this.lineIsBlank = true;
            else if (!WS.test(c)) this.lineIsBlank = false;
        }
        this.lastChar = lastCodePoint(s);
        return s;
    }

    _drain(final) {
        let out = '';
        let i = 0;
        const buf = this.buf;
        // A trailing high surrogate is half a character; scanning it as one
        // would classify it as plain. Hold it back until its partner arrives.
        const full = buf.length;
        const n = (!final && full > 0 && isHighSurrogate(buf.charCodeAt(full - 1))) ? full - 1 : full;

        // Stop and wait for more input; everything from `i` onward stays buffered.
        const need = () => { this.buf = buf.slice(i); return out; };
        const take = (j) => { const s = buf.slice(i, j); i = j; return this._emit(s); };

        while (i < n) {
            const ch = buf[i];

            // ---- inside a fenced block: verbatim until the closing fence ----
            if (this.inFence) {
                if (this.atLineStart) {
                    // The run must be one character repeated: CommonMark does
                    // not let ``` ~ close a backtick fence, and a mixed-run
                    // pattern accepted it as a four-character close, leaving the
                    // scanner rewriting the code that followed.
                    const close = /^ {0,3}(`{3,}|~{3,})[ \t]*(\n|$)/.exec(buf.slice(i, n));
                    if (close && (close[2] === '\n' || final)) {
                        if (close[1][0] === this.fenceChar && close[1].length >= this.fenceLen) {
                            this.inFence = false;
                        }
                        out += take(i + close[0].length);
                        continue;
                    }
                    // A line that starts like a fence but whose end has not
                    // arrived: waiting beats guessing, and such lines are short.
                    // The trailing `[ \t]*` matters — without it a chunk boundary
                    // inside a closing fence's trailing spaces made the scanner
                    // miss the fence for the rest of the block and rewrite the
                    // code inside it, differently depending on where the split
                    // fell (723 of 20,000 fence-shaped texts).
                    if (!final && /^ {0,3}[`~]*[ \t]*$/.test(buf.slice(i, n))) return need();
                }
                const nl = buf.indexOf('\n', i);
                if (nl === -1 || nl >= n) { out += take(n); break; }
                out += take(nl + 1);
                continue;
            }

            // ---- inside inline code: verbatim until a matching backtick run ----
            if (this.codeTicks > 0) {
                if (ch === '`') {
                    let j = i;
                    while (j < n && buf[j] === '`') j++;
                    if (j === n && !final) return need();
                    if (j - i === this.codeTicks) this.codeTicks = 0;
                    out += take(j);
                    continue;
                }
                if (ch === '\n' && this.lineIsBlank) this.codeTicks = 0; // unterminated
                out += take(i + codePointAt(buf, i).length);
                continue;
            }

            // ---- inside a link destination: verbatim until `)` ------------------
            // A URL is not prose. `[参照](https://example.com/**注意。**次)` was
            // repaired inside the parentheses, which leaves the label unchanged
            // and silently points it at a different address — the same class of
            // damage the non-ASCII restriction closes from the other side. Stops
            // at the first `)` or at the end of the line, which is what an inline
            // destination can contain anyway.
            if (this.inLinkDest) {
                if (ch === ')' || ch === '\n') this.inLinkDest = false;
                out += take(i + 1);
                continue;
            }
            if (ch === ']') {
                if (i + 1 >= n && !final) return need(); // is a `(` coming?
                if (buf[i + 1] === '(') {
                    this.inLinkDest = true;
                    out += take(i + 2);
                    continue;
                }
            }

            // ---- an opening fence ----------------------------------------------
            if (this.atLineStart) {
                const open = /^ {0,3}(`{3,}|~{3,})/.exec(buf.slice(i, n));
                if (open) {
                    if (i + open[0].length >= n && !final) return need(); // run may grow
                    this.inFence = true;
                    this.fenceChar = open[1][0];
                    this.fenceLen = open[1].length;
                    this.bold = false;
                    out += take(i + open[0].length);
                    continue;
                }
                // A fence may still be arriving one character at a time, and its
                // leading indent counts: a buffer of nothing but spaces has to
                // wait too, or the line stops being a line start and the fence
                // that follows is never recognised.
                if (!final && /^ {0,3}[`~]*$/.test(buf.slice(i, n))) return need();
            }

            // ---- a backtick run opens inline code --------------------------------
            if (ch === '`') {
                let j = i;
                while (j < n && buf[j] === '`') j++;
                if (j === n && !final) return need();
                this.codeTicks = j - i;
                out += take(j);
                continue;
            }

            // ---- a movable punctuation run inside a span: the repair site ---------
            if (this.bold && isMovable(codePointAt(buf, i))) {
                let p = i;
                for (;;) {
                    const c = codePointAt(buf, p);
                    if (p >= n || !isMovable(c)) break;
                    p += c.length;
                }
                if (p === n && !final) return need(); // the run may still grow
                if (buf[p] === '*') {
                    let j = p;
                    while (j < n && buf[j] === '*') j++;
                    if (j === n && !final) return need(); // the `*` run may still grow
                    const after = j < n ? codePointAt(buf, j) : undefined;
                    const beforeRun = this.lastChar;
                    // `breaks` is the right-flanking test failing. After the move
                    // the closer is followed by the punctuation that used to
                    // precede it, and `isPunct(after)` alone satisfies
                    // right-flanking — so `beforeRun` may be punctuation itself
                    // (a span ending in `code`, say). The one thing it may not be
                    // is whitespace, which no move can fix, or the opener's own
                    // `*`, which would collapse an all-punctuation span into a
                    // four-asterisk run.
                    const breaks = isPlain(after);
                    const safe = !isWS(beforeRun) && beforeRun !== '*';
                    if (j - p === 2 && breaks && safe) {
                        out += this._emit('**' + buf.slice(i, p));
                        this.repairs.closer++;
                        this.bold = false;
                        i = j;
                        continue;
                    }
                }
                out += take(p);
                continue;
            }

            // ---- an asterisk run ---------------------------------------------------
            if (ch === '*') {
                let j = i;
                while (j < n && buf[j] === '*') j++;
                if (j === n && !final) return need();
                const after = j < n ? codePointAt(buf, j) : undefined;
                const before = this.lastChar;
                if (j - i === 2) {
                    if (this.bold) {
                        this.bold = false;
                    } else if (!isWS(after) && (!isPunct(after) || isWS(before) || isPunct(before))) {
                        this.bold = true; // left-flanking, so it can open
                    } else if (isOpeningBracket(after)) {
                        // The mirror defect: an opener dies the same way a
                        // closer does. `は**「引用」**を` fails on BOTH ends —
                        // left-flanking needs the following character not to be
                        // punctuation unless the preceding one is. Moving the
                        // leading bracket run outside the span revives it, and
                        // the closer repair above then handles the other end, so
                        // the pair lands as `は「**引用**」を`.
                        let q = j;
                        for (;;) {
                            const c = codePointAt(buf, q);
                            if (q >= n || !isOpeningBracket(c)) break;
                            q += c.length;
                        }
                        if (q === n && !final) return need(); // the run may still grow
                        const next = q < n ? codePointAt(buf, q) : undefined;
                        // `next !== '*'` is the mirror of the closer's `safe`
                        // guard, and it was missing: `注**【**次` moved the
                        // bracket in front of an opener whose own run followed,
                        // producing `注【****次` — a four-asterisk run out of
                        // text that had none. `!isWS(next)` alone declines only
                        // the moves that cannot make anything render.
                        if (!isWS(next) && next !== '*') {
                            out += this._emit(buf.slice(j, q) + '**');
                            this.repairs.opener++;
                            this.bold = true;
                            i = q;
                            continue;
                        }
                    }
                } else {
                    // `*`, `***`, `****`: emphasis and strong overlap here and the
                    // pairing stops being obvious. Drop out rather than guess.
                    this.bold = false;
                }
                out += take(j);
                continue;
            }

            // ---- an ordinary character -----------------------------------------------
            // A blank line ends the paragraph, and with it any open span. Other
            // block starts end one too — an ATX heading, a thematic break, a list
            // marker — and this scanner does not recognise them; see KNOWN LIMITS.
            if (ch === '\n' && this.lineIsBlank) this.bold = false;
            // Take the WHOLE code point. Emitting one UTF-16 unit at a time left
            // `lastChar` holding a lone low surrogate after an astral character —
            // category Cs, which reads as plain — so `あ🎉**「引用」**を` fired an
            // opener repair it must not, and `🎉**「**x` produced a `****` run out
            // of text that had none.
            out += take(i + codePointAt(buf, i).length);
        }

        this.buf = buf.slice(i);
        return out;
    }
}

/** Whole strings, with the repair tally the log line reports. */
function repairCounted(text) {
    const rewriter = new CJKEmphasisRewriter();
    const out = rewriter.feed(text) + rewriter.end();
    return { text: out, closer: rewriter.repairs.closer, opener: rewriter.repairs.opener };
}

/** Convenience for whole strings (history replay, tests). */
function repairMarkdown(text) {
    return repairCounted(text).text;
}

module.exports = { CJKEmphasisRewriter, repairMarkdown, repairCounted, isWS, isPunct, isPlain };
