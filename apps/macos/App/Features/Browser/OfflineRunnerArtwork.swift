import SwiftUI

/// Three colored pixel silhouettes keep repeat runs varied without breaking the runner's style.
struct PixelTreeObstacle: View {
    let variant: TreeVariant

    var body: some View {
        Canvas { context, size in
            let gridSize: CGSize = switch variant {
            case .round:
                CGSize(width: 10, height: 14)
            case .pine:
                CGSize(width: 10, height: 16)
            case .bush:
                CGSize(width: 14, height: 10)
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

            let leaf = Color(red: 0.25, green: 0.58, blue: 0.32)
            let leafLight = Color(red: 0.40, green: 0.71, blue: 0.41)
            let leafShadow = Color(red: 0.11, green: 0.35, blue: 0.19)
            let trunk = Color(red: 0.48, green: 0.29, blue: 0.13)
            let trunkShadow = Color(red: 0.29, green: 0.17, blue: 0.08)

            switch variant {
            case .round:
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

            case .pine:
                let pine = Color(red: 0.18, green: 0.49, blue: 0.35)
                let pineLight = Color(red: 0.31, green: 0.64, blue: 0.43)
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
                let bush = Color(red: 0.31, green: 0.63, blue: 0.31)
                let bushLight = Color(red: 0.47, green: 0.74, blue: 0.38)
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
            }
        }
    }
}

/// Sparse pixel flecks give the earth strip depth without making the calm palette visually noisy.
struct PixelGroundDetails: View {
    var body: some View {
        Canvas { context, size in
            let earth = Color(red: 0.42, green: 0.27, blue: 0.14).opacity(0.28)
            let grass = Color(red: 0.31, green: 0.57, blue: 0.25).opacity(0.45)
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
