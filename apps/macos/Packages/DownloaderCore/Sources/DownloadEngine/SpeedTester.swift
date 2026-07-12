import Foundation
import DownloadModels

/// Tunables for one speed-test run. Tests inject short phases; production uses `.default`.
public struct SpeedTestConfiguration: Sendable {
    /// Parallel streams per throughput phase — one connection can't saturate a fast link.
    public var connectionCount: Int
    /// Timed round trips for the idle-latency phase (an extra warm-up probe is discarded).
    public var latencySampleCount: Int
    public var downloadDuration: Duration
    public var uploadDuration: Duration
    /// Payload size requested per download connection; workers re-request until the deadline.
    public var downloadRequestBytes: Int
    /// Body size posted per upload connection; workers re-post until the deadline.
    public var uploadRequestBytes: Int
    /// Leading fraction of each throughput phase excluded from the final rate, so TCP
    /// slow-start and connection ramp-up don't drag the steady-state number down.
    public var warmupFraction: Double
    /// How often live `.downloadRate`/`.uploadRate` events are emitted.
    public var rateUpdateInterval: Duration
    /// Gap between latency probes fired *during* the download phase (bufferbloat signal).
    public var loadedLatencyInterval: Duration

    public init(
        connectionCount: Int = 6,
        latencySampleCount: Int = 8,
        downloadDuration: Duration = .seconds(8),
        uploadDuration: Duration = .seconds(6),
        downloadRequestBytes: Int = 25_000_000,
        uploadRequestBytes: Int = 8_000_000,
        warmupFraction: Double = 0.25,
        rateUpdateInterval: Duration = .milliseconds(250),
        loadedLatencyInterval: Duration = .milliseconds(400)
    ) {
        self.connectionCount = max(1, connectionCount)
        self.latencySampleCount = max(1, latencySampleCount)
        self.downloadDuration = downloadDuration
        self.uploadDuration = uploadDuration
        self.downloadRequestBytes = max(1, downloadRequestBytes)
        self.uploadRequestBytes = max(1, uploadRequestBytes)
        self.warmupFraction = min(max(warmupFraction, 0), 0.9)
        self.rateUpdateInterval = rateUpdateInterval
        self.loadedLatencyInterval = loadedLatencyInterval
    }

    public static let `default` = SpeedTestConfiguration()
}

/// Where a running test currently is, for the UI's status line.
public enum SpeedTestPhase: Sendable, Hashable {
    case findingServer, latency, download, upload
}

/// Live progress of a test run, streamed from `SpeedTester.run(provider:)`.
public enum SpeedTestEvent: Sendable {
    case phase(SpeedTestPhase)
    /// The server the test settled on (Ookla picks the nearest from the directory).
    case server(name: String)
    /// Running median of idle round trips so far, updated after each probe.
    case idleLatency(milliseconds: Double)
    case downloadRate(bytesPerSecond: Double)
    case uploadRate(bytesPerSecond: Double)
    case finished(SpeedTestResult)
}

// MARK: - Endpoints

/// The concrete URLs one test run measures against.
struct SpeedTestEndpoints: Sendable, Hashable {
    var serverName: String
    var latencyURL: URL
    var downloadURL: URL
    var uploadURL: URL

    /// Cloudflare's anycast speed endpoints — no account, no server discovery step.
    static func cloudflare(downloadBytes: Int) -> SpeedTestEndpoints {
        let base = URL(string: "https://speed.cloudflare.com")!
        return SpeedTestEndpoints(
            serverName: "Cloudflare",
            latencyURL: base.appending(path: "__down").appending(queryItems: [.init(name: "bytes", value: "0")]),
            downloadURL: base.appending(path: "__down").appending(queryItems: [.init(name: "bytes", value: String(downloadBytes))]),
            uploadURL: base.appending(path: "__up")
        )
    }

    static func ookla(_ server: OoklaServer) -> SpeedTestEndpoints {
        SpeedTestEndpoints(
            serverName: server.displayName,
            latencyURL: server.baseURL.appending(path: "latency.txt"),
            // The largest of the fixed random payloads every Ookla server serves (~31 MB).
            downloadURL: server.baseURL.appending(path: "random4000x4000.jpg"),
            uploadURL: server.uploadURL
        )
    }
}

/// One HTTPS-reachable entry from Ookla's public server directory.
struct OoklaServer: Sendable, Hashable {
    /// City, e.g. "Pune".
    var name: String
    /// Operator, e.g. an ISP or exchange.
    var sponsor: String
    /// The server's `…/speedtest` root over HTTPS on its canonical `ooklaserver.net` host.
    var baseURL: URL

    var uploadURL: URL { baseURL.appending(path: "upload.php") }
    var displayName: String { sponsor.isEmpty ? name : "\(sponsor) — \(name)" }
}

enum OoklaServerDirectory {
    /// Ookla's public nearest-servers listing (the same one its own web client queries). Pull a
    /// wide list because only the subset with a canonical `ooklaserver.net` host is usable (below).
    static let listURL = URL(string: "https://www.speedtest.net/api/js/servers?engine=js&https_functional=true&limit=20")!

    /// Decode the directory, keeping only servers whose canonical `host` is under
    /// `ooklaserver.net` — the servers that carry Ookla's wildcard TLS cert, so HTTPS validates.
    ///
    /// Why not the listed `url`: it is always plain **http** on a vanity hostname. App Transport
    /// Security blocks cleartext HTTP, and the vanity host (`speedtestX.some-isp.in`) usually has
    /// no matching cert, so HTTPS to it fails validation too. The directory's `host` field, when
    /// it ends in `.ooklaserver.net` (~80% of nearby servers do), is the one form that loads over
    /// valid HTTPS — so we build every test URL from that and skip the rest.
    static func parse(_ data: Data) throws -> [OoklaServer] {
        struct Entry: Decodable {
            var host: String?
            var name: String?
            var sponsor: String?
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries.compactMap { entry -> OoklaServer? in
            guard let host = entry.host, !host.isEmpty else { return nil }
            // `host` is "hostname[:port]"; the hostname must be an ooklaserver.net name.
            let hostname = host.split(separator: ":").first.map(String.init) ?? host
            guard hostname.hasSuffix(".ooklaserver.net") else { return nil }
            guard let base = URL(string: "https://\(host)/speedtest") else { return nil }
            return OoklaServer(name: entry.name ?? "", sponsor: entry.sponsor ?? "", baseURL: base)
        }
    }
}

// MARK: - Math

/// Pure math for turning raw samples into the reported numbers. I/O-free and unit-tested directly.
enum SpeedTestMath {
    /// Median, or `nil` for an empty input.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Mean absolute difference between consecutive round trips — 0 when fewer than two.
    static func jitter(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let diffs = zip(values.dropFirst(), values).map { abs($0 - $1) }
        return diffs.reduce(0, +) / Double(diffs.count)
    }

    /// Steady-state bytes/sec over a throughput phase: samples inside the leading warm-up
    /// window are excluded so connection ramp-up doesn't dilute the sustained rate.
    /// `samples` are `(secondsSincePhaseStart, byteCount)` in arrival order.
    static func steadyRate(
        samples: [(offset: Double, bytes: Int64)],
        phaseSeconds: Double,
        warmupFraction: Double
    ) -> Double {
        guard let last = samples.last, phaseSeconds > 0 else { return 0 }
        let warmupEnd = phaseSeconds * warmupFraction
        let steady = samples.filter { $0.offset > warmupEnd }
        // The phase can outlive its nominal deadline by a beat (cancellation latency), so
        // measure over the real span covered by the samples, never less than the phase.
        let span = max(phaseSeconds, last.offset) - warmupEnd
        guard !steady.isEmpty, span > 0 else {
            let total = samples.reduce(Int64(0)) { $0 + $1.bytes }
            return Double(total) / max(phaseSeconds, last.offset)
        }
        let bytes = steady.reduce(Int64(0)) { $0 + $1.bytes }
        return Double(bytes) / span
    }
}

// MARK: - Tester

/// Orchestrates one speed test: resolve a server, probe idle latency, then saturate the
/// link downstream and upstream with parallel workers while sampling loaded latency.
///
/// An actor so the measurement state (samples, the live-rate `SpeedSampler`) mutates
/// serially no matter how many workers report bytes.
public actor SpeedTester {
    private let transport: any SpeedTestTransport
    private let configuration: SpeedTestConfiguration

    // Per-phase measurement state, reset by `beginPhase()`.
    private var phaseStart: ContinuousClock.Instant = .now
    private var samples: [(offset: Double, bytes: Int64)] = []
    private var sampler = SpeedSampler(windowSeconds: 2.0)
    private var loadedLatencies: [Double] = []

    public init(
        transport: any SpeedTestTransport = URLSessionSpeedTestTransport(),
        configuration: SpeedTestConfiguration = .default
    ) {
        self.transport = transport
        self.configuration = configuration
    }

    /// Run a full test. Events stream live; the final `.finished(result)` carries the report.
    /// Cancelling the consuming task aborts the run (surfaced as `CancellationError`).
    public nonisolated func run(provider: SpeedTestProvider) -> AsyncThrowingStream<SpeedTestEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<SpeedTestEvent, Error>.makeStream()
        let task = Task { await self.perform(provider: provider, continuation: continuation) }
        continuation.onTermination = { reason in
            if case .cancelled = reason { task.cancel() }
        }
        return stream
    }

    private func perform(
        provider: SpeedTestProvider,
        continuation: AsyncThrowingStream<SpeedTestEvent, Error>.Continuation
    ) async {
        do {
            continuation.yield(.phase(.findingServer))
            let endpoints = try await resolveEndpoints(provider: provider)
            continuation.yield(.server(name: endpoints.serverName))

            continuation.yield(.phase(.latency))
            let idleRTTs = try await measureIdleLatency(endpoints, continuation: continuation)

            continuation.yield(.phase(.download))
            let (downloadRate, loadedRTTs) = try await measureThroughput(.download, endpoints, continuation: continuation)

            continuation.yield(.phase(.upload))
            let (uploadRate, _) = try await measureThroughput(.upload, endpoints, continuation: continuation)

            let result = SpeedTestResult(
                provider: provider,
                serverName: endpoints.serverName,
                downloadBytesPerSecond: downloadRate,
                uploadBytesPerSecond: uploadRate,
                idleLatencyMilliseconds: SpeedTestMath.median(idleRTTs) ?? 0,
                loadedLatencyMilliseconds: SpeedTestMath.median(loadedRTTs),
                jitterMilliseconds: SpeedTestMath.jitter(idleRTTs),
                date: Date()
            )
            continuation.yield(.finished(result))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    // MARK: Server resolution

    private func resolveEndpoints(provider: SpeedTestProvider) async throws -> SpeedTestEndpoints {
        switch provider {
        case .cloudflare:
            return .cloudflare(downloadBytes: configuration.downloadRequestBytes)
        case .ookla:
            let data = try await transport.fetch(OoklaServerDirectory.listURL)
            guard let server = try OoklaServerDirectory.parse(data).first else {
                throw SpeedTestError.noServers
            }
            return .ookla(server)
        }
    }

    // MARK: Latency

    private func measureIdleLatency(
        _ endpoints: SpeedTestEndpoints,
        continuation: AsyncThrowingStream<SpeedTestEvent, Error>.Continuation
    ) async throws -> [Double] {
        var rtts: [Double] = []
        // Probe 0 is a discarded warm-up: it pays the TCP/TLS handshake so the timed
        // probes measure the round trip, not connection setup.
        for probe in 0...configuration.latencySampleCount {
            try Task.checkCancellation()
            let start = ContinuousClock.now
            _ = try await transport.fetch(Self.bustingCache(endpoints.latencyURL))
            let milliseconds = start.seconds(to: .now) * 1000
            guard probe > 0 else { continue }
            rtts.append(milliseconds)
            continuation.yield(.idleLatency(milliseconds: SpeedTestMath.median(rtts) ?? milliseconds))
        }
        return rtts
    }

    // MARK: Throughput

    private enum ThroughputKind: Sendable { case download, upload }

    /// Thrown by the phase-deadline child to end an otherwise endless worker group.
    private struct PhaseDeadline: Error {}

    /// Returns the steady-state rate and (for the download phase) the loaded-latency
    /// samples collected while the link was saturated — returned rather than left in actor
    /// state, so the result can't be erased by the next phase's reset.
    private func measureThroughput(
        _ kind: ThroughputKind,
        _ endpoints: SpeedTestEndpoints,
        continuation: AsyncThrowingStream<SpeedTestEvent, Error>.Continuation
    ) async throws -> (rate: Double, loadedLatencies: [Double]) {
        beginPhase()
        let duration = kind == .download ? configuration.downloadDuration : configuration.uploadDuration
        let uploadBody = kind == .upload ? Self.makeUploadBody(byteCount: configuration.uploadRequestBytes) : Data()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<configuration.connectionCount {
                    switch kind {
                    case .download:
                        group.addTask { try await self.downloadWorker(endpoints) }
                    case .upload:
                        group.addTask { try await self.uploadWorker(endpoints, body: uploadBody) }
                    }
                }
                group.addTask { await self.reportRates(kind, continuation: continuation) }
                if kind == .download {
                    group.addTask { await self.probeLoadedLatency(endpoints) }
                }
                group.addTask {
                    try await Task.sleep(for: duration)
                    throw PhaseDeadline()
                }
                // Workers loop until cancelled, so the first child to complete is the
                // deadline (or a real transport failure, which aborts the whole test).
                // `waitForAll` would deadlock here: a thrown deadline doesn't cancel the
                // still-looping workers, so race with `next()` and cancel the rest.
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch is PhaseDeadline {
            // Normal end of phase.
        }
        try Task.checkCancellation()

        let rate = SpeedTestMath.steadyRate(
            samples: samples,
            phaseSeconds: duration.timeInterval,
            warmupFraction: configuration.warmupFraction
        )
        return (rate, loadedLatencies)
    }

    private func downloadWorker(_ endpoints: SpeedTestEndpoints) async throws {
        while !Task.isCancelled {
            var received: Int64 = 0
            do {
                let chunks = try await transport.download(Self.bustingCache(endpoints.downloadURL))
                for try await chunk in chunks {
                    received += Int64(chunk)
                    record(bytes: Int64(chunk))
                }
            } catch is CancellationError {
                return
            }
            // A degenerate empty response would otherwise spin this loop flat out.
            if received == 0 {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func uploadWorker(_ endpoints: SpeedTestEndpoints, body: Data) async throws {
        while !Task.isCancelled {
            var sent: Int64 = 0
            do {
                let deltas = try await transport.upload(endpoints.uploadURL, body: body)
                for try await delta in deltas {
                    sent += Int64(delta)
                    record(bytes: Int64(delta))
                }
            } catch is CancellationError {
                return
            }
            // Same guard as downloads: a server that answers without any body progress
            // reaching the stream must not turn this into a connection-rate POST loop.
            if sent == 0 {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Emits a smoothed live rate on a fixed cadence until the phase is cancelled.
    private func reportRates(
        _ kind: ThroughputKind,
        continuation: AsyncThrowingStream<SpeedTestEvent, Error>.Continuation
    ) async {
        while !Task.isCancelled {
            guard (try? await Task.sleep(for: configuration.rateUpdateInterval)) != nil else { return }
            let rate = sampler.rate(now: .now)
            switch kind {
            case .download: continuation.yield(.downloadRate(bytesPerSecond: rate))
            case .upload: continuation.yield(.uploadRate(bytesPerSecond: rate))
            }
        }
    }

    /// Best-effort latency probes while the download workers saturate the link. Failures are
    /// dropped — a probe lost to congestion is itself a symptom, not a test failure.
    private func probeLoadedLatency(_ endpoints: SpeedTestEndpoints) async {
        while !Task.isCancelled {
            guard (try? await Task.sleep(for: configuration.loadedLatencyInterval)) != nil else { return }
            let start = ContinuousClock.now
            guard (try? await transport.fetch(Self.bustingCache(endpoints.latencyURL))) != nil else {
                continue
            }
            loadedLatencies.append(start.seconds(to: .now) * 1000)
        }
    }

    // MARK: Measurement state

    private func beginPhase() {
        phaseStart = .now
        samples = []
        sampler = SpeedSampler(windowSeconds: 2.0)
        loadedLatencies = []
    }

    private func record(bytes: Int64) {
        let now = ContinuousClock.now
        samples.append((phaseStart.seconds(to: now), bytes))
        sampler.add(bytes: bytes, at: now)
    }

    // MARK: Helpers

    /// Append a random token so caches along the path can't answer a repeat request —
    /// random rather than sequential, so tokens can't collide across probes or runs.
    static func bustingCache(_ url: URL) -> URL {
        url.appending(queryItems: [URLQueryItem(name: "nocache", value: String(UInt64.random(in: .min ... .max)))])
    }

    /// An incompressible upload body: a random 64 KiB block tiled to size, so a compressing
    /// middlebox can't make the upstream look faster than it is.
    static func makeUploadBody(byteCount: Int) -> Data {
        let blockSize = min(64 * 1024, byteCount)
        var generator = SystemRandomNumberGenerator()
        var block = Data(capacity: blockSize)
        while block.count < blockSize {
            withUnsafeBytes(of: generator.next() as UInt64) { block.append(contentsOf: $0) }
        }
        block = block.prefix(blockSize)
        var body = Data(capacity: byteCount)
        while body.count < byteCount {
            body.append(block)
        }
        return body.prefix(byteCount)
    }
}
