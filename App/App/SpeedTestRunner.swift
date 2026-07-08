import Foundation
import Observation
import DownloadModels
import DownloadEngine

/// Drives one speed-test run at a time: consumes `SpeedTester`'s event stream into
/// observable live values and keeps the last completed result across launches.
///
/// Owned by `AppModel` (the app/core bridge) so every surface — the Settings tab, the menu
/// bar, future automation — observes the same run instead of spawning its own.
@MainActor @Observable
final class SpeedTestRunner {
    enum Status: Equatable {
        case idle
        case running(SpeedTestPhase)
        case failed
    }

    private(set) var status: Status = .idle
    private(set) var serverName: String?
    private(set) var liveDownloadRate: Double?
    private(set) var liveUploadRate: Double?
    private(set) var liveLatency: Double?
    private(set) var lastResult: SpeedTestResult?

    private var task: Task<Void, Never>?
    /// Monotonic run token: a superseded run's trailing writes (status, `task = nil`) are
    /// dropped so they can't clobber the run that replaced it.
    private var runID = 0
    private static let lastResultKey = "speedTest.lastResult"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.lastResultKey) {
            lastResult = try? JSONDecoder().decode(SpeedTestResult.self, from: data)
        }
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// Start a run against `provider`, routed through `proxy` — the same path downloads
    /// take, so the test measures what the engine can actually achieve (and never bypasses
    /// a proxy the user set up on purpose).
    func start(provider: SpeedTestProvider, proxy: ProxyConfiguration) {
        guard !isRunning else { return }
        task?.cancel()
        runID += 1
        let id = runID

        status = .running(.findingServer)
        serverName = nil
        liveDownloadRate = nil
        liveUploadRate = nil
        liveLatency = nil

        let tester = SpeedTester(transport: URLSessionSpeedTestTransport(proxy: proxy))
        task = Task {
            do {
                for try await event in tester.run(provider: provider) {
                    guard id == runID else { return }
                    apply(event)
                }
                // A cancelled stream can end without a result; don't stay stuck "running".
                if id == runID, isRunning { status = .idle }
            } catch is CancellationError {
                if id == runID { status = .idle }
            } catch {
                if id == runID { status = .failed }
            }
            if id == runID { task = nil }
        }
    }

    func stop() {
        task?.cancel()
    }

    private func apply(_ event: SpeedTestEvent) {
        switch event {
        case .phase(let phase):
            status = .running(phase)
        case .server(let name):
            serverName = name
        case .idleLatency(let milliseconds):
            liveLatency = milliseconds
        case .downloadRate(let rate):
            liveDownloadRate = rate
        case .uploadRate(let rate):
            liveUploadRate = rate
        case .finished(let result):
            lastResult = result
            status = .idle
            if let data = try? JSONEncoder().encode(result) {
                UserDefaults.standard.set(data, forKey: Self.lastResultKey)
            }
        }
    }
}
