import AppKit
import SwiftUI

// All geometry is expressed in source-image pixels, with a top-left origin.
enum ImageTool: String, CaseIterable { case arrow = "Arrow", rectangle = "Rectangle", text = "Text", crop = "Crop" }
enum Ink: String, CaseIterable {
    case red = "Red", yellow = "Yellow", white = "White", black = "Black"
    var color: NSColor {
        switch self { case .red: return NSColor(srgbRed: 0.95, green: 0.12, blue: 0.14, alpha: 1)
        case .yellow: return NSColor(srgbRed: 1, green: 0.85, blue: 0.05, alpha: 1)
        case .white: return .white; case .black: return .black }
    }
}
struct ImageMark {
    var id = UUID()
    var tool: ImageTool
    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    var width: CGFloat
    var text: String
    var fontSize: CGFloat
    var rect: CGRect { CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)) }
    func draw() {
        color.setStroke(); color.setFill()
        let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        switch tool {
        case .arrow:
            path.move(to: start); path.line(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = min(max(width * 4, 12), hypot(end.x - start.x, end.y - start.y) * 0.45)
            for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: end)
                path.line(to: CGPoint(x: end.x - length * cos(angle + offset), y: end.y - length * sin(angle + offset)))
            }
            path.stroke()
        case .rectangle: NSBezierPath(rect: rect).withStroke(width)
        case .text:
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
            (text as NSString).draw(in: CGRect(x: start.x, y: start.y, width: max(1, end.x - start.x), height: max(fontSize * 1.5, end.y - start.y)), withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: color, .paragraphStyle: style])
        case .crop:
            path.appendRect(rect); path.setLineDash([6, 4], count: 2, phase: 0); path.stroke()
        }
    }
}
private extension NSBezierPath { func withStroke(_ width: CGFloat) { lineWidth = width; stroke() } }

enum ImageRenderer {
    static func render(_ image: CGImage, mark: ImageMark? = nil) -> CGImage? { render(image, marks: mark.map { [$0] } ?? []) }
    static func render(_ image: CGImage, marks: [ImageMark]) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(image.height)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: CGRect(x: 0, y: 0, width: image.width, height: image.height), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        marks.forEach { $0.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let clipped = rect.standardized.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        return image.cropping(to: clipped)
    }
    static func png(_ image: CGImage) -> Data? { NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) }
}

final class ImageDraft: ObservableObject {
    @Published var image: CGImage?
    @Published var loading = false
    @Published var marks: [ImageMark] = []
    @Published var selected: UUID?
    @Published var tool: ImageTool = .arrow
    @Published var ink: Ink = .red
    @Published var text = ""
    @Published var width: CGFloat = 4
    @Published var fontSize: CGFloat = 24
    @Published var zoom: CGFloat = 1
    @Published var pan = CGPoint.zero
    @Published var panMode = false
    @Published var generation = UUID()
    @Published var error = ""
    struct Snapshot { let image: CGImage; let marks: [ImageMark] }
    @Published var history: [Snapshot] = []
    var undoImages: [CGImage] { history.map(\.image) }
    private var original: CGImage?
    weak var canvas: ImageCanvasView?
    var selectedMark: ImageMark? { marks.first { $0.id == selected } }
    func load(_ source: NSImage?) {
        var rect = CGRect(origin: .zero, size: source?.size ?? .zero)
        loadImage(source?.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        if source != nil && image == nil { error = "This image could not be decoded." }
    }
    func loadImage(_ source: CGImage?) {
        canvas?.finishText(); original = source
        image = original; marks = []; history = []; selected = nil; text = ""; error = ""; loading = false
        zoom = 1; pan = .zero; panMode = false; generation = UUID()
    }
    func mark(from start: CGPoint, to end: CGPoint) -> ImageMark {
        ImageMark(tool: tool, start: start, end: end, color: ink.color, width: width, text: text, fontSize: fontSize)
    }
    func checkpoint() {
        guard let image else { return }
        history.append(Snapshot(image: image, marks: marks))
        // Shared raster references count only once; annotation undo does not copy the bitmap.
        while history.count > 1 {
            var seen = Set<ObjectIdentifier>(); var bytes = 0
            for step in history where seen.insert(ObjectIdentifier(step.image)).inserted { bytes += step.image.bytesPerRow * step.image.height }
            if history.count <= 40 && bytes <= 128 * 1024 * 1024 { break }; history.removeFirst()
        }
    }
    func apply(_ mark: ImageMark) {
        guard let image else { return }
        if mark.tool != .text && hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y) < 2 { return }
        if mark.tool == .crop {
            let rect = mark.rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let cropped = ImageRenderer.crop(image, to: rect) else { error = "Drag a larger crop area."; return }
            checkpoint(); self.image = cropped
            marks = marks.map { var m = $0; m.start.x -= rect.minX; m.end.x -= rect.minX; m.start.y -= rect.minY; m.end.y -= rect.minY; return m }
            selected = nil; resetZoom()
        } else { checkpoint(); marks.append(mark); selected = mark.id }
        error = ""
    }
    func update(_ mark: ImageMark) { if let i = marks.firstIndex(where: { $0.id == mark.id }) { marks[i] = mark } }
    func deleteSelected() { canvas?.finishText(); guard let selected, marks.contains(where: { $0.id == selected }) else { return }; checkpoint(); marks.removeAll { $0.id == selected }; self.selected = nil }
    func undo() { canvas?.finishText(); if let previous = history.popLast() { image = previous.image; marks = previous.marks; selected = nil; error = ""; resetZoom() } }
    func reset() { canvas?.finishText(); guard let original, image != nil else { return }; checkpoint(); image = original; marks = []; selected = nil; error = ""; resetZoom() }
    func resetZoom() { canvas?.finishText(); zoom = 1; pan = .zero }
    func setZoom(_ value: CGFloat) { canvas?.finishText(); zoom = min(6, max(1, value)); if zoom == 1 { pan = .zero } }
    func selectTool(_ value: ImageTool) { canvas?.finishText(); selected = nil; panMode = false; tool = value; canvas?.window?.makeFirstResponder(canvas) }
    func changeStyle() {
        canvas?.finishText(); guard var mark = selectedMark else { return }; checkpoint()
        mark.color = ink.color; mark.width = width; mark.fontSize = fontSize; update(mark)
    }
    func export() -> CGImage? { canvas?.finishText(); guard let image else { return nil }; return ImageRenderer.render(image, marks: marks) }
    func escape() -> Bool {
        if canvas?.textEditor != nil { canvas?.finishText(); return true }
        if selected != nil { selected = nil; return true }
        return false
    }
}

struct ImageCanvas: NSViewRepresentable {
    @ObservedObject var draft: ImageDraft
    var editable = true
    func makeNSView(context: Context) -> ImageCanvasView { let view = ImageCanvasView(); view.draft = draft; view.editable = editable; draft.canvas = view; return view }
    func updateNSView(_ view: ImageCanvasView, context: Context) { view.draft = draft; view.editable = editable; draft.canvas = view; view.refresh() }
    static func dismantleNSView(_ view: ImageCanvasView, coordinator: ()) { view.finishText(); if view.draft.canvas === view { view.draft.canvas = nil } }
}

// Explicit foreground colors avoid the low-contrast teal tint inherited from
// the window. Disabled controls remain distinguishable from available actions.
struct ImageControlStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(scheme == .dark ? Color(white: 0.95) : Color(white: 0.12))
            .background(configuration.isPressed ? Color.primary.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

struct ImageEditor: View {
    @Environment(\.colorScheme) private var scheme
    private var controlColor: Color { scheme == .dark ? Color(white: 0.95) : Color(white: 0.12) }
    @ObservedObject var draft: ImageDraft
    var back: () -> Void
    var copy: () -> Void
    private func symbol(_ tool: ImageTool) -> String {
        switch tool { case .arrow: return "arrow.up.right"; case .rectangle: return "rectangle"; case .text: return "textformat"; case .crop: return "crop" }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: back) { Image(systemName: "chevron.left").font(.system(size: 17, weight: .medium)).frame(width: 32, height: 32) }.help("Back to preview (Escape)").accessibilityLabel("Back to preview")
                Divider().frame(height: 18)
                ForEach(ImageTool.allCases, id: \.self) { tool in
                    Button { draft.selectTool(tool) } label: {
                        Image(systemName: symbol(tool)).font(.system(size: 18, weight: .medium)).frame(width: 34, height: 32)
                            .background(draft.tool == tool ? Color(red: 0.16, green: 0.43, blue: 0.46) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }.help(tool == .crop ? "Crop: drag to keep an area" : tool.rawValue)
                        .accessibilityLabel(tool.rawValue).accessibilityAddTraits(draft.tool == tool ? .isSelected : [])
                }
                Divider().frame(height: 18)
                if draft.tool != .crop {
                    Menu {
                        ForEach(Ink.allCases, id: \.self) { ink in
                            Button { draft.ink = ink; draft.changeStyle() } label: { Label(ink.rawValue, systemImage: draft.ink == ink ? "checkmark.circle.fill" : "circle") }
                        }
                    } label: { Text(draft.ink.rawValue).foregroundStyle(controlColor) }
                    .menuStyle(.borderlessButton).tint(controlColor).foregroundStyle(controlColor).frame(width: 55).help("Color: \(draft.ink.rawValue)").accessibilityLabel("Annotation color: \(draft.ink.rawValue)")
                    if draft.tool == .text {
                        Picker("Text size", selection: $draft.fontSize) { ForEach([CGFloat(12), 18, 24, 32, 42, 54, 64], id: \.self) { Text("\(Int($0)) pt").tag($0) } }.labelsHidden().tint(controlColor).foregroundStyle(controlColor).frame(width: 66).onChange(of: draft.fontSize) { _ in draft.changeStyle() }
                    } else {
                        Picker("Stroke", selection: $draft.width) { Text("Thin").tag(CGFloat(2)); Text("Medium").tag(CGFloat(4)); Text("Thick").tag(CGFloat(8)) }.labelsHidden().tint(controlColor).foregroundStyle(controlColor).frame(width: 74).onChange(of: draft.width) { _ in draft.changeStyle() }.help("Stroke width")
                    }
                }
                Spacer(minLength: 0)
                Button { draft.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 17, weight: .medium)).frame(width: 32, height: 32) }.disabled(draft.history.isEmpty).help("Undo (⌘Z)").accessibilityLabel("Undo")
                Button { draft.reset() } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 17, weight: .medium)).frame(width: 32, height: 32) }.help("Reset to original image").accessibilityLabel("Reset image")
                Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(.borderedProminent).help("Copy edited image as a new item (⌘C)")
            }.buttonStyle(ImageControlStyle()).controlSize(.regular).font(.system(size: 13)).padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            ImageCanvas(draft: draft).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ImageStatus: View {
    @ObservedObject var draft: ImageDraft
    var editing: Bool
    var clip: Clip?
    var body: some View {
        if draft.loading { Text("Loading image…") }
        else if let image = draft.image {
            Text("\(image.width) × \(image.height) · \(editing || clip?.data[NSPasteboard.PasteboardType.png.rawValue] != nil ? "PNG" : "TIFF")")
        }

    }
}
struct ImageEditHint: View {
    @ObservedObject var draft: ImageDraft
    var body: some View {
        Text(draft.error.isEmpty ? "Drag to draw · Click to edit · Delete removes · ⌘C Copy" : draft.error)
            .foregroundStyle(draft.error.isEmpty ? Color.secondary : Color.red)
            .lineLimit(1).help(draft.error)
    }
}

struct ImageZoomControls: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var draft: ImageDraft
    var body: some View {
        HStack(spacing: 4) {
            Button { draft.canvas?.finishText(); draft.panMode.toggle() } label: { Image(systemName: "hand.raised").font(.system(size: 19, weight: .medium)).frame(width: 34, height: 32).background(draft.panMode ? Color(red: 0.16, green: 0.43, blue: 0.46) : .clear, in: RoundedRectangle(cornerRadius: 5)) }.help("Pan image (or hold Space and drag)").accessibilityLabel("Pan image")
            Button { draft.setZoom(draft.zoom - 0.5) } label: { Image(systemName: "minus").font(.system(size: 17, weight: .medium)).frame(width: 32, height: 32) }.disabled(draft.zoom <= 1).help("Zoom out").accessibilityLabel("Zoom out")
            Text(String(format: "%g×", Double(draft.zoom))).foregroundStyle(scheme == .dark ? Color(white: 0.95) : Color(white: 0.12)).font(.system(size: 13)).monospacedDigit().frame(width: 34)
            Button { draft.setZoom(draft.zoom + 0.5) } label: { Image(systemName: "plus").font(.system(size: 17, weight: .medium)).frame(width: 32, height: 32) }.disabled(draft.zoom >= 6).help("Zoom in").accessibilityLabel("Zoom in")
            Button { draft.resetZoom() } label: { Text("Reset zoom").font(.system(size: 13)).frame(height: 32) }.help("Return to the default image view and center it")
        }.buttonStyle(ImageControlStyle()).controlSize(.regular)
    }
}
