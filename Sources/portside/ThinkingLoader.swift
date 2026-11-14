import SwiftUI

/// Compact "thinking" indicators for the Top Notch and dock Working chip.
///
/// `snakeBoxes` is a 2x3 grid with one empty cell that walks the loop
/// (Nawsome blue-dragon-70 style). At very small sizes it reads poorly, so
/// callers can pass `.dots` (three pulsing dots, same as the dock chip).
struct ThinkingLoader: View {
    enum Style {
        case snakeBoxes
        case dots
    }

    var style: Style = .snakeBoxes
    var paused = false
    /// Longest side. Snake uses a 2:3 frame; dots are roughly square.
    var size: CGFloat = 14
    var color: Color = .white

    private var frameSize: CGSize {
        switch style {
        case .snakeBoxes: CGSize(width: size * 0.72, height: size)
        case .dots: CGSize(width: size, height: size * 0.55)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: paused)) { context in
            let t = paused ? nil : context.date.timeIntervalSinceReferenceDate
            Canvas { gc, canvasSize in
                switch style {
                case .snakeBoxes: Self.drawSnake(gc, size: canvasSize, t: t, color: color)
                case .dots: Self.drawDots(gc, size: canvasSize, t: t, color: color)
                }
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .accessibilityHidden(true)
    }

    /// Prefer snake boxes when there is room; fall back to dots under about 11pt.
    static func preferredStyle(for size: CGFloat) -> Style {
        size >= 11 ? .snakeBoxes : .dots
    }

    // Counter-clockwise loop around a 2x3 grid, starting at top-left.
    private static let snakePath: [(Int, Int)] = [
        (0, 0), (1, 0), (1, 1), (1, 2), (0, 2), (0, 1),
    ]

    private static func drawSnake(_ gc: GraphicsContext, size: CGSize, t: Double?, color: Color) {
        let gap = max(1, min(size.width, size.height) * 0.1)
        let cell = min((size.width - gap) / 2, (size.height - gap * 2) / 3)
        guard cell >= 1 else { return }
        let totalW = cell * 2 + gap
        let totalH = cell * 3 + gap * 2
        let origin = CGPoint(x: (size.width - totalW) / 2, y: (size.height - totalH) / 2)
        // Empty cell walks the loop; paused keeps the top-left empty.
        let empty = t.map { Int(($0 / 0.11).rounded(.down)) % snakePath.count } ?? 0
        for (index, cellPos) in snakePath.enumerated() where index != empty {
            let rect = CGRect(
                x: origin.x + CGFloat(cellPos.0) * (cell + gap),
                y: origin.y + CGFloat(cellPos.1) * (cell + gap),
                width: cell,
                height: cell
            )
            gc.fill(Path(rect), with: .color(color))
        }
    }

    /// Three dots pulsing in turn, like a typing indicator.
    private static func drawDots(_ gc: GraphicsContext, size: CGSize, t: Double?, color: Color) {
        let dot = size.width / 4.2
        let step = (size.width - dot) / 2
        for i in 0..<3 {
            let pulse = t.map { 0.5 + 0.5 * sin($0 * 6 - Double(i) * 0.9) } ?? 1
            let scale = 0.7 + 0.3 * pulse
            let side = dot * scale
            let rect = CGRect(
                x: CGFloat(i) * step + (dot - side) / 2,
                y: (size.height - side) / 2,
                width: side,
                height: side
            )
            gc.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.4 + 0.6 * pulse)))
        }
    }
}

/// Compact bouncing bars for the Top Notch while Spotify or Music is
/// playing (Bartender-style). Hidden by the caller when nothing is playing.
struct NotchAudioBars: View {
    var paused = false
    var color: Color = .white
    var height: CGFloat = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: paused)) { context in
            let t = paused ? 0.0 : context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = paused
                        ? [0.45, 0.7, 0.55, 0.85][i]
                        : 0.28 + 0.72 * abs(sin(t * (4.0 + Double(i) * 0.85) + Double(i) * 0.9))
                    RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                        .fill(color)
                        .frame(width: 2.2, height: max(2, height * phase))
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}
