import CoreGraphics

/// Experimental signature observed on macOS 27, not a public system contract.
enum OverlayPresence {
    struct Surface {
        let owner: String
        let layer: Int
        let bounds: CGRect
        let onScreen: Bool
    }

    static func isActive(_ surfaces: [Surface], displays: [CGRect]) -> Bool {
        surfaces.contains { surface in
            guard surface.owner == "WindowManager", surface.layer == 19, surface.onScreen else { return false }
            return displays.contains { display in
                guard display.width > 0, display.height > 0 else { return false }
                return surface.bounds.insetBy(dx: -1, dy: -1).contains(display)
            }
        }
    }
}
