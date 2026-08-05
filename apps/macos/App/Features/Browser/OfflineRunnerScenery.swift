import SwiftUI

/// Broad horizontal color bands keep the sky calm while removing the smooth UI gradient that
/// previously clashed with the pixel-authored runner and obstacles.
struct RunnerPixelSky: View {
    let isNight: Bool

    var body: some View {
        Canvas { context, size in
            let colors = isNight
                ? [
                    Color(red: 0.035, green: 0.075, blue: 0.16),
                    Color(red: 0.055, green: 0.105, blue: 0.19),
                    Color(red: 0.075, green: 0.135, blue: 0.21),
                    Color(red: 0.10, green: 0.16, blue: 0.19)
                ]
                : [
                    Color(red: 0.79, green: 0.89, blue: 0.93),
                    Color(red: 0.83, green: 0.91, blue: 0.93),
                    Color(red: 0.88, green: 0.94, blue: 0.93),
                    Color(red: 0.91, green: 0.95, blue: 0.90)
                ]
            let bandHeight = ceil(size.height / CGFloat(colors.count))

            for (index, color) in colors.enumerated() {
                context.fill(
                    Path(CGRect(
                        x: 0,
                        y: CGFloat(index) * bandHeight,
                        width: size.width,
                        height: bandHeight + 1
                    )),
                    with: .color(color)
                )
            }

            let pixel = max(2, min(6, floor(size.height / 100)))
            let seam = bandHeight * 2
            let dither = (isNight ? Color.white : Color(red: 0.56, green: 0.75, blue: 0.77))
                .opacity(isNight ? 0.025 : 0.09)
            for x in stride(from: pixel * 2, through: size.width, by: pixel * 7) {
                context.fill(
                    Path(CGRect(x: x, y: seam - pixel, width: pixel, height: pixel)),
                    with: .color(dither)
                )
            }
        }
        .accessibilityHidden(true)
    }
}

struct RunnerPixelCelestialBody: View {
    let isNight: Bool

    var body: some View {
        Canvas { context, size in
            let grid: CGFloat = 18
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

            if isNight {
                let moon = Color(red: 0.91, green: 0.89, blue: 0.64)
                let moonLight = Color(red: 1.0, green: 0.96, blue: 0.76)
                let moonShadow = Color(red: 0.69, green: 0.70, blue: 0.52)
                fill(5, 2, 5, 2, moonLight)
                fill(3, 4, 6, 3, moonLight)
                fill(2, 7, 6, 5, moon)
                fill(3, 12, 6, 3, moon)
                fill(5, 15, 5, 1, moonShadow)
                fill(7, 4, 4, 2, moonShadow)
                fill(7, 6, 3, 3, moonShadow)
                fill(6, 13, 4, 2, moonShadow)
                fill(12, 4, 1, 1, .white.opacity(0.72))
                fill(15, 8, 2, 2, .white.opacity(0.55))
                fill(12, 13, 1, 1, .white.opacity(0.68))
            } else {
                let sun = Color(red: 0.98, green: 0.58, blue: 0.27)
                let sunLight = Color(red: 1.0, green: 0.72, blue: 0.34)
                let sunShadow = Color(red: 0.88, green: 0.39, blue: 0.20)
                fill(8, 0, 2, 3, sun)
                fill(8, 15, 2, 3, sun)
                fill(0, 8, 3, 2, sun)
                fill(15, 8, 3, 2, sun)
                fill(3, 3, 2, 2, sun)
                fill(13, 3, 2, 2, sun)
                fill(3, 13, 2, 2, sun)
                fill(13, 13, 2, 2, sun)
                fill(6, 4, 6, 1, sunShadow)
                fill(4, 6, 10, 6, sunShadow)
                fill(6, 12, 6, 1, sunShadow)
                fill(6, 5, 6, 7, sun)
                fill(6, 5, 3, 3, sunLight)
            }
        }
        .accessibilityHidden(true)
    }
}

struct RunnerPixelCloud: View {
    let isNight: Bool
    let tint: Color
    let variant: Int

    var body: some View {
        Canvas { context, size in
            let columns: CGFloat = 20
            let rows: CGFloat = 10
            let pixel = max(1, floor(min(size.width / columns, size.height / rows)))
            let origin = CGPoint(
                x: floor((size.width - columns * pixel) / 2),
                y: floor((size.height - rows * pixel) / 2)
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

            let main = tint.opacity(isNight ? 0.18 : 0.58)
            let light = (isNight ? Color.white : tint).opacity(isNight ? 0.13 : 0.76)
            let shadow = tint.opacity(isNight ? 0.10 : 0.38)
            let shift = CGFloat(abs(variant) % 3)

            fill(2, 7, 16, 2, shadow)
            fill(4, 4, 12, 4, main)
            fill(6 + shift, 2, 5, 5, main)
            fill(11 - shift, 3, 4, 4, main)
            fill(1, 6, 18, 2, main)
            fill(4, 5, 5, 2, light)
            fill(7 + shift, 3, 3, 2, light)
            fill(3, 8, 14, 1, shadow)
        }
        .accessibilityHidden(true)
    }
}

struct RunnerPixelMountains: View {
    enum Layer {
        case distant
        case near
    }

    let isNight: Bool
    let layer: Layer
    let variant: Int

    var body: some View {
        Canvas { context, size in
            let pixel = max(2, floor(size.height / 24))
            let baseY = floor(size.height / pixel) * pixel
            let baseColor: Color = switch (isNight, layer) {
            case (true, .distant):
                Color(red: 0.18, green: 0.25, blue: 0.34).opacity(0.62)
            case (true, .near):
                Color(red: 0.16, green: 0.30, blue: 0.31).opacity(0.78)
            case (false, .distant):
                Color(red: 0.52, green: 0.70, blue: 0.72).opacity(0.24)
            case (false, .near):
                Color(red: 0.42, green: 0.63, blue: 0.53).opacity(0.24)
            }
            let lightColor = (isNight ? Color(red: 0.39, green: 0.48, blue: 0.56) : .white)
                .opacity(layer == .distant ? 0.20 : 0.24)
            let shadowColor = (isNight ? Color.black : Color(red: 0.24, green: 0.43, blue: 0.39))
                .opacity(layer == .distant ? 0.16 : 0.20)

            func fill(_ rectangle: CGRect, _ color: Color) {
                context.fill(Path(rectangle), with: .color(color))
            }

            func mountain(center: CGFloat, levels: Int, snow: Bool) {
                for row in 0..<levels {
                    let blocks = CGFloat(row * 2 + 3)
                    let y = baseY - CGFloat(levels - row) * pixel
                    let x = (center - blocks * pixel / 2).rounded(.down)
                    fill(CGRect(x: x, y: y, width: blocks * pixel, height: pixel), baseColor)
                    fill(
                        CGRect(x: center, y: y, width: blocks * pixel / 2, height: pixel),
                        shadowColor
                    )

                    if snow, row < 3 {
                        let snowBlocks = max(1, 3 - row)
                        fill(
                            CGRect(
                                x: center - CGFloat(snowBlocks) * pixel,
                                y: y,
                                width: CGFloat(snowBlocks * 2) * pixel,
                                height: pixel
                            ),
                            lightColor
                        )
                    }
                }
            }

            let offset = CGFloat((variant % 3) - 1) * pixel * 2
            mountain(center: size.width * 0.22 + offset, levels: layer == .near ? 9 : 7, snow: false)
            mountain(center: size.width * 0.54 - offset, levels: layer == .near ? 14 : 11, snow: true)
            mountain(center: size.width * 0.84 + offset, levels: layer == .near ? 8 : 6, snow: false)
        }
        .accessibilityHidden(true)
    }
}
