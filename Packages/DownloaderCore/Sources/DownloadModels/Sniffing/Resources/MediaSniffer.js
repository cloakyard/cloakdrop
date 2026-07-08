// CloakDrop media collector — injected at document start into EVERY frame of the in-app browser,
// in the page's content world. It is a dumb reporter: it observes network/media activity and posts
// raw sightings to the native side, where the (unit-tested) Swift classifier decides what they
// mean. Keep it free of policy — every heuristic belongs in MediaSniffer.swift.
//
// Wire format (see SniffEvent.swift, the other half of this contract):
//   { v: 1, frame: <frame URL>, top: <bool>, events: [ { kind, ... } ] }
// Event kinds: resource | response | element | mse | drm | page | navigated
//
// Hardening: every hook is wrapped in try/catch (a hostile or exotic page must never see us
// throw), the per-document dedup set is capped, batches are throttled, and the whole script is
// idempotent (re-injection is a no-op).
(function () {
    "use strict";
    if (window.__cloakdropSniffer) { return; }
    window.__cloakdropSniffer = 1;

    var SEEN_MAX = 800;          // distinct sightings per document — beyond this the page is noise
    var BATCH_DELAY_MS = 250;    // coalesce bursts into one bridge message
    var BATCH_MAX = 64;          // ...but never let a batch grow unbounded
    var PAGE_SNAPSHOT_MS = 400;  // debounce for page (title/players) snapshots

    var seen = Object.create(null);
    var seenCount = 0;
    var queue = [];
    var timer = null;
    var pageTimer = null;
    var lastHref = String(location.href).split("#")[0];

    function bridge() {
        try { return window.webkit.messageHandlers.mediaSniffer; } catch (e) { return null; }
    }

    function post(events) {
        var handler = bridge();
        if (!handler || !events.length) { return; }
        try {
            handler.postMessage({ v: 1, frame: String(location.href), top: window === window.top, events: events });
        } catch (e) { /* bridge gone (teardown) — drop silently */ }
    }

    function flush() {
        timer = null;
        if (!queue.length) { return; }
        var batch = queue;
        queue = [];
        post(batch);
    }

    function emit(event) {
        queue.push(event);
        if (queue.length >= BATCH_MAX) { flush(); return; }
        if (!timer) { timer = setTimeout(flush, BATCH_DELAY_MS); }
    }

    // Report a URL-keyed sighting once per document. `extra` carries kind-specific fields.
    function report(kind, url, extra) {
        if (typeof url !== "string" || !url) { return; }
        if (url.slice(0, 5) === "data:") { return; }
        var key = kind + "|" + url;
        if (seen[key] || seenCount >= SEEN_MAX) { return; }
        seen[key] = 1;
        seenCount += 1;
        var event = extra || {};
        event.kind = kind;
        event.url = url;
        emit(event);
    }

    function absolute(url) {
        try { return new URL(url, location.href).href; } catch (e) { return String(url || ""); }
    }

    // ── 1. PerformanceObserver — the catch-all URL stream (sees every subresource the page loads,
    // including service-worker-served media the fetch/XHR hooks can miss). URL only; the Swift side
    // classifies by extension.
    try {
        new PerformanceObserver(function (list) {
            var entries = list.getEntries();
            for (var i = 0; i < entries.length; i++) {
                var entry = entries[i];
                report("resource", entry.name, {
                    initiator: String(entry.initiatorType || ""),
                    size: entry.transferSize > 0 ? Math.floor(entry.transferSize) : 0
                });
            }
        }).observe({ entryTypes: ["resource"], buffered: true });
    } catch (e) { /* observer unsupported — the other channels still work */ }

    // Response headers (where CORS exposes them) → the content-type/disposition classifier.
    function reportResponseHeaders(url, contentType, contentLength, contentDisposition) {
        if (!contentType && !contentDisposition) { return; }
        var length = contentLength ? parseInt(contentLength, 10) : null;
        report("response", url, {
            contentType: contentType || null,
            contentLength: isFinite(length) && length > 0 ? length : null,
            contentDisposition: contentDisposition || null
        });
    }

    // ── 2. fetch hook — observe response headers without touching the body or the promise chain.
    try {
        var originalFetch = window.fetch;
        if (typeof originalFetch === "function") {
            window.fetch = function () {
                var promise = originalFetch.apply(this, arguments);
                try {
                    promise.then(function (response) {
                        try {
                            if (!response || !response.url || !response.headers || !response.headers.get) { return; }
                            reportResponseHeaders(
                                response.url,
                                response.headers.get("content-type"),
                                response.headers.get("content-length"),
                                response.headers.get("content-disposition")
                            );
                        } catch (e) { /* opaque response — headers hidden */ }
                    }, function () { /* network failure is the page's problem */ });
                } catch (e) { /* never break the page's fetch */ }
                return promise;
            };
        }
    } catch (e) { /* leave fetch alone */ }

    // ── 3. XMLHttpRequest hook — same idea, header-phase only (readyState 2).
    try {
        var originalOpen = XMLHttpRequest.prototype.open;
        var originalSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (method, url) {
            try { this.__cloakdropURL = absolute(url); } catch (e) { /* keep going */ }
            return originalOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function () {
            var xhr = this;
            try {
                xhr.addEventListener("readystatechange", function () {
                    try {
                        if (xhr.readyState !== 2) { return; }
                        var url = xhr.responseURL || xhr.__cloakdropURL;
                        if (!url) { return; }
                        reportResponseHeaders(
                            url,
                            xhr.getResponseHeader("content-type"),
                            xhr.getResponseHeader("content-length"),
                            xhr.getResponseHeader("content-disposition")
                        );
                    } catch (e) { /* cross-origin header access denied */ }
                });
            } catch (e) { /* never break the page's XHR */ }
            return originalSend.apply(this, arguments);
        };
    } catch (e) { /* leave XHR alone */ }

    // ── 4. Media elements — src sightings plus the page snapshot's player inventory.
    function reportElement(el) {
        try {
            var isVideo = el.tagName === "VIDEO";
            var tag = isVideo ? "video" : "audio";
            var src = el.currentSrc || el.src || "";
            if (src) {
                if (src.slice(0, 5) === "blob:") {
                    report("element", src, { tag: tag, blob: true });   // MediaSource playback signal
                } else {
                    report("element", absolute(src), {
                        tag: tag,
                        duration: isFinite(el.duration) && el.duration > 0 ? el.duration : null
                    });
                }
            }
            var sources = el.querySelectorAll ? el.querySelectorAll("source") : [];
            for (var i = 0; i < sources.length; i++) {
                var alt = sources[i].getAttribute("src");
                if (alt) { report("element", absolute(alt), { tag: tag }); }
            }
        } catch (e) { /* detached/exotic element */ }
    }

    function scanMediaElements() {
        try {
            var els = document.querySelectorAll("video,audio");
            for (var i = 0; i < els.length; i++) { reportElement(els[i]); }
        } catch (e) { /* document not ready */ }
    }

    // Capture-phase listeners see events for players inside closed shadow roots too.
    try {
        document.addEventListener("loadstart", function (ev) {
            var t = ev.target;
            if (t && (t.tagName === "VIDEO" || t.tagName === "AUDIO")) { reportElement(t); schedulePageSnapshot(); }
        }, true);
        document.addEventListener("durationchange", function (ev) {
            var t = ev.target;
            if (t && (t.tagName === "VIDEO" || t.tagName === "AUDIO")) { reportElement(t); schedulePageSnapshot(); }
        }, true);
    } catch (e) { /* no document yet */ }

    // ── 5. MediaSource + EME hooks — "assembled in JS" and "DRM" signals.
    try {
        if (window.MediaSource && MediaSource.prototype.addSourceBuffer) {
            var originalAddSourceBuffer = MediaSource.prototype.addSourceBuffer;
            MediaSource.prototype.addSourceBuffer = function (mime) {
                try { report("mse", "mse:" + String(mime || ""), { mime: String(mime || "") }); } catch (e) { /* report only */ }
                return originalAddSourceBuffer.apply(this, arguments);
            };
        }
    } catch (e) { /* leave MSE alone */ }
    try {
        if (navigator.requestMediaKeySystemAccess) {
            var originalRequestMediaKeySystemAccess = navigator.requestMediaKeySystemAccess.bind(navigator);
            navigator.requestMediaKeySystemAccess = function (keySystem, configurations) {
                try { report("drm", "drm:" + String(keySystem || ""), { keySystem: String(keySystem || "") }); } catch (e) { /* report only */ }
                return originalRequestMediaKeySystemAccess(keySystem, configurations);
            };
        }
    } catch (e) { /* leave EME alone */ }

    // ── 6. Page snapshots — title + player inventory (top frame only), for the primary-player pick
    // and the "extract this page's video" offer. Snapshots bypass the seen-set: they're repeated
    // state, replaced wholesale on the native side.
    function sendPageSnapshot() {
        pageTimer = null;
        if (window !== window.top) { return; }
        try {
            var els = document.querySelectorAll("video,audio");
            var players = [];
            var hasBlobPlayer = false;
            for (var i = 0; i < els.length; i++) {
                var el = els[i];
                var isVideo = el.tagName === "VIDEO";
                var rect = el.getBoundingClientRect ? el.getBoundingClientRect() : { width: 0, height: 0 };
                players.push({
                    video: isVideo,
                    area: Math.max(0, rect.width || 0) * Math.max(0, rect.height || 0)
                });
                var src = el.currentSrc || el.src || "";
                if (src.slice(0, 5) === "blob:" || (!src && el.srcObject)) { hasBlobPlayer = true; }
            }
            post([{
                kind: "page",
                url: String(location.href),
                title: String(document.title || ""),
                players: players,
                blob: hasBlobPlayer
            }]);
        } catch (e) { /* snapshot is best-effort */ }
    }

    function schedulePageSnapshot() {
        if (window !== window.top) { return; }
        if (!pageTimer) { pageTimer = setTimeout(sendPageSnapshot, PAGE_SNAPSHOT_MS); }
    }

    // Re-scan when media elements are added or re-sourced.
    function watchMutations() {
        try {
            new MutationObserver(function (mutations) {
                var relevant = false;
                for (var i = 0; i < mutations.length && !relevant; i++) {
                    var m = mutations[i];
                    if (m.type === "attributes") { relevant = true; break; }
                    var added = m.addedNodes || [];
                    for (var j = 0; j < added.length; j++) {
                        var node = added[j];
                        if (node.nodeType !== 1) { continue; }
                        if (node.tagName === "VIDEO" || node.tagName === "AUDIO" || node.tagName === "SOURCE" ||
                            (node.querySelector && node.querySelector("video,audio"))) { relevant = true; break; }
                    }
                }
                if (relevant) { scanMediaElements(); schedulePageSnapshot(); }
            }).observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ["src"]
            });
        } catch (e) { /* observer unsupported */ }
    }

    // ── 7. SPA navigation — the URL changed (sans fragment) without a document load. Reset local
    // dedup and tell the native side to start a fresh page state.
    function checkNavigation() {
        var now = String(location.href).split("#")[0];
        if (now === lastHref) { return; }
        lastHref = now;
        seen = Object.create(null);
        seenCount = 0;
        queue = [];
        post([{ kind: "navigated", url: String(location.href) }]);
        scanMediaElements();
        schedulePageSnapshot();
    }
    try {
        var originalPushState = history.pushState;
        history.pushState = function () {
            var result = originalPushState.apply(this, arguments);
            try { checkNavigation(); } catch (e) { /* observe only */ }
            return result;
        };
        var originalReplaceState = history.replaceState;
        history.replaceState = function () {
            var result = originalReplaceState.apply(this, arguments);
            try { checkNavigation(); } catch (e) { /* observe only */ }
            return result;
        };
        window.addEventListener("popstate", function () { try { checkNavigation(); } catch (e) { /* observe only */ } });
    } catch (e) { /* history API locked down */ }

    // ── Boot: scan whatever already exists, then watch.
    function boot() {
        scanMediaElements();
        watchMutations();
        schedulePageSnapshot();
    }
    if (document.readyState === "loading") {
        try { document.addEventListener("DOMContentLoaded", boot, { once: true }); } catch (e) { boot(); }
    } else {
        boot();
    }
    try { window.addEventListener("load", function () { scanMediaElements(); schedulePageSnapshot(); }); } catch (e) { /* best-effort */ }
})();
