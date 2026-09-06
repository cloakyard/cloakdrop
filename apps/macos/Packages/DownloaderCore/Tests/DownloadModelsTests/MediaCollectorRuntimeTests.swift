import JavaScriptCore
import Testing
@testable import DownloadModels

@Suite("Browser media collector runtime")
struct MediaCollectorRuntimeTests {
    /// Execute the actual bundled collector with an in-memory browser surface. This exercises its
    /// event/dedup behavior without visiting a site or making any network request.
    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var window = this;
        window.top = window;
        var location = { href: 'https://site.example/watch' };
        var collected = [];
        var pendingTimers = [];
        function setTimeout(callback) { pendingTimers.push(callback); return pendingTimers.length; }
        function flushTimers() {
            var timers = pendingTimers; pendingTimers = [];
            timers.forEach(function(callback) { callback(); });
        }
        window.addEventListener = function() {};
        window.webkit = { messageHandlers: { mediaSniffer: {
            postMessage: function(message) { collected = collected.concat(message.events); }
        } } };
        var document = {
            readyState: 'complete', title: 'Test',
            querySelectorAll: function() { return []; },
            addEventListener: function() {}
        };
        document.documentElement = document;
        var history = {
            pushState: function(state, title, url) { location.href = url; },
            replaceState: function(state, title, url) { location.href = url; }
        };
        var resourceObserver;
        function PerformanceObserver(callback) { resourceObserver = callback; }
        PerformanceObserver.prototype.observe = function() {};
        function reportResources(urls) {
            resourceObserver({ getEntries: function() {
                return urls.map(function(url) { return {name: url, initiatorType: 'fetch', transferSize: 4000}; });
            } });
            flushTimers();
        }
        """)
        context.evaluateScript(MediaSniffer.collectorScript)
        #expect(context.exception == nil)
        return context
    }

    @Test("Players appearing after a thousand page resources remain discoverable")
    func latePlayerSurvivesBoundedDedupe() throws {
        let context = try context()
        context.evaluateScript("""
        var noise = [];
        for (var i = 0; i < 1000; i++) { noise.push('https://cdn.example/resource-' + i + '.js'); }
        reportResources(noise);
        reportResources(['https://cdn.example/late-player.mp4']);
        """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("collected.filter(function(e) { return e.url === 'https://cdn.example/late-player.mp4'; }).length")?.toInt32() == 1)
    }

    @Test("Recent duplicate sightings stay suppressed and SPA navigation resets the window")
    func dedupeAndNavigation() throws {
        let context = try context()
        context.evaluateScript("""
        reportResources(['https://cdn.example/video.mp4', 'https://cdn.example/video.mp4']);
        history.pushState({}, '', 'https://site.example/next');
        reportResources(['https://cdn.example/video.mp4']);
        """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("collected.filter(function(e) { return e.url === 'https://cdn.example/video.mp4'; }).length")?.toInt32() == 2)
        #expect(context.evaluateScript("collected.filter(function(e) { return e.kind === 'navigated'; }).length")?.toInt32() == 1)
    }
}
