import Combine
import SwiftUI

/// The browser's offline-page easter egg: a tiny native runner that stays entirely on-device.
///
/// The score is deliberately simple (survival time) and the best run lives in UserDefaults, so a
/// future offline visit can pick up the challenge without introducing another persistence system.
struct BrowserOfflineView: View {
    let message: String
    let host: String?
    let symbolName: String
    let actionTitle: String
    let onRetry: () -> Void

    init(
        message: String,
        host: String?,
        symbolName: String = "wifi.slash",
        actionTitle: String = String(localized: "Try Again"),
        onRetry: @escaping () -> Void
    ) {
        self.message = message
        self.host = host
        self.symbolName = symbolName
        self.actionTitle = actionTitle
        self.onRetry = onRetry
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = min(1_680, geometry.size.width * 0.96)
            let preferredTrackHeight = contentWidth * 0.45
            let availableTrackHeight = max(190, geometry.size.height - 195)
            let trackHeight = min(700, min(preferredTrackHeight, availableTrackHeight))
            let isRoomy = trackHeight >= 320

            VStack(spacing: isRoomy ? 14 : 10) {
                VStack(spacing: isRoomy ? 6 : 4) {
                    Image(systemName: symbolName)
                        .font(.system(size: isRoomy ? 38 : 32, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(isRoomy ? .title2.weight(.semibold) : .headline.weight(.semibold))
                    if let host {
                        Text(host)
                            .font((isRoomy ? Font.body : Font.callout).monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                OfflineRunnerView(trackHeight: trackHeight)
                    .frame(maxWidth: .infinity)

                Button(actionTitle, action: onRetry)
                    .controlSize(isRoomy ? .large : .regular)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(width: contentWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// The explicit `cloakdrop://runner` destination removes the offline-page explanation and retry
/// button, leaving only the game and the browser's own navigation chrome for an immersive break.
struct BrowserRunnerView: View {
    var body: some View {
        GeometryReader { geometry in
            let contentWidth = min(1_820, geometry.size.width * 0.985)
            let trackHeight = min(820, max(190, geometry.size.height - 105))

            OfflineRunnerView(trackHeight: trackHeight)
                .frame(width: contentWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// A responsive Chrome-dino-style runner with a CloakDrop character. Space, ↑, or a click starts
/// the run and jumps; obstacles speed up gradually. Only the integer high score is persisted.
private struct OfflineRunnerView: View {
    private enum Phase {
        case ready
        case running
        case gameOver
    }

    private struct Obstacle: Identifiable {
        let id = UUID()
        var x: CGFloat
        var variant: RunnerObstacleVariant
        var hasPassedPlayer = false
    }

    let trackHeight: CGFloat

    @AppStorage("browser.offlineRunner.highScore") private var highScore = 0
    @AppStorage("browser.offlineRunner.isMuted") private var isMuted = false
    @Environment(\.colorScheme) private var colorScheme

    @State private var phase: Phase = .ready
    @State private var score = 0.0
    @State private var finalScore = 0
    @State private var isNewBest = false
    @State private var playerHeight: CGFloat = 0
    @State private var playerVelocity: CGFloat = 0
    @State private var obstacles: [Obstacle] = []
    @State private var obstacleCursor = 0
    @State private var nextGap: CGFloat = 280
    @State private var trackWidth: CGFloat = 520
    @State private var trackScale: CGFloat = 1
    @State private var ambientTime: CGFloat = 0
    @State private var lastTick = Date()
    @State private var audio = RunnerAudioController()
    @FocusState private var isFocused: Bool
    private let ticks = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        let isExpanded = trackHeight >= 320

        VStack(spacing: isExpanded ? 12 : 8) {
            HStack(spacing: 8) {
                Label("Cloak Runner", systemImage: "figure.run")
                    .font((isExpanded ? Font.headline : Font.callout).weight(.semibold))
                Spacer()
                Text("Score \(displayedScore)")
                    .monospacedDigit()
                Text("Best \(highScore)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    isMuted.toggle()
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isMuted ? .secondary : .primary)
                .help(isMuted ? String(localized: "Turn game sound on") : String(localized: "Mute game sound"))
                .accessibilityLabel(isMuted ? Text("Turn game sound on") : Text("Mute game sound"))
            }
            .font(isExpanded ? .callout : .caption)

            GeometryReader { geometry in
                runnerTrack(size: geometry.size)
                    .onAppear { updateTrackMetrics(for: geometry.size) }
                    .onChange(of: geometry.size) { _, size in updateTrackMetrics(for: size) }
                    .contentShape(.rect)
                    .onTapGesture { jumpOrStart() }
            }
            .frame(height: trackHeight)

            Text(instruction)
                .font(isExpanded ? .callout : .caption)
                .foregroundStyle(.secondary)
        }
        .padding(isExpanded ? 20 : 14)
        .background(.secondary.opacity(0.065), in: .rect(cornerRadius: isExpanded ? 18 : 14))
        .overlay {
            RoundedRectangle(cornerRadius: isExpanded ? 18 : 14, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            audio.setMuted(isMuted)
        }
        .onDisappear { audio.stop() }
        .onChange(of: isMuted) { _, muted in audio.setMuted(muted) }
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
        let scale = sceneScale(for: size)
        let groundY = floor(size.height - 28 * scale)
        let groundDepth = size.height - groundY
        let playerX = 96 * scale
        let isNight = colorScheme == .dark

        return ZStack {
            LinearGradient(
                colors: isNight
                    ? [
                        Color(red: 0.035, green: 0.075, blue: 0.16),
                        Color(red: 0.07, green: 0.12, blue: 0.20),
                        Color(red: 0.10, green: 0.16, blue: 0.19)
                    ]
                    : [
                        Color.accentColor.opacity(0.10),
                        Color.cyan.opacity(0.045),
                        Color.green.opacity(0.055)
                    ],
                startPoint: .top,
                endPoint: .bottom
            )
            .accessibilityHidden(true)

            decorativeSky(in: size, scale: scale)

            Rectangle()
                .fill(
                    isNight
                        ? Color(red: 0.14, green: 0.11, blue: 0.10)
                        : Color(red: 0.48, green: 0.32, blue: 0.17).opacity(0.22)
                )
                .frame(height: groundDepth)
                .position(x: size.width / 2, y: groundY + groundDepth / 2)

            Rectangle()
                .fill(
                    isNight
                        ? Color(red: 0.24, green: 0.47, blue: 0.30)
                        : Color(red: 0.39, green: 0.65, blue: 0.30).opacity(0.86)
                )
                .frame(height: 3 * scale)
                .position(x: size.width / 2, y: groundY - 1.5 * scale)

            PixelGroundDetails(isNight: isNight)
                .frame(width: size.width, height: groundDepth)
                .position(x: size.width / 2, y: groundY + groundDepth / 2)
                .accessibilityHidden(true)

            ForEach(obstacles) { obstacle in
                let renderedWidth = (obstacle.variant.size.width * scale).rounded()
                let renderedHeight = (obstacle.variant.size.height * scale).rounded()
                let frame = Int(ambientTime * obstacle.variant.animationRate)

                PixelRunnerObstacle(variant: obstacle.variant, isNight: isNight, animationFrame: frame)
                    .frame(width: renderedWidth, height: renderedHeight)
                    .position(
                        x: obstacle.x.rounded(),
                        y: groundY - renderedHeight / 2
                    )
                    .accessibilityHidden(true)
            }

            CloakedRunnerSprite(
                isMoving: phase == .running,
                isJumping: playerHeight > 1,
                runFrame: (Int(score * 0.75) % 4) + 1
            )
                .frame(width: 64 * scale, height: 76 * scale)
                .position(x: playerX, y: groundY - (38 + playerHeight) * scale)
                .accessibilityHidden(true)

            if phase != .running {
                VStack(spacing: 3) {
                    Text(phase == .ready ? "Ready?" : "Run over")
                        .font(scale > 1.05 ? .title3.weight(.semibold) : .headline)
                    if phase == .gameOver {
                        Text("Score \(finalScore)")
                            .font((scale > 1.05 ? Font.callout : Font.caption).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16 * min(scale, 1.25))
                .padding(.vertical, 9 * min(scale, 1.25))
                .background(.regularMaterial, in: Capsule())
                .allowsHitTesting(false)
            }
        }
        .clipped()
    }

    private func decorativeSky(in size: CGSize, scale: CGFloat) -> some View {
        let isNight = colorScheme == .dark

        return ZStack {
            if isNight {
                PixelNightStars()
                    .frame(width: size.width, height: max(1, size.height * 0.64))
                    .position(x: size.width / 2, y: size.height * 0.30)

                Image(systemName: "moon.fill")
                    .font(.system(size: 48 * scale, weight: .medium))
                    .foregroundStyle(Color(red: 0.89, green: 0.91, blue: 0.72).opacity(0.90))
                    .shadow(color: .white.opacity(0.20), radius: 10 * scale)
                    .position(x: size.width * 0.70, y: 50 * scale)
            } else {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 48 * scale, weight: .medium))
                    .foregroundStyle(Color.orange.opacity(0.54))
                    .position(x: size.width * 0.70, y: 50 * scale)
            }

            Image(systemName: "cloud.fill")
                .font(.system(size: 54 * scale))
                .foregroundStyle((isNight ? Color.white : Color.blue).opacity(isNight ? 0.10 : 0.18))
                .scaleEffect(x: 1.15, y: 0.90)
                .position(x: size.width * 0.18, y: 58 * scale)
            Image(systemName: "cloud.fill")
                .font(.system(size: 38 * scale))
                .foregroundStyle((isNight ? Color.white : Color.accentColor).opacity(isNight ? 0.08 : 0.16))
                .scaleEffect(x: 1.20, y: 0.86)
                .position(x: size.width * 0.48, y: 92 * scale)
            Image(systemName: "cloud.fill")
                .font(.system(size: 46 * scale))
                .foregroundStyle((isNight ? Color.white : Color.blue).opacity(isNight ? 0.09 : 0.13))
                .scaleEffect(x: 1.10, y: 0.92)
                .position(x: size.width * 0.86, y: 68 * scale)

            flyingBirds(in: size, scale: scale, isNight: isNight)

            Image(systemName: "mountain.2.fill")
                .font(.system(size: 104 * scale, weight: .regular))
                .foregroundStyle((isNight ? Color.indigo : Color.green).opacity(isNight ? 0.22 : 0.075))
                .position(x: size.width * 0.22, y: size.height - 52 * scale)
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 142 * scale, weight: .regular))
                .foregroundStyle((isNight ? Color.blue : Color.accentColor).opacity(isNight ? 0.15 : 0.07))
                .position(x: size.width * 0.54, y: size.height - 65 * scale)
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 92 * scale, weight: .regular))
                .foregroundStyle((isNight ? Color.indigo : Color.green).opacity(isNight ? 0.18 : 0.065))
                .position(x: size.width * 0.84, y: size.height - 48 * scale)
        }
        .accessibilityHidden(true)
    }

    private func flyingBirds(in size: CGSize, scale: CGFloat, isNight: Bool) -> some View {
        let travel = size.width + 180 * scale
        let speeds: [CGFloat] = [24, 31, 27, 37]
        let offsets: [CGFloat] = [0.12, 0.40, 0.67, 0.86]
        let heights: [CGFloat] = [0.25, 0.17, 0.31, 0.22]

        return ZStack {
            ForEach(0..<4, id: \.self) { index in
                let distance = (ambientTime * speeds[index] + travel * offsets[index])
                    .truncatingRemainder(dividingBy: travel)
                let x = size.width + 90 * scale - distance
                let y = size.height * heights[index]
                    + sin(ambientTime * 0.8 + CGFloat(index)) * 5 * scale

                PixelBird(
                    wingsRaised: (Int(ambientTime * 5) + index) % 2 == 0,
                    color: isNight ? Color.white.opacity(0.55) : Color.black.opacity(0.42)
                )
                .frame(width: 22 * scale, height: 13 * scale)
                .position(x: x.rounded(), y: y.rounded())
            }
        }
    }

    private func sceneScale(for size: CGSize) -> CGFloat {
        min(max(size.height / 360, 0.85), 1.55)
    }

    private func updateTrackMetrics(for size: CGSize) {
        trackWidth = size.width
        trackScale = sceneScale(for: size)
    }

    private func jumpOrStart() {
        isFocused = true
        switch phase {
        case .ready, .gameOver:
            startRun()
            playerVelocity = 420
            audio.playJump()
        case .running:
            guard playerHeight <= 1 else { return }
            playerVelocity = 420
            audio.playJump()
        }
    }

    private func startRun() {
        phase = .running
        score = 0
        finalScore = 0
        isNewBest = false
        playerHeight = 0
        playerVelocity = 0
        obstacleCursor = Int.random(in: 0..<RunnerObstacleVariant.spawnOrder.count)
        let firstTree = RunnerObstacleVariant.roundTree
        obstacles = [Obstacle(
            x: max(trackWidth, 360) + 54 * trackScale,
            variant: firstTree
        )]
        nextGap = RunnerObstacleVariant.minimumCenterGap * trackScale
        lastTick = Date()
        audio.beginRun()
    }

    private func tick(at now: Date) {
        let delta = min(max(now.timeIntervalSince(lastTick), 0), 0.05)
        lastTick = now
        guard delta > 0 else { return }

        ambientTime = (ambientTime + CGFloat(delta)).truncatingRemainder(dividingBy: 3_600)
        guard phase == .running else { return }

        let dt = CGFloat(delta)
        score += delta * 10
        let speed = CGFloat(190 + min(score * 0.55, 145)) * trackScale
        let minimumGap = RunnerObstacleVariant.minimumCenterGap * trackScale
        playerVelocity -= 1_080 * dt
        playerHeight += playerVelocity * dt
        if playerHeight <= 0 {
            playerHeight = 0
            playerVelocity = 0
        }

        for index in obstacles.indices {
            let approachSpeed = obstacles[index].variant.approachSpeed * trackScale
            let safeX = index > 0 ? obstacles[index - 1].x + minimumGap : -.infinity
            obstacles[index].x = max(obstacles[index].x - (speed + approachSpeed) * dt, safeX)
            if !obstacles[index].hasPassedPlayer,
               obstacles[index].x + obstacles[index].variant.collisionWidth / 2 * trackScale
                    < 78 * trackScale {
                obstacles[index].hasPassedPlayer = true
                audio.playPass()
            }
        }
        obstacles.removeAll { $0.x < -80 * trackScale }

        if let last = obstacles.last, last.x < trackWidth - nextGap {
            let recentVariants = Set(obstacles.suffix(2).map(\.variant))
            var variant = RunnerObstacleVariant.spawnOrder[obstacleCursor % RunnerObstacleVariant.spawnOrder.count]
            obstacleCursor += 1
            if recentVariants.contains(variant) {
                variant = RunnerObstacleVariant.spawnOrder[obstacleCursor % RunnerObstacleVariant.spawnOrder.count]
                obstacleCursor += 1
            }
            obstacles.append(Obstacle(
                x: trackWidth + 48 * trackScale,
                variant: variant
            ))
            nextGap = CGFloat.random(in: 380...520) * trackScale
        }

        if obstacles.contains(where: collides(with:)) {
            finishRun()
        }
    }

    private func collides(with obstacle: Obstacle) -> Bool {
        let playerX = 96 * trackScale
        // The sprite's cape trails left of its body. Keep the hitbox on the torso so landing after
        // a tree has passed cannot punish the player for a few decorative cloak pixels.
        let playerCollisionCenter = playerX + 8 * trackScale
        let playerHalfWidth = 12 * trackScale
        let obstacleHalfWidth = obstacle.variant.collisionWidth / 2 * trackScale
        let horizontal = playerCollisionCenter + playerHalfWidth > obstacle.x - obstacleHalfWidth
            && playerCollisionCenter - playerHalfWidth < obstacle.x + obstacleHalfWidth
        let vertical = playerHeight < obstacle.variant.collisionHeight
        return horizontal && vertical
    }

    private func finishRun() {
        finalScore = Int(score)
        phase = .gameOver
        if finalScore > highScore {
            highScore = finalScore
            isNewBest = true
        }
        audio.endRun()
    }
}
