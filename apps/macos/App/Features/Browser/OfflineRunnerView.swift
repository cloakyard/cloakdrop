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
            let contentWidth = min(1_440, geometry.size.width * 0.92)
            let preferredTrackHeight = contentWidth * 0.34
            let availableTrackHeight = max(170, geometry.size.height - 220)
            let trackHeight = min(500, min(preferredTrackHeight, availableTrackHeight))
            let isRoomy = trackHeight >= 320

            VStack(spacing: isRoomy ? 18 : 12) {
                VStack(spacing: isRoomy ? 8 : 5) {
                    Image(systemName: symbolName)
                        .font(.system(size: isRoomy ? 42 : 34, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(isRoomy ? .title.weight(.semibold) : .title2.weight(.semibold))
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
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

enum TreeVariant: CaseIterable, Hashable {
    case round
    case pine
    case bush

    var size: CGSize {
        switch self {
        case .round:
            CGSize(width: 40, height: 56)
        case .pine:
            CGSize(width: 40, height: 64)
        case .bush:
            CGSize(width: 56, height: 40)
        }
    }

    var collisionWidth: CGFloat {
        switch self {
        case .round:
            28
        case .pine:
            24
        case .bush:
            38
        }
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
        var width: CGFloat
        var height: CGFloat
        var variant: TreeVariant
    }

    let trackHeight: CGFloat

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
    @State private var trackScale: CGFloat = 1
    @State private var lastTick = Date()
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
            }
            .font(isExpanded ? .callout : .caption)

            GeometryReader { geometry in
                runnerTrack(size: geometry.size)
                    .onAppear { updateTrackMetrics(for: geometry.size) }
                    .onChange(of: geometry.size) { _, size in updateTrackMetrics(for: size) }
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
        let scale = sceneScale(for: size)
        let groundY = floor(size.height - 28 * scale)
        let groundDepth = size.height - groundY
        let playerX = 96 * scale

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

            decorativeSky(in: size, scale: scale)

            Rectangle()
                .fill(Color(red: 0.48, green: 0.32, blue: 0.17).opacity(0.22))
                .frame(height: groundDepth)
                .position(x: size.width / 2, y: groundY + groundDepth / 2)

            Rectangle()
                .fill(Color(red: 0.39, green: 0.65, blue: 0.30).opacity(0.86))
                .frame(height: 3 * scale)
                .position(x: size.width / 2, y: groundY - 1.5 * scale)

            PixelGroundDetails()
                .frame(width: size.width, height: groundDepth)
                .position(x: size.width / 2, y: groundY + groundDepth / 2)
                .accessibilityHidden(true)

            ForEach(obstacles) { obstacle in
                let renderedWidth = (obstacle.width * scale).rounded()
                let renderedHeight = (obstacle.height * scale).rounded()

                PixelTreeObstacle(variant: obstacle.variant)
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
        ZStack {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 42 * scale, weight: .medium))
                .foregroundStyle(Color.orange.opacity(0.48))
                .position(x: size.width * 0.70, y: 46 * scale)

            Image(systemName: "cloud.fill")
                .font(.system(size: 50 * scale))
                .foregroundStyle(Color.blue.opacity(0.18))
                .scaleEffect(x: 1.15, y: 0.90)
                .position(x: size.width * 0.18, y: 58 * scale)
            Image(systemName: "cloud.fill")
                .font(.system(size: 34 * scale))
                .foregroundStyle(Color.accentColor.opacity(0.16))
                .scaleEffect(x: 1.20, y: 0.86)
                .position(x: size.width * 0.48, y: 92 * scale)
            Image(systemName: "cloud.fill")
                .font(.system(size: 42 * scale))
                .foregroundStyle(Color.blue.opacity(0.13))
                .scaleEffect(x: 1.10, y: 0.92)
                .position(x: size.width * 0.86, y: 68 * scale)

            Image(systemName: "mountain.2.fill")
                .font(.system(size: 104 * scale, weight: .regular))
                .foregroundStyle(Color.green.opacity(0.075))
                .position(x: size.width * 0.22, y: size.height - 52 * scale)
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 142 * scale, weight: .regular))
                .foregroundStyle(Color.accentColor.opacity(0.07))
                .position(x: size.width * 0.54, y: size.height - 65 * scale)
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 92 * scale, weight: .regular))
                .foregroundStyle(Color.green.opacity(0.065))
                .position(x: size.width * 0.84, y: size.height - 48 * scale)
        }
        .accessibilityHidden(true)
    }

    private func sceneScale(for size: CGSize) -> CGFloat {
        min(max(size.height / 360, 0.85), 1.4)
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
        case .running:
            guard playerHeight <= 1 else { return }
            playerVelocity = 420
        }
    }

    private func startRun() {
        phase = .running
        score = 0
        finalScore = 0
        isNewBest = false
        playerHeight = 0
        playerVelocity = 0
        let firstTree = TreeVariant.round
        obstacles = [Obstacle(
            x: max(trackWidth, 360) + 54 * trackScale,
            width: firstTree.size.width,
            height: firstTree.size.height,
            variant: firstTree
        )]
        nextGap = 270 * trackScale
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
        let speed = CGFloat(190 + min(score * 0.55, 145)) * trackScale

        playerVelocity -= 1_080 * dt
        playerHeight += playerVelocity * dt
        if playerHeight <= 0 {
            playerHeight = 0
            playerVelocity = 0
        }

        for index in obstacles.indices {
            obstacles[index].x -= speed * dt
        }
        obstacles.removeAll { $0.x < -60 * trackScale }

        if let last = obstacles.last, last.x < trackWidth - nextGap {
            let recentVariants = Set(obstacles.suffix(2).map(\.variant))
            let variants = TreeVariant.allCases.filter { !recentVariants.contains($0) }
            let variant = variants.randomElement() ?? .round
            obstacles.append(Obstacle(
                x: trackWidth + 48 * trackScale,
                width: variant.size.width,
                height: variant.size.height,
                variant: variant
            ))
            nextGap = CGFloat.random(in: 245...370) * trackScale
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
        let vertical = playerHeight < obstacle.height - 10
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
