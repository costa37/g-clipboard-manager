import AppKit
import SwiftUI

// Explicit responders keep toolbar navigation independent of macOS's
// "Keyboard navigation" preference. Menus retain native arrow/Return/Escape handling.
private final class ImageToolbarButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill() }
    override func draw(_ dirtyRect: NSRect) {
        if state == .on || tag == 7 {
            NSColor(srgbRed: 0.16, green: 0.43, blue: 0.46, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
    override func keyDown(with event: NSEvent) {
        if [36, 76, 49].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            performClick(nil)
        } else { super.keyDown(with: event) }
    }
}

private final class ImageToolbarPopup: NSPopUpButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override func keyDown(with event: NSEvent) {
        if [125, 126, 36, 76, 49].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            performClick(nil)
        } else { super.keyDown(with: event) }
    }
}

struct ImageToolbar: NSViewRepresentable {
    @ObservedObject var draft: ImageDraft
    var back: () -> Void
    var save: () -> Void
    func makeNSView(context: Context) -> ImageToolbarView { ImageToolbarView() }
    func updateNSView(_ view: ImageToolbarView, context: Context) {
        view.update(draft: draft, back: back, save: save)
        draft.toolbar = view
    }
    static func dismantleNSView(_ view: ImageToolbarView, coordinator: ()) {
        if view.draft?.toolbar === view { view.draft?.toolbar = nil }
    }
}

final class ImageToolbarView: NSView {
    weak var draft: ImageDraft?
    private var back: () -> Void = {}
    private var save: () -> Void = {}
    private var buttons: [NSButton] = []
    private let color = ImageToolbarPopup(frame: .zero, pullsDown: false)
    private let size = ImageToolbarPopup(frame: .zero, pullsDown: false)
    private let stack = NSStackView()
    private var controls: [NSControl] { Array(buttons[1...4]) + [color, size] + Array(buttons.suffix(3)) + [buttons[0]] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        let specs = [("rectangle.portrait.and.arrow.right", "Exit editing (Escape)"), ("arrow.up.right", "Arrow"),
                     ("rectangle", "Rectangle"), ("textformat", "Text"), ("crop", "Crop: drag to keep an area"),
                     ("arrow.uturn.backward", "Undo (⌘Z)"), ("arrow.counterclockwise", "Reset to original image"),
                     ("checkmark", "Save edited image as a new item (⌘S)")]
        for (index, spec) in specs.enumerated() {
            let button = ImageToolbarButton()
            button.image = NSImage(systemSymbolName: spec.0, accessibilityDescription: spec.1)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
            button.title = index == 7 ? "Save" : ""
            button.imagePosition = index == 7 ? .imageLeading : .imageOnly
            button.bezelStyle = .regularSquare; button.isBordered = false
            // Tools activate on focus, so their selected fill already identifies
            // keyboard position without a second outline around the icon.
            button.focusRingType = (1...4).contains(index) ? .none : .exterior
            button.setButtonType(index >= 1 && index <= 4 ? .toggle : .momentaryPushIn)
            button.toolTip = spec.1; button.setAccessibilityLabel(spec.1)
            button.tag = index; button.target = self; button.action = #selector(activate(_:))
            button.widthAnchor.constraint(equalToConstant: index == 7 ? 70 : 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            buttons.append(button)
        }
        for button in buttons[1...4] { stack.addArrangedSubview(button) }
        for popup in [color, size] {
            popup.font = .systemFont(ofSize: 13); popup.target = self
            stack.addArrangedSubview(popup)
        }
        color.addItems(withTitles: Ink.allCases.map(\.rawValue))
        color.action = #selector(changeColor); color.setAccessibilityLabel("Annotation color")
        size.action = #selector(changeSize)
        color.widthAnchor.constraint(equalToConstant: 78).isActive = true
        size.widthAnchor.constraint(equalToConstant: 88).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        for button in buttons.suffix(3) { stack.addArrangedSubview(button) }
        stack.addArrangedSubview(buttons[0])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(draft: ImageDraft, back: @escaping () -> Void, save: @escaping () -> Void) {
        self.draft = draft; self.back = back; self.save = save
        for (index, tool) in ImageTool.allCases.enumerated() {
            buttons[index + 1].state = draft.tool == tool ? .on : .off
            buttons[index + 1].contentTintColor = draft.tool == tool ? .white : .labelColor
        }
        buttons[7].contentTintColor = .white
        color.isHidden = draft.tool == .crop; size.isHidden = color.isHidden
        color.selectItem(withTitle: draft.ink.rawValue)
        let titles = draft.tool == .text ? ["12 pt", "18 pt", "24 pt", "32 pt", "42 pt", "54 pt", "64 pt"] : ["Thin", "Medium", "Thick"]
        if size.itemTitles != titles { size.removeAllItems(); size.addItems(withTitles: titles) }
        size.selectItem(at: draft.tool == .text ? ([CGFloat(12), 18, 24, 32, 42, 54, 64].firstIndex(of: draft.fontSize) ?? 2) : ([CGFloat(2), 4, 8].firstIndex(of: draft.width) ?? 1))
        size.setAccessibilityLabel(draft.tool == .text ? "Text size" : "Stroke width")
        buttons[5].isEnabled = !draft.history.isEmpty
        // A selected tool or a now-disabled Undo must not strand keyboard focus.
        if let focused = window?.firstResponder as? NSControl,
           controls.contains(where: { $0 === focused }), focused.isHidden || !focused.isEnabled {
            _ = moveFocus(backward: false)
        }
    }

    func focusDefaultTool() {
        guard let draft, let window else { return }
        draft.selectTool(.arrow)
        update(draft: draft, back: back, save: save)
        window.makeFirstResponder(buttons[1])
    }

    @discardableResult
    func moveFocus(backward: Bool) -> Bool {
        guard let window else { return false }
        let available = controls.filter { !$0.isHidden && $0.isEnabled }
        guard !available.isEmpty else { return false }
        var current = available.firstIndex { $0 === window.firstResponder }
        // Drawing gives the canvas focus. Resume from the active tool instead
        // of treating the next Tab as a fresh entry into the toolbar.
        if current == nil, let draft, let canvas = draft.canvas,
           window.firstResponder === canvas,
           let toolIndex = ImageTool.allCases.firstIndex(of: draft.tool) {
            current = available.firstIndex { $0 === buttons[toolIndex + 1] }
        }
        let index = current.map { ($0 + (backward ? -1 : 1) + available.count) % available.count } ?? (backward ? available.count - 1 : 0)
        let control = available[index]
        guard window.makeFirstResponder(control) else { return false }
        if let button = control as? NSButton, (1...4).contains(button.tag), let draft {
            activate(button)
            // Refresh conditional dropdowns immediately, including on rapid Tab presses.
            update(draft: draft, back: back, save: save)
        }
        return true
    }

    @objc private func activate(_ sender: NSButton) {
        guard let draft else { return }
        let keepFocus = window?.firstResponder === sender
        switch sender.tag {
        case 0: back()
        case 1...4: draft.selectTool(ImageTool.allCases[sender.tag - 1])
        case 5: draft.undo()
        case 6: draft.reset()
        default: save()
        }
        if keepFocus && (1...6).contains(sender.tag) { window?.makeFirstResponder(sender) }
    }
    @objc private func changeColor() {
        guard let draft, let ink = Ink(rawValue: color.titleOfSelectedItem ?? "") else { return }
        draft.ink = ink; draft.changeStyle()
        window?.makeFirstResponder(color)
    }
    @objc private func changeSize() {
        guard let draft, size.indexOfSelectedItem >= 0 else { return }
        if draft.tool == .text { draft.fontSize = [CGFloat(12), 18, 24, 32, 42, 54, 64][size.indexOfSelectedItem] }
        else { draft.width = [CGFloat(2), 4, 8][size.indexOfSelectedItem] }
        draft.changeStyle()
        window?.makeFirstResponder(size)
    }
}
