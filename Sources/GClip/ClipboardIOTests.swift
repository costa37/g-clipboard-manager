import AppKit

private final class ReplacingClipboardProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString("stale generation", forType: type)
        pasteboard?.clearContents()
        pasteboard?.setString("new generation", forType: .string)
    }
}

enum ClipboardIOTests {
    static func run() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = Store(directory: directory)
        defer { store.flushPersistence(); try? FileManager.default.removeItem(at: directory) }
        store.change = -1
        board.clearContents()
        board.declareTypes([.string], owner: nil)
        let pending = board.changeCount
        store.capture(board: board, sourceApp: nil)
        precondition(store.clips.isEmpty && store.change != pending, "Unavailable data must remain retryable")
        board.setString("Delayed text", forType: .string)
        store.capture(board: board, sourceApp: nil)
        precondition(store.clips.first?.text == "Delayed text")
        store.capture(board: board, sourceApp: nil)
        precondition(store.clips.count == 1, "Unchanged board must not duplicate history")
        board.clearContents(); board.setString("Second text", forType: .string)
        store.capture(board: board, sourceApp: nil)
        precondition(store.clips.count == 2 && store.clips.first?.text == "Second text")
        board.clearContents(); board.setString("secret", forType: .string)
        board.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        store.capture(board: board, sourceApp: nil)
        precondition(store.clips.count == 2, "Concealed content must remain excluded")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!
        board.clearContents(); board.setData(png, forType: .png)
        board.setData(Data(repeating: 0, count: ClipboardIO.limit + 1), forType: .tiff)
        store.capture(board: board, sourceApp: nil)
        precondition(store.clips.first?.isImage == true, "Redundant TIFF must not reject valid PNG")
        precondition(store.clips.first?.data.count == 1)
        let image = store.clips.first!
        board.clearContents(); board.declareTypes([.png, .string], owner: nil)
        board.setString("image description", forType: .string)
        let beforePendingImage = store.clips.count
        store.capture(board: board, sourceApp: nil)
        precondition(store.clips.count == beforePendingImage)
        board.setData(png, forType: .png)
        store.capture(board: board, sourceApp: nil)
        precondition(store.clips.first?.isImage == true)
        board.clearContents(); board.setData(bitmap.representation(using: .jpeg, properties: [:])!, forType: .init("public.jpeg"))
        store.capture(board: board, sourceApp: nil)
        precondition(store.clips.first?.isImage == true && store.clips.first?.image != nil)
        board.clearContents(); board.setString("https://example.com/", forType: .URL)
        store.capture(board: board, sourceApp: nil)
        precondition(store.clips.first?.text == "https://example.com/")
        precondition(ClipboardIO.write(image, rich: false, to: board))
        precondition(board.data(forType: .png) == png)
        let provider = ReplacingClipboardProvider()
        let lazy = NSPasteboardItem()
        lazy.setDataProvider(provider, forTypes: [.string])
        board.clearContents(); board.writeObjects([lazy])
        let beforeRace = store.clips.count
        store.capture(board: board, sourceApp: nil)
        precondition(store.clips.count == beforeRace, "A changed clipboard generation must not enter history")
        store.capture(board: board, sourceApp: nil)
        precondition(store.clips.first?.text == "new generation")
        let rich = NSAttributedString(string: "Formatted", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        let rtf = try! rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.clearContents(); board.setData(rtf, forType: .rtf)
        store.capture(board: board, sourceApp: nil)
        let text = store.clips.first!
        precondition(text.text == "Formatted")
        precondition(ClipboardIO.write(text, rich: false, to: board))
        precondition(board.string(forType: .string) == "Formatted" && board.data(forType: .rtf) == nil)
        precondition(ClipboardIO.write(text, rich: true, to: board))
        precondition(board.data(forType: .rtf) == rtf && board.string(forType: .string) == "Formatted")
        print("Passed: delayed capture retries, consecutive copies, deduplication, privacy markers, redundant image sizes, image and plain/rich writes.")
    }
}
