import AppKit

enum WindowLayout {
    static let maximumDefault = CGSize(width: 1500, height: 890)
    static let preferredMinimum = CGSize(width: 980, height: 540)
    static func area(_ visible: CGRect) -> CGRect {
        visible.insetBy(dx: min(16, max(0, visible.width / 20)), dy: min(16, max(0, visible.height / 20)))
    }
    static func minimum(in visible: CGRect) -> CGSize {
        let available = area(visible)
        return CGSize(width: min(preferredMinimum.width, available.width), height: min(preferredMinimum.height, available.height))
    }
    static func valid(_ size: CGSize?) -> CGSize? {
        guard let size, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return size
    }
    static func size(in visible: CGRect, preferred: CGSize?) -> CGSize {
        let available = area(visible), minimum = minimum(in: visible)
        let desired = valid(preferred) ?? CGSize(width: min(maximumDefault.width, visible.width * 0.88), height: min(maximumDefault.height, visible.height * 0.88))
        return CGSize(width: min(available.width, max(minimum.width, desired.width)), height: min(available.height, max(minimum.height, desired.height)))
    }
    static func frame(in visible: CGRect, preferred: CGSize?, origin: CGPoint? = nil) -> CGRect {
        let available = area(visible), size = size(in: visible, preferred: preferred)
        // Match the slightly elevated placement expected of a floating palette.
        // Use available slack so a nearly full-height window stays on screen.
        let lift = min(80, max(0, available.height - size.height) * 0.25)
        let wanted = origin ?? CGPoint(x: available.midX - size.width / 2, y: available.midY - size.height / 2 + lift)
        return CGRect(x: max(available.minX, min(wanted.x, available.maxX - size.width)),
                      y: max(available.minY, min(wanted.y, available.maxY - size.height)), width: size.width, height: size.height)
    }
}
