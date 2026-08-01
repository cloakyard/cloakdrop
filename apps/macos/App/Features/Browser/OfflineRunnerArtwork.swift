import SwiftUI

enum RunnerObstacleVariant: CaseIterable, Hashable {
    case roundTree
    case pineTree
    case bush
    case rock
    case fallenLog
    case mushrooms
    case rabbit
    case fox
    case hedgehog
    case wildBoar

    /// Alternates scenery and wildlife so every run feels varied without animal clusters.
    static let spawnOrder: [Self] = [
        .roundTree, .rabbit, .rock, .fox, .pineTree,
        .hedgehog, .bush, .wildBoar, .fallenLog, .mushrooms
    ]

    /// Center-to-center clearance that leaves one full jump cycle at the fastest game speed.
    static let minimumCenterGap: CGFloat = 380

    var size: CGSize {
        switch self {
        case .roundTree:
            CGSize(width: 44, height: 62)
        case .pineTree:
            CGSize(width: 42, height: 68)
        case .bush:
            CGSize(width: 58, height: 42)
        case .rock:
            CGSize(width: 48, height: 34)
        case .fallenLog:
            CGSize(width: 66, height: 30)
        case .mushrooms:
            CGSize(width: 50, height: 34)
        case .rabbit:
            CGSize(width: 48, height: 44)
        case .fox:
            CGSize(width: 68, height: 44)
        case .hedgehog:
            CGSize(width: 52, height: 34)
        case .wildBoar:
            CGSize(width: 64, height: 46)
        }
    }

    var collisionWidth: CGFloat {
        switch self {
        case .roundTree:
            30
        case .pineTree:
            26
        case .bush:
            40
        case .rock:
            38
        case .fallenLog:
            54
        case .mushrooms:
            38
        case .rabbit:
            32
        case .fox:
            54
        case .hedgehog:
            40
        case .wildBoar:
            50
        }
    }

    /// How high the player must be before their boots are clear of the visible obstacle.
    var collisionHeight: CGFloat {
        switch self {
        case .roundTree:
            52
        case .pineTree:
            58
        case .bush:
            32
        case .rock:
            24
        case .fallenLog:
            20
        case .mushrooms:
            23
        case .rabbit:
            28
        case .fox:
            31
        case .hedgehog:
            22
        case .wildBoar:
            34
        }
    }

    var animalVariant: RunnerAnimalVariant? {
        switch self {
        case .rabbit:
            .rabbit
        case .fox:
            .fox
        case .hedgehog:
            .hedgehog
        case .wildBoar:
            .wildBoar
        default:
            nil
        }
    }

    var animationRate: CGFloat {
        switch self {
        case .rabbit:
            5
        case .fox:
            8
        case .hedgehog:
            7
        case .wildBoar:
            6
        default:
            0
        }
    }

    /// Extra speed toward the player, on top of the world's scrolling speed.
    var approachSpeed: CGFloat {
        switch self {
        case .rabbit:
            58
        case .fox:
            86
        case .hedgehog:
            34
        case .wildBoar:
            72
        default:
            0
        }
    }
}

/// Grounded scenery and animated animals keep repeat runs varied without breaking the calm style.
struct PixelRunnerObstacle: View {
    let variant: RunnerObstacleVariant
    let isNight: Bool
    let animationFrame: Int

    @ViewBuilder
    var body: some View {
        if let animalVariant = variant.animalVariant {
            PixelAnimalObstacle(
                variant: animalVariant,
                isNight: isNight,
                animationFrame: animationFrame
            )
        } else {
            sceneryArtwork
        }
    }

    private var sceneryArtwork: some View {
        Canvas { context, size in
            let gridSize: CGSize = switch variant {
            case .roundTree:
                CGSize(width: 10, height: 14)
            case .pineTree:
                CGSize(width: 10, height: 16)
            case .bush:
                CGSize(width: 14, height: 10)
            case .rock:
                CGSize(width: 12, height: 9)
            case .fallenLog:
                CGSize(width: 18, height: 8)
            case .mushrooms:
                CGSize(width: 14, height: 9)
            case .rabbit, .fox, .hedgehog, .wildBoar:
                .zero
            }
            let rawPixel = min(size.width / gridSize.width, size.height / gridSize.height)
            let pixel = floor(rawPixel * 2) / 2
            let origin = CGPoint(
                x: floor((size.width - pixel * gridSize.width) / 2),
                y: size.height - pixel * gridSize.height
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

            let leaf = isNight
                ? Color(red: 0.20, green: 0.46, blue: 0.31)
                : Color(red: 0.25, green: 0.58, blue: 0.32)
            let leafLight = isNight
                ? Color(red: 0.30, green: 0.58, blue: 0.38)
                : Color(red: 0.40, green: 0.71, blue: 0.41)
            let leafShadow = isNight
                ? Color(red: 0.08, green: 0.25, blue: 0.18)
                : Color(red: 0.11, green: 0.35, blue: 0.19)
            let trunk = isNight
                ? Color(red: 0.37, green: 0.24, blue: 0.14)
                : Color(red: 0.48, green: 0.29, blue: 0.13)
            let trunkShadow = isNight
                ? Color(red: 0.21, green: 0.14, blue: 0.10)
                : Color(red: 0.29, green: 0.17, blue: 0.08)

            switch variant {
            case .roundTree:
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

            case .pineTree:
                let pine = isNight
                    ? Color(red: 0.14, green: 0.38, blue: 0.30)
                    : Color(red: 0.18, green: 0.49, blue: 0.35)
                let pineLight = isNight
                    ? Color(red: 0.24, green: 0.50, blue: 0.36)
                    : Color(red: 0.31, green: 0.64, blue: 0.43)
                fill(4, 11, 2, 5, trunk)
                fill(5, 11, 1, 5, trunkShadow)
                fill(4, 0, 2, 2, leafShadow)
                fill(3, 2, 4, 2, leafShadow)
                fill(2, 4, 6, 3, leafShadow)
                fill(1, 7, 8, 3, leafShadow)
                fill(0, 10, 10, 3, leafShadow)
                fill(4, 1, 1, 2, pineLight)
                fill(3, 3, 2, 3, pineLight)
                fill(2, 6, 5, 3, pine)
                fill(1, 9, 7, 2, pine)

            case .bush:
                let bush = isNight
                    ? Color(red: 0.24, green: 0.49, blue: 0.29)
                    : Color(red: 0.31, green: 0.63, blue: 0.31)
                let bushLight = isNight
                    ? Color(red: 0.34, green: 0.58, blue: 0.34)
                    : Color(red: 0.47, green: 0.74, blue: 0.38)
                fill(6, 7, 2, 3, trunk)
                fill(7, 7, 1, 3, trunkShadow)
                fill(3, 1, 4, 2, leafShadow)
                fill(8, 0, 3, 2, leafShadow)
                fill(1, 3, 12, 4, leafShadow)
                fill(0, 5, 14, 3, leafShadow)
                fill(3, 2, 4, 3, bushLight)
                fill(8, 1, 2, 3, bushLight)
                fill(2, 4, 10, 3, bush)
                fill(4, 7, 6, 1, bush)

            case .rock:
                let rock = isNight
                    ? Color(red: 0.34, green: 0.39, blue: 0.45)
                    : Color(red: 0.46, green: 0.51, blue: 0.54)
                let rockLight = isNight
                    ? Color(red: 0.45, green: 0.51, blue: 0.58)
                    : Color(red: 0.65, green: 0.69, blue: 0.69)
                let rockShadow = isNight
                    ? Color(red: 0.20, green: 0.24, blue: 0.30)
                    : Color(red: 0.31, green: 0.35, blue: 0.37)
                fill(4, 1, 4, 1, rockShadow)
                fill(2, 2, 8, 2, rockShadow)
                fill(1, 4, 10, 3, rockShadow)
                fill(0, 7, 12, 2, rockShadow)
                fill(4, 2, 3, 1, rockLight)
                fill(3, 3, 5, 2, rock)
                fill(2, 5, 7, 2, rock)
                fill(2, 7, 8, 1, rock)

            case .fallenLog:
                let bark = isNight
                    ? Color(red: 0.38, green: 0.24, blue: 0.14)
                    : Color(red: 0.53, green: 0.32, blue: 0.15)
                let barkLight = isNight
                    ? Color(red: 0.51, green: 0.32, blue: 0.16)
                    : Color(red: 0.69, green: 0.42, blue: 0.19)
                let rings = Color(red: 0.77, green: 0.55, blue: 0.28)
                    .opacity(isNight ? 0.72 : 1)
                fill(2, 2, 13, 6, trunkShadow)
                fill(1, 3, 15, 4, bark)
                fill(3, 2, 10, 2, barkLight)
                fill(0, 4, 3, 3, rings)
                fill(1, 5, 1, 1, trunkShadow)
                fill(15, 3, 3, 4, trunkShadow)
                fill(16, 4, 1, 2, rings)
                fill(5, 1, 2, 2, leafShadow)
                fill(12, 0, 3, 3, leaf)

            case .mushrooms:
                let cap = Color(red: 0.83, green: 0.24, blue: 0.20)
                    .opacity(isNight ? 0.82 : 1)
                let capLight = Color(red: 0.96, green: 0.49, blue: 0.29)
                    .opacity(isNight ? 0.82 : 1)
                let stem = Color(red: 0.84, green: 0.75, blue: 0.55)
                    .opacity(isNight ? 0.78 : 1)
                fill(2, 3, 2, 5, stem)
                fill(8, 4, 2, 4, stem)
                fill(12, 6, 1, 3, stem)
                fill(0, 2, 6, 3, cap)
                fill(1, 1, 4, 1, cap)
                fill(1, 2, 2, 1, capLight)
                fill(6, 3, 6, 3, cap)
                fill(8, 2, 3, 1, cap)
                fill(7, 3, 2, 1, capLight)
                fill(10, 5, 4, 2, cap)
                fill(11, 4, 2, 1, cap)

            case .rabbit, .fox, .hedgehog, .wildBoar:
                break
            }
        }
    }
}

/// Sparse pixel flecks give the earth strip depth without making the calm palette visually noisy.
struct PixelGroundDetails: View {
    let isNight: Bool

    var body: some View {
        Canvas { context, size in
            let earth = (isNight ? Color.white : Color(red: 0.42, green: 0.27, blue: 0.14))
                .opacity(isNight ? 0.15 : 0.28)
            let grass = (isNight ? Color(red: 0.38, green: 0.63, blue: 0.41)
                                   : Color(red: 0.31, green: 0.57, blue: 0.25))
                .opacity(isNight ? 0.32 : 0.45)
            let spacing: CGFloat = 34

            for x in stride(from: 12 as CGFloat, through: size.width, by: spacing) {
                let grassPixel = CGRect(x: x, y: 1, width: 2, height: 4)
                context.fill(Path(grassPixel), with: .color(grass))

                let y = 10 + CGFloat(Int(x / spacing) % 3) * 5
                let earthPixel = CGRect(x: x + 10, y: y, width: 4, height: 2)
                context.fill(Path(earthPixel), with: .color(earth))
            }
        }
    }
}

/// A tiny two-frame silhouette, animated by the runner's shared clock so no extra timers are needed.
struct PixelBird: View {
    let wingsRaised: Bool
    let color: Color

    var body: some View {
        Canvas { context, size in
            let gridWidth: CGFloat = 11
            let gridHeight: CGFloat = 6
            let pixel = max(1, floor(min(size.width / gridWidth, size.height / gridHeight)))
            let origin = CGPoint(
                x: floor((size.width - pixel * gridWidth) / 2),
                y: floor((size.height - pixel * gridHeight) / 2)
            )

            func fill(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
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

            fill(4, 3, 3, 2)
            fill(7, 2, 2, 1)
            fill(3, 4, 5, 1)
            if wingsRaised {
                fill(2, 2, 2, 2)
                fill(1, 1, 2, 1)
                fill(7, 1, 2, 2)
                fill(9, 0, 1, 1)
            } else {
                fill(1, 4, 3, 1)
                fill(0, 5, 2, 1)
                fill(7, 4, 3, 1)
                fill(9, 5, 2, 1)
            }
        }
    }
}

/// Fixed pixel stars avoid any shimmer while the surrounding birds remain animated.
private struct PixelStar {
    let x: CGFloat
    let y: CGFloat
    let side: CGFloat
}

struct PixelNightStars: View {
    var body: some View {
        Canvas { context, size in
            let stars: [PixelStar] = [
                PixelStar(x: 0.08, y: 0.22, side: 2), PixelStar(x: 0.15, y: 0.52, side: 1),
                PixelStar(x: 0.27, y: 0.15, side: 1), PixelStar(x: 0.35, y: 0.39, side: 2),
                PixelStar(x: 0.46, y: 0.18, side: 1), PixelStar(x: 0.57, y: 0.48, side: 1),
                PixelStar(x: 0.64, y: 0.12, side: 2), PixelStar(x: 0.78, y: 0.35, side: 1),
                PixelStar(x: 0.88, y: 0.16, side: 2), PixelStar(x: 0.94, y: 0.55, side: 1),
                PixelStar(x: 0.53, y: 0.68, side: 1), PixelStar(x: 0.22, y: 0.72, side: 1)
            ]

            for star in stars {
                let rectangle = CGRect(
                    x: (size.width * star.x).rounded(),
                    y: (size.height * star.y).rounded(),
                    width: star.side,
                    height: star.side
                )
                context.fill(
                    Path(rectangle),
                    with: .color(.white.opacity(star.side > 1 ? 0.68 : 0.42))
                )
            }
        }
    }
}

/// Six consistently authored poses packed into one asset keep movement crisp and prevent SwiftUI
/// from blending between pixel edges while the game animates.
struct CloakedRunnerSprite: View {
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
