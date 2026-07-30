import Combine
import SwiftUI

/// The browser's offline-page easter egg: a tiny native runner that stays entirely on-device.
///
/// The score is deliberately simple (survival time) and the best run lives in UserDefaults, so a
/// future offline visit can pick up the challenge without introducing another persistence system.
struct BrowserOfflineView: View {
    let message: String
    let host: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 5) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.title2.weight(.semibold))
                if let host {
                    Text(host)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            OfflineRunnerView()
                .frame(maxWidth: 580)

            Button("Try Again", action: onRetry)
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// A compact Chrome-dino-style runner with a CloakDrop character. Space, ↑, or a click starts the
/// run and jumps; obstacles speed up gradually. Only the integer high score is persisted.
private struct OfflineRunnerView: View {
    private enum Phase {
        case ready
        case running
        case gameOver
    }

    private struct Obstacle: Identifiable {
        let id = UUID()
        var x: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    @AppStorage("browser.offlineRunner.highScore") private var highScore = 0

    @State private var phase: Phase = .ready
    @State private var score = 0.0
    @State private var finalScore = 0
    @State private var isNewBest = false
    @State private var playerHeight: CGFloat = 0
    @State private var playerVelocity: CGFloat = 0
    @State private var obstacles: [Obstacle] = []
    @State private var nextGap: CGFloat = 280
    @State private var trackWidth: CGFloat = 520
    @State private var lastTick = Date()
    @FocusState private var isFocused: Bool

    private let ticks = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("Cloak Runner", systemImage: "figure.run")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("Score \(displayedScore)")
                    .monospacedDigit()
                Text("Best \(highScore)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            GeometryReader { geometry in
                runnerTrack(size: geometry.size)
                    .onAppear { trackWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in trackWidth = width }
            }
            .frame(height: 160)

            Text(instruction)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.secondary.opacity(0.065), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
        .contentShape(.rect)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onTapGesture { jumpOrStart() }
        .onKeyPress(.space) {
            jumpOrStart()
            return .handled
        }
        .onKeyPress(.upArrow) {
            jumpOrStart()
            return .handled
        }
        .onReceive(ticks) { tick(at: $0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cloak Runner")
        .accessibilityValue("Score \(displayedScore), best \(highScore)")
    }

    private var displayedScore: Int {
        phase == .gameOver ? finalScore : Int(score)
    }

    private var instruction: String {
        switch phase {
        case .ready:
            String(localized: "Press Space, ↑, or click to start")
        case .running:
            String(localized: "Space, ↑, or click to jump")
        case .gameOver:
            if isNewBest {
                String(localized: "New best! Press Space to run again")
            } else {
                String(localized: "Press Space to run again")
            }
        }
    }

    private func runnerTrack(size: CGSize) -> some View {
        let groundY = size.height - 22
        let playerX: CGFloat = 84

        return ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color.cyan.opacity(0.045),
                    Color.green.opacity(0.055)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .accessibilityHidden(true)

            decorativeSky

            Rectangle()
                .fill(Color(red: 0.39, green: 0.65, blue: 0.30).opacity(0.82))
                .frame(height: 2)
                .position(x: size.width / 2, y: groundY - 1)

            Rectangle()
                .fill(Color(red: 0.48, green: 0.32, blue: 0.17).opacity(0.68))
                .frame(height: 3)
                .position(x: size.width / 2, y: groundY + 1.5)

            ForEach(obstacles) { obstacle in
                PixelTreeObstacle()
                    .frame(width: obstacle.width, height: obstacle.height)
                    .position(x: obstacle.x, y: groundY - obstacle.height / 2 + 1)
                    .accessibilityHidden(true)
            }

            CloakedRunnerSprite(
                isMoving: phase == .running,
                isJumping: playerHeight > 1,
                runFrame: (Int(score * 0.75) % 4) + 1
            )
                .frame(width: 64, height: 76)
                .position(x: playerX, y: groundY - 38 - playerHeight)
                .accessibilityHidden(true)

            if phase != .running {
                VStack(spacing: 3) {
                    Text(phase == .ready ? "Ready?" : "Run over")
                        .font(.headline)
                    if phase == .gameOver {
                        Text("Score \(finalScore)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .allowsHitTesting(false)
            }
        }
        .clipped()
    }

    private var decorativeSky: some View {
        GeometryReader { geometry in
            ZStack {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.orange.opacity(0.48))
                    .position(x: geometry.size.width * 0.62, y: 26)
                Image(systemName: "cloud.fill")
                    .font(.title3)
                    .foregroundStyle(Color.blue.opacity(0.18))
                    .position(x: geometry.size.width * 0.32, y: 28)
                Image(systemName: "cloud.fill")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor.opacity(0.16))
                    .position(x: geometry.size.width * 0.76, y: 48)
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 62, weight: .regular))
                    .foregroundStyle(Color.green.opacity(0.09))
                    .position(x: geometry.size.width * 0.50, y: geometry.size.height - 44)
            }
        }
        .accessibilityHidden(true)
    }

    private func jumpOrStart() {
        isFocused = true
        switch phase {
        case .ready, .gameOver:
            startRun()
            playerVelocity = 330
        case .running:
            guard playerHeight <= 1 else { return }
            playerVelocity = 330
        }
    }

    private func startRun() {
        phase = .running
        score = 0
        finalScore = 0
        isNewBest = false
        playerHeight = 0
        playerVelocity = 0
        obstacles = [Obstacle(x: max(trackWidth, 360) + 54, width: 34, height: 46)]
        nextGap = 270
        lastTick = Date()
    }

    private func tick(at now: Date) {
        guard phase == .running else {
            lastTick = now
            return
        }

        let delta = min(max(now.timeIntervalSince(lastTick), 0), 0.05)
        lastTick = now
        guard delta > 0 else { return }

        let dt = CGFloat(delta)
        score += delta * 10
        let speed = CGFloat(190 + min(score * 0.55, 145))

        playerVelocity -= 1_080 * dt
        playerHeight += playerVelocity * dt
        if playerHeight <= 0 {
            playerHeight = 0
            playerVelocity = 0
        }

        for index in obstacles.indices {
            obstacles[index].x -= speed * dt
        }
        obstacles.removeAll { $0.x < -50 }

        if let last = obstacles.last, last.x < trackWidth - nextGap {
            let tall = Bool.random()
            obstacles.append(Obstacle(
                x: trackWidth + 42,
                width: tall ? 36 : 30,
                height: tall ? 50 : 40
            ))
            nextGap = CGFloat.random(in: 235...345)
        }

        if obstacles.contains(where: collides(with:)) {
            finishRun()
        }
    }

    private func collides(with obstacle: Obstacle) -> Bool {
        let playerX: CGFloat = 84
        let horizontal = abs(obstacle.x - playerX) < (obstacle.width + 50) * 0.38
        let vertical = playerHeight < obstacle.height - 7
        return horizontal && vertical
    }

    private func finishRun() {
        finalScore = Int(score)
        phase = .gameOver
        if finalScore > highScore {
            highScore = finalScore
            isNewBest = true
        }
    }
}

/// A tiny colored pixel tree keeps the obstacle in the same visual language as the runner.
private struct PixelTreeObstacle: View {
    var body: some View {
        Canvas { context, size in
            let pixel = floor(min(size.width / 10, size.height / 14))
            let origin = CGPoint(
                x: floor((size.width - pixel * 10) / 2),
                y: floor((size.height - pixel * 14) / 2)
            )

            func fill(
                _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: Color
            ) {
                let rectangle = CGRect(
                    x: origin.x + x * pixel,
                    y: origin.y + y * pixel,
                    width: width * pixel,
                    height: height * pixel
                )
                context.fill(Path(rectangle), with: .color(color))
            }

            let leaf = Color(red: 0.25, green: 0.58, blue: 0.32)
            let leafLight = Color(red: 0.40, green: 0.71, blue: 0.41)
            let leafShadow = Color(red: 0.11, green: 0.35, blue: 0.19)
            let trunk = Color(red: 0.48, green: 0.29, blue: 0.13)
            let trunkShadow = Color(red: 0.29, green: 0.17, blue: 0.08)

            fill(4, 8, 2, 6, trunk)
            fill(5, 8, 1, 6, trunkShadow)
            fill(4, 0, 2, 1, leafShadow)
            fill(3, 1, 4, 1, leafShadow)
            fill(2, 2, 6, 2, leafShadow)
            fill(1, 4, 8, 2, leafShadow)
            fill(0, 6, 10, 3, leafShadow)
            fill(1, 9, 8, 2, leafShadow)
            fill(4, 1, 2, 1, leafLight)
            fill(3, 2, 4, 2, leaf)
            fill(2, 4, 6, 2, leaf)
            fill(1, 6, 8, 3, leaf)
            fill(2, 9, 6, 1, leaf)
            fill(3, 3, 2, 4, leafLight)
        }
    }
}

/// Six consistently authored poses packed into one asset keep movement crisp and prevent SwiftUI
/// from blending between pixel edges while the game animates.
private struct CloakedRunnerSprite: View {
    let isMoving: Bool
    let isJumping: Bool
    let runFrame: Int

    var body: some View {
        GeometryReader { geometry in
            Image("OfflineRunnerSprites")
                .resizable()
                .interpolation(.none)
                .frame(width: geometry.size.width * 6, height: geometry.size.height)
                .offset(x: -geometry.size.width * CGFloat(frameIndex))
        }
        .clipped()
    }

    private var frameIndex: Int {
        if !isMoving { return 0 }
        if isJumping { return 5 }
        return runFrame
    }
}
