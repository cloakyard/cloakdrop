import AVFoundation

/// A small procedural soundscape for Cloak Runner. Keeping the audio synthesized means the game
/// remains self-contained, works offline, and adds no bundled media or network dependency.
@MainActor
final class RunnerAudioController {
    private static let sampleRate = 22_050.0

    private let engine = AVAudioEngine()
    private let ambiencePlayer = AVAudioPlayerNode()
    private let effectsPlayer = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: RunnerAudioController.sampleRate,
        channels: 2
    )!

    private var isMuted = false
    private var isRunActive = false

    private lazy var ambienceBuffer = makeAmbientLoop()
    private lazy var jumpBuffer = makeTone(
        duration: 0.14,
        startFrequency: 360,
        endFrequency: 660,
        amplitude: 0.16
    )
    private lazy var passBuffer = makeTone(
        duration: 0.10,
        startFrequency: 720,
        endFrequency: 930,
        amplitude: 0.10
    )
    private lazy var crashBuffer = makeCrash()

    init() {
        engine.attach(ambiencePlayer)
        engine.attach(effectsPlayer)
        engine.connect(ambiencePlayer, to: engine.mainMixerNode, format: format)
        engine.connect(effectsPlayer, to: engine.mainMixerNode, format: format)
        ambiencePlayer.volume = 0.38
        effectsPlayer.volume = 0.72
        engine.prepare()
    }

    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        if muted {
            ambiencePlayer.stop()
            effectsPlayer.stop()
        } else if isRunActive {
            startAmbience()
        }
    }

    func beginRun() {
        isRunActive = true
        guard !isMuted else { return }
        startAmbience()
    }

    func playJump() {
        playEffect(jumpBuffer)
    }

    func playPass() {
        playEffect(passBuffer)
    }

    func endRun() {
        isRunActive = false
        ambiencePlayer.stop()
        playEffect(crashBuffer)
    }

    func stop() {
        isRunActive = false
        ambiencePlayer.stop()
        effectsPlayer.stop()
        engine.pause()
    }

    private func startAmbience() {
        guard startEngineIfNeeded() else { return }
        ambiencePlayer.stop()
        ambiencePlayer.scheduleBuffer(ambienceBuffer, at: nil, options: .loops)
        ambiencePlayer.play()
    }

    private func playEffect(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted, startEngineIfNeeded() else { return }
        effectsPlayer.stop()
        effectsPlayer.scheduleBuffer(buffer)
        effectsPlayer.play()
    }

    private func startEngineIfNeeded() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            // Audio is an enhancement: a missing or changing output device must never stop play.
            return false
        }
    }

    private func makeAmbientLoop() -> AVAudioPCMBuffer {
        let duration = 4.0
        let notes = [261.63, 329.63, 392.00, 329.63, 293.66, 349.23, 440.00, 349.23]

        return makeBuffer(duration: duration) { time in
            let beatLength = 0.50
            let beat = min(Int(time / beatLength), notes.count - 1)
            let beatTime = time.truncatingRemainder(dividingBy: beatLength)
            let attack = min(beatTime / 0.025, 1)
            let decay = max(0, 1 - beatTime / beatLength)
            let envelope = attack * decay
            let frequency = notes[beat]
            let melody = triangleWave(frequency: frequency, at: time)
                + 0.16 * triangleWave(frequency: frequency * 2, at: time)
            let bass = triangleWave(frequency: frequency / 2, at: time) * 0.28
            let loopProgress = time / duration
            let slowSwell = 0.86 + 0.14 * (1 - abs(loopProgress * 2 - 1))
            let loopFade = min(1, min(time / 0.025, (duration - time) / 0.025))
            return Float((melody + bass) * envelope * slowSwell * loopFade * 0.115)
        }
    }

    private func triangleWave(frequency: Double, at time: Double) -> Double {
        let phase = (time * frequency).truncatingRemainder(dividingBy: 1)
        return 1 - 4 * abs(phase - 0.5)
    }

    private func makeTone(
        duration: Double,
        startFrequency: Double,
        endFrequency: Double,
        amplitude: Double
    ) -> AVAudioPCMBuffer {
        makeBuffer(duration: duration) { time in
            let progress = time / duration
            let frequency = startFrequency + (endFrequency - startFrequency) * progress
            let envelope = sin(.pi * progress)
            let fundamental = sin(2 * .pi * frequency * time)
            let sparkle = sin(2 * .pi * frequency * 2 * time) * 0.18
            return Float((fundamental + sparkle) * envelope * amplitude)
        }
    }

    private func makeCrash() -> AVAudioPCMBuffer {
        let duration = 0.34
        return makeBuffer(duration: duration) { time in
            let progress = time / duration
            let frequency = 240 - 150 * progress
            let envelope = pow(1 - progress, 1.6)
            let tone = sin(2 * .pi * frequency * time)
            let grit = sin(2 * .pi * 1_973 * time) * sin(2 * .pi * 113 * time)
            return Float((tone * 0.16 + grit * 0.045) * envelope)
        }
    }

    private func makeBuffer(
        duration: Double,
        sample: (Double) -> Float
    ) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount((duration * Self.sampleRate).rounded(.up))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        if let channels = buffer.floatChannelData {
            for frame in 0..<Int(frameCount) {
                let value = sample(Double(frame) / Self.sampleRate)
                channels[0][frame] = value
                channels[1][frame] = value * 0.96
            }
        }
        return buffer
    }
}
