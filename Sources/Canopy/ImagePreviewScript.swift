import Foundation

/// Inline image previews for Read tool results.
///
/// The CC extension's webview renderer for the Read tool is `body() { return null }`,
/// so when Claude reads an image the base64 data reaches the webview inside the
/// tool_result block but nothing displays it — VSCode shows only the filename too
/// (the iOS app renders images through its own native UI, not this webview).
///
/// This injected script closes that gap without touching the extension bundle:
///  - listens to the same window.postMessage stream the webview app consumes
///    (live `io_message` events and `get_session_request` response replays),
///  - assigns every image-extension Read tool_use a per-file sequence number the
///    moment it appears, captures base64 image tool_results, and
///  - decorates the "Read <file>" summary rows in the DOM with their images,
///    pairing rows and sequence numbers tail-aligned so the webview evicting
///    old rendered history from the front can't shift the mapping
///    (click-to-zoom lightbox included).
///
/// Sequence numbers are allocated at tool_use time — before the result is known —
/// so a failed Read or a byte-budget eviction leaves a gap (that row simply stays
/// undecorated) instead of shifting every later thumbnail onto the wrong row.
/// Replay re-deliveries are deduplicated by tool_use_id (no double-count, no seq
/// shift).
///
/// It matches DOM rows by semantics (a `summary` starting with "Read" containing
/// an anchor whose text is the file basename), never by minified identifiers or
/// hashed CSS class names, so extension minification churn between versions
/// doesn't break it. Decoration is idempotent and re-applied by a
/// MutationObserver if React re-renders a row.
enum ImagePreviewScript {
    static let javascript = """
    (function() {
        'use strict';
        var IMG_EXT = /\\.(png|jpe?g|gif|webp|bmp|avif)$/i;
        // Data-URL byte budget across all captured images. Oldest URLs are
        // dropped past this (their rows just stay undecorated); entries and
        // sequence numbers are kept so later rows still pair correctly.
        var MAX_IMAGE_BYTES = 50 * 1024 * 1024;
        // tool_use_id -> {file, seq, urls: [dataUrl]|null}, in arrival order.
        // Entries persist for the webview's lifetime (each is ~100 bytes once
        // evicted) — that permanence is what keeps seq pairing stable.
        var imageReads = new Map();
        var seqByFile = new Map(); // file basename -> next sequence number
        var totalBytes = 0;
        var hasImages = false;
        var scanScheduled = false;
        var failedKeys = new Set(); // thumbnails whose <img> failed to load — never retried

        function noteToolUse(block) {
            if (!block || block.type !== 'tool_use' || block.name !== 'Read' ||
                !block.input || typeof block.input.file_path !== 'string' ||
                !IMG_EXT.test(block.input.file_path)) return;
            if (imageReads.has(block.id)) return; // replay re-delivery
            var file = block.input.file_path.split('/').pop();
            var seq = seqByFile.get(file) || 0;
            seqByFile.set(file, seq + 1);
            imageReads.set(block.id, { file: file, seq: seq, urls: null });
        }

        function noteToolResult(block) {
            if (!block || block.type !== 'tool_result') return;
            var rec = imageReads.get(block.tool_use_id);
            if (!rec || rec.urls) return; // untracked, or replay duplicate
            // Error results carry string content — leave the row undecorated.
            if (!Array.isArray(block.content)) return;
            var urls = [];
            var malformed = 0;
            for (var i = 0; i < block.content.length; i++) {
                var item = block.content[i];
                if (!item || item.type !== 'image') continue;
                if (item.source && item.source.type === 'base64' &&
                    typeof item.source.media_type === 'string' &&
                    item.source.data) {
                    urls.push('data:' + item.source.media_type + ';base64,' + item.source.data);
                } else {
                    malformed++;
                }
            }
            if (malformed) {
                console.warn('[Canopy ImagePreview] skipped ' + malformed +
                    ' malformed image item(s) in result for "' + rec.file +
                    '" - stream contract may have changed');
            }
            if (!urls.length) {
                // A tracked image Read whose successful result has no base64
                // image is the signature of a stream-contract change upstream.
                console.warn('[Canopy ImagePreview] image Read "' + rec.file +
                    '" returned no base64 image - stream contract may have changed');
                return;
            }
            rec.urls = urls;
            for (var j = 0; j < urls.length; j++) totalBytes += urls[j].length;
            evictOverBudget();
            hasImages = true;
            scheduleScan();
        }

        function evictOverBudget() {
            if (totalBytes <= MAX_IMAGE_BYTES) return;
            var evicted = 0;
            var freedBytes = 0;
            var iter = imageReads.values();
            for (var e = iter.next(); !e.done && totalBytes > MAX_IMAGE_BYTES; e = iter.next()) {
                var rec = e.value;
                if (!rec.urls) continue;
                for (var i = 0; i < rec.urls.length; i++) {
                    totalBytes -= rec.urls[i].length;
                    freedBytes += rec.urls[i].length;
                }
                rec.urls = null; // already-inserted <img> nodes keep their src
                evicted++;
            }
            console.info('[Canopy ImagePreview] evicted ' + evicted + ' image(s) (~' +
                Math.round(freedBytes / 1048576) + ' MB) over the 50 MB budget');
        }

        function noteMessage(msg) {
            if (!msg || !msg.message || !Array.isArray(msg.message.content)) return;
            var content = msg.message.content;
            if (msg.type === 'assistant') content.forEach(noteToolUse);
            else if (msg.type === 'user') content.forEach(noteToolResult);
        }

        window.addEventListener('message', function(e) {
            var d = e.data;
            if (!d || d.type !== 'from-extension' || !d.message) return;
            var m = d.message;
            if (m.type === 'io_message') noteMessage(m.message);
            else if (m.type === 'response' && m.response && Array.isArray(m.response.messages)) {
                m.response.messages.forEach(noteMessage);
            }
        });

        function scheduleScan() {
            if (scanScheduled) return;
            scanScheduled = true;
            requestAnimationFrame(function() { scanScheduled = false; scan(); });
        }

        function scan() {
            if (!hasImages) return;
            var byFile = new Map(); // file -> Map(seq -> {id, rec})
            imageReads.forEach(function(rec, id) {
                if (!rec.urls) return;
                if (!byFile.has(rec.file)) byFile.set(rec.file, new Map());
                byFile.get(rec.file).set(rec.seq, { id: id, rec: rec });
            });
            if (!byFile.size) return;
            // Collect "Read <file>" anchors in DOM order, per basename.
            var rows = new Map(); // file -> [{summary, ...}]
            var anchors = document.querySelectorAll('summary a');
            for (var i = 0; i < anchors.length; i++) {
                var a = anchors[i];
                if (!byFile.has(a.textContent)) continue;
                var summary = a.closest('summary');
                if (!summary || (summary.textContent || '').indexOf('Read') !== 0) continue;
                if (!rows.has(a.textContent)) rows.set(a.textContent, []);
                rows.get(a.textContent).push(summary);
            }
            // Pair rows and sequence numbers tail-aligned: the LAST anchor for a
            // file pairs with its newest allocated seq. Both sides count every
            // image-extension Read tool_use (successful or not), and the webview
            // only ever evicts rendered history from the FRONT, so aligning from
            // the tail keeps the pairing stable even after old rows disappear.
            // With nothing evicted the offset is 0 (plain k-th <-> seq k).
            rows.forEach(function(list, file) {
                var offset = (seqByFile.get(file) || 0) - list.length;
                if (offset < 0) offset = 0; // more rows than tracked tool_uses
                for (var k = 0; k < list.length; k++) {
                    var hit = byFile.get(file).get(k + offset);
                    if (hit) decorate(list[k], hit.id, hit.rec);
                }
            });
        }

        function decorate(summary, id, rec) {
            var wrap = summary.nextElementSibling;
            if (!wrap || !wrap.hasAttribute('data-canopy-images')) {
                wrap = document.createElement('div');
                wrap.setAttribute('data-canopy-images', '');
                wrap.style.cssText = 'display:flex;flex-wrap:wrap;gap:8px;margin:6px 0 2px 22px;';
                summary.insertAdjacentElement('afterend', wrap);
            }
            for (var j = 0; j < rec.urls.length; j++) {
                addThumbnail(wrap, id + ':' + j, rec.urls[j], rec.file);
            }
        }

        function addThumbnail(wrap, key, url, file) {
            if (failedKeys.has(key)) return;
            for (var i = 0; i < wrap.children.length; i++) {
                if (wrap.children[i].getAttribute('data-canopy-key') === key) return;
            }
            var img = document.createElement('img');
            img.src = url;
            img.setAttribute('data-canopy-key', key);
            img.alt = file;
            img.tabIndex = 0;
            img.setAttribute('role', 'button');
            img.setAttribute('aria-label', 'View ' + file + ' full size');
            img.style.cssText = 'max-width:280px;max-height:180px;border-radius:6px;'
                + 'border:1px solid var(--vscode-widget-border, rgba(0,0,0,0.12));'
                + 'cursor:zoom-in;display:block;';
            img.addEventListener('error', function() {
                console.warn('[Canopy ImagePreview] thumbnail failed to load: ' + file);
                failedKeys.add(key); // stop the remove -> observer -> re-add retry loop
                img.remove();
            });
            img.addEventListener('click', function(ev) {
                ev.stopPropagation();
                openLightbox(url);
            });
            img.addEventListener('keydown', function(ev) {
                if (ev.key === 'Enter' || ev.key === ' ') {
                    ev.preventDefault();
                    ev.stopPropagation();
                    openLightbox(url);
                }
            });
            wrap.appendChild(img);
        }

        function openLightbox(url) {
            var overlay = document.createElement('div');
            overlay.style.cssText = 'position:fixed;inset:0;z-index:100000;'
                + 'background:rgba(0,0,0,0.78);display:flex;align-items:center;'
                + 'justify-content:center;cursor:zoom-out;';
            var img = document.createElement('img');
            img.src = url;
            img.style.cssText = 'max-width:92vw;max-height:92vh;border-radius:8px;'
                + 'box-shadow:0 8px 40px rgba(0,0,0,0.5);';
            overlay.appendChild(img);
            function close() {
                overlay.remove();
                document.removeEventListener('keydown', onKey, true);
            }
            function onKey(e) {
                if (e.key === 'Escape') {
                    e.preventDefault();
                    e.stopPropagation();
                    close();
                }
            }
            overlay.addEventListener('click', close);
            document.addEventListener('keydown', onKey, true);
            document.body.appendChild(overlay);
        }

        // Only mutations that touch a Read row (or our own wrapper) warrant a
        // rescan — streaming text updates elsewhere in the chat must not
        // trigger per-frame full scans in long sessions.
        function touchesReadRow(mutation) {
            var t = mutation.target;
            if (t && t.nodeType === 1 && t.closest && t.closest('summary')) return true;
            var lists = [mutation.addedNodes, mutation.removedNodes];
            for (var l = 0; l < 2; l++) {
                for (var i = 0; i < lists[l].length; i++) {
                    var n = lists[l][i];
                    if (n.nodeType !== 1) continue;
                    if (n.matches('summary') || n.hasAttribute('data-canopy-images')) return true;
                    if (n.querySelector('summary') || n.querySelector('[data-canopy-images]')) return true;
                }
            }
            return false;
        }

        function startObserver() {
            new MutationObserver(function(mutations) {
                if (!hasImages) return;
                for (var i = 0; i < mutations.length; i++) {
                    if (touchesReadRow(mutations[i])) { scheduleScan(); return; }
                }
            }).observe(document.body, { childList: true, subtree: true });
        }
        if (document.body) startObserver();
        else document.addEventListener('DOMContentLoaded', startObserver);
    })();
    """
}
