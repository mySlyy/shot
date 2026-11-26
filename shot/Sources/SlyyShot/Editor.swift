import AppKit
import CoreImage
import UniformTypeIdentifiers

// Simple annotation editor: one window per image. Marks are kept as vectors
// (undoable) and flattened into the PNG on save/copy.

enum Tool: Int, CaseIterable {
    case move, arrow, rect, ellipse, highlight, text, number, pixelate, blur, crop

    private var info: (title: String, symbol: String, key: String) {
        switch self {
        case .move: return ("Move (V)", "hand.point.up.left", "v")
        case .arrow: return ("Arrow (A)", "arrow.up.right", "a")
        case .rect: return ("Box (R)", "rectangle", "r")
        case .ellipse: return ("Ellipse (O)", "circle", "o")
        case .highlight: return ("Highlight (H)", "highlighter", "h")
        case .text: return ("Text (T)", "textformat", "t")
        case .number: return ("Number (N)", "number", "n")
        case .pixelate: return ("Pixelate (X)", "square.grid.3x3.fill", "x")
        case .blur: return ("Blur (B)", "drop.halffull", "b")
        case .crop: return ("Crop (C)", "crop", "c")
        }
    }

    var title: String { info.title }
    var symbol: String { info.symbol }
    var key: String { info.key }
}

struct Mark {
    enum Kind {
        case arrow(CGPoint, CGPoint)
        case rect(CGRect)
        case ellipse(CGRect)
        case highlight(CGRect)
        case text(CGPoint, String)
        /// Numbered badge (Number tool): center, number shown.
        case number(CGPoint, Int)
        case pixelate(CGRect)
        case blur(CGRect)
    }

    var kind: Kind
    var color: NSColor
    /// Thin/Medium/Thick step (2/4/8); the popup shows it. Drawn sizes are width × scale.
    var width: CGFloat
    /// Image resizes (⇧⌘R) shrink/grow marks with the shot; new marks start at 1.
    var scale: CGFloat = 1

    /// Stroke width as drawn.
    var lineWidth: CGFloat { width * scale }
    /// Text and number font size as drawn.
    var fontSize: CGFloat { EditorCanvas.fontSize(width) * scale }

    /// The mark after resizing the shot by `s`: geometry and drawn sizes multiplied.
    func scaled(by s: CGFloat) -> Mark {
        func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * s, y: q.y * s) }
        func r(_ q: CGRect) -> CGRect { CGRect(x: q.minX * s, y: q.minY * s, width: q.width * s, height: q.height * s) }
        var m = self
        m.scale *= s
        switch kind {
        case .arrow(let a, let b): m.kind = .arrow(p(a), p(b))
        case .rect(let q): m.kind = .rect(r(q))
        case .ellipse(let q): m.kind = .ellipse(r(q))
        case .highlight(let q): m.kind = .highlight(r(q))
        case .text(let q, let t): m.kind = .text(p(q), t)
        case .number(let q, let n): m.kind = .number(p(q), n)
        case .pixelate(let q): m.kind = .pixelate(r(q))
        case .blur(let q): m.kind = .blur(r(q))
        }
        return m
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Mark {
        func o(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        var m = self
        switch kind {
        case .arrow(let a, let b): m.kind = .arrow(o(a), o(b))
        case .rect(let r): m.kind = .rect(r.offsetBy(dx: dx, dy: dy))
        case .ellipse(let r): m.kind = .ellipse(r.offsetBy(dx: dx, dy: dy))
        case .highlight(let r): m.kind = .highlight(r.offsetBy(dx: dx, dy: dy))
        case .text(let p, let s): m.kind = .text(o(p), s)
        case .number(let p, let n): m.kind = .number(o(p), n)
        case .pixelate(let r): m.kind = .pixelate(r.offsetBy(dx: dx, dy: dy))
        case .blur(let r): m.kind = .blur(r.offsetBy(dx: dx, dy: dy))
        }
        return m
    }

    /// Whether a click at `p` grabs this mark (generous tolerance).
    func contains(_ p: CGPoint) -> Bool {
        let tol = max(6, lineWidth * 1.5)
        func nearSegment(_ a: CGPoint, _ b: CGPoint) -> Bool {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)) <= tol
        }
        switch kind {
        case .arrow(let a, let b): return nearSegment(a, b)
        case .rect(let r): // the outline, so shapes inside a box stay clickable
            return r.insetBy(dx: -tol, dy: -tol).contains(p) && !r.insetBy(dx: tol, dy: tol).contains(p)
        case .ellipse(let r):
            let rx = max(r.width / 2, 1), ry = max(r.height / 2, 1)
            let d = hypot((p.x - r.midX) / rx, (p.y - r.midY) / ry)
            return abs(d - 1) * min(rx, ry) <= tol
        case .highlight(let r), .pixelate(let r), .blur(let r):
            return r.insetBy(dx: -tol, dy: -tol).contains(p)
        case .text, .number:
            return bounds.insetBy(dx: -4, dy: -4).contains(p)
        }
    }

    var bounds: CGRect {
        switch kind {
        case .arrow(let a, let b): return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        case .rect(let r), .ellipse(let r), .highlight(let r), .pixelate(let r), .blur(let r): return r
        case .text(let at, let s):
            let size = (s as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: fontSize)])
            return CGRect(origin: at, size: size)
        case .number(let center, let n):
            return EditorCanvas.badge(n, at: center, size: fontSize).rect
        }
    }

    var isMeaningful: Bool {
        switch kind {
        case .arrow(let a, let b): return hypot(b.x - a.x, b.y - a.y) > 4
        case .rect(let r), .ellipse(let r), .highlight(let r), .pixelate(let r), .blur(let r): return r.width > 3 && r.height > 3
        case .text(_, let s): return !s.isEmpty
        case .number: return true
        }
    }
}

@MainActor
final class EditorCanvas: NSView, NSTextFieldDelegate {
    /// The shot; replaced by Resize Image (⇧⌘R).
    private(set) var image: NSImage
    private var pixelated: NSImage?
    /// Blurred copy of the whole shot, made on first use of the Blur tool (outer nil = not made yet).
    private var blurCache: NSImage??
    private var blurred: NSImage? {
        if let made = blurCache { return made }
        let b = Self.blur(image)
        blurCache = .some(b)
        return b
    }
    private(set) var marks: [Mark] = []
    private(set) var crop: CGRect? { didSet { onCropChange?() } }
    private(set) var changeCount = 0
    /// Undo states: marks, applied crop, and the shot (differs only across a resize).
    private var undoStack: [([Mark], CGRect?, NSImage)] = []
    private var draft: Mark?
    private var draftCrop: CGRect?
    private var start = CGPoint.zero

    /// Dragged crop selection big enough to use (Return not pressed yet); nil for a stray click.
    private var pendingCrop: CGRect? {
        guard let c = draftCrop, c.width > 4, c.height > 4 else { return nil }
        return c.integral
    }

    /// Area Copy exports: the pending selection (shown un-shaded) wins over the applied crop, so Copy
    /// takes what is on screen. Nothing is committed: no undo step, document stays unchanged.
    var copyArea: CGRect? { pendingCrop ?? crop }

    var tool: Tool = .arrow {
        didSet {
            onToolChange?(tool)
            if tool != .crop { draftCrop = nil; needsDisplay = true }
        }
    }
    private var moving: (index: Int, original: [Mark])?
    var color: NSColor = .systemRed { didSet { styleTextField() } }
    var lineWidth: CGFloat = 4 { didSet { styleTextField() } }
    var onChange: (() -> Void)?
    var onToolChange: ((Tool) -> Void)?
    /// Applied crop changed (set/undone): the stage moves its shadow.
    var onCropChange: (() -> Void)?
    /// Shot resized (or resize undone): the stage follows the canvas size.
    var onSizeChange: (() -> Void)?

    /// What is visible of the shot: the applied crop, else the whole image (view points).
    var visibleArea: CGRect { crop ?? bounds }

    init(image: NSImage) {
        self.image = image
        self.pixelated = Self.pixelate(image)
        super.init(frame: NSRect(origin: .zero, size: image.size))
        // Own layer: an applied crop clears the outside to transparent here, not in the stage below.
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        var visible = marks
        if let i = editingIndex, visible.indices.contains(i) { visible.remove(at: i) }
        render(draft.map { visible + [$0] } ?? visible)
        if let i = selected, i != editingIndex, marks.indices.contains(i) {
            let outline = NSBezierPath(rect: marks[i].bounds.insetBy(dx: -5, dy: -5))
            outline.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
        }
        if let c = draftCrop ?? crop {
            let shade = NSBezierPath(rect: bounds)
            shade.appendRect(c)
            shade.windingRule = .evenOdd
            guard draftCrop != nil else {
                // Applied crop: cut the outside away (transparent), so the cropped image floats on its own.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .copy
                NSColor.clear.setFill()
                shade.fill()
                NSGraphicsContext.restoreGraphicsState()
                return
            }
            // Pending selection: dim the outside, dashed border.
            NSColor.black.withAlphaComponent(0.55).setFill()
            shade.fill()
            let border = NSBezierPath(rect: c)
            border.lineWidth = 1
            NSColor.white.setStroke()
            border.setLineDash([5, 4], count: 2, phase: 0)
            border.stroke()
        }
    }

    /// The shot (always 100% opaque, on screen and in Copy/Save), then the marks.
    private func render(_ marks: [Mark]) {
        let full = NSRect(origin: .zero, size: image.size)
        image.draw(in: full)
        for m in marks { draw(m, in: full) }
    }

    nonisolated static func fontSize(_ width: CGFloat) -> CGFloat { 12 + width * 4 }

    /// Number badge geometry, shared by drawing and hit-testing: a circle for one digit, a pill for more.
    /// Size follows the text size (Mark.fontSize: Thin/Medium/Thick × scale); digits are monospaced and bold.
    nonisolated static func badge(_ n: Int, at center: CGPoint, size: CGFloat)
        -> (rect: CGRect, text: String, font: NSFont, textWidth: CGFloat, baseline: CGFloat) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size * 0.72, weight: .bold)
        let text = String(n)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let height = ceil(font.pointSize * 1.6)
        let w = max(height, textWidth + height * 0.6)
        let rect = CGRect(x: center.x - w / 2, y: center.y - height / 2, width: w, height: height)
        // Digits are cap-height tall: baseline half a cap height below the center centers them optically.
        return (rect, text, font, textWidth, center.y - font.capHeight / 2)
    }

    /// Next number for the Number tool: one above the highest on the shot (1 on a fresh shot), so a
    /// deleted or moved badge never causes a duplicate. Undo brings the count back with the marks.
    private var nextNumber: Int {
        marks.reduce(0) { top, m in if case .number(_, let n) = m.kind { return max(top, n) } else { return top } } + 1
    }

    private func draw(_ m: Mark, in full: NSRect) {
        m.color.setStroke()
        m.color.setFill()
        switch m.kind {
        case .arrow(let a, let b):
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(12, m.width * 4) * m.scale
            let shaftEnd = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
            let shaft = NSBezierPath()
            shaft.lineWidth = m.lineWidth
            shaft.lineCapStyle = .round
            shaft.move(to: a)
            shaft.line(to: shaftEnd)
            shaft.stroke()
            let tip = NSBezierPath()
            tip.move(to: b)
            tip.line(to: CGPoint(x: b.x - head * cos(angle - .pi / 7), y: b.y - head * sin(angle - .pi / 7)))
            tip.line(to: CGPoint(x: b.x - head * cos(angle + .pi / 7), y: b.y - head * sin(angle + .pi / 7)))
            tip.close()
            tip.fill()
        case .rect(let r), .ellipse(let r):
            let p: NSBezierPath
            let radius = 3 * m.scale
            if case .rect = m.kind { p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) } else { p = NSBezierPath(ovalIn: r) }
            p.lineWidth = m.lineWidth
            p.stroke()
        case .highlight(let r):
            m.color.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: r).fill()
        case .text(let at, let s):
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 3 * m.scale
            shadow.shadowOffset = NSSize(width: 0, height: -m.scale)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: m.fontSize),
                .foregroundColor: m.color,
                .shadow: shadow,
            ]
            (s as NSString).draw(at: at, withAttributes: attrs)
        case .number(let center, let n):
            // Rounded badge in the mark color; the digit black or white by WCAG contrast (Contrast.swift).
            let b = Self.badge(n, at: center, size: m.fontSize)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow() // lifts the badge off backgrounds of a similar color
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 3 * m.scale
            shadow.shadowOffset = NSSize(width: 0, height: -m.scale)
            shadow.set()
            NSBezierPath(roundedRect: b.rect, xRadius: b.rect.height / 2, yRadius: b.rect.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            (b.text as NSString).draw(with: CGRect(x: b.rect.midX - b.textWidth / 2, y: b.baseline, width: b.textWidth, height: 0),
                                      options: [], attributes: [.font: b.font, .foregroundColor: m.color.contrastingTextColor])
        case .pixelate(let r):
            replace(r, with: pixelated, in: full)
        case .blur(let r):
            replace(r, with: blurred, in: full)
        }
    }

    /// Pixelate/Blur: the area `r` shows the filtered copy of the shot (black if the filter failed).
    /// .copy replaces the pixels: drawn over (sourceOver), translucent content under it (e.g. a
    /// see-through window) would stay readable in the export.
    private func replace(_ r: CGRect, with filtered: NSImage?, in full: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        if let filtered {
            filtered.draw(in: full, from: .zero, operation: .copy, fraction: 1)
        } else {
            NSColor.black.setFill()
            NSBezierPath(rect: r).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func pixelate(_ image: NSImage) -> NSImage? {
        filtered(image, "CIPixellate") { filter, width in
            filter.setValue(max(8, width / 100), forKey: kCIInputScaleKey)
            filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        }
    }

    /// Strong Gaussian blur (radius ~1% of the shot width, at least 12 px): text underneath is unreadable.
    private static func blur(_ image: NSImage) -> NSImage? {
        filtered(image, "CIGaussianBlur") { filter, width in
            filter.setValue(max(12, width / 100), forKey: kCIInputRadiusKey)
        }
    }

    /// The whole shot through a Core Image filter, at its pixel size. Edges clamped, so the border
    /// does not fade to transparent.
    private static func filtered(_ image: NSImage, _ name: String, _ configure: (CIFilter, CGFloat) -> Void) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: name) else { return nil }
        let input = CIImage(cgImage: cg)
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        configure(filter, CGFloat(cg.width))
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let result = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: result, size: image.size)
    }

    // MARK: Editing

    private func commit(_ change: () -> Void) {
        let before = (marks, crop, image)
        change()
        recordChange(undoTo: before)
    }

    private func recordChange(undoTo before: ([Mark], CGRect?, NSImage)) {
        undoStack.append(before)
        changeCount += 1
        needsDisplay = true
        onChange?()
    }

    func undo() {
        guard let last = undoStack.popLast() else {
            NSSound.beep()
            return
        }
        selected = nil
        if last.2 !== image { setImage(last.2) }
        marks = last.0
        crop = last.1
        changeCount += 1
        needsDisplay = true
        onChange?()
    }

    // MARK: Resize (⇧⌘R)

    /// Pixel size of the shot (what Save writes before a crop).
    var pixelSize: (width: Int, height: Int) {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        return (cg?.width ?? Int(image.size.width), cg?.height ?? Int(image.size.height))
    }

    /// Resize the shot to `factor` (0.75 = 75%), marks and crop with it, in one undo step.
    /// Pixels are resampled (high quality); the Retina point/pixel ratio stays as it was.
    func resize(by factor: CGFloat) {
        guard factor > 0, factor != 1, let resized = Self.resized(image, by: factor) else { return }
        // Actual factor after rounding to whole pixels, so marks land on the same content.
        let s = resized.size.width / image.size.width
        draft = nil
        draftCrop = nil
        selected = nil
        commit {
            marks = marks.map { $0.scaled(by: s) }
            crop = crop.map { CGRect(x: $0.minX * s, y: $0.minY * s, width: $0.width * s, height: $0.height * s).integral }
            setImage(resized)
        }
    }

    /// Swap the shot: filtered copies follow, the view takes the new point size.
    private func setImage(_ new: NSImage) {
        image = new
        pixelated = Self.pixelate(new)
        blurCache = nil
        setFrameSize(new.size)
        onSizeChange?()
    }

    /// `image` resampled to `factor` of its pixel size, same color space (P3 stays P3), at least 1×1.
    private static func resized(_ image: NSImage, by factor: CGFloat) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = max(1, Int((CGFloat(cg.width) * factor).rounded()))
        let h = max(1, Int((CGFloat(cg.height) * factor).rounded()))
        // RGB spaces only: CGBitmapContext rejects indexed (GIF) and gray+alpha.
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        // Keep points per pixel (Retina shots: 2 px per pt), so the resized shot is shown and saved alike.
        let size = NSSize(width: CGFloat(w) * image.size.width / CGFloat(cg.width),
                          height: CGFloat(h) * image.size.height / CGFloat(cg.height))
        return NSImage(cgImage: out, size: size)
    }

    // MARK: Selection (click a mark: select, drag: move, click text: edit)

    private(set) var selected: Int? {
        didSet {
            needsDisplay = true
            onSelectionChange?(selected.flatMap { marks.indices.contains($0) ? marks[$0] : nil })
        }
    }
    var onSelectionChange: ((Mark?) -> Void)?

    /// Apply a property change (color, width) to the selected mark, undoable.
    func updateSelection(_ change: (inout Mark) -> Void) {
        guard textField == nil, let i = selected, marks.indices.contains(i) else { return }
        commit { change(&marks[i]) }
    }

    private func deleteSelection() {
        guard let i = selected, marks.indices.contains(i) else { return }
        selected = nil; commit { marks.remove(at: i) }
    }

    private func hitMark(at p: CGPoint) -> Int? {
        marks.indices.reversed().first { $0 != editingIndex && marks[$0].contains(p) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)) }
    }
    override func mouseMoved(with event: NSEvent) { (tool == .move || hitMark(at: point(event)) != nil ? NSCursor.openHand : .crosshair).set() }
    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self) // ends a running text edit first
        start = point(event)
        if tool != .crop, let i = hitMark(at: start) {
            selected = i
            moving = (i, marks)
            NSCursor.closedHand.set()
            return
        }
        selected = nil
        if tool == .number { // one click places the next number, centered on the click
            let mark = Mark(kind: .number(start, nextNumber), color: color, width: lineWidth)
            commit { marks.append(mark) }
            return
        }
        if tool == .text {
            textScale = 1
            openTextField(text: "", at: CGPoint(x: start.x - 3, y: start.y - Self.fieldHeight(textSize) / 2))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if let m = moving {
            marks[m.index] = m.original[m.index].offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            needsDisplay = true
            return
        }
        let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        switch tool {
        case .arrow: draft = Mark(kind: .arrow(start, p), color: color, width: lineWidth)
        case .rect: draft = Mark(kind: .rect(r), color: color, width: lineWidth)
        case .ellipse: draft = Mark(kind: .ellipse(r), color: color, width: lineWidth)
        case .highlight: draft = Mark(kind: .highlight(r), color: color, width: lineWidth)
        case .pixelate: draft = Mark(kind: .pixelate(r), color: color, width: lineWidth)
        case .blur: draft = Mark(kind: .blur(r), color: color, width: lineWidth)
        case .crop: draftCrop = r
        case .move, .text, .number: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let m = moving {
            moving = nil
            NSCursor.openHand.set()
            if hypot(point(event).x - start.x, point(event).y - start.y) > 0.5 {
                recordChange(undoTo: (m.original, crop, image))
            } else {
                marks = m.original
                needsDisplay = true
                if case .text = marks[m.index].kind { editText(m.index) } // plain click on text: edit it
            }
            return
        }
        let finishedDraft = draft
        draft = nil
        if tool != .crop, let d = finishedDraft, d.isMeaningful {
            commit { marks.append(d) }
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isEmpty, let t = Tool.allCases.first(where: { $0.key == chars }) {
            tool = t
        } else if event.keyCode == 51 || event.keyCode == 117, selected != nil { // Delete / forward delete
            deleteSelection()
        } else if event.keyCode == 36 || event.keyCode == 76, let c = pendingCrop { // Return: crop
            draftCrop = nil
            commit { crop = c }
        } else if event.keyCode == 53 { // Esc: drop drafts, deselect, back to Move
            draft = nil
            selected = nil
            tool = .move
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Text (typed and edited in place)

    private var textField: NSTextField?
    private var textCancelled = false
    private var editingIndex: Int?
    /// Scale of the text being typed: the edited mark's (after a resize), 1 for new text.
    private var textScale: CGFloat = 1
    /// Font size of the text being typed.
    private var textSize: CGFloat { Self.fontSize(lineWidth) * textScale }

    nonisolated static func fieldHeight(_ size: CGFloat) -> CGFloat { ceil(size * 1.4) }
    nonisolated static func lineHeight(_ size: CGFloat) -> CGFloat { NSLayoutManager().defaultLineHeight(for: .boldSystemFont(ofSize: size)) }

    private func openTextField(text: String, at origin: CGPoint) {
        let size = textSize
        let field = NSTextField(frame: NSRect(x: origin.x, y: origin.y, width: max(120, size * 6), height: Self.fieldHeight(size)))
        field.stringValue = text
        field.font = NSFont.boldSystemFont(ofSize: size)
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .exterior
        field.placeholderString = "Type text"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        addSubview(field)
        textField = field
        textCancelled = false
        fitTextField()
        window?.makeFirstResponder(field)
    }

    /// Edit an existing text mark in place (hidden while its field is open).
    private func editText(_ i: Int) {
        guard case .text(let at, let s) = marks[i].kind else { return }
        selected = i
        color = marks[i].color
        lineWidth = marks[i].width
        textScale = marks[i].scale
        editingIndex = i
        needsDisplay = true
        let pad = (Self.fieldHeight(textSize) - Self.lineHeight(textSize)) / 2
        openTextField(text: s, at: CGPoint(x: at.x - 2, y: at.y - max(0, pad)))
    }

    /// Color/size changes while typing go to the open field.
    private func styleTextField() {
        guard let field = textField else { return }
        field.textColor = color
        field.font = NSFont.boldSystemFont(ofSize: textSize)
        field.frame.size.height = Self.fieldHeight(textSize)
        fitTextField()
    }

    private func fitTextField() {
        guard let field = textField, let font = field.font else { return }
        let w = (field.stringValue as NSString).size(withAttributes: [.font: font]).width + 24
        field.frame.size.width = min(max(120, w), max(120, bounds.width - field.frame.minX))
    }

    /// End text entry (places the text unless cancelled); used before save/copy.
    func finishText() {
        if textField != nil { window?.makeFirstResponder(self) }
    }

    func controlTextDidChange(_ obj: Notification) { fitTextField() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            textCancelled = true
            window?.makeFirstResponder(self)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = textField else { return }
        textField = nil
        let editing = editingIndex
        editingIndex = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let frame = field.frame
        field.removeFromSuperview()
        needsDisplay = true
        if textCancelled { return }
        // Same spot as typed: text field inset 2 pt, line box vertically centered.
        let at = CGPoint(x: frame.minX + 2, y: frame.minY + max(0, (frame.height - Self.lineHeight(textSize)) / 2))
        let mark = Mark(kind: .text(at, text), color: color, width: lineWidth, scale: textScale)
        if let i = editing, marks.indices.contains(i) {
            selected = text.isEmpty ? nil : i
            commit { if text.isEmpty { marks.remove(at: i) } else { marks[i] = mark } }
        } else if !text.isEmpty {
            commit { marks.append(mark) }
            selected = marks.count - 1
        }
    }

    // MARK: Export

    /// The image with all marks, cut to `area` (view points; nil = whole image), at the original pixel size, as PNG.
    func renderedPNG(cropTo area: CGRect?) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              var rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // Keep the shot's color profile (Retina Macs: Display P3): converting to sRGB shifts saturated colors.
        if let space = cg.colorSpace.flatMap(NSColorSpace.init(cgColorSpace:)), space.colorSpaceModel == .rgb,
           let tagged = rep.retagging(with: space) {
            rep = tagged
        }
        // Point size BEFORE the context: the context takes its scale from it. Created first (as up to 2.0.0),
        // a Retina shot was drawn at 1x into the 2x bitmap: content in one corner at 50%, rest transparent.
        let size = image.size
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        render(marks)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var out = rep
        if let crop = area, let full = rep.cgImage {
            let sx = CGFloat(cg.width) / size.width
            let sy = CGFloat(cg.height) / size.height
            // CGImage cropping uses a top-left origin.
            let px = CGRect(x: crop.minX * sx, y: (size.height - crop.maxY) * sy,
                            width: crop.width * sx, height: crop.height * sy).integral
            if let cropped = full.cropping(to: px) {
                out = NSBitmapImageRep(cgImage: cropped)
                out.size = crop.size
            }
        }
        return out.representation(using: .png, properties: [:])
    }
}

@MainActor
final class Editor: NSObject, NSWindowDelegate, NSPopoverDelegate {
    private static var editors: [Editor] = []
    /// Called after a file was renamed in an editor (old URL, new URL).
    static var onRename: ((URL, URL) -> Void)?
    /// File moved to the Trash by the Delete button.
    static var onDelete: ((URL) -> Void)?

    static func open(_ url: URL) {
        if let existing = editors.first(where: { $0.url == url }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let image = NSImage(contentsOf: url), image.isValid else {
            Alerts.info("Cannot open image", url.path)
            return
        }
        let editor = Editor(url: url, image: image)
        editors.append(editor)
        editor.show()
    }

    static var hasOpenEditors: Bool { !editors.isEmpty }

    /// ⌘⇧F: all open shots in front of other apps (minimized ones restored); the newest is key.
    static func bringAllToFront() {
        guard !editors.isEmpty else { return NSSound.beep() }
        NSApp.activate(ignoringOtherApps: true)
        for e in editors {
            if e.window.isMiniaturized { e.window.deminiaturize(nil) }
            e.window.orderFront(nil)
        }
        editors.last?.window.makeKeyAndOrderFront(nil)
    }

    /// Image types the editor opens (Open panel, Open All; Info.plist CFBundleDocumentTypes alike).
    static let imageTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .gif, .bmp]
    /// Above this many shots, Open All asks first (each shot is a window).
    static let openAllLimit = 20

    /// ⌘⌥⇧O: every image in the shots folder, each in its own editor, oldest first (newest ends on top).
    /// More than `openAllLimit`: asks, offering the newest ones only.
    static func openAllInFolder() {
        let folder = Settings.folder
        let keys: [URLResourceKey] = [.contentTypeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        let shots = files.filter { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, let t = v.contentType else { return false }
            return imageTypes.contains { t.conforms(to: $0) }
        }.sorted { date($0) < date($1) }
        NSApp.activate(ignoringOtherApps: true)
        guard !shots.isEmpty else {
            return Alerts.info("No shots to open", "\(folder.path) has no images.")
        }
        var open = shots
        if shots.count > openAllLimit {
            let alert = NSAlert()
            alert.messageText = "Open all \(shots.count) shots?"
            alert.informativeText = "Each shot opens in its own editor window."
            alert.addButton(withTitle: "Open Newest \(openAllLimit)")
            alert.addButton(withTitle: "Open All \(shots.count)")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: open = Array(shots.suffix(openAllLimit))
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        for url in open { Editor.open(url) }
    }

    static func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = imageTypes
        panel.directoryURL = Settings.folder
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private(set) var url: URL
    let window: EditorWindow
    private let canvas: EditorCanvas
    private let stage: FloatingStage
    private let scroll = NSScrollView()
    private let tools = NSSegmentedControl()
    private let colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
    private let widths = NSPopUpButton(frame: .zero, pullsDown: false)
    private static let widthSteps: [CGFloat] = [2, 4, 8]
    /// Editor background around the shot: the former solid grey at 70% opacity (30% transparent).
    static let canvasBackground = NSColor(white: 0.18, alpha: 0.7)

    /// Borderless filled panel (honors the fill's alpha).
    private static func panel(_ fill: NSColor) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.fillColor = fill
        box.borderWidth = 0
        box.titlePosition = .noTitle
        return box
    }
    private var savedChangeCount = 0

    private var isDirty: Bool { canvas.changeCount != savedChangeCount }

    private init(url: URL, image: NSImage) {
        self.url = url
        canvas = EditorCanvas(image: image)
        stage = FloatingStage(canvas: canvas)
        window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        // Transparent window: only the canvas background (70% grey) lets the desktop show through.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.delegate = self
        window.minSize = NSSize(width: 560, height: 320)
        setURL(url)
        buildUI()
        canvas.onChange = { [weak self] in self?.updateTitle() }
        canvas.onToolChange = { [weak self] t in self?.tools.selectedSegment = t.rawValue }
        canvas.onSelectionChange = { [weak self] mark in
            guard let self, let mark else { return }
            self.colorWell.color = mark.color
            let steps = Editor.widthSteps
            self.widths.selectItem(at: steps.indices.min { abs(steps[$0] - mark.width) < abs(steps[$1] - mark.width) } ?? 1)
        }
        window.onTitleClick = { [weak self] rect in self?.showRename(at: rect) }
    }

    private func buildUI() {
        tools.segmentCount = Tool.allCases.count
        tools.trackingMode = .selectOne
        for t in Tool.allCases {
            if let img = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title) {
                tools.setImage(img, forSegment: t.rawValue)
            } else {
                tools.setLabel(String(t.title.prefix(1)), forSegment: t.rawValue)
            }
            tools.setToolTip(t.title, forSegment: t.rawValue)
            tools.setWidth(30, forSegment: t.rawValue)
        }
        tools.selectedSegment = canvas.tool.rawValue
        tools.target = self
        tools.action = #selector(toolChanged(_:))

        colorWell.color = canvas.color
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.toolTip = "Color"
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true

        widths.addItems(withTitles: ["Thin", "Medium", "Thick"])
        widths.selectItem(at: 1)
        widths.target = self
        widths.action = #selector(widthChanged(_:))
        widths.toolTip = "Line width / text and number size"

        let undo = NSButton(title: "Undo", target: self, action: #selector(undoMark(_:)))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copy(_:)))
        let save = NSButton(title: "Save", target: self, action: #selector(saveDocument(_:)))
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteShot(_:)))
        save.bezelColor = .controlAccentColor
        undo.toolTip = "Undo (⌘Z)"
        copy.toolTip = "Copy image (⌘C)"
        save.toolTip = "Save (⌘S); Save As: ⇧⌘S"
        delete.toolTip = "Move the shot to the Trash and close"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [tools, colorWell, widths, spacer, undo, delete, copy, save])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        scroll.contentView = CenteringClipView()
        scroll.documentView = stage
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 4
        // Area around the shot: grey at 70% opacity, so the desktop shows through 30% (sharp, no blur).
        // The window itself is transparent (see init); the shot and the toolbar stay 100% opaque.
        // Painted by a panel behind the scroll view: NSClipView paints its backgroundColor opaque, ignoring alpha.
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        let canvasBackground = Self.panel(Self.canvasBackground)
        let barBackground = Self.panel(.windowBackgroundColor) // solid toolbar strip, adapts to light/dark

        let content = NSView()
        for v in [canvasBackground, barBackground, bar, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            canvasBackground.topAnchor.constraint(equalTo: scroll.topAnchor),
            canvasBackground.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            canvasBackground.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            canvasBackground.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            barBackground.topAnchor.constraint(equalTo: bar.topAnchor),
            barBackground.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            barBackground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            barBackground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    private func show() {
        let barHeight: CGFloat = 44
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let img = stage.frame.size // shot + shadow margin
        let fit = min(1, (visible.width * 0.85) / max(img.width, 1), (visible.height * 0.85 - barHeight) / max(img.height, 1))
        let size = NSSize(width: max(640, img.width * fit + 2), height: max(360, img.height * fit + barHeight + 2))
        window.setContentSize(size)
        // Cascade from the newest other editor (Open All: a staircase, not one stack); else centered.
        if let previous = Editor.editors.last(where: { $0 !== self && $0.window.isVisible }) {
            let f = previous.window.frame
            window.setFrameTopLeftPoint(NSPoint(x: f.minX + 24, y: f.maxY - 24))
            window.setFrame(window.constrainFrameRect(window.frame, to: previous.window.screen), display: false)
        } else {
            window.center()
        }
        scroll.magnification = fit
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    private func updateTitle() {
        window.isDocumentEdited = isDirty
    }

    // MARK: Actions (buttons + the Edit/File menu via the responder chain)

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        if let t = Tool(rawValue: sender.selectedSegment) { canvas.tool = t }
        window.makeFirstResponder(canvas)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        let c = sender.color
        canvas.color = c
        canvas.updateSelection { $0.color = c }
    }

    @objc private func widthChanged(_ sender: NSPopUpButton) {
        let w = Editor.widthSteps[max(0, min(2, sender.indexOfSelectedItem))]
        canvas.lineWidth = w
        canvas.updateSelection { $0.width = w }
    }

    @objc func undoMark(_ sender: Any?) {
        canvas.undo()
    }

    /// ⇧⌘R: resize the shot by a percentage (default 75%, then the last one used); marks scale along.
    /// Undoable like a mark. Save then writes the smaller (or larger) PNG.
    @objc func resizeImage(_ sender: Any?) {
        canvas.finishText()
        guard window.attachedSheet == nil else { return }
        let px = canvas.pixelSize
        let field = NSTextField(string: String(Settings.resizePercent))
        field.frame = NSRect(x: 0, y: 0, width: 64, height: 22)
        field.alignment = .right
        let unit = NSTextField(labelWithString: "%")
        unit.frame = NSRect(x: 70, y: 2, width: 20, height: 18)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 90, height: 22))
        accessory.addSubview(field)
        accessory.addSubview(unit)

        let alert = NSAlert()
        alert.messageText = "Resize Image"
        alert.informativeText = "Now \(px.width) × \(px.height) px. Arrows, boxes, text and numbers scale along (1–400%)."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            guard let percent = Int(text), (1...400).contains(percent) else {
                NSSound.beep()
                return
            }
            Settings.resizePercent = percent
            self.canvas.resize(by: CGFloat(percent) / 100)
            self.window.makeFirstResponder(self.canvas)
        }
    }

    @objc func copy(_ sender: Any?) {
        canvas.finishText()
        guard let png = canvas.renderedPNG(cropTo: canvas.copyArea) else { return }
        Clipboard.copy(png: png, file: nil)
        NSSound(named: "Tink")?.play()
    }

    /// ⌘D (File > Move to Trash) or the Delete button: moves the file to the Trash (recoverable there)
    /// and closes without the save prompt; the next open shot becomes key. Not ⌘⌫: that would also
    /// fire while typing a text mark.
    @objc func deleteShot(_ sender: Any?) {
        canvas.finishText()
        let old = url
        do {
            try FileManager.default.trashItem(at: old, resultingItemURL: nil)
        } catch {
            Alerts.info("Cannot delete", error.localizedDescription)
            return
        }
        NSSound(named: "Funk")?.play()
        Editor.onDelete?(old)
        // Next shot: the one opened after this (wrapping to the first), so ⌘D walks through them.
        let others = Editor.editors
        let next = others.firstIndex { $0 === self }.flatMap { i -> Editor? in
            let rest = Array(others[(i + 1)...]) + Array(others[..<i])
            return rest.first { $0.window.isVisible }
        }
        window.close() // close() skips windowShouldClose, so no "Save changes?" for a trashed file
        next?.window.makeKeyAndOrderFront(nil)
    }

    private var canSaveInPlace: Bool { url.pathExtension.lowercased() == "png" }

    @objc func saveDocument(_ sender: Any?) {
        canvas.finishText()
        if canSaveInPlace { write(to: url) } else { saveDocumentAs(sender) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-edited.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let target = panel.url else { return }
            self.write(to: target)
        }
    }

    @discardableResult
    private func write(to target: URL) -> Bool {
        guard let png = canvas.renderedPNG(cropTo: canvas.crop) else {
            Alerts.info("Save failed", "Could not render the image.")
            return false
        }
        do {
            try png.write(to: target, options: .atomic)
        } catch {
            Alerts.info("Save failed", error.localizedDescription)
            return false
        }
        setURL(target)
        savedChangeCount = canvas.changeCount
        updateTitle()
        if Settings.copyToClipboard { Clipboard.copy(png: png, file: target) }
        return true
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.finishText()
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(url.lastPathComponent)?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if canSaveInPlace { return write(to: url) }
            saveDocumentAs(nil)
            return false
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Rename (click on the title)

    private var renamePopover: NSPopover?

    private func showRename(at rect: NSRect) {
        guard renamePopover == nil, let frameView = window.contentView?.superview else { return }
        let field = NSTextField(string: url.deletingPathExtension().lastPathComponent)
        field.frame = NSRect(x: 12, y: 12, width: 240, height: 24)
        field.target = self
        field.action = #selector(renameCommitted(_:))
        let ext = NSTextField(labelWithString: url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
        ext.frame = NSRect(x: 256, y: 15, width: 44, height: 18)
        ext.textColor = .secondaryLabelColor
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 48))
        view.addSubview(field)
        view.addSubview(ext)
        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        renamePopover = popover
        popover.show(relativeTo: rect, of: frameView, preferredEdge: .minY)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func renameCommitted(_ sender: NSTextField) {
        renamePopover?.close()
        rename(to: sender.stringValue)
    }

    private func rename(to newName: String) {
        var base = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if !url.pathExtension.isEmpty, base.lowercased().hasSuffix("." + url.pathExtension.lowercased()) {
            base = String(base.dropLast(url.pathExtension.count + 1))
        }
        guard !base.isEmpty, !base.hasPrefix(".") else { return }
        var target = url.deletingLastPathComponent().appendingPathComponent(base)
        if !url.pathExtension.isEmpty { target.appendPathExtension(url.pathExtension) }
        guard target.path != url.path else { return }
        let onlyCaseChanges = target.path.lowercased() == url.path.lowercased()
        if !onlyCaseChanges, FileManager.default.fileExists(atPath: target.path) {
            Alerts.info("Cannot rename", "\"\(target.lastPathComponent)\" already exists in this folder.")
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            Alerts.info("Cannot rename", error.localizedDescription)
            return
        }
        let old = url
        setURL(target)
        Editor.onRename?(old, target)
    }

    private func setURL(_ new: URL) {
        url = new
        window.title = new.lastPathComponent
        window.representedURL = new
    }

    func windowWillClose(_ notification: Notification) {
        Editor.editors.removeAll { $0 === self }
    }
}

extension Editor {
    func popoverDidClose(_ notification: Notification) {
        renamePopover = nil
        window.makeFirstResponder(canvas)
    }
}

/// Editor window that reports a single click on its title (not a drag, not a
/// double-click) with the title's rectangle in window coordinates.
@MainActor
final class EditorWindow: NSWindow {
    var onTitleClick: ((NSRect) -> Void)?
    private var pending: (origin: NSPoint, rect: NSRect)?
    private var clickWork: DispatchWorkItem?

    private func titleRect() -> NSRect {
        let layout = contentLayoutRect
        let barHeight = frame.height - layout.maxY
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.titleBarFont(ofSize: 0)]
        let textWidth = (title as NSString).size(withAttributes: attrs).width
        let width = min(frame.width - 160, textWidth + (representedURL == nil ? 16 : 40))
        return NSRect(x: (frame.width - width) / 2, y: layout.maxY, width: width, height: barHeight)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            clickWork?.cancel()
            clickWork = nil
            pending = nil
            let rect = titleRect()
            if event.clickCount == 1, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               rect.contains(event.locationInWindow) {
                pending = (frame.origin, rect)
            }
        }
        super.sendEvent(event)
        switch event.type {
        case .leftMouseDown where pending != nil && NSEvent.pressedMouseButtons & 1 == 0:
            finishTitleClick() // the titlebar's own tracking loop consumed the mouse-up
        case .leftMouseUp where pending != nil:
            finishTitleClick()
        default:
            break
        }
    }

    private func finishTitleClick() {
        guard let p = pending else { return }
        pending = nil
        guard frame.origin == p.origin else { return } // the window was dragged
        // Wait out a possible double-click (zoom).
        let work = DispatchWorkItem { [weak self] in self?.onTitleClick?(p.rect) }
        clickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
}

/// Scroll document: the canvas plus a margin with a soft drop shadow AROUND the visible shot, never under it
/// (the shot is 30% see-through on screen; a shadow beneath would darken it). Follows an applied crop.
final class FloatingStage: NSView {
    static let margin: CGFloat = 32 // > shadow blur + offset
    private let canvas: EditorCanvas

    init(canvas: EditorCanvas) {
        self.canvas = canvas
        let m = Self.margin
        super.init(frame: NSRect(x: 0, y: 0, width: canvas.frame.width + 2 * m, height: canvas.frame.height + 2 * m))
        canvas.setFrameOrigin(NSPoint(x: m, y: m))
        addSubview(canvas)
        canvas.onCropChange = { [weak self] in self?.needsDisplay = true }
        canvas.onSizeChange = { [weak self] in self?.fitCanvas() }
    }

    /// Canvas resized (Resize Image or its undo): margin stays, shadow redrawn.
    private func fitCanvas() {
        let m = Self.margin
        setFrameSize(NSSize(width: canvas.frame.width + 2 * m, height: canvas.frame.height + 2 * m))
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        let shot = canvas.visibleArea.offsetBy(dx: canvas.frame.minX, dy: canvas.frame.minY)
        NSGraphicsContext.saveGraphicsState()
        // Clip the shot out, then fill it with a shadow: only the shadow outside the shot remains.
        let outside = NSBezierPath(rect: bounds)
        outside.appendRect(shot)
        outside.windingRule = .evenOdd
        outside.addClip()
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.45)
        s.shadowBlurRadius = 16
        s.shadowOffset = NSSize(width: 0, height: -6)
        s.set()
        NSColor.black.setFill()
        NSBezierPath(rect: shot).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Keeps the image centered when it is smaller than the window (e.g. the toolbar's minimum width).
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView?.frame else { return r }
        if r.width > doc.width { r.origin.x = (doc.width - r.width) / 2 }
        if r.height > doc.height { r.origin.y = (doc.height - r.height) / 2 }
        return r
    }
}
