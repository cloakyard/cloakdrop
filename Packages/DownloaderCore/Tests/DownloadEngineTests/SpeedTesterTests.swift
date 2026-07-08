import Foundation
import Network
import Testing
@testable import DownloadModels
@testable import DownloadEngine

// MARK: - Math

@Suite("Speed test math")
struct SpeedTestMathTests {

    @Test func medianOfOddAndEvenCounts() {
        #expect(SpeedTestMath.median([]) == nil)
        #expect(SpeedTestMath.median([7]) == 7)
        #expect(SpeedTestMath.median([30, 10, 20]) == 20)
        #expect(SpeedTestMath.median([10, 20, 30, 40]) == 25)
    }

    @Test func jitterIsMeanSuccessiveDifference() {
        #expect(SpeedTestMath.jitter([]) == 0)
        #expect(SpeedTestMath.jitter([12]) == 0)
        #expect(SpeedTestMath.jitter([10, 20, 10]) == 10)
        #expect(abs(SpeedTestMath.jitter([10, 12, 11, 15]) - (2.0 + 1.0 + 4.0) / 3.0) < 1e-9)
    }

    @Test func steadyRateExcludesWarmup() {
        // 100 bytes every 0.1 s across a 1 s phase; warm-up is the first quarter.
        let samples = (1...10).map { (offset: Double($0) / 10, bytes: Int64(100)) }
        let rate = SpeedTestMath.steadyRate(samples: samples, phaseSeconds: 1.0, warmupFraction: 0.25)
        // Samples after 0.25 s: 0.3…1.0 → 800 bytes over a 0.75 s span.
        #expect(abs(rate - 800.0 / 0.75) < 1e-9)
    }

    @Test func steadyRateFallsBackWhenAllSamplesAreInWarmup() {
        let samples = [(offset: 0.1, bytes: Int64(500))]
        let rate = SpeedTestMath.steadyRate(samples: samples, phaseSeconds: 1.0, warmupFraction: 0.25)
        #expect(abs(rate - 500.0) < 1e-9)  // whole-phase average
    }

    @Test func steadyRateOfNothingIsZero() {
        #expect(SpeedTestMath.steadyRate(samples: [], phaseSeconds: 1.0, warmupFraction: 0.25) == 0)
    }

    @Test func steadyRateUsesRealSpanWhenPhaseOverruns() {
        // Last sample lands past the nominal deadline; the span must stretch to cover it.
        let samples = [(offset: 0.5, bytes: Int64(100)), (offset: 1.2, bytes: Int64(100))]
        let rate = SpeedTestMath.steadyRate(samples: samples, phaseSeconds: 1.0, warmupFraction: 0.25)
        #expect(abs(rate - 200.0 / (1.2 - 0.25)) < 1e-9)
    }
}

// MARK: - Endpoints & directory

@Suite("Speed test endpoints")
struct SpeedTestEndpointTests {

    @Test func cloudflareEndpoints() {
        let endpoints = SpeedTestEndpoints.cloudflare(downloadBytes: 25_000_000)
        #expect(endpoints.serverName == "Cloudflare")
        #expect(endpoints.latencyURL.absoluteString == "https://speed.cloudflare.com/__down?bytes=0")
        #expect(endpoints.downloadURL.absoluteString == "https://speed.cloudflare.com/__down?bytes=25000000")
        #expect(endpoints.uploadURL.absoluteString == "https://speed.cloudflare.com/__up")
    }

    @Test func ooklaDirectoryParsesAndDerivesURLs() throws {
        let json = Data("""
        [
          {"url": "http://example-isp.test:8080/speedtest/upload.php",
           "name": "San Jose, CA", "sponsor": "Example ISP", "host": "example-isp.test:8080"},
          {"url": "not a url", "name": "Broken", "sponsor": "Broken"},
          {"url": "https://second.test/speedtest/upload.php", "name": "Oakland, CA", "sponsor": "Second"}
        ]
        """.utf8)
        let servers = try OoklaServerDirectory.parse(json)
        #expect(servers.count == 2)

        let first = try #require(servers.first)
        #expect(first.displayName == "Example ISP — San Jose, CA")
        let endpoints = SpeedTestEndpoints.ookla(first)
        #expect(endpoints.downloadURL.absoluteString == "http://example-isp.test:8080/speedtest/random4000x4000.jpg")
        #expect(endpoints.latencyURL.absoluteString == "http://example-isp.test:8080/speedtest/latency.txt")
        #expect(endpoints.uploadURL.absoluteString == "http://example-isp.test:8080/speedtest/upload.php")
    }

    @Test func cacheBustingAppendsUniqueQueryItem() {
        let url = URL(string: "https://host.test/latency.txt")!
        let first = SpeedTester.bustingCache(url)
        #expect(first.absoluteString.hasPrefix("https://host.test/latency.txt?nocache="))
        // Random tokens: two busts of the same URL must not collide (else a cache between
        // runs could answer, inflating the measured numbers).
        #expect(first != SpeedTester.bustingCache(url))
        let sized = URL(string: "https://host.test/__down?bytes=0")!
        #expect(SpeedTester.bustingCache(sized).absoluteString.contains("bytes=0&nocache="))
    }

    @Test func uploadBodyHasExactSizeAndIsNotConstant() {
        let body = SpeedTester.makeUploadBody(byteCount: 200_000)
        #expect(body.count == 200_000)
        #expect(Set(body.prefix(4096)).count > 16)  // random block, not zero-fill
    }
}

// MARK: - Orchestration (mock transport)

/// Scripted transport: downloads yield fixed chunks on a timer, uploads report the body in
/// quarters, fetches answer after a fixed simulated round trip.
private final class MockSpeedTestTransport: SpeedTestTransport, @unchecked Sendable {
    let ooklaDirectory: Data?
    let chunkSize: Int
    let chunksPerRequest: Int
    let chunkInterval: Duration
    let fetchDelay: Duration

    init(
        ooklaDirectory: Data? = nil,
        chunkSize: Int = 64 * 1024,
        chunksPerRequest: Int = 10,
        chunkInterval: Duration = .milliseconds(5),
        fetchDelay: Duration = .milliseconds(2)
    ) {
        self.ooklaDirectory = ooklaDirectory
        self.chunkSize = chunkSize
        self.chunksPerRequest = chunksPerRequest
        self.chunkInterval = chunkInterval
        self.fetchDelay = fetchDelay
    }

    func fetch(_ url: URL) async throws -> Data {
        if url.absoluteString.hasPrefix(OoklaServerDirectory.listURL.absoluteString) {
            if let ooklaDirectory { return ooklaDirectory }
            throw SpeedTestError.noServers
        }
        try await Task.sleep(for: fetchDelay)
        return Data()
    }

    func download(_ url: URL) async throws -> AsyncThrowingStream<Int, Error> {
        streamingChunks(count: chunksPerRequest, size: chunkSize, interval: chunkInterval)
    }

    func upload(_ url: URL, body: Data) async throws -> AsyncThrowingStream<Int, Error> {
        streamingChunks(count: 4, size: body.count / 4, interval: chunkInterval)
    }

    private func streamingChunks(count: Int, size: Int, interval: Duration) -> AsyncThrowingStream<Int, Error> {
        let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        let task = Task {
            for _ in 0..<count {
                try await Task.sleep(for: interval)
                continuation.yield(size)
            }
            continuation.finish()
        }
        continuation.onTermination = { reason in
            if case .cancelled = reason { task.cancel() }
        }
        return stream
    }
}

private let shortConfiguration = SpeedTestConfiguration(
    connectionCount: 2,
    latencySampleCount: 3,
    downloadDuration: .milliseconds(500),
    uploadDuration: .milliseconds(400),
    downloadRequestBytes: 1_000_000,
    uploadRequestBytes: 200_000,
    warmupFraction: 0.25,
    rateUpdateInterval: .milliseconds(100),
    loadedLatencyInterval: .milliseconds(100)
)

@Suite("Speed tester")
struct SpeedTesterTests {

    @Test func fullRunEmitsPhasesAndFinishes() async throws {
        let tester = SpeedTester(transport: MockSpeedTestTransport(), configuration: shortConfiguration)

        var phases: [SpeedTestPhase] = []
        var idleLatencies: [Double] = []
        var liveDownloadRates: [Double] = []
        var result: SpeedTestResult?
        for try await event in tester.run(provider: .cloudflare) {
            switch event {
            case .phase(let phase): phases.append(phase)
            case .idleLatency(let ms): idleLatencies.append(ms)
            case .downloadRate(let rate): liveDownloadRates.append(rate)
            case .server, .uploadRate: break
            case .finished(let final): result = final
            }
        }

        #expect(phases == [.findingServer, .latency, .download, .upload])
        #expect(idleLatencies.count == 3)

        let final = try #require(result)
        #expect(final.provider == .cloudflare)
        #expect(final.serverName == "Cloudflare")
        #expect(final.downloadBytesPerSecond > 0)
        #expect(final.uploadBytesPerSecond > 0)
        #expect(final.idleLatencyMilliseconds > 0)
        #expect(!liveDownloadRates.isEmpty)
    }

    @Test func ooklaRunUsesDirectoryServer() async throws {
        let directory = Data("""
        [{"url": "http://mock-server.test/speedtest/upload.php", "name": "Testville", "sponsor": "MockNet"}]
        """.utf8)
        let tester = SpeedTester(
            transport: MockSpeedTestTransport(ooklaDirectory: directory),
            configuration: shortConfiguration
        )

        var serverName: String?
        var result: SpeedTestResult?
        for try await event in tester.run(provider: .ookla) {
            if case .server(let name) = event { serverName = name }
            if case .finished(let final) = event { result = final }
        }

        #expect(serverName == "MockNet — Testville")
        let final = try #require(result)
        #expect(final.provider == .ookla)
        #expect(final.serverName == "MockNet — Testville")
    }

    @Test func emptyOoklaDirectoryFailsCleanly() async {
        let tester = SpeedTester(
            transport: MockSpeedTestTransport(ooklaDirectory: Data("[]".utf8)),
            configuration: shortConfiguration
        )
        await #expect(throws: SpeedTestError.noServers) {
            for try await _ in tester.run(provider: .ookla) {}
        }
    }

    @Test func cancellingConsumerAbortsWithoutResult() async throws {
        // Long phases so cancellation lands mid-download.
        let slow = SpeedTestConfiguration(
            connectionCount: 2,
            latencySampleCount: 1,
            downloadDuration: .seconds(30),
            uploadDuration: .seconds(30)
        )
        let tester = SpeedTester(transport: MockSpeedTestTransport(), configuration: slow)

        let consumer = Task { () -> Bool in
            var sawResult = false
            do {
                for try await event in tester.run(provider: .cloudflare) {
                    if case .finished = event { sawResult = true }
                }
            } catch {}
            return sawResult
        }
        try await Task.sleep(for: .milliseconds(300))
        consumer.cancel()
        #expect(await consumer.value == false)
    }
}

// MARK: - Real transport over loopback

/// Minimal POST-capable loopback server: reads the request head, consumes exactly
/// `Content-Length` body bytes, then answers `200 OK` — enough to exercise the real
/// upload path end to end.
private final class LoopbackUploadServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cloakdrop.loopback.upload")
    private(set) var port: UInt16 = 0

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(connection, buffer: Data(), expectedTotal: nil)
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func receive(_ connection: NWConnection, buffer: Data, expectedTotal: Int?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            var total = expectedTotal
            if total == nil, let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: accumulated[..<headerEnd.lowerBound], as: UTF8.self)
                let contentLength = header
                    .split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) }
                total = headerEnd.upperBound + (contentLength ?? 0)
            }

            if let total, accumulated.count >= total {
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if error == nil && !isComplete {
                self.receive(connection, buffer: accumulated, expectedTotal: total)
            } else {
                connection.cancel()
            }
        }
    }
}

@Suite("Speed test transport (loopback)")
struct SpeedTestTransportLoopbackTests {

    @Test func downloadStreamsAllBytesAsChunkCounts() async throws {
        let payload = Data(repeating: 0xA5, count: 512 * 1024)
        let server = try LoopbackHTTPServer(payload: payload)
        try await server.start()
        defer { server.stop() }

        let transport = URLSessionSpeedTestTransport()
        var received = 0
        for try await chunk in try await transport.download(server.baseURL.appending(path: "file.bin")) {
            received += chunk
        }
        #expect(received == payload.count)
    }

    @Test func fetchReturnsBody() async throws {
        let payload = Data("pong".utf8)
        let server = try LoopbackHTTPServer(payload: payload)
        try await server.start()
        defer { server.stop() }

        let transport = URLSessionSpeedTestTransport()
        let body = try await transport.fetch(server.baseURL.appending(path: "latency.txt"))
        #expect(body == payload)
    }

    @Test func uploadReportsEverySentByte() async throws {
        let server = try LoopbackUploadServer()
        try await server.start()
        defer { server.stop() }

        let transport = URLSessionSpeedTestTransport()
        let body = SpeedTester.makeUploadBody(byteCount: 300_000)
        var sent = 0
        for try await delta in try await transport.upload(server.baseURL.appending(path: "upload"), body: body) {
            sent += delta
        }
        #expect(sent == body.count)
    }
}
