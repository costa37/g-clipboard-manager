import AppKit
import ApplicationServices

// The keyboard recipient can be a nonactivating floating panel even when
// NSWorkspace reports the underlying app as frontmost. Never read field values.
final class PasteDestination {
    let app: NSRunningApplication
    var window: AXUIElement?
    var field: AXUIElement?
    let geminiMiniTitle: String?
    private var requestedMini = false
    private var activatedGemini = false
    init(app: NSRunningApplication, window: AXUIElement?, field: AXUIElement?) {
        self.app = app; self.window = window; self.field = field
        let title = window.flatMap { Self.string($0, kAXTitleAttribute) }
        geminiMiniTitle = GeminiMiniChatPolicy.isMini(bundleID: app.bundleIdentifier, title: title) ? title : nil
    }
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
    // Only structural UI metadata is inspected, never prompt or conversation values.
    static func find(_ root: AXUIElement, matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)], index = 0
        while index < queue.count && index < 100 {
            let (node, depth) = queue[index]; index += 1
            if matches(node) { return node }
            let role = string(node, kAXRoleAttribute) ?? ""
            if depth < 8 && ![kAXTextAreaRole, kAXTextFieldRole, kAXListRole, kAXTableRole, kAXOutlineRole].contains(role) {
                queue.append(contentsOf: elements(node, kAXChildrenAttribute).prefix(40).map { ($0, depth + 1) })
            }
        }
        return nil
    }
    func restoreGeminiMini() {
        guard let title = geminiMiniTitle, !app.isTerminated else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(axApp, 0.15)
        let windows = Self.elements(axApp, kAXWindowsAttribute)
        if let mini = windows.first(where: { Self.string($0, kAXTitleAttribute) == title }),
           let input = Self.find(mini, matches: { Self.string($0, kAXRoleAttribute) == kAXTextAreaRole }) {
            window = mini; field = input
            AXUIElementPerformAction(mini, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            // A visible, focused mini panel needs no toggle action.
            if isReady() { return }
        }
        guard !requestedMini else { return }
        if !activatedGemini { app.activate(options: [.activateIgnoringOtherApps]); activatedGemini = true }
        for candidate in windows {
            if let button = Self.find(candidate, matches: {
                GeminiMiniChatPolicy.isOpenButton(identifier: Self.string($0, kAXIdentifierAttribute),
                                                   description: Self.string($0, kAXDescriptionAttribute))
            }) {
                // Never press twice: the action is a toggle and a second press could close it.
                requestedMini = true
                AXUIElementPerformAction(button, kAXPressAction as CFString)
                return
            }
        }
    }
    func prepareForPaste() { if geminiMiniTitle != nil { restoreGeminiMini() } }
    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, 0.15)
        return result
    }
    static func pid(_ element: AXUIElement?) -> pid_t? {
        guard let element else { return nil }; var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid > 0 ? pid : nil
    }
    static func focus() -> (app: AXUIElement?, field: AXUIElement?) {
        guard AXIsProcessTrusted() else { return (nil, nil) }
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.15)
        let app = element(system, kAXFocusedApplicationAttribute)
        let field = element(system, kAXFocusedUIElementAttribute) ?? app.flatMap { element($0, kAXFocusedUIElementAttribute) }
        return (app, field)
    }
    static func capture(fallback: NSRunningApplication?) -> PasteDestination? {
        let focused = focus(), ownPID = ProcessInfo.processInfo.processIdentifier
        let focusedPID = pid(focused.field) ?? pid(focused.app)
        let app = focusedPID.flatMap { $0 != ownPID ? NSRunningApplication(processIdentifier: $0) : nil } ?? fallback
        guard let app, !app.isTerminated, app.processIdentifier != ownPID else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(axApp, 0.15)
        let field = pid(focused.field) == app.processIdentifier ? focused.field : element(axApp, kAXFocusedUIElementAttribute)
        let window = field.flatMap { element($0, kAXWindowAttribute) ?? element($0, kAXTopLevelUIElementAttribute) } ?? element(axApp, kAXFocusedWindowAttribute)
        return PasteDestination(app: app, window: window, field: field)
    }
    func restore() {
        guard !app.isTerminated else { return }
        if geminiMiniTitle != nil { restoreGeminiMini(); return }
        // Restore the captured panel first. Activating its app first can bring
        // a different main window forward or dismiss a transient floating panel.
        if let window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        if let field { AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
        let focused = Self.focus()
        // AX success only acknowledges the request; it does not prove keyboard focus moved.
        if PasteReadiness.needsActivation(expected: app.processIdentifier,
                                          focused: Self.pid(focused.field) ?? Self.pid(focused.app)) {
            app.activate(options: [.activateIgnoringOtherApps])
            if let window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
            if let field { AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
        }
    }
    func isReady() -> Bool {
        let focused = Self.focus()
        let focusedPID = Self.pid(focused.field) ?? Self.pid(focused.app)
        guard PasteReadiness.matchesProcess(expected: app.processIdentifier, focused: focusedPID,
                                           frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                           capturedElement: field != nil || window != nil) else { return false }
        if let field { guard let current = focused.field, CFEqual(field, current) else { return false } }
        if let window {
            let currentWindow = focused.field.flatMap { Self.element($0, kAXWindowAttribute) ?? Self.element($0, kAXTopLevelUIElementAttribute) }
                ?? focused.app.flatMap { Self.element($0, kAXFocusedWindowAttribute) }
            guard let currentWindow, CFEqual(window, currentWindow) else { return false }
        }
        return true
    }
}

enum PasteReadiness {
    static func needsActivation(expected: pid_t, focused: pid_t?) -> Bool {
        focused != expected
    }
    static func matchesProcess(expected: pid_t, focused: pid_t?, frontmost: pid_t?, capturedElement: Bool) -> Bool {
        if let focused { return focused == expected }
        return !capturedElement && frontmost == expected
    }
    static func modifiersReleased(_ flags: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty
    }
}

// These identifiers were observed in Gemini's native accessibility tree.
enum GeminiMiniChatPolicy {
    static func isMini(bundleID: String?, title: String?) -> Bool {
        bundleID == "com.google.GeminiMacOS" && (title?.hasPrefix("Gemini Mini Chat") == true)
    }
    static func isOpenButton(identifier: String?, description: String?) -> Bool {
        identifier == "collapse_button" || description == "Open mini chat"
    }
}
