import AppKit
import SwiftUI
import Carbon
import CryptoKit
import Combine
import ServiceManagement

struct Clip: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var text: String
    var source: String
    var data: [String: Data]
    var isImage: Bool { data[NSPasteboard.PasteboardType.png.rawValue] != nil || data[NSPasteboard.PasteboardType.tiff.rawValue] != nil }
    var isRich: Bool { data[NSPasteboard.PasteboardType.rtf.rawValue] != nil || data[NSPasteboard.PasteboardType.html.rawValue] != nil }
    var image: NSImage? { ImageAssets.shared.image(self).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } }
    var thumbnail: NSImage? { ImageAssets.shared.image(self, thumbnail: true).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } }
    var fingerprint: String {
        let bytes = data.keys.sorted().reduce(into: Data()) { result, key in
            result.append(Data(key.utf8)); result.append(0); result.append(data[key]!)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    var plainPreview: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
    }
    var attributed: NSAttributedString {
        for (type, format) in [(NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf), (.html, .html)] {
            if let bytes = data[type.rawValue], let value = try? NSAttributedString(data: bytes, options: [.documentType: format], documentAttributes: nil) { return value }
        }
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
    }
}

enum ClipAge {
    static func label(since date: Date, now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "Just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) min ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) hr ago" }
        let days = Int(elapsed / 86400)
        return "\(days) \(days == 1 ? "day" : "days") ago"
    }
}

enum ClipFilter: String, CaseIterable {
    case all = "All", text = "Text", images = "Images"
    func advanced(backward: Bool = false) -> ClipFilter {
        let cases = Self.allCases
        let index = cases.firstIndex(of: self)!
        return cases[(index + (backward ? cases.count - 1 : 1)) % cases.count]
    }
    func matches(_ clip: Clip, query: String) -> Bool {
        let typeMatches = self == .all || (self == .images ? clip.isImage : !clip.isImage)
        return typeMatches && (query.isEmpty || clip.text.localizedCaseInsensitiveContains(query) || clip.source.localizedCaseInsensitiveContains(query))
    }
}

enum ClearCommand: Equatable {
    case all, recent(TimeInterval), invalid
    static func isCommand(_ value: String) -> Bool {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).first == "/clear"
    }
    static func parse(_ value: String) -> ClearCommand {
        let parts = value.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard parts.first == "/clear" else { return .invalid }
        if parts.count == 1 { return .all }
        guard parts.count == 2, let unit = parts[1].last, let count = Double(parts[1].dropLast()), count > 0, count.isFinite else { return .invalid }
        let multipliers: [Character: Double] = ["m": 60, "h": 3600, "d": 86400]
        guard let factor = multipliers[unit], (count * factor).isFinite else { return .invalid }
        return .recent(count * factor)
    }
}

final class Store: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var query = ""
    @Published var filter: ClipFilter = .all
    @Published var searchFocusRequest = 0
    @Published var selected: UUID? { didSet { if selected != oldValue { imagePreview.select(current) } } }
    let imagePreview = ImagePreview()
    @Published var editing: Clip?
    let imageDraft = ImageDraft()
    lazy var imageEditorLoader = ImagePreview(draft: imageDraft)
    @Published var draft = NSAttributedString(string: "")
    @Published var message = ""
    @Published var paused = false { didSet { change = NSPasteboard.general.changeCount } }
    @Published var windowMinimum = WindowLayout.preferredMinimum
    @Published var directPasteAllowed = AXIsProcessTrusted()
    var dividerStart: CGFloat?
    @Published var splitRatio: Double = {
        let value = UserDefaults.standard.object(forKey: "splitRatio") as? Double ?? 0.35
        return value.isFinite ? min(0.75, max(0.2, value)) : 0.35
    }() {
        didSet { if !CommandLine.arguments.contains("--preview") { UserDefaults.standard.set(splitRatio, forKey: "splitRatio") } }
    }
    @Published var textScale: Double = {
        let stored = UserDefaults.standard.object(forKey: "textScale") as? Double ?? 1
        return stored.isFinite ? min(1.8, max(0.85, stored)) : 1
    }() {
        didSet { if !CommandLine.arguments.contains("--preview") { UserDefaults.standard.set(textScale, forKey: "textScale") } }
    }
    @Published var theme = UserDefaults.standard.string(forKey: "theme") ?? "System"
    var persistenceBlocked = false
    private let persistenceQueue = DispatchQueue(label: "local.gclip.persistence", qos: .utility)
    private var fingerprints: [UUID: String] = [:]
    var timer: Timer?
    var change = NSPasteboard.general.changeCount
    let directory: URL
    var filtered: [Clip] { clips.filter { filter.matches($0, query: query) } }
    func cycleFilter(backward: Bool = false) {
        filter = filter.advanced(backward: backward)
        selected = filtered.first?.id
        searchFocusRequest += 1
    }
    func resetBrowser() {
        query = ""; editing = nil; filter = .all
        prune(); selected = clips.first?.id
        searchFocusRequest += 1
    }
    var current: Clip? { filtered.first(where: { $0.id == selected }) ?? filtered.first }
    var historyURL: URL { directory.appendingPathComponent("history.json") }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("G-Clip")
        if CommandLine.arguments.contains("--preview") { return }
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: historyURL.path) { clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: historyURL)) }
            fingerprints = Dictionary(clips.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { _, last in last })
            prune(); save()
        } catch { persistenceBlocked = true; message = "History could not be loaded. The original file is preserved; new history will not be saved until it is recovered. \(error.localizedDescription)" }
    }
    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.capture() }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func prune() {
        clips.removeAll { $0.date < Date().addingTimeInterval(-30 * 86400) }
        clips = Array(clips.prefix(1000))
        var total = 0
        clips = clips.filter { clip in total += clip.data.values.reduce(0) { $0 + $1.count }; return total <= 100 * 1024 * 1024 }
    }
    func save() {
        guard !CommandLine.arguments.contains("--preview"), !persistenceBlocked else { return }
        let snapshot = clips
        let destination = historyURL
        // Serial writes preserve mutation order; no encoding or disk IO on the UI thread.
        persistenceQueue.async { [weak self] in
            do {
                try JSONEncoder().encode(snapshot).write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } catch {
                DispatchQueue.main.async { self?.message = "History could not be saved: \(error.localizedDescription)" }
            }
        }
    }
    func flushPersistence() { persistenceQueue.sync {} }
    func insert(_ clip: Clip, deduplicate: Bool = true) {
        ImageAssets.shared.invalidate(clip.id)
        let fingerprint = clip.fingerprint
        clips.removeAll { (deduplicate && fingerprints[$0.id] == fingerprint) || $0.id == clip.id }
        fingerprints[clip.id] = fingerprint
        clips.insert(clip, at: 0); prune()
        let live = Set(clips.map(\.id))
        fingerprints = fingerprints.filter { live.contains($0.key) }
        save(); selected = clip.id
    }
    func removeHistory(ids: Set<UUID>) {
        clips.removeAll { ids.contains($0.id) }
        fingerprints = fingerprints.filter { !ids.contains($0.key) }
        if let item = editing, ids.contains(item.id) {
            editing = nil; draft = NSAttributedString(string: ""); imageEditorLoader.select(nil)
        }
        if let selected, ids.contains(selected) { self.selected = nil }
        save()
    }
    func capture(board: NSPasteboard = .general, sourceApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        let generation = board.changeCount
        guard generation != change else { return }
        guard !paused else { change = generation; return }
        let blocked = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess"]
        guard !blocked.contains(sourceApp?.bundleIdentifier ?? "") else { change = generation; return }
        let result = ClipboardIO.read(board, source: sourceApp?.localizedName ?? "Clipboard")
        // A producer may replace the board during a lazy data read. Never mix generations.
        guard board.changeCount == generation else { return }
        switch result {
        case .retry: return // Empty or temporarily unavailable data: try again next poll.
        case .skip(let reason): change = generation; if let reason { message = reason }
        case .clip(let clip): change = generation; insert(clip)
        }
    }
    @discardableResult func copy(_ item: Clip, rich: Bool, addition: Bool = false) -> Bool {
        // Preserve a recent external copy before replacing the system clipboard.
        capture()
        guard ClipboardIO.write(item, rich: rich, to: .general) else {
            message = "Could not write to the clipboard. Please try copying again."
            return false
        }
        change = NSPasteboard.general.changeCount
        var moved = item; moved.date = Date(); insert(moved, deduplicate: !addition)
        return true
    }
    func select(_ item: Clip) { if editing?.isImage == true && item.isImage { if editing?.id != item.id { edit(item) }; return }; editing = nil; selected = item.id }
    func edit(_ item: Clip) { message = ""; selected = item.id; imageEditorLoader.select(item.isImage ? item : nil); draft = item.attributed; editing = item }
    func saveEdited() {
        guard var item = editing else { return }
        item.id = UUID()
        if item.isImage {
            guard let image = imageDraft.export(), let png = ImageRenderer.png(image) else { message = "Could not export the edited image."; return }
            guard png.count <= 10 * 1024 * 1024 else { message = "Edited image exceeds 10 MB. Crop it before saving."; return }
            item.data = [NSPasteboard.PasteboardType.png.rawValue: png]; item.text = ""
        } else {
            item.text = draft.string
            item.data = [NSPasteboard.PasteboardType.string.rawValue: Data(item.text.utf8)]
            if let rtf = try? draft.data(from: NSRange(location: 0, length: draft.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) { item.data[NSPasteboard.PasteboardType.rtf.rawValue] = rtf }
        }
        guard copy(item, rich: true, addition: true) else { return }; editing = nil; query = ""; message = "Saved a new item. Original preserved."
    }
    func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let index = filtered.firstIndex(where: { $0.id == selected }) ?? 0
        selected = filtered[max(0, min(filtered.count - 1, index + delta))].id
    }
    func clear() {
        let command = ClearCommand.parse(query)
        guard command != .invalid else { message = "Use /clear, /clear 1d, /clear 2h, or /clear 30m."; return }
        let doomed = clips.filter { clip in
            switch command { case .all: return true; case .recent(let interval): return clip.date >= Date().addingTimeInterval(-interval); case .invalid: return false }
        }
        let alert = NSAlert(); alert.messageText = "Delete \(doomed.count) clips?"
        alert.informativeText = "This permanently removes matching history. /clear 1d means the last 24 hours. The current system clipboard is also emptied."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ids = Set(doomed.map(\.id)); removeHistory(ids: ids)
        NSPasteboard.general.clearContents(); change = NSPasteboard.general.changeCount
        query = ""; save(); message = "Deleted \(doomed.count) clips."
    }
}

enum BrowsingKeys {
    static func handles(_ key: UInt16, modifiers: NSEvent.ModifierFlags, query: String) -> Bool {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        switch key {
        case 48, 36, 76: return flags.isEmpty || flags == .shift
        case 125, 126: return flags.isEmpty
        case 124: return flags.isEmpty && query.isEmpty
        default: return false
        }
    }
}

final class MatchingStyleTextView: NSTextView {
    // Keep existing rich runs; newly pasted text uses the insertion point's style.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

final class WrappingTextScrollView: NSScrollView {
    override func layout() {
        super.layout()
        fitTextToViewport()
    }

    func fitTextToViewport() {
        guard let text = documentView as? NSTextView else { return }
        // Clip-view bounds are in document coordinates, including text magnification.
        let width = max(1, contentView.bounds.width)
        if abs(text.frame.width - width) > 0.5 {
            text.setFrameSize(NSSize(width: width, height: text.frame.height))
        }
        text.textContainer?.containerSize = NSSize(
            width: max(1, width - 2 * text.textContainerInset.width),
            height: .greatestFiniteMagnitude)
    }
}

struct RichEditor: NSViewRepresentable {
    @Binding var value: NSAttributedString
    var editable = true
    var textScale: Double = 1
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = WrappingTextScrollView()
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let text = MatchingStyleTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        text.isEditable = editable; text.isSelectable = true; text.allowsUndo = true; text.isRichText = true; text.isAutomaticQuoteSubstitutionEnabled = false
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.delegate = context.coordinator; text.textStorage?.setAttributedString(value)
        text.typingAttributes = value.length > 0 ? value.attributes(at: 0, effectiveRange: nil) : [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]
        text.drawsBackground = false; scroll.drawsBackground = false
        scroll.minMagnification = 0.85; scroll.maxMagnification = 1.8
        scroll.magnification = textScale
        scroll.fitTextToViewport()
        if editable { DispatchQueue.main.async { text.window?.makeFirstResponder(text) } }
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if abs(view.magnification - textScale) > 0.001 { view.magnification = textScale }
        (view as? WrappingTextScrollView)?.fitTextToViewport()
        let text = view.documentView as! NSTextView
        if !text.attributedString().isEqual(to: value) { text.textStorage?.setAttributedString(value) }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichEditor
        init(_ parent: RichEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let text = notification.object as? NSTextView { parent.value = text.attributedString() } }
    }
}

enum SplitLayout {
    static func listWidth(total: CGFloat, ratio: Double) -> CGFloat {
        let available = max(0, total - 10)
        return max(260, min(available - 620, available * ratio))
    }
}

final class MenuTypographyView: NSView {
    let store: Store
    let slider: NSSlider
    let percentage = NSTextField(labelWithString: "")
    let example = NSTextField(labelWithString: "Example")
    init(store: Store) {
        self.store = store
        slider = NSSlider(value: store.textScale, minValue: 0.85, maxValue: 1.8, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: 142))
        let small = NSTextField(labelWithString: "A"); small.font = .systemFont(ofSize: 13)
        small.frame = NSRect(x: 14, y: 94, width: 20, height: 22)
        let large = NSTextField(labelWithString: "A"); large.font = .systemFont(ofSize: 30)
        large.frame = NSRect(x: 291, y: 87, width: 30, height: 38)
        slider.frame = NSRect(x: 40, y: 95, width: 242, height: 24)
        slider.numberOfTickMarks = 20; slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true; slider.target = self; slider.action = #selector(changeSize)
        slider.setAccessibilityLabel("Text size")
        percentage.frame = NSRect(x: 100, y: 69, width: 130, height: 20); percentage.alignment = .center
        example.frame = NSRect(x: 14, y: 30, width: 302, height: 35); example.alignment = .center
        let reset = NSButton(title: "Default", target: self, action: #selector(resetSize))
        reset.bezelStyle = .inline; reset.frame = NSRect(x: 125, y: 4, width: 80, height: 24)
        for view in [small, large, slider, percentage, example, reset] { addSubview(view) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func changeSize() { store.textScale = slider.doubleValue; refresh() }
    @objc func resetSize() { store.textScale = 1; slider.doubleValue = 1; refresh() }
    func refresh() {
        percentage.stringValue = abs(store.textScale - 1) < 0.001 ? "Default" : "\(Int((store.textScale * 100).rounded()))%"
        example.font = .systemFont(ofSize: 15 * store.textScale)
    }
}

// An explicit drag target keeps moving reliable even when the SwiftUI search
// bar consumes mouse events. Text fields and the drawing canvas keep their gestures.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {}
}
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

struct Content: View {
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { store.theme == "Dark" || (store.theme == "System" && colorScheme == .dark) }
    private var selectionColor: Color { dark ? Color(red: 0.21, green: 0.50, blue: 0.53) : Color.accentColor.opacity(0.16) }

    @ObservedObject var store: Store
    var paste: (Clip, Bool) -> Void
    var enablePaste: () -> Void
    @FocusState var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 28, height: 28).overlay(WindowDragHandle()).help("Drag to move G-Clip").accessibilityLabel("G-Clip — drag to move window")
                TextField("Search clips…  /clear · /clear 1d", text: $store.query).textFieldStyle(.plain).font(.system(size: 14 * store.textScale)).focused($searchFocused)
                    .onChange(of: store.query) { _ in store.selected = store.filtered.first?.id }
                Text(store.filter.rawValue).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .accessibilityLabel("Current filter: \(store.filter.rawValue)")
                    .help("Tab: next filter · Shift+Tab: previous filter")
                Text("Tab ⇥").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("All → Text → Images; Shift+Tab reverses")
                if store.paused { Image(systemName: "pause.circle.fill").foregroundStyle(.orange).help("Clipboard capture paused") }
                Text("ESC").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.vertical, 7).background(dark ? Color(red: 0.065, green: 0.06, blue: 0.085) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8)).padding(10)
            Divider()
            GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if ClearCommand.isCommand(store.query) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Clear clipboard history", systemImage: "trash").font(.headline)
                            Text("/clear — all history\n/clear 1d — last 24 hours\n/clear 2h — last 2 hours\n/clear 30m — last 30 minutes").foregroundStyle(.secondary)
                            Button("Review deletion…") { store.clear() }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
                    } else if store.filtered.isEmpty {
                        VStack(spacing: 12) { Image(systemName: "clipboard").font(.system(size: 36)).foregroundStyle(.secondary); Text(store.filter == .images ? "No matching images" : store.filter == .text ? "No matching text" : store.query.isEmpty ? "A little more room for your memory." : "No matching clips").font(.headline); Text(store.query.isEmpty ? "Copy an item, or press Tab to change the filter." : "Try another search or press Tab to change the filter.").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    ForEach(store.filtered) { item in
                                        HStack(spacing: 12) {
                                            if let image = item.thumbnail { Image(nsImage: image).resizable().scaledToFit().frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 5)) }
                                            else { Image(systemName: "text.alignleft").font(.system(size: 19)).foregroundStyle(.secondary).frame(width: 42, height: 42) }
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(item.isImage ? "Image" : item.text).font(.system(size: 13 * store.textScale, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                                HStack { Text(item.source); Text("·"); TimelineView(.periodic(from: .now, by: 60)) { context in Text(ClipAge.label(since: item.date, now: context.date)) } }.font(.system(size: 10 * store.textScale)).foregroundStyle(.secondary)
                                            }
                                            if item.isRich && !item.isImage { Button { paste(item, true) } label: { Image(systemName: "textformat") }.buttonStyle(.borderless).help("Paste with formatting (⇧↵)").accessibilityLabel("Paste with formatting") }
                                            Button { store.edit(item) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).help("Edit or preview (→)").accessibilityLabel("Edit or preview clip")
                                        }.padding(10).background(store.current?.id == item.id ? selectionColor : Color.clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                                            .onTapGesture(count: 2) { paste(item, false) }.onTapGesture { store.select(item) }.id(item.id)
                                    }
                                }.padding(8)
                            }.onChange(of: store.selected) { id in if let id { proxy.scrollTo(id) } }
                        }
                    }
                }.frame(width: SplitLayout.listWidth(total: geometry.size.width, ratio: store.splitRatio))
                Rectangle().fill(Color.secondary.opacity(0.14)).frame(width: 10)
                    .overlay(Capsule().fill(Color.secondary.opacity(0.55)).frame(width: 3, height: 36))
                    .contentShape(Rectangle()).help("Drag to resize history and preview")
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if store.dividerStart == nil { store.dividerStart = SplitLayout.listWidth(total: geometry.size.width, ratio: store.splitRatio) }
                        let available = max(1, geometry.size.width - 10)
                        let proposed = (store.dividerStart! + value.translation.width) / available
                        store.splitRatio = SplitLayout.listWidth(total: geometry.size.width, ratio: proposed) / available
                    }.onEnded { _ in store.dividerStart = nil })
                    .accessibilityLabel("History and preview divider")
                    .accessibilityAdjustableAction { direction in
                        store.splitRatio = min(0.75, max(0.2, store.splitRatio + (direction == .increment ? 0.03 : -0.03)))
                    }
                if let item = store.editing {
                    if item.isImage {
                        ImageEditor(draft: store.imageDraft, back: { store.editing = nil }, save: { store.saveEdited() })
                    } else {
                        VStack(spacing: 0) {
                            HStack {
                                Button { store.editing = nil } label: { Label("Back", systemImage: "chevron.left") }.help("Back to preview (Escape)")
                                Spacer()
                                Button { store.saveEdited() } label: { Label("Save", systemImage: "checkmark") }.buttonStyle(.borderedProminent).help("Save as a new formatted item (⌘S)")
                            }.controlSize(.small).padding(8)
                            Divider()
                            RichEditor(value: $store.draft, textScale: store.textScale)
                        }
                    }
                } else if let item = store.current, !ClearCommand.isCommand(store.query) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Preview").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Edit →") { store.edit(item) }
                            Button("Paste") { paste(item, false) }
                        }.controlSize(.small).padding(8)
                        Divider()
                        if item.isImage { ImageCanvas(draft: store.imagePreview.draft, editable: false) }
                        else { RichEditor(value: .constant(item.plainPreview), editable: false, textScale: store.textScale).id(item.id) }
                    }
                } else {
                    Text("Select a clip to preview it").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            }
            Divider()
            HStack {
                if store.editing?.isImage == true && store.message.isEmpty { ImageEditHint(draft: store.imageDraft) }
                else { Text(store.message.isEmpty ? (store.editing == nil ? "↑↓ Browse    ↵ Paste    ⇧↵ With formatting    → Edit" : "Esc Back to list    ⌘S Save as new item") : store.message).lineLimit(1).help(store.message) }
                Spacer()
                if store.editing?.isImage == true || store.current?.isImage == true { ImageZoomControls(draft: store.editing?.isImage == true ? store.imageDraft : store.imagePreview.draft) }
                ImageStatus(draft: store.editing?.isImage == true ? store.imageDraft : store.imagePreview.draft, editing: store.editing?.isImage == true, clip: store.current)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 7)
        }.frame(minWidth: store.windowMinimum.width, idealWidth: 1500, maxWidth: .infinity, minHeight: store.windowMinimum.height, idealHeight: 890, maxHeight: .infinity)
            .background { if dark { LinearGradient(colors: [Color(red: 0.15, green: 0.10, blue: 0.09), Color(red: 0.09, green: 0.10, blue: 0.13), Color(red: 0.07, green: 0.14, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing) } else { Color(nsColor: .windowBackgroundColor) } }
            .tint(dark ? Color(red: 0.21, green: 0.50, blue: 0.53) : .accentColor)
            .preferredColorScheme(store.theme == "Dark" ? .dark : store.theme == "Light" ? .light : nil)
            .onAppear { searchFocused = true }
            .onChange(of: store.searchFocusRequest) { _ in searchFocused = true }
            .onChange(of: store.editing?.id) { id in if id == nil { searchFocused = true } }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in if store.editing == nil { searchFocused = true } }
    }
}

final class FloatingPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store()
    var status: NSStatusItem!
    var panel: FloatingPanel!
    var previous: NSRunningApplication?
    var pasteDestination: PasteDestination?
    var activationObserver: NSObjectProtocol?
    var pasteAttempt = UUID()
    var hotkey: EventHotKeyRef?
    var localMonitor: Any?
    var mouseMonitor: Any?
    var editorSubscription: AnyCancellable?
    var screenObserver: NSObjectProtocol?
    var fittingWindow = false
    var preferredWindowSize: CGSize?
    var alwaysOpenOnMainDisplay: Bool {
        get { UserDefaults.standard.object(forKey: "alwaysOpenOnMainDisplay") as? Bool ?? true }
        set { if !CommandLine.arguments.contains("--preview") { UserDefaults.standard.set(newValue, forKey: "alwaysOpenOnMainDisplay") } }
    }
    var hotkeyLabel = "⌥⌘Space"
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let appMenu = NSMenu(); let root = NSMenuItem(); appMenu.addItem(root)
        let edit = NSMenu(title: "Edit"); root.submenu = edit
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"), ("Undo", "undo:", "z")] { edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        let redo = edit.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        NSApp.mainMenu = appMenu
        if !CommandLine.arguments.contains("--preview"),
           let stored = UserDefaults.standard.array(forKey: "preferredWindowSize") as? [Double], stored.count == 2 {
            preferredWindowSize = WindowLayout.valid(CGSize(width: stored[0], height: stored[1]))
        }
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 890), styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "G-Clip"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: Content(store: store, paste: { [weak self] item, rich in self?.paste(item, rich: rich) }, enablePaste: { [weak self] in self?.accessibility() }))
        rememberDestination(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            self.store.directPasteAllowed = AXIsProcessTrusted()
            if !self.panel.isVisible { self.rememberDestination(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication) }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }; self.fitWindow(center: self.alwaysOpenOnMainDisplay, usePreferred: false)
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "G-Clip")
        status.button?.target = self; status.button?.action = #selector(statusClicked); status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        installHotkey()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type != .keyDown { if event.window !== self.panel && NSApp.modalWindow == nil { self.panel.orderOut(nil) }; return event }
            guard NSApp.modalWindow == nil, event.window === self.panel else { return event }
            let textResponder = self.panel.firstResponder as? NSTextView
            // Input-method composition owns Return, Escape and navigation until committed.
            if textResponder?.hasMarkedText() == true { return event }
            if event.keyCode == 53 { if self.store.editing?.isImage == true && self.store.imageDraft.escape() { return nil }; if self.store.editing != nil { self.store.editing = nil } else { self.dismissAndRestoreFocus() }; return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if self.store.editing != nil {
                if self.store.editing?.isImage == true && !(textResponder?.isEditable ?? false) && flags.intersection([.command, .control, .option, .shift]) == .command && event.charactersIgnoringModifiers?.lowercased() == "z" { self.store.imageDraft.undo(); return nil }
                if flags.intersection([.command, .control, .option, .shift]) == .command && event.charactersIgnoringModifiers?.lowercased() == "s" { self.store.saveEdited(); return nil }
                return event
            }
            // A selected text preview keeps normal text navigation and selection.
            if textResponder is MatchingStyleTextView && [48, 123, 124, 125, 126].contains(event.keyCode) { return event }
            guard BrowsingKeys.handles(event.keyCode, modifiers: flags, query: self.store.query) else { return event }
            if event.keyCode == 48 {
                self.store.cycleFilter(backward: flags.contains(.shift)); return nil
            }
            switch event.keyCode {
            case 125: self.store.move(1); return nil
            case 126: self.store.move(-1); return nil
            case 124: if let item = self.store.current { self.store.edit(item) }; return nil
            case 36, 76:
                if ClearCommand.isCommand(self.store.query) { self.store.clear() } else if let item = self.store.current { self.paste(item, rich: flags.contains(.shift)) }; return nil
            default: return event
            }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in if NSApp.modalWindow == nil { self?.panel.orderOut(nil) } }
        if CommandLine.arguments.contains("--preview") {
            for text in ["Design notes\nKeep the things you copy close at hand.", "https://developer.apple.com", "Welcome to G-Clip. Your clipboard, with memory."] {
                store.insert(Clip(text: text, source: "Preview", data: [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]))
            }
            toggle()
            if CommandLine.arguments.contains("--preview-image"), let context = CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.setFillColor(CGColor(red: 0.12, green: 0.17, blue: 0.25, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
                context.setFillColor(CGColor(red: 0.3, green: 0.65, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 100, y: 120, width: 300, height: 340))
                context.setFillColor(CGColor(red: 0.8, green: 0.65, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 490, y: 120, width: 300, height: 340))
                if let image = context.makeImage(), let png = ImageRenderer.png(image) {
                    let clip = Clip(text: "", source: "Synthetic image", data: [NSPasteboard.PasteboardType.png.rawValue: png])
                    if let detail = image.cropping(to: CGRect(x: 450, y: 0, width: 450, height: 600)), let detailPNG = ImageRenderer.png(detail) {
                        store.insert(Clip(text: "", source: "Synthetic detail", data: [NSPasteboard.PasteboardType.png.rawValue: detailPNG]))
                    }
                    store.insert(clip); store.edit(clip)
                }
            }
        } else { configureLogin(); store.start() }
    }
    func fitWindow(center: Bool, usePreferred: Bool) {
        guard !fittingWindow else { return }; fittingWindow = true; defer { fittingWindow = false }
        let screens = NSScreen.screens
        // The first screen is the configured primary display; NSScreen.main follows keyboard focus.
        let openingIndex = WindowLayout.openingScreenIndex(frames: screens.map(\.frame), pointer: NSEvent.mouseLocation, preferPrimary: alwaysOpenOnMainDisplay)
        let openingScreen = openingIndex.map { screens[$0] }
        guard let screen = (center ? openingScreen : panel.screen) ?? screens.first else { return }
        let visible = screen.visibleFrame
        let minimum = WindowLayout.minimum(in: visible)
        store.windowMinimum = minimum
        panel.minSize = minimum
        panel.maxSize = WindowLayout.area(visible).size
        panel.setFrame(WindowLayout.frame(in: visible,
            preferred: usePreferred ? preferredWindowSize : panel.frame.size,
            origin: center ? nil : panel.frame.origin), display: true)
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        guard !fittingWindow else { return }
        preferredWindowSize = panel.frame.size
        if !CommandLine.arguments.contains("--preview") {
            UserDefaults.standard.set([Double(panel.frame.width), Double(panel.frame.height)], forKey: "preferredWindowSize")
        }
    }
    func windowDidChangeScreen(_ notification: Notification) {
        if panel.isVisible && !fittingWindow { fitWindow(center: false, usePreferred: false) }
    }
    func windowDidResignKey(_ notification: Notification) { if NSApp.modalWindow == nil { panel.orderOut(nil) } }
    func dismissAndRestoreFocus() {
        // Escape/hotkey cancellation restores the app that owned focus on opening.
        // Click-away and resign-key dismissal intentionally do not call this helper:
        // the user's newly chosen app must retain focus.
        let destination = pasteDestination
        pasteAttempt = UUID()
        panel.orderOut(nil)
        destination?.restore()
        let attempt = pasteAttempt
        restoreAfterDismiss(destination, attempt: attempt, remaining: 12)
    }
    func restoreAfterDismiss(_ target: PasteDestination?, attempt: UUID, remaining: Int) {
        guard let target, target.geminiMiniTitle != nil, attempt == pasteAttempt, remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, attempt == self.pasteAttempt, !self.panel.isVisible else { return }
            target.prepareForPaste()
            if !target.isReady() { self.restoreAfterDismiss(target, attempt: attempt, remaining: remaining - 1) }
        }
    }
    func rememberDestination(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previous = app
    }
    @objc func toggle() {
        pasteAttempt = UUID()
        store.directPasteAllowed = AXIsProcessTrusted()
        if panel.isVisible { dismissAndRestoreFocus(); return }
        rememberDestination(NSWorkspace.shared.frontmostApplication)
        pasteDestination = PasteDestination.capture(fallback: previous)
        store.capture()
        store.resetBrowser()
        fitWindow(center: true, usePreferred: true); panel.makeKeyAndOrderFront(nil)
    }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { toggle() }
    }
    func showMenu() {
        let menu = NSMenu()
        func action(_ parent: NSMenu, _ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
            let item = parent.addItem(withTitle: title, action: selector, keyEquivalent: key)
            item.target = self
            return item
        }
        func submenu(_ title: String) -> NSMenu {
            let child = NSMenu(title: title)
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.submenu = child
            return child
        }
        // Frequent actions stay directly accessible.
        _ = action(menu, "\(panel.isVisible ? "Hide" : "Open") G-Clip (\(hotkeyLabel))", #selector(toggle))
        _ = action(menu, store.paused ? "Resume capture" : "Pause capture", #selector(pause))
        menu.addItem(.separator())

        let themes = submenu("Theme")
        for name in ["System", "Light", "Dark"] {
            let item = action(themes, name, #selector(setTheme(_:)))
            item.representedObject = name
            item.state = store.theme == name ? .on : .off
        }
        let fontMenu = submenu("Font size")
        let control = NSMenuItem(); control.view = MenuTypographyView(store: store)
        fontMenu.addItem(control)
        let display = action(menu, "Always open on main display", #selector(toggleMainDisplay))
        display.state = alwaysOpenOnMainDisplay ? .on : .off
        display.toolTip = "Open on the main display configured in macOS. Turn off to use the display under the pointer."
        menu.addItem(.separator())

        let shortcuts = submenu("Keyboard shortcut")
        let primary = action(shortcuts, "⌥⌘Space", #selector(commandShortcut))
        primary.state = hotkey != nil && hotkeyLabel == "⌥⌘Space" ? .on : .off
        let alternate = action(shortcuts, "⌃⌥Space", #selector(alternateShortcut))
        alternate.state = hotkey != nil && hotkeyLabel == "⌃⌥Space" ? .on : .off
        let login = action(menu, SMAppService.mainApp.status == .requiresApproval ? "Launch at login — approval needed…" : "Launch at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let directPaste = action(menu, "Open Accessibility Settings…", #selector(accessibility))
        directPaste.toolTip = "Opens macOS permission settings. Allow G-Clip there to paste automatically into your previous app."
        menu.addItem(.separator())
        _ = action(menu, "Quit G-Clip", #selector(quit), key: "q")
        status.menu = menu; status.button?.performClick(nil); status.menu = nil
    }
    @objc func toggleMainDisplay() {
        alwaysOpenOnMainDisplay.toggle()
        if panel.isVisible { fitWindow(center: true, usePreferred: true) }
    }
    @objc func setTheme(_ sender: NSMenuItem) { store.theme = sender.representedObject as! String; UserDefaults.standard.set(store.theme, forKey: "theme") }
    func configureLogin() {
        // Preview/test launches never register a login item. Respect a later user opt-out.
        guard UserDefaults.standard.object(forKey: "launchAtLoginRequested") == nil else { return }
        enableLogin()
    }
    func enableLogin() {
        do {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            UserDefaults.standard.set(true, forKey: "launchAtLoginRequested")
            if SMAppService.mainApp.status == .requiresApproval { store.message = "Allow G-Clip in System Settings → General → Login Items." }
        } catch { store.message = "Launch at login could not be enabled: \(error.localizedDescription). Retry from the menu bar." }
    }
    @objc func toggleLogin() {
        if CommandLine.arguments.contains("--preview") { store.message = "Launch at login is disabled in preview mode."; return }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
        if SMAppService.mainApp.status == .enabled {
            do { try SMAppService.mainApp.unregister(); UserDefaults.standard.set(false, forKey: "launchAtLoginRequested") }
            catch { store.message = "Could not disable launch at login: \(error.localizedDescription)" }
        } else { enableLogin() }
    }
    @objc func pause() { store.paused.toggle() }
    func applicationWillTerminate(_ notification: Notification) { store.flushPersistence() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func accessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @objc func commandShortcut() { registerShortcut(alternate: false) }
    @objc func alternateShortcut() { registerShortcut(alternate: true) }
    func installHotkey() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return noErr }
            Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue().toggle(); return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), nil)
        registerShortcut(alternate: UserDefaults.standard.bool(forKey: "alternateShortcutV2"))
    }
    func registerShortcut(alternate: Bool) {
        if let hotkey { UnregisterEventHotKey(hotkey) }; hotkey = nil
        let code = RegisterEventHotKey(UInt32(kVK_Space), UInt32(alternate ? controlKey | optionKey : cmdKey | optionKey), EventHotKeyID(signature: 0x47434c50, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        if code != noErr {
            if !alternate { registerShortcut(alternate: true); store.message = "⌥⌘Space is occupied. Using ⌃⌥Space; release ⌥⌘Space in the other app or macOS keyboard settings to switch." }
            else { store.message = "Shortcut unavailable. Open G-Clip from the menu bar." }
        } else { hotkeyLabel = alternate ? "⌃⌥Space" : "⌥⌘Space"; UserDefaults.standard.set(alternate, forKey: "alternateShortcutV2") }
    }
    func paste(_ item: Clip, rich: Bool) {
        guard store.copy(item, rich: rich) else { return }
        let target = pasteDestination
        panel.orderOut(nil)
        store.directPasteAllowed = AXIsProcessTrusted()
        guard store.directPasteAllowed else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Allow G-Clip to paste into other apps"
            alert.informativeText = "The item was copied, but macOS Accessibility permission is required for automatic paste. Enable the installed G-Clip in System Settings → Privacy & Security → Accessibility. If you replaced the app, remove its old entry and add the installed copy again if necessary."
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Paste manually")
            if alert.runModal() == .alertFirstButtonReturn { accessibility() }
            else { target?.restore() }
            return
        }
        guard let target, target.app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !target.app.isTerminated else {
            pasteFallback("No destination app found. Focus a text field in another app, then open G-Clip again."); return
        }
        pasteAttempt = UUID()
        let attempt = pasteAttempt, expectedChange = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.pasteAttempt == attempt else { return }
            target.restore()
            self.waitForDestination(target, deadline: Date().addingTimeInterval(2), expectedChange: expectedChange, attempt: attempt)
        }
    }
    func pasteFallback(_ reason: String) {
        store.message = reason
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
    }
    func waitForDestination(_ target: PasteDestination, deadline: Date, expectedChange: Int, attempt: UUID, readyOnce: Bool = false, poll: Int = 0) {
        guard attempt == pasteAttempt else { return }
        guard NSPasteboard.general.changeCount == expectedChange else {
            pasteFallback("Clipboard changed before paste. Select the item again."); return
        }
        if Date() < deadline { target.prepareForPaste() }
        let destinationReady = target.isReady()
        let modifiersReleased = PasteReadiness.modifiersReleased(CGEventSource.flagsState(.combinedSessionState))
        let ready = destinationReady && modifiersReleased
        // Retry normal windows sparingly: activating an app can complete asynchronously.
        // Gemini has its own toggle-aware restoration path above.
        if !destinationReady && target.geminiMiniTitle == nil && [5, 12, 20].contains(poll) && Date() < deadline {
            target.restore()
        }
        if ready && readyOnce {
            let source = CGEventSource(stateID: .privateState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                pasteFallback("Copied, but the paste shortcut could not be sent. Press ⌘V in the destination."); return
            }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.postToPid(target.app.processIdentifier); up.postToPid(target.app.processIdentifier)
            return
        }
        guard Date() < deadline, !target.app.isTerminated else {
            pasteFallback(destinationReady && !modifiersReleased
                ? "Copied, but a shortcut key was still held. Release the keys and try again, or press ⌘V in the destination."
                : "Copied, but the original input field could not regain focus. Click it and press ⌘V."); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.waitForDestination(target, deadline: deadline, expectedChange: expectedChange, attempt: attempt, readyOnce: ready, poll: poll + 1)
        }
    }
}

if CommandLine.arguments.contains("--self-test") {
    ClipboardIOTests.run()
    for key: UInt16 in [123, 124, 125, 126] {
        for flags: NSEvent.ModifierFlags in [.command, .option, .shift, [.command, .shift], [.option, .shift], .control] {
            assert(!BrowsingKeys.handles(key, modifiers: flags, query: ""))
        }
    }
    assert(!BrowsingKeys.handles(124, modifiers: [], query: "search text"))
    assert(BrowsingKeys.handles(124, modifiers: [], query: ""))
    for key: UInt16 in [36, 76, 48] {
        assert(BrowsingKeys.handles(key, modifiers: [], query: "text"))
        assert(BrowsingKeys.handles(key, modifiers: .shift, query: "text"))
        assert(!BrowsingKeys.handles(key, modifiers: .command, query: "text"))
    }
    print("Passed: browsing shortcuts preserve modified arrows, search caret movement and standard modifier combinations.")
    let annotationEditor = AnnotationTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    annotationEditor.allowsUndo = true
    annotationEditor.undoManager?.beginUndoGrouping()
    annotationEditor.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
    annotationEditor.undoManager?.endUndoGrouping()
    assert(annotationEditor.string == "hello")
    annotationEditor.undoManager?.undo()
    assert(annotationEditor.string.isEmpty)
    annotationEditor.undoManager?.redo()
    assert(annotationEditor.string == "hello")
    print("Passed: annotation text Undo/Redo restores typed content.")
    let wrapScroll = WrappingTextScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
    let wrapText = MatchingStyleTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 250))
    wrapText.isHorizontallyResizable = false
    wrapText.isVerticallyResizable = true
    wrapText.textContainerInset = NSSize(width: 14, height: 14)
    wrapText.textContainer?.widthTracksTextView = true
    wrapScroll.documentView = wrapText
    wrapScroll.minMagnification = 0.85; wrapScroll.maxMagnification = 1.8
    for sample in [String(repeating: "Long clipboard text ", count: 100), String(repeating: "abcdefghij", count: 200)] {
        wrapText.textStorage?.setAttributedString(NSAttributedString(string: sample, attributes: [.font: NSFont.systemFont(ofSize: 15)]))
        for width: CGFloat in [300, 700, 220] {
            wrapScroll.setFrameSize(NSSize(width: width, height: 250))
            for scale: CGFloat in [1, 1.8, 0.85] {
                wrapScroll.magnification = scale
                wrapScroll.layoutSubtreeIfNeeded()
                wrapScroll.fitTextToViewport()
                let container = wrapText.textContainer!
                let manager = wrapText.layoutManager!
                manager.ensureLayout(for: container)
                assert(abs(wrapText.frame.width - wrapScroll.contentView.bounds.width) < 1)
                assert(manager.usedRect(for: container).height > 30, "Long text must wrap")
                assert(manager.usedRect(for: container).width <= container.containerSize.width + 1)
                assert(wrapText.string == sample, "Wrapping must not insert line breaks")
            }
        }
    }
    print("Passed: long spaced and unbroken text wraps at changing pane widths and text scales.")
    let displayFrames = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: 0, width: 1920, height: 1080)]
    assert(WindowLayout.openingScreenIndex(frames: displayFrames, pointer: CGPoint(x: -500, y: 400), preferPrimary: true) == 0)
    assert(WindowLayout.openingScreenIndex(frames: displayFrames, pointer: CGPoint(x: -500, y: 400), preferPrimary: false) == 1)
    assert(WindowLayout.openingScreenIndex(frames: displayFrames, pointer: CGPoint(x: 9000, y: 0), preferPrimary: false) == 0)
    assert(WindowLayout.openingScreenIndex(frames: [], pointer: .zero, preferPrimary: true) == nil)
    let largeDisplay = CGRect(x: 0, y: 0, width: 2560, height: 1400)
    assert(WindowLayout.size(in: largeDisplay, preferred: nil) == CGSize(width: 1500, height: 890))
    let laptop = CGRect(x: 0, y: 40, width: 1440, height: 820)
    let raisedFrame = WindowLayout.frame(in: largeDisplay, preferred: nil)
    assert(raisedFrame.midY > WindowLayout.area(largeDisplay).midY)
    assert(raisedFrame.midX == WindowLayout.area(largeDisplay).midX)
    let manualOrigin = CGPoint(x: 100, y: 120)
    assert(WindowLayout.frame(in: largeDisplay, preferred: nil, origin: manualOrigin).origin == manualOrigin)
    let laptopFrame = WindowLayout.frame(in: laptop, preferred: nil)
    assert(laptop.contains(laptopFrame) && laptopFrame.width < 1500 && laptopFrame.height < 890)
    let tinyDisplay = CGRect(x: -800, y: 30, width: 800, height: 500)
    assert(tinyDisplay.contains(WindowLayout.frame(in: tinyDisplay, preferred: CGSize(width: 1600, height: 1000))))
    let custom = CGSize(width: 1300, height: 800)
    assert(WindowLayout.size(in: largeDisplay, preferred: custom) == custom)
    assert(WindowLayout.valid(CGSize(width: Double.nan, height: 500)) == nil)
    assert(WindowLayout.valid(CGSize(width: -2, height: 500)) == nil)
    assert(laptop.contains(WindowLayout.frame(in: laptop, preferred: custom, origin: CGPoint(x: -5000, y: 8000))))
    print("Passed: screen-relative sizing, larger cap, saved custom size, small-screen clamping and offscreen recovery.")
    assert(GeminiMiniChatPolicy.isMini(bundleID: "com.google.GeminiMacOS", title: "Gemini Mini Chat — New chat"))
    assert(!GeminiMiniChatPolicy.isMini(bundleID: "com.google.GeminiMacOS", title: "Gemini — New chat"))
    assert(!GeminiMiniChatPolicy.isMini(bundleID: "another.app", title: "Gemini Mini Chat — New chat"))
    assert(GeminiMiniChatPolicy.isOpenButton(identifier: "collapse_button", description: nil))
    assert(!GeminiMiniChatPolicy.isOpenButton(identifier: nil, description: "Open full app"))
    assert(PasteReadiness.needsActivation(expected: 42, focused: 99))
    assert(PasteReadiness.needsActivation(expected: 42, focused: nil))
    // A floating panel can own keyboard focus while another app appears frontmost.
    assert(!PasteReadiness.needsActivation(expected: 42, focused: 42))
    assert(PasteReadiness.matchesProcess(expected: 42, focused: 42, frontmost: 99, capturedElement: true))
    assert(!PasteReadiness.matchesProcess(expected: 42, focused: 99, frontmost: 42, capturedElement: true))
    assert(!PasteReadiness.matchesProcess(expected: 42, focused: nil, frontmost: 42, capturedElement: true))
    assert(PasteReadiness.matchesProcess(expected: 42, focused: nil, frontmost: 42, capturedElement: false))
    assert(PasteReadiness.modifiersReleased([]))
    assert(!PasteReadiness.modifiersReleased([.maskAlternate, .maskCommand]))
    print("Passed: floating-panel keyboard recipient and paste-modifier guards.")
    let ageNow = Date(timeIntervalSince1970: 1000000)
    for (seconds, expected) in [(0.0, "Just now"), (59, "Just now"), (60, "1 min ago"), (3599, "59 min ago"), (3600, "1 hr ago"), (86400, "1 day ago"), (172800, "2 days ago")] {
        assert(ClipAge.label(since: ageNow.addingTimeInterval(-seconds), now: ageNow) == expected)
    }
    assert(SplitLayout.listWidth(total: 1200, ratio: 0.5) == 570)
    assert(SplitLayout.listWidth(total: 980, ratio: 0.9) == 350)
    assert(SplitLayout.listWidth(total: 980, ratio: 0.1) == 260)
    assert(ClearCommand.parse("/clear") == .all)
    assert(ClearCommand.parse("/clear 1d") == .recent(86400))
    assert(ClearCommand.parse("/clear 2h") == .recent(7200))
    assert(ClearCommand.parse("/clear 30m") == .recent(1800))
    for bad in ["/clear 0d", "/clear -1d", "/clear 1x", "/clear 1d extra", "/clear nand", "/clear infd"] { assert(ClearCommand.parse(bad) == .invalid) }
    let styled = NSAttributedString(string: "Styled text", attributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.red])
    let styledRTF = try! styled.data(from: NSRange(location: 0, length: styled.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let styledClip = Clip(text: styled.string, source: "Test", data: [NSPasteboard.PasteboardType.rtf.rawValue: styledRTF])
    assert(styledClip.plainPreview.string == styled.string)
    assert((styledClip.plainPreview.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == 15)
    assert((styledClip.attributed.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == 24)
    assert(styledClip.data[NSPasteboard.PasteboardType.rtf.rawValue] == styledRTF)
    let a = Clip(text: "hello", source: "Test", data: ["public.utf8-plain-text": Data("hello".utf8)])
    let b = Clip(text: "hello", source: "Other", data: a.data)
    assert(a.fingerprint == b.fingerprint)
    assert(try! JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(a)).text == "hello")
    assert(ClearCommand.isCommand("/clear 1d"))
    assert(!ClearCommand.isCommand("/developer"))
    assert(!ClearCommand.isCommand("/clearance"))
    let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("gclip-tests-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    let brokenFile = testDirectory.appendingPathComponent("history.json")
    let brokenData = Data("invalid json original history".utf8)
    try! brokenData.write(to: brokenFile)
    let brokenStore = Store(directory: testDirectory)
    assert(brokenStore.persistenceBlocked)
    brokenStore.insert(a); brokenStore.flushPersistence()
    assert(try! Data(contentsOf: brokenFile) == brokenData)
    let cleanDirectory = testDirectory.appendingPathComponent("clean")
    let cleanStore = Store(directory: cleanDirectory)
    cleanStore.insert(a); cleanStore.insert(b)
    let syntheticImage = Clip(text: "", source: "Safari", data: [NSPasteboard.PasteboardType.png.rawValue: Data([0])])
    assert(ClipFilter.all.advanced() == .text)
    assert(ClipFilter.text.advanced() == .images)
    assert(ClipFilter.images.advanced() == .all)
    assert(ClipFilter.all.advanced(backward: true) == .images)
    assert(ClipFilter.images.matches(syntheticImage, query: "safari"))
    assert(!ClipFilter.images.matches(syntheticImage, query: "Notes"))
    assert(!ClipFilter.text.matches(syntheticImage, query: ""))
    assert(!ClipFilter.images.matches(a, query: ""))
    assert(ClipFilter.text.matches(a, query: "HELLO"))
    cleanStore.query = "hello"; cleanStore.cycleFilter()
    assert(cleanStore.filter == .text && cleanStore.query == "hello" && cleanStore.current?.id == b.id)
    cleanStore.cycleFilter(); assert(cleanStore.current == nil && cleanStore.selected == nil)
    cleanStore.resetBrowser(); assert(cleanStore.filter == .all && cleanStore.query.isEmpty && cleanStore.current?.id == b.id)
    assert(cleanStore.clips.count == 1)
    var editedCopy = b; editedCopy.id = UUID(); editedCopy.text = "Edited"; editedCopy.data = ["public.utf8-plain-text": Data("Edited".utf8)]
    cleanStore.insert(editedCopy, deduplicate: false)
    assert(cleanStore.clips.count == 2 && cleanStore.clips.first?.id == editedCopy.id)
    assert(cleanStore.clips.contains { $0.id == b.id && $0.text == "hello" })
    cleanStore.removeHistory(ids: [editedCopy.id])
    cleanStore.edit(b)
    cleanStore.select(b)
    assert(cleanStore.editing == nil && cleanStore.current?.id == b.id)
    cleanStore.edit(b)
    cleanStore.removeHistory(ids: [b.id])
    assert(cleanStore.editing == nil && cleanStore.draft.length == 0 && cleanStore.imageDraft.image == nil)
    cleanStore.flushPersistence()
    assert(try! JSONDecoder().decode([Clip].self, from: Data(contentsOf: cleanStore.historyURL)).isEmpty)
    try! FileManager.default.removeItem(at: testDirectory)
    print("Passed: failed-load preservation, deduplication, editor invalidation, ordered persistence and slash searches.")
    testImageEditing()
    print("Passed: clear command boundaries, content identity, persistence round-trip.")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
