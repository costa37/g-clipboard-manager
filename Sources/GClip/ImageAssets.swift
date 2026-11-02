import AppKit
import ImageIO

// Clips are immutable: edited content is assigned a new UUID before insertion.
// Keep list thumbnails separate so browsing never decodes every full-resolution image.
final class ImageAssets {
    static let shared = ImageAssets()
    private let full = NSCache<NSString, CGImage>()
    private let thumbnails = NSCache<NSString, CGImage>()
    let queue = DispatchQueue(label: "local.gclip.image-preview", qos: .userInitiated)
    init() { full.totalCostLimit = 96 * 1024 * 1024; full.countLimit = 12; thumbnails.totalCostLimit = 16 * 1024 * 1024 }
    func image(_ clip: Clip, thumbnail: Bool = false) -> CGImage? {
        let cache = thumbnail ? thumbnails : full, key = clip.id.uuidString as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let data = clip.data[NSPasteboard.PasteboardType.png.rawValue] ?? clip.data[NSPasteboard.PasteboardType.tiff.rawValue],
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let image: CGImage?
        if thumbnail {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else { image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) }
        if let image { cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height) }
        return image
    }
    func invalidate(_ id: UUID) { full.removeObject(forKey: id.uuidString as NSString); thumbnails.removeObject(forKey: id.uuidString as NSString) }
}

// Selection owns the request, not SwiftUI appearance callbacks. A late completion
// can never replace a newer selection, even if the old image took longer to decode.
final class ImagePreview: ObservableObject {
    let draft: ImageDraft
    init(draft: ImageDraft = ImageDraft()) { self.draft = draft }
    private(set) var clipID: UUID?
    private var request = UUID()
    private var task: DispatchWorkItem?
    func select(_ clip: Clip?) {
        task?.cancel(); request = UUID(); clipID = clip?.isImage == true ? clip?.id : nil
        draft.loadImage(nil)
        guard let clip, clip.isImage else { return }
        draft.loading = true
        let token = request
        let task = DispatchWorkItem { [weak self] in
            let image = ImageAssets.shared.image(clip)
            DispatchQueue.main.async { [weak self] in self?.complete(image, request: token, clipID: clip.id) }
        }
        self.task = task; ImageAssets.shared.queue.async(execute: task)
    }
    @discardableResult func complete(_ image: CGImage?, request token: UUID, clipID: UUID) -> Bool {
        guard request == token, self.clipID == clipID else { return false }
        draft.loadImage(image); draft.loading = false
        if image == nil { draft.error = "This image could not be decoded." }
        return true
    }
    // Expose a token for deterministic out-of-order completion regression tests.
    var requestToken: UUID { request }
    deinit { task?.cancel() }
}
