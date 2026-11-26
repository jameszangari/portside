import SwiftUI

/// Compact "thinking" indicators for the Top Notch and dock Working chip.
///
/// `ship` (the default) is Portside's sailboat rocking gently over sliding
/// waves, and `wheel` a ship's wheel turning a half turn and resting; both
/// in one color so they take the accent or provider tint.
/// `snakeBoxes` is a 2x3 grid with one empty cell that walks the loop
/// (Nawsome blue-dragon-70 style). At very small sizes it reads poorly, so
/// callers can pass `.dots` (three pulsing dots, same as the dock chip).
struct ThinkingLoader: View {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case ship
        case wheel
        case snakeBoxes = "boxes"
        case dots

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ship: "Ship"
            case .wheel: "Ship's wheel"
            case .snakeBoxes: "Boxes"
            case .dots: "Dots"
            }
        }
    }

    var style: Style = .ship
    var paused = false
    /// Longest side. Snake uses a 2:3 frame; dots are roughly square.
    var size: CGFloat = 14
    var color: Color = .white
    /// Frames a second. The dock chip asks for fewer: an 11 pt chip looks
    /// the same at 12, and every frame redraws the dock.
    var frameRate: Double = 24

    private var frameSize: CGSize {
        switch style {
        case .ship: CGSize(width: size * 1.15, height: size)
        case .wheel: CGSize(width: size, height: size)
        case .snakeBoxes: CGSize(width: size * 0.72, height: size)
        case .dots: CGSize(width: size, height: size * 0.55)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / frameRate, paused: paused)) { context in
            let t = paused ? nil : context.date.timeIntervalSinceReferenceDate
            if style == .dots {
                // Plain shapes, not a Canvas: a Canvas draws into its own
                // layer, which the main thread waits on the GPU to finish
                // every frame. The dots are simple enough not to need it.
                Self.dots(size: frameSize, t: t, color: color)
            } else {
                Canvas { gc, canvasSize in
                switch style {
                case .ship: Self.drawShip(gc, size: canvasSize, t: t, color: color)
                case .wheel: Self.drawWheel(gc, size: canvasSize, t: t, color: color)
                case .snakeBoxes: Self.drawSnake(gc, size: canvasSize, t: t, color: color)
                case .dots: Self.drawDots(gc, size: canvasSize, t: t, color: color)
                }
                }
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .accessibilityHidden(true)
    }

    /// `chosen` when there is room; boxes fall back to dots under about
    /// 11pt, where they read poorly. The ship and wheel hold up to 9pt.
    static func preferredStyle(_ chosen: Style = .ship, for size: CGFloat) -> Style {
        switch chosen {
        case .ship: size >= 9 ? .ship : .dots
        case .wheel: size >= 9 ? .wheel : .dots
        case .snakeBoxes: size >= 11 ? .snakeBoxes : .dots
        case .dots: .dots
        }
    }

    /// The sailboat, after LottieFiles' "Ship" (the maintainer's
    /// reference; its keyframes, not its art): the boat tilts 3 degrees
    /// each way about its middle over 6 s and dips 1.6% of the frame every
    /// 3 s, both eased, while one continuous wave rolls left under it. The brand's two sails (a straight jib and a rounded
    /// main) over a hull. Paused, it sits level over still waves.
    private static func drawShip(_ gc: GraphicsContext, size: CGSize, t: Double?, color: Color) {
        let w = size.width, h = size.height
        guard w >= 4, h >= 4 else { return }
        drawWaves(gc, size: size, t: t, color: color)

        let tilt = t.map { -3 * cos(2 * .pi * $0 / 6) } ?? 0
        let dip = t.map { 0.016 * (1 - cos(2 * .pi * $0 / 3)) / 2 } ?? 0
        let u = h
        // Pivot: the boat's middle, about halfway up the sails.
        let pivot = CGPoint(x: 0.5 * w, y: (0.82 + dip) * h - 0.36 * u)
        var boat = gc
        boat.translateBy(x: pivot.x, y: pivot.y)
        boat.rotate(by: .degrees(tilt))
        boat.translateBy(x: 0, y: 0.36 * u)
        var hull = Path()
        hull.move(to: CGPoint(x: -0.36 * u, y: -0.13 * u))
        hull.addLine(to: CGPoint(x: 0.36 * u, y: -0.13 * u))
        hull.addLine(to: CGPoint(x: 0.24 * u, y: 0.02 * u))
        hull.addLine(to: CGPoint(x: -0.26 * u, y: 0.02 * u))
        hull.closeSubpath()
        boat.fill(hull, with: .color(color))

        var jib = Path()
        jib.move(to: CGPoint(x: -0.03 * u, y: -0.78 * u))
        jib.addLine(to: CGPoint(x: -0.03 * u, y: -0.19 * u))
        jib.addLine(to: CGPoint(x: -0.33 * u, y: -0.19 * u))
        jib.closeSubpath()
        boat.fill(jib, with: .color(color.opacity(0.85)))

        var main = Path()
        main.move(to: CGPoint(x: 0.03 * u, y: -0.78 * u))
        main.addQuadCurve(to: CGPoint(x: 0.03 * u, y: -0.24 * u), control: CGPoint(x: 0.5 * u, y: -0.56 * u))
        main.closeSubpath()
        boat.fill(main, with: .color(color.opacity(0.85)))
    }

    /// One continuous wave across the frame, rolling left at about 0.4 of
    /// the frame width per second (the reference's pace). Still when paused.
    private static func drawWaves(_ gc: GraphicsContext, size: CGSize, t: Double?, color: Color) {
        let w = size.width, h = size.height
        let shift = (t ?? 0) * 0.4
        var water = Path()
        let steps = 32
        for step in 0...steps {
            let x = Double(step) / Double(steps)
            let point = CGPoint(x: x * w, y: (0.88 + 0.035 * sin(2 * .pi * (x * 1.5 + shift))) * h)
            if step == 0 { water.move(to: point) } else { water.addLine(to: point) }
        }
        gc.stroke(water, with: .color(color.opacity(0.6)),
                  style: StrokeStyle(lineWidth: max(1, h * 0.07), lineCap: .round, lineJoin: .round))
    }

    /// A ship's wheel, after LottieFiles' "Boat steering": a half turn,
    /// eased, over 2.25 s, then a rest until the 5 s loop starts again. The
    /// wheel looks the same every 45 degrees, so the loop is seamless.
    private static func drawWheel(_ gc: GraphicsContext, size: CGSize, t: Double?, color: Color) {
        let side = min(size.width, size.height)
        guard side >= 4 else { return }
        let angle: Double = t.map { time in
            let p = min(time.truncatingRemainder(dividingBy: 5) / 2.25, 1)
            return 180 * (1 - cos(.pi * p)) / 2
        } ?? 0
        var wheel = gc
        wheel.translateBy(x: size.width / 2, y: size.height / 2)
        wheel.rotate(by: .degrees(angle))
        let r = side / 2
        let line = max(1, side * 0.09)
        // Handles past the rim, then the rim, spokes and hub.
        for k in 0..<8 {
            let a = Double(k) * .pi / 4
            let dir = CGPoint(x: cos(a), y: sin(a))
            var spoke = Path()
            spoke.move(to: CGPoint(x: dir.x * r * 0.18, y: dir.y * r * 0.18))
            spoke.addLine(to: CGPoint(x: dir.x * r * 0.86, y: dir.y * r * 0.86))
            wheel.stroke(spoke, with: .color(color), style: StrokeStyle(lineWidth: line, lineCap: .round))
            let knob = r * 0.13
            wheel.fill(Path(ellipseIn: CGRect(x: dir.x * r * 0.86 - knob, y: dir.y * r * 0.86 - knob, width: knob * 2, height: knob * 2)),
                       with: .color(color))
        }
        let rim = r * 0.6
        wheel.stroke(Path(ellipseIn: CGRect(x: -rim, y: -rim, width: rim * 2, height: rim * 2)),
                     with: .color(color), lineWidth: line * 1.2)
        let hub = r * 0.2
        wheel.fill(Path(ellipseIn: CGRect(x: -hub, y: -hub, width: hub * 2, height: hub * 2)), with: .color(color))
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
    /// The dots as views, laid out as `drawDots` draws them.
    private static func dots(size: CGSize, t: Double?, color: Color) -> some View {
        let dot = size.width / 4.2
        let step = (size.width - dot) / 2
        return ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { i in
                let pulse = t.map { 0.5 + 0.5 * sin($0 * 6 - Double(i) * 0.9) } ?? 1
                let side = dot * (0.7 + 0.3 * pulse)
                Circle()
                    .fill(color.opacity(0.4 + 0.6 * pulse))
                    .frame(width: side, height: side)
                    .offset(x: CGFloat(i) * step + (dot - side) / 2, y: (size.height - side) / 2)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

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
