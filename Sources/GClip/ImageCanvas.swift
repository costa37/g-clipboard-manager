import AppKit

extension ImageMark {
    func translated(by delta: CGPoint) -> ImageMark {
        var copy = self; copy.start.x += delta.x; copy.start.y += delta.y; copy.end.x += delta.x; copy.end.y += delta.y; return copy
    }
    func hit(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if tool == .text { return rect.contains(point) }
        if tool == .rectangle { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) && !rect.insetBy(dx: tolerance, dy: tolerance).contains(point) }
        let dx = end.x - start.x, dy = end.y - start.y, length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length)) : 0
        return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy) <= tolerance
    }
}

// Canvas chrome is in window points; only image pixels and marks are scaled.
// Keep the control group behind the drawing start, away from the arrow tip.
enum AnnotationControls {
    static func rects(start: CGPoint, end: CGPoint, bounds: CGRect) -> (move: CGRect, delete: CGRect) {
        let w: CGFloat = 54, h: CGFloat = 24, gap: CGFloat = 8
        var x = start.x <= end.x ? start.x - w - gap : start.x + gap
        var y = start.y <= end.y ? start.y - h - gap : start.y + gap
        x = min(max(bounds.minX + 4, x), max(bounds.minX + 4, bounds.maxX - w - 4))
        y = min(max(bounds.minY + 4, y), max(bounds.minY + 4, bounds.maxY - h - 4))
        return (CGRect(x: x, y: y + 2, width: 26, height: 20), CGRect(x: x + 30, y: y + 1, width: 22, height: 22))
    }
}

final class AnnotationTextView: NSTextView {
    weak var canvas: ImageCanvasView?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { canvas?.finishText(); return }; super.keyDown(with: event)
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in
            guard let self, self.canvas?.textEditor === self, self.window?.firstResponder !== self else { return }
            self.canvas?.finishText(restoreFocus: false)
        } }
        return result
    }
}

final class ImageCanvasView: NSView, NSTextViewDelegate {
    var draft: ImageDraft!
    var editable = true
    var textEditor: AnnotationTextView?
    private var editingID: UUID?
    private var finishing = false
    private var generation: UUID?
    private var dragStart: CGPoint?
    private var live: ImageMark?
    private var moving: ImageMark?
    private var moveCheckpoint = false
    private var panStart: CGPoint?
    private var oldPan = CGPoint.zero
    private var spaceHeld = false
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; layer?.masksToBounds = true }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true; layer?.masksToBounds = true }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var imageRect: CGRect {
        guard let image = draft.image else { return .zero }
        let available = bounds.insetBy(dx: 12, dy: 12)
        let scale = max(0.001, min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))) * draft.zoom
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let maxX = max(0, (size.width - available.width) / 2), maxY = max(0, (size.height - available.height) / 2)
        let panX = max(-maxX, min(maxX, draft.pan.x)), panY = max(-maxY, min(maxY, draft.pan.y))
        return CGRect(x: bounds.midX - size.width / 2 + panX, y: bounds.midY - size.height / 2 + panY, width: size.width, height: size.height)
    }
    func setPan(_ proposed: CGPoint) {
        let rect = imageRect, available = bounds.insetBy(dx: 12, dy: 12)
        let x = max(0, (rect.width - available.width) / 2), y = max(0, (rect.height - available.height) / 2)
        draft.pan = CGPoint(x: max(-x, min(x, proposed.x)), y: max(-y, min(y, proposed.y)))
    }
    var scale: CGFloat { guard let image = draft.image else { return 1 }; return imageRect.width / CGFloat(image.width) }
    func pixel(_ point: CGPoint, clamp: Bool = true) -> CGPoint {
        guard let image = draft.image else { return .zero }; let r = imageRect
        let p = CGPoint(x: (point.x - r.minX) / scale, y: (point.y - r.minY) / scale)
        return clamp ? CGPoint(x: min(CGFloat(image.width), max(0, p.x)), y: min(CGFloat(image.height), max(0, p.y))) : p
    }
    func screen(_ point: CGPoint) -> CGPoint { CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale) }
    func screenRect(_ rect: CGRect) -> CGRect { CGRect(origin: screen(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale)) }
    func refresh() {
        if generation != draft.generation { finishText(restoreFocus: false); generation = draft.generation; live = nil; moving = nil; dragStart = nil; spaceHeld = false }
        if let editingID, !draft.marks.contains(where: { $0.id == editingID }) { finishText(restoreFocus: false) }
        layoutText(); needsDisplay = true
    }
    override func layout() { super.layout(); layoutText() }
    func layoutText() {
        guard let editor = textEditor, let mark = draft.marks.first(where: { $0.id == editingID }) else { return }
        editor.frame = screenRect(mark.rect); editor.font = .systemFont(ofSize: mark.fontSize * scale, weight: .semibold)
        editor.textColor = mark.color; editor.insertionPointColor = mark.color
        editor.textContainer?.containerSize = CGSize(width: editor.bounds.width, height: .greatestFiniteMagnitude)
    }
    func beginText(_ mark: ImageMark, checkpoint: Bool) {
        finishText(); if checkpoint { draft.checkpoint() }; draft.selected = mark.id; editingID = mark.id
        let editor = AnnotationTextView(frame: screenRect(mark.rect)); editor.canvas = self; editor.delegate = self
        editor.isRichText = false; editor.isEditable = true; editor.isSelectable = true; editor.drawsBackground = false
        editor.textContainerInset = .zero; editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = false; editor.isHorizontallyResizable = false; editor.allowsUndo = false
        editor.string = mark.text; textEditor = editor; addSubview(editor); layoutText(); window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }
    func textDidChange(_ notification: Notification) {
        guard let editor = textEditor, var mark = draft.marks.first(where: { $0.id == editingID }) else { return }
        mark.text = editor.string
        let height = (mark.text as NSString).boundingRect(with: CGSize(width: mark.rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: mark.fontSize, weight: .semibold)]).height
        mark.end.y = min(CGFloat(draft.image?.height ?? 0), mark.start.y + max(mark.fontSize * 1.8, ceil(height) + 6))
        draft.update(mark)
    }
    func finishText(restoreFocus: Bool = true) {
        guard !finishing, let editor = textEditor else { return }; finishing = true
        if var mark = draft.marks.first(where: { $0.id == editingID }) { mark.text = editor.string; draft.update(mark) }
        textEditor = nil; editingID = nil; editor.delegate = nil
        if window?.firstResponder === editor { window?.makeFirstResponder(restoreFocus ? self : nil) }
        editor.removeFromSuperview(); finishing = false; needsDisplay = true
    }
    func controls(_ mark: ImageMark) -> (move: CGRect, delete: CGRect) {
        let start = mark.tool == .text ? CGPoint(x: mark.rect.maxX, y: mark.rect.minY) : mark.start
        let end = mark.tool == .text ? mark.rect.origin : mark.end
        return AnnotationControls.rects(start: screen(start), end: screen(end), bounds: bounds)
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(srgbRed: 0.09, green: 0.105, blue: 0.12, alpha: 1) : .controlBackgroundColor).setFill(); bounds.fill()
        guard let image = draft.image, let context = NSGraphicsContext.current?.cgContext else {
            let label = draft.loading ? "Loading image…" : draft.error
            if !label.isEmpty { (label as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]) }
            return
        }
        let rect = imageRect
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.saveGState(); context.clip(to: rect.intersection(bounds)); context.translateBy(x: rect.minX, y: rect.minY); context.scaleBy(x: scale, y: scale)
        for mark in draft.marks where mark.id != editingID { mark.draw() }
        if var placeholder = draft.marks.first(where: { $0.id == editingID && $0.text.isEmpty }) {
            placeholder.text = "Type here…"; placeholder.color = placeholder.color.withAlphaComponent(0.5); placeholder.draw()
        }
        live?.draw(); context.restoreGState()
        if editable, let mark = live ?? draft.selectedMark, mark.tool != .crop {
            NSColor(srgbRed: 0.2, green: 0.63, blue: 0.7, alpha: 1).setStroke()
            let outline = NSBezierPath(rect: screenRect(mark.rect).insetBy(dx: -3, dy: -3)); outline.lineWidth = 1; outline.setLineDash([4, 3], count: 2, phase: 0); outline.stroke()
            let buttons = controls(mark)
            let fill = NSColor(srgbRed: 0.14, green: 0.26, blue: 0.3, alpha: 1)
            fill.setFill(); NSBezierPath(roundedRect: buttons.move, xRadius: 4, yRadius: 4).fill(); NSBezierPath(ovalIn: buttons.delete).fill()
            NSColor(srgbRed: 0.5, green: 0.7, blue: 0.73, alpha: 1).setStroke(); NSBezierPath(ovalIn: buttons.delete).stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.white]
            ("×" as NSString).draw(at: CGPoint(x: buttons.delete.midX - 6, y: buttons.delete.midY - 11), withAttributes: attrs)
            ("⠿" as NSString).draw(at: CGPoint(x: buttons.move.midX - 6, y: buttons.move.midY - 10), withAttributes: attrs)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil); finishText(); window?.makeFirstResponder(self)
        if draft.panMode || spaceHeld { panStart = point; oldPan = draft.pan; return }
        guard editable else { return }
        if let mark = draft.selectedMark {
            let c = controls(mark)
            if c.delete.contains(point) { draft.deleteSelected(); return }
            if c.move.contains(point) { moving = mark; dragStart = pixel(point, clamp: false); moveCheckpoint = false; return }
        }
        guard imageRect.contains(point), let image = draft.image else { draft.selected = nil; return }
        let first = pixel(point)
        if let mark = draft.marks.reversed().first(where: { $0.hit(first, tolerance: max($0.width / 2, 7 / scale)) }) {
            draft.selected = mark.id
            if mark.tool == .text { beginText(mark, checkpoint: true) }
            else { moving = mark; dragStart = first; moveCheckpoint = false }
        } else if draft.tool == .text {
            let w = min(CGFloat(image.width), max(120, 220 / scale)), h = min(CGFloat(image.height), max(draft.fontSize * 1.8, 44 / scale))
            let origin = CGPoint(x: min(first.x, CGFloat(image.width) - w), y: min(first.y, CGFloat(image.height) - h))
            var mark = draft.mark(from: origin, to: CGPoint(x: origin.x + w, y: origin.y + h)); mark.text = ""
            draft.apply(mark); beginText(mark, checkpoint: false)
        } else {
            draft.selected = nil; dragStart = first; live = draft.mark(from: first, to: first)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let panStart { setPan(CGPoint(x: oldPan.x + point.x - panStart.x, y: oldPan.y + point.y - panStart.y)); return }
        guard let dragStart else { return }
        if let moving {
            let p = pixel(point, clamp: false)
            if !moveCheckpoint { draft.checkpoint(); moveCheckpoint = true }
            var delta = CGPoint(x: p.x - dragStart.x, y: p.y - dragStart.y)
            if let image = draft.image {
                // Keep at least part of the annotation reachable, including after cropping.
                delta.x = min(CGFloat(image.width) - 2 - moving.rect.minX, max(2 - moving.rect.maxX, delta.x))
                delta.y = min(CGFloat(image.height) - 2 - moving.rect.minY, max(2 - moving.rect.maxY, delta.y))
            }
            draft.update(moving.translated(by: delta))
        } else { live?.end = pixel(point); needsDisplay = true }
    }
    override func mouseUp(with event: NSEvent) {
        if panStart != nil { panStart = nil; return }
        if var mark = live { mark.end = pixel(convert(event.locationInWindow, from: nil)); draft.apply(mark) }
        live = nil; moving = nil; dragStart = nil; moveCheckpoint = false; needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = true; return }
        if editable && (event.keyCode == 51 || event.keyCode == 117) { draft.deleteSelected(); return }
        if event.keyCode == 53 { _ = draft.escape(); return }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceHeld = false } else { super.keyUp(with: event) } }
    override func resignFirstResponder() -> Bool { spaceHeld = false; return super.resignFirstResponder() }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { draft.setZoom(draft.zoom + (event.scrollingDeltaY > 0 ? 0.25 : -0.25)) }
        else if draft.zoom > 1 { finishText(); setPan(CGPoint(x: draft.pan.x + event.scrollingDeltaX, y: draft.pan.y + event.scrollingDeltaY)) }
        else { super.scrollWheel(with: event) }
    }
    override func magnify(with event: NSEvent) { draft.setZoom(draft.zoom * (1 + event.magnification)) }
}
