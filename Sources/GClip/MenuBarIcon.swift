import AppKit

/// Keep the clipboard silhouette visible in both states; template rendering
/// lets macOS supply the correct menu-bar color in light and dark appearances.
enum MenuBarIcon {
    static func make(updateAvailable: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 20), flipped: false) { _ in
            NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)?
                .draw(in: NSRect(x: 1, y: 0, width: 16, height: 20))
            if updateAvailable {
                NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
                    .draw(in: NSRect(x: 5, y: 4, width: 8, height: 10))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = updateAvailable ? "G-Clip update available" : "G-Clip"
        return image
    }
}
