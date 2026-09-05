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
 * It fires ONLY when the original would actually break, so text that already
 * renders correctly passes through byte-identical. The opener fails the mirror
 * way — `は**「引用」**を` dies at BOTH ends — and the leading bracket moves out
 * too, landing the pair as `は「**引用**」を`.
 *
 * MEASURED against 25,163 Japanese assistant text blocks from ~/.claude
 * transcripts, judged by rendering each block with micromark (the engine behind
 * the webview's renderer) and counting the ** that survive into the HTML
 * outside <code>: 1,664 blocks showed a literal ** and 31 still do, 5,148 stray
 * runs down to 66, 1,641 blocks improved, 0 made worse, and every block came
 * back with the same multiset of characters it went in with.
 *
 * KNOWN LIMIT, and it is structural rather than a bug to fix: CommonMark pairs
 * delimiters with a stack over the whole paragraph, and a streaming rewriter
 * cannot see the rest of the paragraph. This scanner pairs naively instead, so
 * where the two disagree a repair can fire in the wrong place — that is how the
 * two regressions found at 26,855 blocks arose, one from reading `。` as a span
 * opener and one from an out-of-date punctuation class. Both classes are closed
 * (see OPENING_BRACKET and isPunct) and the measured count is now zero, but zero
 * measured is not zero possible. A DOM pass over the rendered output cannot have
 * this failure mode at all, because it only ever touches the ** a renderer has
 * already refused to consume.
 *
 * STREAMING CONTRACT: feed() accepts arbitrary chunk splits, and the
 * concatenation of every feed() plus the final end() does not depend on where
 * those splits fell. That is bought by refusing to emit any suffix whose
 * meaning a later character could still change — a `*` run that may still be
 * growing, a punctuation run that may turn out to precede a closer, an
 * unresolved backtick run. Everything else is emitted immediately, so the
 * held-back tail is a few characters and never a whole line.
 *
 * Code is never rewritten: fenced blocks and inline code pass through verbatim
 * and suppress all emphasis bookkeeping, so a glob or a Python **kwargs sitting
 * inside them cannot be touched.
 */

'use strict';

// CommonMark "Unicode whitespace" is space, tab, newline, form feed, carriage
// return plus the Zs category; JavaScript's own `\s` is that set plus U+FEFF,
// which no assistant text carries. Spelling the class out by hand is a trap:
// U+2028 and U+2029 are line terminators in JavaScript source, so a literal one
// inside a regex literal is a syntax error rather than a class member.
const WS = /\s/;
const ASCII_PUNCT = /[!-/:-@[-`{-~]/;

// `undefined` means "past the boundary". CommonMark treats the start and end of
// the document as whitespace, never as punctuation — which is exactly why
// `**注意。**` at the end of a paragraph renders fine and needs no repair.
const isWS = (c) => c === undefined || WS.test(c);
// CommonMark 0.31 widened "Unicode punctuation" to include the SYMBOL
// categories, and micromark — the engine behind the webview's renderer —
// follows it. Testing \p{P} alone is the older definition and it is not a
// harmless approximation: it makes `＝**.x y**（z）` look like a span that never
// opened, which then invites the opener repair to fire on the real closer and
// break a paragraph that rendered perfectly. Measured, once, on a 26,855-block
// corpus. \p{S} also sweeps in emoji (So), which is what the spec says.
const isPunct = (c) => c !== undefined && (ASCII_PUNCT.test(c) || /[\p{P}\p{S}]/u.test(c));
const isPlain = (c) => c !== undefined && !isWS(c) && !isPunct(c);

// Opening brackets and initial quotes (Ps, Pi): 「『（【〈《〔〖〘〚［｛ and the
// ASCII ones. The opener repair is restricted to these rather than to
// punctuation at large, and the restriction is what removes a measured
// regression: `強調**。続き` is a well-formed CLOSER followed by a full stop,
// and it is locally indistinguishable from a failed opener. Nothing in real
// prose starts a bold span with 。 or 、 , so declining them costs nothing and
// stops the repair firing on a closer whose opener this scanner lost track of.
const OPENING_BRACKET = /[\p{Ps}\p{Pi}]/u;

class CJKEmphasisRewriter {
    constructor() {
        this.buf = '';
        this.lastChar = undefined;  // last character already emitted
        this.atLineStart = true;
        this.prevWasNewline = false;
        this.inFence = false;
        this.fenceChar = '';
        this.fenceLen = 0;
        this.codeTicks = 0;         // backtick-run length while inside inline code
        this.bold = false;
        this.spanHasPlain = false;  // span content holds a non-punct, non-ws char
        // One repair === one span that would otherwise have rendered its
        // markers literally, so these are the "how much did this fix" numbers.
        this.repairs = { closer: 0, opener: 0 };
    }

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
        if (s) this.lastChar = s[s.length - 1];
        return s;
    }

    _drain(final) {
        let out = '';
        let i = 0;
        const buf = this.buf;
        const n = buf.length;

        // Stop and wait for more input; everything from `i` onward stays buffered.
        const need = () => { this.buf = buf.slice(i); return out; };
        const take = (j) => { const s = buf.slice(i, j); i = j; return this._emit(s); };

        while (i < n) {
            const ch = buf[i];

            // ---- inside a fenced block: verbatim until the closing fence ----
            if (this.inFence) {
                if (this.atLineStart) {
                    const close = /^ {0,3}([`~]{3,})[ \t]*(\n|$)/.exec(buf.slice(i));
                    if (close && (close[2] === '\n' || final)) {
                        if (close[1][0] === this.fenceChar && close[1].length >= this.fenceLen) {
                            this.inFence = false;
                        }
                        out += take(i + close[0].length);
                        this.atLineStart = true;
                        continue;
                    }
                    // A line that starts like a fence but whose end has not
                    // arrived: waiting beats guessing, and such lines are short.
                    if (!final && /^ {0,3}[`~]*$/.test(buf.slice(i))) return need();
                }
                const nl = buf.indexOf('\n', i);
                if (nl === -1) { out += take(n); this.atLineStart = false; break; }
                out += take(nl + 1);
                this.atLineStart = true;
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
                if (ch === '\n' && this.prevWasNewline) this.codeTicks = 0; // unterminated
                this.prevWasNewline = ch === '\n';
                if (this.bold) this.spanHasPlain = true;
                this.atLineStart = ch === '\n';
                out += take(i + 1);
                continue;
            }

            // ---- an opening fence ----------------------------------------------
            if (this.atLineStart) {
                const open = /^ {0,3}([`~]{3,})/.exec(buf.slice(i));
                if (open) {
                    if (i + open[0].length >= n && !final) return need(); // run may grow
                    this.inFence = true;
                    this.fenceChar = open[1][0];
                    this.fenceLen = open[1].length;
                    this.bold = false;
                    this.spanHasPlain = false;
                    this.atLineStart = false;
                    out += take(i + open[0].length);
                    continue;
                }
                // Three backticks may still be arriving one character at a time.
                if (!final && /[`~]/.test(buf.slice(i)) && /^ {0,3}[`~]*$/.test(buf.slice(i))) {
                    return need();
                }
            }

            // ---- a backtick run opens inline code --------------------------------
            if (ch === '`') {
                let j = i;
                while (j < n && buf[j] === '`') j++;
                if (j === n && !final) return need();
                this.codeTicks = j - i;
                this.atLineStart = false;
                out += take(j);
                continue;
            }

            // ---- a punctuation run inside a span: the repair site -----------------
            if (this.bold && isPunct(ch) && ch !== '*') {
                let p = i;
                while (p < n && isPunct(buf[p]) && buf[p] !== '*' && buf[p] !== '`') p++;
                if (p === n && !final) return need(); // the run may still grow
                if (buf[p] === '*') {
                    let j = p;
                    while (j < n && buf[j] === '*') j++;
                    if (j === n && !final) return need(); // the `*` run may still grow
                    const after = j < n ? buf[j] : undefined;
                    const beforeRun = i > 0 ? buf[i - 1] : this.lastChar;
                    // `breaks` is the right-flanking test failing. `safe` keeps
                    // the rewrite from producing something worse: an all-
                    // punctuation span would collapse to `****`, and a span
                    // ending in a space stays unclosable after the move.
                    const breaks = isPlain(after);
                    // After the move the closer is followed by the punctuation
                    // that used to precede it, and `isPunct(after)` alone
                    // satisfies right-flanking — so `beforeRun` may be
                    // punctuation itself (a span ending in `code`, say). The one
                    // thing it may not be is whitespace, which no move can fix,
                    // or the opener's own `*`, which would collapse an
                    // all-punctuation span into a four-asterisk run.
                    const safe = !isWS(beforeRun) && beforeRun !== '*';
                    if (j - p === 2 && breaks && safe) {
                        out += this._emit('**' + buf.slice(i, p));
                        this.repairs.closer++;
                        this.bold = false;
                        this.spanHasPlain = false;
                        this.atLineStart = false;
                        i = j;
                        continue;
                    }
                }
                this.atLineStart = false;
                out += take(p);
                continue;
            }

            // ---- an asterisk run ---------------------------------------------------
            if (ch === '*') {
                let j = i;
                while (j < n && buf[j] === '*') j++;
                if (j === n && !final) return need();
                const after = j < n ? buf[j] : undefined;
                const before = i > 0 ? buf[i - 1] : this.lastChar;
                if (j - i === 2) {
                    if (this.bold) {
                        this.bold = false;
                        this.spanHasPlain = false;
                    } else if (!isWS(after) && (!isPunct(after) || isWS(before) || isPunct(before))) {
                        this.bold = true; // left-flanking, so it can open
                        this.spanHasPlain = false;
                    } else if (OPENING_BRACKET.test(after) && !isWS(before)) {
                        // The mirror defect: an opener dies the same way a
                        // closer does. `は**「引用」**を` fails on BOTH ends —
                        // left-flanking needs the following character not to be
                        // punctuation unless the preceding one is. Moving the
                        // leading punctuation run outside the span revives it,
                        // and the closer repair above then handles the other
                        // end, so the pair lands as `「**引用**」を`.
                        let q = j;
                        while (q < n && OPENING_BRACKET.test(buf[q])) q++;
                        if (q === n && !final) return need(); // the run may still grow
                        const next = q < n ? buf[q] : undefined;
                        if (!isWS(next)) {
                            out += this._emit(buf.slice(j, q) + '**');
                            this.repairs.opener++;
                            this.bold = true;
                            this.spanHasPlain = false;
                            this.atLineStart = false;
                            i = q;
                            continue;
                        }
                    }
                } else {
                    // `*`, `***`, `****`: emphasis and strong overlap here and the
                    // pairing stops being obvious. Drop out rather than guess.
                    this.bold = false;
                    this.spanHasPlain = false;
                }
                this.atLineStart = false;
                out += take(j);
                continue;
            }

            // ---- an ordinary character -----------------------------------------------
            if (ch === '\n') {
                // A blank line ends the paragraph, and with it any open span.
                if (this.prevWasNewline) { this.bold = false; this.spanHasPlain = false; }
                this.prevWasNewline = true;
                this.atLineStart = true;
            } else {
                this.prevWasNewline = false;
                this.atLineStart = false;
                if (this.bold && isPlain(ch)) this.spanHasPlain = true;
            }
            out += take(i + 1);
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
