import SwiftUI

enum RunnerPhase {
    case ready
    case running
    case gameOver
}

struct RunnerObstacle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var variant: RunnerObstacleVariant
    var hasPassedPlayer = false
}

/// A deliberately bold, code-drawn game card for the two moments where the runner needs a clear
/// decision. Its flat solid layers match the scene's 2D pixel artwork without placing glass over
/// scrolling/game content.
struct RunnerPhasePanel: View {
    enum State {
        case ready(bestScore: Int)
        case finished(score: Int, bestScore: Int, isNewBest: Bool)
    }

    let state: State
    let availableSize: CGSize
    let isNight: Bool

    private var isCompact: Bool {
        availableSize.height < 460 || availableSize.width < 640
    }

    private var contentWidth: CGFloat {
        let reservedSpace: CGFloat = isCompact ? 46 : 64
        return max(220, min(availableSize.width - reservedSpace, isCompact ? 360 : 396))
    }

    private var title: String {
        switch state {
        case .ready:
            String(localized: "Ready for the trail?")
        case let .finished(_, _, isNewBest):
            if isNewBest {
                String(localized: "New best!")
            } else {
                String(localized: "Run complete")
            }
        }
    }

    private var subtitle: String {
        switch state {
        case .ready:
            String(localized: "Leap over the wild trail and chase your best score.")
        case let .finished(_, _, isNewBest):
            if isNewBest {
                String(localized: "You raised the bar. Can you beat it again?")
            } else {
                String(localized: "Good run. The trail is ready for another try.")
            }
        }
    }

    private var actionTitle: String {
        switch state {
        case .ready:
            String(localized: "Start Run")
        case .finished:
            String(localized: "Run Again")
        }
    }

    private var artworkKind: RunnerPhaseArtwork.Kind {
        switch state {
        case .ready:
            .start
        case let .finished(_, _, isNewBest):
            isNewBest ? .record : .finish
        }
    }

    var body: some View {
        Group {
            if isCompact {
                compactLayout
            } else {
                expandedLayout
            }
        }
        .frame(width: contentWidth)
        .padding(isCompact ? 14 : 22)
        .background {
            RunnerPixelPanelShape(step: isCompact ? 4 : 6)
                .fill(panelBackground)
        }
        .overlay(panelBorder)
    }

    private var compactLayout: some View {
        HStack(spacing: 14) {
            RunnerPhaseArtwork(kind: artworkKind, isNight: isNight)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title3.weight(.heavy))
                if case let .finished(score, bestScore, _) = state {
                    Text("Score \(score)  •  Best \(bestScore)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                actionLabel(compact: true)
            }

            Spacer(minLength: 0)
        }
    }

    private var expandedLayout: some View {
        VStack(spacing: 13) {
            RunnerPhaseArtwork(kind: artworkKind, isNight: isNight)
                .frame(width: 116, height: 116)

            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            scoreSummary
            actionLabel(compact: false)

            HStack(spacing: 6) {
                RunnerKeycap(title: "Space")
                Text("or")
                RunnerKeycap(title: "↑")
                Text("or click anywhere")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var scoreSummary: some View {
        switch state {
        case let .ready(bestScore):
            if bestScore > 0 {
                RunnerScoreTile(label: String(localized: "BEST"), value: bestScore, isNight: isNight)
            }
        case let .finished(score, bestScore, _):
            HStack(spacing: 10) {
                RunnerScoreTile(label: String(localized: "SCORE"), value: score, isNight: isNight)
                RunnerScoreTile(label: String(localized: "BEST"), value: bestScore, isNight: isNight)
            }
        }
    }

    private func actionLabel(compact: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: state.isReady ? "play.fill" : "arrow.counterclockwise")
                .font(.system(size: compact ? 12 : 15, weight: .bold))
            Text(actionTitle)
                .font((compact ? Font.callout : Font.headline).weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 15 : 24)
        .frame(height: compact ? 36 : 48)
        .frame(maxWidth: compact ? 150 : 230)
        .background {
            let shape = RunnerPixelButtonShape(cut: compact ? 3 : 5)
            ZStack {
                shape.fill(actionColor)

                VStack(spacing: 0) {
                    Rectangle()
                        .fill(.white.opacity(0.20))
                        .frame(height: 2)
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(actionEdgeColor)
                        .frame(height: compact ? 3 : 4)
                }
                .padding(.horizontal, compact ? 3 : 5)
                .clipShape(shape)
            }
        }
        .overlay {
            RunnerPixelButtonShape(cut: compact ? 3 : 5)
                .stroke(actionEdgeColor, lineWidth: 2)
        }
    }

    private var actionColor: Color {
        isNight
            ? Color(red: 0.12, green: 0.48, blue: 0.43)
            : Color(red: 0.12, green: 0.43, blue: 0.29)
    }

    private var actionEdgeColor: Color {
        isNight
            ? Color(red: 0.04, green: 0.22, blue: 0.22)
            : Color(red: 0.05, green: 0.25, blue: 0.17)
    }

    private var panelBackground: some ShapeStyle {
        isNight
            ? Color(red: 0.09, green: 0.14, blue: 0.21)
            : Color(red: 0.97, green: 0.965, blue: 0.90)
    }

    private var panelBorder: some View {
        RunnerPixelPanelShape(step: isCompact ? 4 : 6)
            .stroke(
                isNight
                    ? Color(red: 0.31, green: 0.48, blue: 0.55)
                    : Color(red: 0.20, green: 0.40, blue: 0.34),
                lineWidth: isCompact ? 2 : 3
            )
    }
}

private extension RunnerPhasePanel.State {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

private struct RunnerScoreTile: View {
    let label: String
    let value: Int
    let isNight: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2.weight(.black))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.title3.weight(.heavy).monospacedDigit())
        }
        .frame(minWidth: 92)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isNight ? Color.white.opacity(0.07) : Color(red: 0.20, green: 0.40, blue: 0.34).opacity(0.10),
            in: RunnerPixelPanelShape(step: 3)
        )
        .overlay {
            RunnerPixelPanelShape(step: 3)
                .stroke(isNight ? Color.white.opacity(0.10) : Color.black.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct RunnerKeycap: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold).monospaced())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.primary.opacity(0.08), in: RunnerPixelPanelShape(step: 2))
            .overlay {
                RunnerPixelPanelShape(step: 2)
                    .stroke(.primary.opacity(0.12), lineWidth: 1)
            }
    }
}

/// Orthogonal stair-step corners keep every panel edge on the same square grid as the scenery.
private struct RunnerPixelPanelShape: Shape {
    let step: CGFloat

    func path(in rect: CGRect) -> Path {
        let pixel = min(max(1, step), min(rect.width, rect.height) / 6)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + pixel * 2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - pixel * 2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - pixel * 2, y: rect.minY + pixel))
        path.addLine(to: CGPoint(x: rect.maxX - pixel, y: rect.minY + pixel))
        path.addLine(to: CGPoint(x: rect.maxX - pixel, y: rect.minY + pixel * 2))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + pixel * 2))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - pixel * 2))
        path.addLine(to: CGPoint(x: rect.maxX - pixel, y: rect.maxY - pixel * 2))
        path.addLine(to: CGPoint(x: rect.maxX - pixel, y: rect.maxY - pixel))
        path.addLine(to: CGPoint(x: rect.maxX - pixel * 2, y: rect.maxY - pixel))
        path.addLine(to: CGPoint(x: rect.maxX - pixel * 2, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + pixel * 2, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + pixel * 2, y: rect.maxY - pixel))
        path.addLine(to: CGPoint(x: rect.minX + pixel, y: rect.maxY - pixel))
        path.addLine(to: CGPoint(x: rect.minX + pixel, y: rect.maxY - pixel * 2))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - pixel * 2))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + pixel * 2))
        path.addLine(to: CGPoint(x: rect.minX + pixel, y: rect.minY + pixel * 2))
        path.addLine(to: CGPoint(x: rect.minX + pixel, y: rect.minY + pixel))
        path.addLine(to: CGPoint(x: rect.minX + pixel * 2, y: rect.minY + pixel))
        path.closeSubpath()
        return path
    }
}

/// A single-cut chamfer keeps the primary action crisp and familiar without the busier stair-step
/// silhouette used by the larger game card.
private struct RunnerPixelButtonShape: Shape {
    let cut: CGFloat

    func path(in rect: CGRect) -> Path {
        let pixel = min(max(1, cut), min(rect.width, rect.height) / 4)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + pixel, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - pixel, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + pixel))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - pixel))
        path.addLine(to: CGPoint(x: rect.maxX - pixel, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + pixel, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - pixel))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + pixel))
        path.closeSubpath()
        return path
    }
}

/// Large pixel-art illustrations make the start and result states legible at a glance while using
/// the same restrained palette and square-grid construction as the runner sprites.
private struct RunnerPhaseArtwork: View {
    enum Kind: Equatable {
        case start
        case finish
        case record
    }

    let kind: Kind
    let isNight: Bool

    var body: some View {
        Canvas { context, size in
            let grid: CGFloat = 24
            let pixel = max(1, floor(min(size.width, size.height) / grid))
            let origin = CGPoint(
                x: floor((size.width - grid * pixel) / 2),
                y: floor((size.height - grid * pixel) / 2)
            )

            func fill(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: Color) {
                context.fill(
                    Path(CGRect(
                        x: origin.x + x * pixel,
                        y: origin.y + y * pixel,
                        width: width * pixel,
                        height: height * pixel
                    )),
                    with: .color(color)
                )
            }

            let outline = isNight
                ? Color(red: 0.04, green: 0.08, blue: 0.12)
                : Color(red: 0.12, green: 0.25, blue: 0.23)
            let sky = isNight
                ? Color(red: 0.11, green: 0.24, blue: 0.34)
                : Color(red: 0.58, green: 0.80, blue: 0.88)
            let skyLight = isNight
                ? Color(red: 0.22, green: 0.38, blue: 0.44)
                : Color(red: 0.79, green: 0.91, blue: 0.91)
            let grass = isNight
                ? Color(red: 0.22, green: 0.46, blue: 0.30)
                : Color(red: 0.34, green: 0.64, blue: 0.34)
            let grassLight = isNight
                ? Color(red: 0.33, green: 0.57, blue: 0.36)
                : Color(red: 0.52, green: 0.75, blue: 0.39)
            let gold = Color(red: 0.96, green: 0.66, blue: 0.18)
            let goldLight = Color(red: 1.0, green: 0.83, blue: 0.34)
            let goldShadow = Color(red: 0.70, green: 0.35, blue: 0.10)

            fill(2, 2, 20, 20, outline)
            fill(3, 3, 18, 18, sky)
            fill(4, 4, 16, 2, skyLight.opacity(0.42))

            switch kind {
            case .start:
                fill(3, 15, 18, 6, grass)
                fill(3, 15, 18, 2, grassLight)
                fill(5, 18, 4, 3, Color(red: 0.72, green: 0.53, blue: 0.31))
                fill(8, 17, 4, 4, Color(red: 0.78, green: 0.60, blue: 0.36))
                fill(11, 16, 4, 5, Color(red: 0.84, green: 0.68, blue: 0.43))
                fill(17, 6, 2, 13, outline)
                fill(18, 7, 4, 2, Color(red: 0.88, green: 0.26, blue: 0.20))
                fill(18, 9, 3, 2, Color(red: 0.96, green: 0.43, blue: 0.22))
                fill(6, 11, 5, 1, .white.opacity(isNight ? 0.55 : 0.72))
                fill(7, 10, 3, 1, .white.opacity(isNight ? 0.55 : 0.72))

            case .finish, .record:
                let baseY: CGFloat = kind == .record ? 17 : 18
                fill(8, 8, 8, 2, outline)
                fill(7, 9, 10, 6, outline)
                fill(9, 10, 6, 5, gold)
                fill(10, 10, 2, 4, goldLight)
                fill(6, 9, 2, 4, goldShadow)
                fill(16, 9, 2, 4, goldShadow)
                fill(10, 15, 4, 3, outline)
                fill(11, 15, 2, 3, goldShadow)
                fill(8, baseY, 8, 3, outline)
                fill(9, baseY, 6, 1, gold)
                fill(5, 6, 2, 2, goldLight)
                fill(18, 5, 2, 2, goldLight)
                fill(4, 12, 2, 2, Color(red: 0.91, green: 0.30, blue: 0.27))
                fill(18, 13, 2, 2, Color(red: 0.25, green: 0.61, blue: 0.77))

                if kind == .record {
                    fill(8, 4, 2, 3, goldShadow)
                    fill(11, 3, 2, 4, goldLight)
                    fill(14, 4, 2, 3, goldShadow)
                    fill(8, 6, 8, 2, gold)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
