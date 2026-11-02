import AppKit

func testImageEditing() {
    // A non-square asymmetric fixture catches vertical flips and point/pixel mistakes.
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<80 { for x in 0..<120 { bitmap.setColor(NSColor(deviceRed: y < 40 ? 1 : 0, green: 0, blue: y < 40 ? 0 : 1, alpha: 1), atX: x, y: y) } }
    let source = bitmap.cgImage!
    func color(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor { NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)! }
    let rendered = ImageRenderer.render(source)!
    assert(rendered.width == 120 && rendered.height == 80)
    assert(color(rendered, 10, 10).redComponent > 0.9, "Render flipped the top of the image")
    assert(color(rendered, 10, 70).blueComponent > 0.9, "Render flipped the bottom of the image")
    let crop = ImageRenderer.crop(source, to: CGRect(x: 10, y: 0, width: 40, height: 20))!
    assert(crop.width == 40 && crop.height == 20 && color(crop, 1, 1).redComponent > 0.9)
    let bottom = ImageRenderer.crop(source, to: CGRect(x: 10, y: 60, width: 40, height: 20))!
    assert(color(bottom, 1, 1).blueComponent > 0.9)
    assert(ImageRenderer.crop(source, to: CGRect(x: 200, y: 100, width: 5, height: 5)) == nil)
    let edge = ImageRenderer.crop(source, to: CGRect(x: -10, y: -10, width: 30, height: 30))!
    assert(edge.width == 20 && edge.height == 20)
    let mark = ImageMark(tool: .rectangle, start: CGPoint(x: 20, y: 10), end: CGPoint(x: 70, y: 30), color: .white, width: 4, text: "", fontSize: 18)
    let annotated = ImageRenderer.render(source, mark: mark)!
    assert(color(annotated, 20, 20).greenComponent > 0.9, "Rectangle missing from exported pixels")
    assert(color(annotated, 45, 20).greenComponent < 0.1, "Rectangle should be an outline")
    var arrow = mark; arrow.tool = .arrow; arrow.start = CGPoint(x: 10, y: 60); arrow.end = CGPoint(x: 90, y: 60)
    let pointed = ImageRenderer.render(source, mark: arrow)!
    assert(color(pointed, 40, 60).redComponent > 0.9, "Arrow missing from export")
    var text = mark; text.tool = .text; text.text = "Test"; text.start = CGPoint(x: 10, y: 42); text.end = CGPoint(x: 110, y: 80)
    let labeled = ImageRenderer.render(source, mark: text)!
    var whitePixels = 0
    for y in 42..<80 { for x in 10..<110 { if color(labeled, x, y).redComponent > 0.8 { whitePixels += 1 } } }
    assert(whitePixels > 10, "Text missing from export")
    let draft = ImageDraft(); draft.load(NSImage(cgImage: source, size: NSSize(width: 60, height: 40)))
    assert(draft.image!.width == 120, "Retina source pixels must be preserved")
    draft.apply(mark); draft.undo()
    assert(draft.image!.width == 120 && color(draft.image!, 20, 20).greenComponent < 0.1)
    var cut = mark; cut.tool = .crop
    draft.apply(cut); assert(draft.image!.width == 50 && draft.image!.height == 20)
    draft.reset(); assert(draft.image!.width == 120 && draft.image!.height == 80)
    // Objects remain editable until export. Moves and deletion must not burn marks into pixels.
    draft.load(NSImage(cgImage: source, size: NSSize(width: 120, height: 80)))
    draft.apply(mark)
    assert(draft.marks.count == 1 && color(draft.image!, 20, 20).greenComponent < 0.1)
    assert(color(draft.export()!, 20, 20).greenComponent > 0.9)
    draft.checkpoint(); draft.update(mark.translated(by: CGPoint(x: 30, y: 30)))
    assert(color(draft.export()!, 20, 20).greenComponent < 0.1)
    assert(color(draft.export()!, 50, 50).greenComponent > 0.9)
    draft.deleteSelected(); assert(draft.marks.isEmpty)
    draft.undo(); assert(draft.marks.count == 1 && draft.marks[0].start == CGPoint(x: 50, y: 40))
    draft.undo(); assert(draft.marks[0].start == mark.start)
    draft.tool = .text; draft.ink = .yellow; draft.setZoom(4)
    draft.load(NSImage(cgImage: source, size: NSSize(width: 120, height: 80)))
    assert(draft.tool == .text && draft.ink == .yellow && draft.zoom == 1 && draft.marks.isEmpty)
    // Text changes export live, preserving original pixels and excluding editor controls.
    draft.apply(text); var changed = text; changed.text = "Updated"; draft.update(changed)
    assert(draft.marks[0].text == "Updated")
    draft.selected = text.id; draft.deleteSelected(); assert(draft.marks.isEmpty)
    assert(color(draft.export()!, 10, 10).redComponent > 0.9)
    // Crop translates editable objects and undo restores their source-image positions.
    draft.apply(mark); draft.apply(cut)
    assert(draft.marks.count == 1 && draft.marks[0].start == .zero)
    draft.undo(); assert(draft.image!.width == 120 && draft.marks[0].start == mark.start)
    let canvasBounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    for factor: CGFloat in [1, 2, 4, 6] {
        let controls = AnnotationControls.rects(start: CGPoint(x: 200, y: 700), end: CGPoint(x: 200 + 30 * factor, y: 700 - 30 * factor), bounds: canvasBounds)
        assert(controls.delete.size == CGSize(width: 22, height: 22))
        assert(controls.delete.maxX < 200 && controls.move.minY > 700)
        assert(!controls.delete.intersects(controls.move))
    }
    for end in [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 10), CGPoint(x: 10, y: 70), CGPoint(x: 100, y: 70)] {
        var directional = arrow; directional.start = CGPoint(x: 60, y: 40); directional.end = end
        assert(directional.hit(end, tolerance: 3))
        let output = ImageRenderer.render(source, mark: directional)!
        assert(color(output, Int(end.x), Int(end.y)).greenComponent > 0.5, "Arrow tip must follow drag endpoint")
    }
    assert(mark.hit(CGPoint(x: 20, y: 20), tolerance: 3))
    assert(!mark.hit(CGPoint(x: 45, y: 20), tolerance: 3), "Rectangle interior must allow drawing another mark")
    print("Passed: movable objects, deletion/undo, live text, crop object coordinates, sticky tools, fixed-size tail controls and all arrow directions.")
    // Reproduce rapid A→B→A selection and completions delivered in the wrong order.
    let preview = ImagePreview()
    let clipA = Clip(text: "", source: "Test A", data: [NSPasteboard.PasteboardType.png.rawValue: ImageRenderer.png(source)!])
    let clipB = Clip(text: "", source: "Test B", data: [NSPasteboard.PasteboardType.png.rawValue: ImageRenderer.png(bottom)!])
    preview.select(clipA); let requestA = preview.requestToken
    preview.select(clipB); let requestB = preview.requestToken
    assert(preview.draft.image == nil && preview.draft.loading, "Selection must clear the old image immediately")
    assert(!preview.complete(source, request: requestA, clipID: clipA.id))
    assert(preview.complete(bottom, request: requestB, clipID: clipB.id))
    assert(preview.draft.image!.width == bottom.width && !preview.draft.loading)
    preview.select(clipA); let latestA = preview.requestToken
    assert(!preview.complete(source, request: requestA, clipID: clipA.id), "Old request for the same clip must also be ignored")
    assert(preview.complete(source, request: latestA, clipID: clipA.id))
    preview.select(nil)
    assert(!preview.complete(source, request: latestA, clipID: clipA.id) && preview.draft.image == nil)
    let thumb = ImageAssets.shared.image(clipA, thumbnail: true)!
    assert(max(thumb.width, thumb.height) <= 96)
    let cached = ImageAssets.shared.image(clipA)!
    assert(cached === ImageAssets.shared.image(clipA)!)
    assert(cached.width == 120 && cached.height == 80, "Thumbnails must not replace source pixels")
    print("Passed: stale preview completion rejection, immediate clearing, same-clip request ordering, thumbnail sizing and full-resolution caching.")
    let png = ImageRenderer.png(annotated)!
    let decoded = NSBitmapImageRep(data: png)!
    assert(decoded.pixelsWide == 120 && decoded.pixelsHigh == 80)
    print("Passed: image orientation, pixel preservation, crop bounds, rectangle/arrow/text export, undo/reset and PNG round-trip.")
}
