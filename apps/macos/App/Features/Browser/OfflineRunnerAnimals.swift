import SwiftUI

enum RunnerAnimalVariant: Hashable {
    case rabbit
    case fox
    case hedgehog
    case wildBoar

    var gridSize: CGSize {
        switch self {
        case .rabbit:
            CGSize(width: 12, height: 11)
        case .fox:
            CGSize(width: 17, height: 11)
        case .hedgehog:
            CGSize(width: 13, height: 9)
        case .wildBoar:
            CGSize(width: 16, height: 12)
        }
    }
}

/// Two grounded poses per animal add movement without changing the obstacle's visual baseline or
/// collision envelope. The resulting animation feels alive but never misrepresents a safe jump.
struct PixelAnimalObstacle: View {
    let variant: RunnerAnimalVariant
    let isNight: Bool
    let animationFrame: Int

    var body: some View {
        Canvas { context, size in
            let gridSize = variant.gridSize
            let rawPixel = min(size.width / gridSize.width, size.height / gridSize.height)
            let pixel = floor(rawPixel * 2) / 2
            let origin = CGPoint(
                x: floor((size.width - pixel * gridSize.width) / 2),
                y: size.height - pixel * gridSize.height
            )
            let alternate = animationFrame.isMultiple(of: 2)

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

            let outline = isNight
                ? Color(red: 0.08, green: 0.10, blue: 0.13)
                : Color(red: 0.16, green: 0.15, blue: 0.13)
            let eye = isNight ? Color(red: 0.90, green: 0.82, blue: 0.52) : outline

            switch variant {
            case .rabbit:
                let fur = isNight
                    ? Color(red: 0.49, green: 0.52, blue: 0.58)
                    : Color(red: 0.70, green: 0.66, blue: 0.59)
                let furLight = isNight
                    ? Color(red: 0.65, green: 0.68, blue: 0.72)
                    : Color(red: 0.87, green: 0.83, blue: 0.75)
                let ear = Color(red: 0.78, green: 0.45, blue: 0.46)
                    .opacity(isNight ? 0.76 : 1)

                fill(4, 5, 6, 5, outline)
                fill(1, 4, 5, 5, outline)
                fill(2, alternate ? 0 : 1, 2, 5, outline)
                fill(4, alternate ? 1 : 0, 2, 5, outline)
                fill(9, 5, 3, 3, outline)
                fill(5, 5, 4, 4, fur)
                fill(2, 5, 4, 3, fur)
                fill(3, alternate ? 1 : 2, 1, 4, ear)
                fill(5, alternate ? 2 : 1, 1, 3, ear)
                fill(10, 6, 1, 1, furLight)
                fill(2, 6, 1, 1, eye)
                fill(1, 8, 2, 1, furLight)
                if alternate {
                    fill(3, 9, 3, 2, outline)
                    fill(8, 9, 2, 2, outline)
                    fill(4, 9, 2, 1, furLight)
                } else {
                    fill(2, 9, 2, 2, outline)
                    fill(7, 9, 3, 2, outline)
                    fill(7, 9, 2, 1, furLight)
                }

            case .fox:
                let coat = isNight
                    ? Color(red: 0.66, green: 0.29, blue: 0.18)
                    : Color(red: 0.86, green: 0.37, blue: 0.18)
                let coatLight = isNight
                    ? Color(red: 0.80, green: 0.50, blue: 0.30)
                    : Color(red: 0.98, green: 0.62, blue: 0.31)
                let cream = Color(red: 0.91, green: 0.82, blue: 0.63)
                    .opacity(isNight ? 0.78 : 1)

                fill(5, 4, 8, 6, outline)
                fill(1, 3, 6, 6, outline)
                fill(0, 6, 3, 3, outline)
                fill(2, 1, 2, 3, outline)
                fill(5, 1, 2, 3, outline)
                fill(11, alternate ? 2 : 3, 5, 5, outline)
                fill(15, alternate ? 1 : 2, 2, 4, outline)
                fill(6, 5, 6, 4, coat)
                fill(2, 4, 4, 4, coat)
                fill(1, 7, 3, 1, cream)
                fill(3, 2, 1, 2, coatLight)
                fill(5, 2, 1, 2, coatLight)
                fill(12, alternate ? 3 : 4, 3, 3, coat)
                fill(15, alternate ? 2 : 3, 1, 2, cream)
                fill(2, 5, 1, 1, eye)
                fill(0, 7, 1, 1, outline)
                if alternate {
                    fill(5, 9, 2, 2, outline)
                    fill(10, 9, 3, 2, outline)
                    fill(6, 9, 1, 1, coatLight)
                } else {
                    fill(4, 9, 3, 2, outline)
                    fill(11, 9, 2, 2, outline)
                    fill(11, 9, 1, 1, coatLight)
                }

            case .hedgehog:
                let quill = isNight
                    ? Color(red: 0.40, green: 0.29, blue: 0.24)
                    : Color(red: 0.50, green: 0.34, blue: 0.23)
                let quillLight = isNight
                    ? Color(red: 0.57, green: 0.42, blue: 0.31)
                    : Color(red: 0.68, green: 0.47, blue: 0.28)
                let face = Color(red: 0.77, green: 0.60, blue: 0.40)
                    .opacity(isNight ? 0.80 : 1)

                fill(3, 2, 9, 6, outline)
                fill(1, 4, 5, 4, outline)
                fill(0, 6, 2, 2, outline)
                fill(4, alternate ? 1 : 2, 2, 2, quillLight)
                fill(7, alternate ? 0 : 1, 2, 3, quill)
                fill(10, alternate ? 1 : 0, 2, 3, quillLight)
                fill(4, 3, 7, 4, quill)
                fill(6, 3, 4, 2, quillLight)
                fill(2, 5, 4, 3, face)
                fill(1, 6, 2, 2, face)
                fill(2, 6, 1, 1, eye)
                fill(0, 7, 1, 1, outline)
                if alternate {
                    fill(3, 8, 2, 1, outline)
                    fill(9, 7, 2, 2, outline)
                } else {
                    fill(2, 7, 2, 2, outline)
                    fill(8, 8, 2, 1, outline)
                }

            case .wildBoar:
                let hide = isNight
                    ? Color(red: 0.35, green: 0.29, blue: 0.27)
                    : Color(red: 0.47, green: 0.36, blue: 0.29)
                let hideLight = isNight
                    ? Color(red: 0.48, green: 0.39, blue: 0.34)
                    : Color(red: 0.62, green: 0.47, blue: 0.35)
                let snout = Color(red: 0.61, green: 0.40, blue: 0.34)
                    .opacity(isNight ? 0.80 : 1)
                let tusk = Color(red: 0.93, green: 0.84, blue: 0.61)
                    .opacity(isNight ? 0.82 : 1)

                fill(5, 4, 9, 6, outline)
                fill(2, 4, 6, 6, outline)
                fill(0, 6, 4, 3, outline)
                fill(4, 2, 2, 3, outline)
                fill(8, 2, 2, 2, outline)
                fill(11, 3, 2, 2, outline)
                fill(6, 5, 7, 4, hide)
                fill(3, 5, 4, 4, hide)
                fill(1, 7, 3, 2, snout)
                fill(5, 4, 5, 2, hideLight)
                fill(4, 3, 1, 2, hideLight)
                fill(3, 6, 1, 1, eye)
                fill(0, 7, 1, 1, outline)
                fill(2, 9, 1, 1, tusk)
                if alternate {
                    fill(5, 9, 2, 3, outline)
                    fill(11, 9, 3, 3, outline)
                    fill(14, 4, 2, 1, hideLight)
                } else {
                    fill(4, 9, 3, 3, outline)
                    fill(12, 9, 2, 3, outline)
                    fill(14, 3, 1, 2, hideLight)
                }
            }
        }
    }
}
