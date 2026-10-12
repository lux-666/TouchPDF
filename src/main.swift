import AppKit
import PDFKit
import UniformTypeIdentifiers

// Compiled into the executable: replacing an app bundle cannot relabel a running process.
let touchPDFBuild = "0.6.12 (19)"

let pdfType = "com.adobe.pdf"
let defaultInkColor = NSColor(calibratedRed: 0.16, green: 0.37, blue: 0.70, alpha: 1)
let inkWidth: CGFloat = 1.6

// Keep sharp mathematical corners; gently filter jitter along smooth parts of a stroke.
// Flatten curves at subpixel precision so standard PDF InkList coordinates, live ink,
// and the eraser all use the same geometry (no raster image or PPI setting).
func inkGeometry(_ samples: [NSPoint], smoothing: Bool) -> [NSPoint] {
    guard smoothing, samples.count > 2 else { return samples }
    func length(_ a: NSPoint, _ b: NSPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    func midpoint(_ a: NSPoint, _ b: NSPoint) -> NSPoint { NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    func smoothCorner(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> Bool {
        let denominator = length(a, b) * length(b, c)
        return denominator > 0.000001 && ((b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y)) / denominator > 0.5
    }
    var filtered = samples
    for i in 1..<(samples.count - 1) where smoothCorner(samples[i - 1], samples[i], samples[i + 1]) {
        let candidate = NSPoint(x: (samples[i - 1].x + 4 * samples[i].x + samples[i + 1].x) / 6,
                                y: (samples[i - 1].y + 4 * samples[i].y + samples[i + 1].y) / 6)
        let shift = length(samples[i], candidate)
        let fraction = shift > 0 ? min(1, 0.3 / shift) : 1
        filtered[i] = NSPoint(x: samples[i].x + (candidate.x - samples[i].x) * fraction,
                              y: samples[i].y + (candidate.y - samples[i].y) * fraction)
    }
    var handles = [NSPoint](repeating: .zero, count: filtered.count)
    for i in 1..<(filtered.count - 1) where smoothCorner(samples[i - 1], samples[i], samples[i + 1]) {
        let before = filtered[i - 1], after = filtered[i + 1]
        let direction = length(before, after)
        if direction > 0 {
            let extent = min(length(before, filtered[i]), length(filtered[i], after)) / 3
            handles[i] = NSPoint(x: (after.x - before.x) / direction * extent, y: (after.y - before.y) / direction * extent)
        }
    }
    var result = [filtered[0]]
    func flatten(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint, _ d: NSPoint, depth: Int = 0) {
        if depth >= 12 || max(distanceToSegment(b, a, d), distanceToSegment(c, a, d)) <= 0.02 {
            result.append(d)
            return
        }
        let ab = midpoint(a, b), bc = midpoint(b, c), cd = midpoint(c, d)
        let abc = midpoint(ab, bc), bcd = midpoint(bc, cd), center = midpoint(abc, bcd)
        flatten(a, ab, abc, center, depth: depth + 1)
        flatten(center, bcd, cd, d, depth: depth + 1)
    }
    for i in 0..<(filtered.count - 1) {
        let a = filtered[i], d = filtered[i + 1]
        flatten(a, NSPoint(x: a.x + handles[i].x, y: a.y + handles[i].y),
                NSPoint(x: d.x - handles[i + 1].x, y: d.y - handles[i + 1].y), d)
    }
    return result
}

func inkPath(_ geometry: [NSPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    for (index, point) in geometry.enumerated() {
        if index == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    if geometry.count == 1, let point = geometry.first { path.line(to: NSPoint(x: point.x + 0.1, y: point.y)) }
    path.lineWidth = inkWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

final class VectorInkAnnotation: PDFAnnotation {
    // PDFKit caches custom annotations in a 1x effect layer on some macOS
    // versions. The reader paints our ink in its Retina overlay instead.
    // This flag is transient and is disabled during PDF serialization.
    var rendersInOverlay = false
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard contents == "TouchPDF", let paths else { super.draw(with: box, in: context); return }
        guard !rendersInOverlay else { return }
        drawVector(paths, in: context)
    }
    func drawVector(_ paths: [NSBezierPath], in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(border?.lineWidth ?? inkWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.translateBy(x: bounds.minX, y: bounds.minY)
        for path in paths {
            var coordinates = [NSPoint](repeating: .zero, count: 3)
            context.beginPath()
            for index in 0..<path.elementCount {
                let element = coordinates.withUnsafeMutableBufferPointer { path.element(at: index, associatedPoints: $0.baseAddress!) }
                switch element {
                case .moveTo: context.move(to: coordinates[0])
                case .lineTo: context.addLine(to: coordinates[0])
                case .curveTo: context.addCurve(to: coordinates[2], control1: coordinates[0], control2: coordinates[1])
                case .closePath: context.closePath()
                default: break
                }
            }
            context.strokePath()
        }
    }
}

func distanceToSegment(_ point: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let length = dx * dx + dy * dy
    let t = length == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
    return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
}

func inkAnnotation(points: [NSPoint], page: PDFPage, color: NSColor = defaultInkColor, smoothing: Bool = true) -> PDFAnnotation {
    let geometry = inkGeometry(points, smoothing: smoothing)
    // A page-sized annotation makes PDFKit cache tiny handwriting in an oversized
    // appearance surface. Keep the appearance bounds local to the actual stroke.
    let bounds = inkPath(geometry).bounds.insetBy(dx: -inkWidth, dy: -inkWidth)
    let annotation = VectorInkAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
    annotation.color = color
    let border = PDFBorder()
    border.lineWidth = inkWidth
    annotation.border = border
    let path = inkPath(geometry.map { NSPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) })
    annotation.add(path)
    annotation.contents = "TouchPDF"
    annotation.modificationDate = Date()
    return annotation
}

func inkIsNear(_ annotation: PDFAnnotation, point: NSPoint, radius: CGFloat) -> Bool {
    guard annotation.type == "Ink", let paths = annotation.paths else { return false }
    let local = NSPoint(x: point.x - annotation.bounds.minX, y: point.y - annotation.bounds.minY)
    for path in paths {
        var previous: NSPoint?
        var coordinates = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<path.elementCount {
            let element = coordinates.withUnsafeMutableBufferPointer {
                path.element(at: index, associatedPoints: $0.baseAddress!)
            }
            switch element {
            case .moveTo:
                previous = coordinates[0]
                if hypot(local.x - coordinates[0].x, local.y - coordinates[0].y) <= radius { return true }
            case .lineTo:
                if let previous, distanceToSegment(local, previous, coordinates[0]) <= radius { return true }
                previous = coordinates[0]
            default:
                // shortcut: erasing follows straight segments; curved ink from other editors is left intact.
                previous = nil
            }
        }
    }
    return false
}

// Split each line at page edges, including when no input sample lands in the gap.
// A nil region is real ink on the surrounding canvas, retained for this session.
struct InkPiece {
    let region: Int?
    var points: [NSPoint]
}
func partitionInk(_ points: [NSPoint], rects: [NSRect]) -> [InkPiece] {
    func region(at p: NSPoint) -> Int? {
        rects.firstIndex { p.x >= $0.minX && p.x <= $0.maxX && p.y >= $0.minY && p.y <= $0.maxY }
    }
    guard points.count > 1 else {
        return points.first.map { [InkPiece(region: region(at: $0), points: [$0])] } ?? []
    }
    var pieces = [InkPiece]()
    for (a, b) in zip(points, points.dropFirst()) {
        let dx = b.x - a.x, dy = b.y - a.y
        func at(_ t: CGFloat) -> NSPoint { NSPoint(x: a.x + dx * t, y: a.y + dy * t) }
        var cuts: [CGFloat] = [0, 1]
        for rect in rects {
            if abs(dx) > 0.000001 {
                for x in [rect.minX, rect.maxX] {
                    let t = (x - a.x) / dx, y = a.y + dy * t
                    if t > 0 && t < 1 && y >= rect.minY && y <= rect.maxY { cuts.append(t) }
                }
            }
            if abs(dy) > 0.000001 {
                for y in [rect.minY, rect.maxY] {
                    let t = (y - a.y) / dy, x = a.x + dx * t
                    if t > 0 && t < 1 && x >= rect.minX && x <= rect.maxX { cuts.append(t) }
                }
            }
        }
        cuts = Array(Set(cuts)).sorted()
        for (start, end) in zip(cuts, cuts.dropFirst()) where end - start > 0.000001 {
            let r = region(at: at((start + end) / 2))
            if let last = pieces.last, last.region == r, last.points.last == at(start) {
                pieces[pieces.count - 1].points.append(at(end))
            } else { pieces.append(InkPiece(region: r, points: [at(start), at(end)])) }
        }
    }
    return pieces
}

final class CanvasInk {
    let anchor: PDFPage
    let points: [NSPoint] // Extended page coordinates; they may be outside its bounds.
    let color: NSColor
    init(anchor: PDFPage, points: [NSPoint], color: NSColor) {
        self.anchor = anchor; self.points = points; self.color = color
    }
}

func samplePDF() -> PDFDocument {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
    for number in 1...2 {
        context.beginPDFPage(nil)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let title = number == 1 ? "Reading, Attention and Memory" : "Following an Argument"
        (title as NSString).draw(at: NSPoint(x: 58, y: 690), withAttributes: [.font: NSFont(name: "TimesNewRomanPS-BoldMT", size: 23) ?? NSFont.boldSystemFont(ofSize: 23), .foregroundColor: NSColor.black])
        let text = number == 1 ? "Reading is an active process. Readers connect new information with what they already know, decide which details matter, and return to passages that remain unclear.\n\nA useful reading habit is to identify the main claim and then examine the evidence supporting it. Working memory helps us keep earlier ideas available while we interpret the next sentence.\n\nSmall marks in the margin can make this process visible. An underline may identify a central claim; a circle may draw attention to an unfamiliar term. The purpose is to leave a clear trail for a second reading." : "An argument connects a claim with supporting evidence. Readers need to understand both the claim and the reasons offered for accepting it.\n\nA useful question is whether the evidence is strong enough for the conclusion. Another is whether a different explanation would also fit the observations.\n\nA few simple marks can make a later review easier: underline a key sentence, circle a term, or draw an arrow between related ideas."
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        (text as NSString).draw(in: NSRect(x: 58, y: 280, width: 496, height: 360), withAttributes: [.font: NSFont(name: "TimesNewRomanPSMT", size: 16) ?? NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
        ("TouchPDF reading sample · \(number)" as NSString).draw(at: NSPoint(x: 58, y: 65), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.darkGray])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }
    context.closePDF()
    return PDFDocument(data: data as Data)!
}

func blankPDF() -> PDFDocument {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
    return PDFDocument(data: data as Data)!
}

@objc(TouchPDFDocument)
final class TouchPDFDocument: NSDocument, PDFDocumentDelegate {
    var canvasInk = [CanvasInk]()
    var pdf = blankPDF() { didSet { pdf.delegate = self } }

    override init() {
        super.init()
        pdf.delegate = self
        fileType = pdfType
    }

    func `class`(forAnnotationType annotationType: String) -> AnyClass {
        annotationType == "Ink" ? VectorInkAnnotation.self : PDFAnnotation.self
    }

    override class var autosavesInPlace: Bool { false }
    override class var readableTypes: [String] { [pdfType] }
    override class var writableTypes: [String] { [pdfType] }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = [.pdf]
        return true
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let loaded = PDFDocument(data: data), loaded.pageCount > 0 else {
            throw NSError(domain: "TouchPDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取这个 PDF 文件。"])
        }
        loaded.delegate = self
        guard !loaded.isLocked else {
            throw NSError(domain: "TouchPDF", code: 2, userInfo: [NSLocalizedDescriptionKey: "这个 PDF 有密码保护，请先解锁后再打开。"])
        }
        guard loaded.allowsCommenting else {
            throw NSError(domain: "TouchPDF", code: 3, userInfo: [NSLocalizedDescriptionKey: "这个 PDF 不允许批注。"])
        }
        pdf = loaded
        canvasInk = []
    }

    override func data(ofType typeName: String) throws -> Data {
        for controller in windowControllers {
            (controller as? ReaderWindowController)?.surface.finishStroke()
        }
        let screenInk = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)!.annotations }
            .compactMap { $0 as? VectorInkAnnotation }.filter { $0.rendersInOverlay }
        screenInk.forEach { $0.rendersInOverlay = false }
        defer { screenInk.forEach { $0.rendersInOverlay = true } }
        guard let data = pdf.dataRepresentation() else {
            throw NSError(domain: "TouchPDF", code: 4, userInfo: [NSLocalizedDescriptionKey: "PDF 保存失败，未写入文件。"])
        }
        // PDFKit may retain a blank appearance stream from the suppressed
        // screen renderer. Rebuild our ink in an export-only document so a
        // fresh vector appearance is generated without touching live undo state.
        guard let export = PDFDocument(data: data) else {
            throw NSError(domain: "TouchPDF", code: 4, userInfo: [NSLocalizedDescriptionKey: "PDF 保存失败，未写入文件。"])
        }
        for index in 0..<export.pageCount {
            guard let page = export.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Ink" && annotation.contents == "TouchPDF" {
                let copy = VectorInkAnnotation(bounds: annotation.bounds, forType: .ink, withProperties: nil)
                copy.color = annotation.color
                copy.border = annotation.border
                copy.contents = annotation.contents
                copy.userName = annotation.userName
                copy.modificationDate = annotation.modificationDate
                copy.shouldDisplay = annotation.shouldDisplay
                copy.shouldPrint = annotation.shouldPrint
                for path in annotation.paths ?? [] { copy.add(path) }
                page.removeAnnotation(annotation)
                page.addAnnotation(copy)
            }
        }
        // Layout changes may put formerly off-page ink over another page.
        // Clip into the copy so repeated saves never duplicate live marks.
        if !canvasInk.isEmpty,
           let viewer = windowControllers.compactMap({ ($0 as? ReaderWindowController)?.pdfView }).first {
            let pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
            let rects = pages.map { viewer.convert($0.bounds(for: .cropBox), from: $0) }
            for ink in canvasInk {
                let geometry = ink.points.map { viewer.convert($0, from: ink.anchor) }
                for piece in partitionInk(geometry, rects: rects) {
                    guard let index = piece.region, let target = export.page(at: index) else { continue }
                    target.addAnnotation(inkAnnotation(points: piece.points.map { viewer.convert($0, to: pages[index]) }, page: target, color: ink.color, smoothing: false))
                }
            }
        }
        guard let result = export.dataRepresentation() else {
            throw NSError(domain: "TouchPDF", code: 4, userInfo: [NSLocalizedDescriptionKey: "PDF 保存失败，未写入文件。"])
        }
        return result
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController(reader: self))
    }

    func changeCanvas(_ ink: CanvasInk, adding: Bool) {
        if adding { canvasInk.append(ink) } else { canvasInk.removeAll { $0 === ink } }
        undoManager?.registerUndo(withTarget: self) { $0.changeCanvas(ink, adding: !adding) }
        for controller in windowControllers { (controller as? ReaderWindowController)?.refresh() }
    }

    func change(_ annotation: PDFAnnotation, on page: PDFPage, adding: Bool) {
        if adding {
            if let ink = annotation as? VectorInkAnnotation, ink.contents == "TouchPDF", !windowControllers.isEmpty {
                ink.rendersInOverlay = true
            }
            page.addAnnotation(annotation)
        } else { page.removeAnnotation(annotation) }
        undoManager?.registerUndo(withTarget: self) { document in
            document.change(annotation, on: page, adding: !adding)
        }
        if undoManager?.isUndoing != true && undoManager?.isRedoing != true {
            undoManager?.setActionName(adding ? "笔画" : "擦除笔画")
        }
        for controller in windowControllers {
            (controller as? ReaderWindowController)?.refresh()
        }
    }
}

struct TouchContact {
    let identity: any NSCopying & NSObjectProtocol
    let position: NSPoint
    var deviceSize = NSSize(width: 155, height: 100)
}

private struct MappedPDFPoint {
    let page: PDFPage?
    let point: NSPoint?
    let viewLocation: NSPoint
}

// The content view also receives touches above the toolbar when the cursor leaves the PDF.
final class TouchRootView: NSView {
    weak var surface: InkSurface?
    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func touchesBegan(with event: NSEvent) { surface?.receiveTouches(event) }
    override func touchesMoved(with event: NSEvent) { surface?.receiveTouches(event) }
    override func touchesEnded(with event: NSEvent) { surface?.endTouches(event) }
    override func touchesCancelled(with event: NSEvent) { surface?.touchesCancelled(with: event) }
    override func pressureChange(with event: NSEvent) { surface?.pressureChange(with: event) }
}

// A lone Shift toggles on release. A chord, text field, click, or focus change
// cancels the candidate, so Shift-Save and capital letters never toggle ink.
struct ShiftTap {
    private var down = false
    private var candidate = false
    mutating func reset() { down = false; candidate = false }
    mutating func cancel() { candidate = false }
    mutating func changed(_ flags: NSEvent.ModifierFlags, eligible: Bool) -> Bool {
        let held = flags.contains(.shift)
        let other = !flags.intersection([.command, .control, .option, .function]).isEmpty
        defer { down = held }
        guard eligible else { candidate = false; return false }
        if other { candidate = false }
        if held && !down { candidate = !other }
        if !held && down {
            let toggle = candidate && !other
            candidate = false
            return toggle
        }
        return false
    }
}

// A held cursor may be above a toolbar button. Active trackpad presses belong to the pen.
final class DrawingWindow: NSWindow {
    weak var surface: InkSurface?
    private var shiftTap = ShiftTap()
    private var allowsToolShortcuts: Bool {
        guard isKeyWindow, attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        return !(firstResponder is NSTextView) && !(firstResponder is NSTextField)
    }
    override func resignKey() { shiftTap.reset(); super.resignKey() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            if shiftTap.changed(event.modifierFlags, eligible: allowsToolShortcuts) {
                (windowController as? ReaderWindowController)?.toggleAnnotation()
                return
            }
        } else if event.type == .keyDown {
            shiftTap.cancel()
            if allowsToolShortcuts, !event.isARepeat,
               event.modifierFlags.intersection([.command, .control, .option, .shift, .function]).isEmpty,
               let controller = windowController as? ReaderWindowController {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "[": controller.adjustRegionSize(by: -0.1); return
                case "]": controller.adjustRegionSize(by: 0.1); return
                case "c": controller.centerWritingRegion(); return
                case "x": controller.selectTool(); return
                case "1", "2", "3", "4", "5":
                    controller.selectPaletteColor(Int(event.charactersIgnoringModifiers!)! - 1); return
                default: break
                }
            }
        } else if [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify].contains(event.type) {
            shiftTap.cancel()
        }
        if let surface, surface.enabled, surface.isNativeNavigation(event) {
            if surface.movingFrameSequence { return }
            if !surface.bounds.contains(surface.convert(event.locationInWindow, from: nil)) {
                // A frozen pointer may still be above the toolbar that enabled ink.
                surface.forwardNativeNavigation(event)
                return
            }
            // Let AppKit hit-test the PDFKit hierarchy underneath the overlay.
            // The original event (including phase, momentum and magnification) is untouched.
            surface.prepareNativeNavigation(event)
            surface.passesNavigationEvents = true
            defer { surface.passesNavigationEvents = false }
            super.sendEvent(event)
            return
        }
        if surface?.handleTrackpadPress(event) == true { return }
        super.sendEvent(event)
    }
}

final class InkSurface: NSView {
    weak var reader: TouchPDFDocument?
    weak var pdfView: PDFView?
    var updateStatus: (() -> Void)?
    var previewsRegion = false { didSet { needsDisplay = true } }
    var editingPenSettings = false {
        didSet { if editingPenSettings { suspendRawInput() } else { configureRawInput() } }
    }
    var enabled = false {
        didSet {
            previewsRegion = false
            resetInput()
            if enabled { ensureRegion() }
            configureRawInput()
            window?.invalidateCursorRects(for: self)
            updateStatus?()
            needsDisplay = true
        }
    }
    var erasing = false { didSet { interruptForNavigation(); needsDisplay = true } }
    var requiresPress = false { didSet { interruptForNavigation(); updateStatus?() } }
    var pressureMode = false {
        didSet {
            if pressureMode { requiresPress = false }
            interruptForNavigation()
            configureRawInput()
            updateStatus?()
        }
    }
    var pressureThreshold: Float = 30 {
        didSet {
            pressureThreshold = min(100, max(10, pressureThreshold))
            interruptForNavigation()
            updateStatus?()
        }
    }
    var pressureReleaseThreshold: Float { pressureThreshold * 0.5 }
    var releaseToPreview = true { didSet { interruptForNavigation(); updateStatus?() } }
    var inkColor = defaultInkColor {
        willSet { interruptForNavigation() }
        didSet { needsDisplay = true }
    }
    var smoothInk = true {
        willSet { interruptForNavigation() }
        didSet { needsDisplay = true }
    }
    private(set) var inputNotice: String?
    var fillsViewport = false { didSet { interruptForNavigation(); resizeRegion(); updateStatus?() } }
    var regionScale: CGFloat = 1 {
        didSet { interruptForNavigation(); resizeRegion(); updateStatus?() }
    }
    private(set) var cursorHoldFailed = false
    private var cursorHeld = false
    private enum Mode { case idle, writing, navigating, panning, blocked }
    private var mode = Mode.idle
    private var contacts = [TouchContact]()
    private var hadMultipleContacts = false
    private(set) var movingFrameSequence = false
    var passesNavigationEvents = false
    // The writing frame lives in the PDF view's overlay coordinate space. It is
    // intentionally independent of any single PDF page, so it may cross the
    // page gap in two-column mode.
    private var writingViewRect = NSRect.zero
    private var padAspect: CGFloat = 1.55
    private var penPosition: NSPoint?
    private var penPage: PDFPage?
    private var penViewPosition: NSPoint?
    private var penArmed = false
    private var pressHeld = false
    private var privateDrawing = false
    private var rawPressure: Float = 0
    private var privateInputAvailable = false
    private var page: PDFPage?
    private var points = [NSPoint]()
    private var pendingErasure = [(PDFPage, PDFAnnotation)]()
    private var pendingCanvasErasure = [CanvasInk]()
    private var strokeStartedAt: TimeInterval = 0
    private var mouseDragLocation: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        wantsLayer = true
        // AppKit pressure begins at normal click; it does not provide a pre-click light-force threshold.
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryGeneric)
        setAccessibilityLabel("PDF 触控板批注区域")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }
    deinit {
        RawTrackpadInput.shared.deactivate(self)
        if cursorHeld { _ = CGAssociateMouseAndMouseCursorPosition(1) }
    }
    override var acceptsFirstResponder: Bool { true }

    var wantsRawInput: Bool { enabled && !editingPenSettings && pressureMode && window?.isKeyWindow == true && NSApp.isActive }
    var hasActiveContacts: Bool { !contacts.isEmpty }
    var usingRawPressure: Bool { pressureMode && privateInputAvailable }

    override func hitTest(_ point: NSPoint) -> NSView? {
        enabled && !passesNavigationEvents && bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        if enabled { addCursorRect(bounds, cursor: .arrow) }
    }

    override func mouseMoved(with event: NSEvent) {} // Pointer movement never supplies ink coordinates.

    override func mouseDown(with event: NSEvent) {
        if event.subtype == .touch { setTrackpadPressed(true); return }
        interruptForNavigation()
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        placeRegion(at: location)
        mouseDragLocation = location
    }
    override func mouseDragged(with event: NSEvent) {
        guard event.subtype != .touch, let previous = mouseDragLocation else { return }
        let location = convert(event.locationInWindow, from: nil)
        moveRegion(by: NSPoint(x: location.x - previous.x, y: location.y - previous.y))
        mouseDragLocation = location
    }
    override func mouseUp(with event: NSEvent) {
        if event.subtype == .touch { setTrackpadPressed(false) }
        else { mouseDragLocation = nil }
    }
    override func pressureChange(with event: NSEvent) { setTrackpadPressed(event.stage >= 1) }

    func configureRawInput() {
        if wantsRawInput, window?.isKeyWindow == true, NSApp.isActive {
            RawTrackpadInput.shared.activate(self)
        } else {
            RawTrackpadInput.shared.deactivate(self)
            privateInputAvailable = false
        }
    }

    func suspendRawInput() {
        RawTrackpadInput.shared.deactivate(self)
        privateInputAvailable = false
        resetInput()
    }

    func rawInputUnavailable() {
        inputNotice = "轻压输入暂不可用，已切换轻触即写"
        privateInputAvailable = false
        pressureMode = false
        updateStatus?()
    }

    func rawInputAvailable() {
        privateInputAvailable = true
        inputNotice = nil
        updateStatus?()
    }

    func rawInputInterrupted() {
        privateDrawing = false
        rawPressure = 0
        finishStroke()
        holdCursor(false)
        mode = .blocked; hadMultipleContacts = true
        penPosition = nil; penPage = nil; penViewPosition = nil
        inputNotice = "轻压输入中断，请全部抬手后重试"
        needsDisplay = true
        updateStatus?()
    }

    func receiveRawContacts(_ rawContacts: [TouchContact], pressure: Float?) {
        guard usingRawPressure, enabled else { return }
        if rawContacts.isEmpty { inputNotice = nil }
        holdCursor(!rawContacts.isEmpty && inputNotice == nil)
        processContacts(rawContacts, previewing: NSEvent.modifierFlags.contains(.command), pressure: pressure)
    }

    func handleTrackpadPress(_ event: NSEvent) -> Bool {
        guard enabled, !contacts.isEmpty else { return false }
        switch event.type {
        case .pressure:
            pressureChange(with: event)
        case .leftMouseDown where event.subtype == .touch:
            setTrackpadPressed(true)
        case .leftMouseUp where event.subtype == .touch:
            setTrackpadPressed(false)
        case .leftMouseDragged where event.subtype == .touch:
            break // Raw touch positions already extend the stroke.
        default:
            return false
        }
        return true
    }

    private func setTrackpadPressed(_ pressed: Bool) {
        guard enabled, requiresPress else { return }
        pressHeld = pressed
        // Releasing pressure does not lift the finger. Keep the stroke armed until raw touch ends.
        if pressed, contacts.count == 1, !hadMultipleContacts, mode == .writing {
            processContacts(contacts)
        }
    }
    override func otherMouseDown(with event: NSEvent) { interruptForNavigation() }
    override func otherMouseDragged(with event: NSEvent) { panPDF(with: event) }
    override func rightMouseDown(with event: NSEvent) { interruptForNavigation() }
    override func rightMouseDragged(with event: NSEvent) { panPDF(with: event) }

    private func panPDF(with event: NSEvent) {
        guard let clip = pdfView?.documentView?.enclosingScrollView?.contentView else { return }
        var proposed = clip.bounds
        proposed.origin.x -= event.deltaX
        proposed.origin.y += clip.isFlipped ? -event.deltaY : event.deltaY
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        needsDisplay = true
    }

    func receiveTouches(_ event: NSEvent) {
        guard enabled, !editingPenSettings, window?.isKeyWindow == true else { return }
        let touches = event.touches(matching: .touching, in: nil).filter { $0.type == .indirect && !$0.isResting }
        if usingRawPressure {
            RawTrackpadInput.shared.observePublicContacts(!touches.isEmpty, from: self)
            return
        }
        holdCursor(!touches.isEmpty)
        processContacts(touches.map { TouchContact(identity: $0.identity, position: $0.normalizedPosition, deviceSize: $0.deviceSize) }, previewing: event.modifierFlags.contains(.command), pressure: nil)
    }

    private func holdCursor(_ hold: Bool) {
        guard hold != cursorHeld else { return }
        let result = CGAssociateMouseAndMouseCursorPosition(hold ? 0 : 1)
        cursorHoldFailed = result != .success
        if result == .success { cursorHeld = hold }
        updateStatus?()
    }

    override func touchesBegan(with event: NSEvent) { receiveTouches(event) }
    override func touchesMoved(with event: NSEvent) { receiveTouches(event) }
    override func touchesEnded(with event: NSEvent) { endTouches(event) }
    override func touchesCancelled(with event: NSEvent) { if !usingRawPressure { resetInput() } }

    func endTouches(_ event: NSEvent) {
        if usingRawPressure { receiveTouches(event); return }
        if mode == .writing, (requiresPress || !event.modifierFlags.contains(.command)), let previous = contacts.first,
           let touch = event.touches(matching: .ended, in: nil).first(where: { previous.identity.isEqual($0.identity) }),
           let mapped = mappedPDFPoint(touch.normalizedPosition) {
            consumeMappedPoint(mapped)
        }
        receiveTouches(event)
    }

    private func processContacts(_ next: [TouchContact], previewing: Bool = false, pressure: Float? = nil) {
        guard enabled, !editingPenSettings else { return }
        let sameFingers = contacts.count == next.count && contacts.allSatisfy { previous in next.contains { previous.identity.isEqual($0.identity) } }
        defer { contacts = next; needsDisplay = true; updateStatus?() }
        if next.isEmpty {
            finishStroke()
            penArmed = false; pressHeld = false; privateDrawing = false; rawPressure = 0
            mode = .idle
            hadMultipleContacts = false
            movingFrameSequence = false
            penPosition = nil
            penPage = nil
            penViewPosition = nil
            return
        }
        if contacts.isEmpty {
            ensureRegion()
            let size = next[0].deviceSize
            if size.width > 0 && size.height > 0 {
                let aspect = size.width / size.height
                if abs(aspect - padAspect) > 0.01 {
                    padAspect = aspect
                    resizeRegion()
                }
            }
        }
        if next.count > 1 {
            penArmed = false; pressHeld = false; privateDrawing = false
            hadMultipleContacts = true
        }
        // A three-finger move owns the contact sequence until every finger lifts.
        // The last one/two fingers must neither scroll the PDF nor resume ink.
        if movingFrameSequence && next.count != 3 {
            finishStroke(discardGesturePrelude: true)
            mode = .blocked
            penPosition = nil; penPage = nil; penViewPosition = nil
            return
        }
        switch next.count {
        case 1:
            guard !hadMultipleContacts, mode != .blocked, let mapped = mappedPDFPoint(next[0].position) else {
                finishStroke(); mode = .blocked; penPosition = nil; penPage = nil; penViewPosition = nil; return
            }
            if mode != .writing || !sameFingers { finishStroke(); penArmed = false; privateDrawing = false }
            mode = .writing
            penPosition = mapped.point
            penPage = mapped.page
            penViewPosition = mapped.viewLocation
            if previewing, !requiresPress { finishStroke(); privateDrawing = false; return }
            if pressureMode {
                guard let pressure, pressure.isFinite, pressure >= 0 else {
                    finishStroke(); privateDrawing = false; return
                }
                rawPressure = pressure
                if privateDrawing {
                    if releaseToPreview && rawPressure <= pressureReleaseThreshold { finishStroke(); privateDrawing = false; return }
                } else if rawPressure >= pressureThreshold {
                    privateDrawing = true
                } else { return }
            }
            if requiresPress, !penArmed {
                guard pressHeld else { return }
                penArmed = true
            }
            consumeMappedPoint(mapped)
        case 2:
            // Native scrollWheel/magnify events own two-finger navigation. Raw
            // contacts only switch the input state away from handwriting.
            finishStroke(discardGesturePrelude: true)
            penPosition = nil
            penPage = nil
            penViewPosition = nil
            mode = .navigating
        case 3:
            movingFrameSequence = true
            finishStroke(discardGesturePrelude: true)
            penPosition = nil; penPage = nil; penViewPosition = nil
            if mode == .panning, sameFingers, let rect = regionViewRect {
                let previous = centroid(contacts), current = centroid(next)
                moveRegion(by: NSPoint(x: (current.x - previous.x) * rect.width, y: (current.y - previous.y) * rect.height))
            }
            mode = .panning
        default:
            finishStroke(discardGesturePrelude: true); mode = .blocked
            penPosition = nil; penPage = nil; penViewPosition = nil
        }
    }

    private func centroid(_ values: [TouchContact]) -> NSPoint {
        NSPoint(x: values.reduce(0) { $0 + $1.position.x } / CGFloat(values.count), y: values.reduce(0) { $0 + $1.position.y } / CGFloat(values.count))
    }
    func resetInput() {
        holdCursor(false)
        finishStroke()
        movingFrameSequence = false
        contacts = []; mode = .idle; hadMultipleContacts = false; penPosition = nil; penPage = nil; penViewPosition = nil
        penArmed = false; pressHeld = false
        privateDrawing = false; rawPressure = 0
        mouseDragLocation = nil
        needsDisplay = true
    }
    func interruptForNavigation() {
        finishStroke()
        penArmed = false; pressHeld = false
        privateDrawing = false; rawPressure = 0
        if !contacts.isEmpty { mode = .blocked; hadMultipleContacts = true }
        penPosition = nil
        penPage = nil
        penViewPosition = nil
        needsDisplay = true
    }

    private var regionViewRect: NSRect? { writingViewRect.isEmpty ? nil : writingViewRect }

    private func ensureRegion() {
        if writingViewRect.isEmpty { placeRegion(at: NSPoint(x: bounds.midX, y: bounds.midY)) }
        else { clampRegion() }
    }

    func viewportChanged() {
        // Moving the document must never recenter the screen-space writing frame.
        if enabled { ensureRegion() }
        needsDisplay = true
    }

    func pdfScaleChanged() {
        if mode == .writing { interruptForNavigation() }
        viewportChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !writingViewRect.isEmpty { resizeRegion() }
    }

    private func resizeRegion() {
        guard bounds.width > 4, bounds.height > 4 else { return }
        if fillsViewport {
            writingViewRect = bounds.insetBy(dx: 2, dy: 2)
            needsDisplay = true
            return
        }
        let center = regionViewRect.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let width = min(440 * regionScale, bounds.width - 4, (bounds.height - 4) * padAspect)
        writingViewRect = NSRect(x: center.x - width / 2, y: center.y - width / padAspect / 2, width: width, height: width / padAspect)
        clampRegion()
        needsDisplay = true
    }

    func centerRegion() {
        interruptForNavigation()
        placeRegion(at: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    private func placeRegion(at location: NSPoint) {
        writingViewRect = NSRect(x: location.x - 0.5, y: location.y - 0.5, width: 1, height: 1)
        resizeRegion()
    }

    private func clampRegion() {
        guard bounds.width > 4, bounds.height > 4 else { return }
        let limit = bounds.insetBy(dx: 2, dy: 2)
        writingViewRect.origin.x = max(limit.minX, min(limit.maxX - writingViewRect.width, writingViewRect.minX))
        writingViewRect.origin.y = max(limit.minY, min(limit.maxY - writingViewRect.height, writingViewRect.minY))
    }

    private func moveRegion(by delta: NSPoint) {
        writingViewRect.origin.x += delta.x
        writingViewRect.origin.y += delta.y
        clampRegion()
        needsDisplay = true
    }

    private func mappedPDFPoint(_ normalized: NSPoint) -> MappedPDFPoint? {
        guard let pdfView, let rect = regionViewRect else { return nil }
        let location = NSPoint(x: rect.minX + max(0, min(1, normalized.x)) * rect.width,
                               y: rect.minY + max(0, min(1, normalized.y)) * rect.height)
        let pdfLocation = pdfView.convert(location, from: self)
        guard let page = pdfView.page(for: pdfLocation, nearest: true) else {
            return MappedPDFPoint(page: nil, point: nil, viewLocation: location)
        }
        let pagePoint = pdfView.convert(pdfLocation, to: page)
        let pageBounds = page.bounds(for: .cropBox).insetBy(dx: -0.01, dy: -0.01)
        return pageBounds.contains(pagePoint)
            ? MappedPDFPoint(page: page, point: pagePoint, viewLocation: location)
            : MappedPDFPoint(page: nil, point: nil, viewLocation: location)
    }

    private func consumeMappedPoint(_ mapped: MappedPDFPoint) {
        guard let pdfView else { return }
        penPosition = mapped.point; penPage = mapped.page; penViewPosition = mapped.viewLocation
        if page == nil {
            // A page supplies a stable transform, never a clipping boundary for input.
            page = pdfView.page(for: pdfView.convert(mapped.viewLocation, from: self), nearest: true)
            strokeStartedAt = ProcessInfo.processInfo.systemUptime
        }
        guard let page else { return }
        extendStroke(to: pdfView.convert(pdfView.convert(mapped.viewLocation, from: self), to: page))
    }

    private let eraserRadius: CGFloat = 10

    private func erasureTargets(at location: NSPoint) -> (annotations: [(PDFPage, PDFAnnotation)], canvas: [CanvasInk]) {
        guard let pdfView else { return ([], []) }
        let pdfLocation = pdfView.convert(location, from: self)
        let radius = eraserRadius / max(pdfView.scaleFactor, 0.1)
        var annotations = [(PDFPage, PDFAnnotation)]()
        for target in pdfView.visiblePages {
            let point = pdfView.convert(pdfLocation, to: target)
            // Only the visible, page-clipped portion of a stroke is erasable.
            let crop = target.bounds(for: pdfView.displayBox)
            guard crop.insetBy(dx: -radius, dy: -radius).contains(point) else { continue }
            for annotation in target.annotations where annotation.shouldDisplay && inkIsNear(annotation, point: point, radius: radius) {
                annotations.append((target, annotation))
            }
        }
        let canvas = (reader?.canvasInk ?? []).filter { ink in
            let point = pdfView.convert(pdfLocation, to: ink.anchor)
            return ink.points.count == 1 ? hypot(point.x - ink.points[0].x, point.y - ink.points[0].y) <= radius
                : zip(ink.points, ink.points.dropFirst()).contains { distanceToSegment(point, $0.0, $0.1) <= radius }
        }
        return (annotations, canvas)
    }

    private func extendStroke(to point: NSPoint) {
        guard let pdfView, let page else { return }
        if erasing {
            let targets = erasureTargets(at: convert(pdfView.convert(point, from: page), from: pdfView))
            for target in targets.annotations where !pendingErasure.contains(where: { $0.1 === target.1 }) {
                pendingErasure.append(target)
            }
            for ink in targets.canvas where !pendingCanvasErasure.contains(where: { $0 === ink }) {
                pendingCanvasErasure.append(ink)
            }
        }
        if points.last.map({ hypot($0.x - point.x, $0.y - point.y) * pdfView.scaleFactor > 0.08 }) ?? true { points.append(point) }
        needsDisplay = true
    }

    func finishStroke(discardGesturePrelude: Bool = false) {
        let finishedPage = page, finishedPoints = points, erased = pendingErasure, canvasErased = pendingCanvasErasure
        page = nil; points = []; pendingErasure = []; pendingCanvasErasure = []
        let prelude = discardGesturePrelude && ProcessInfo.processInfo.systemUptime - strokeStartedAt < 0.12 && finishedPoints.allSatisfy { point in
            finishedPoints.first.map { hypot(point.x - $0.x, point.y - $0.y) * (pdfView?.scaleFactor ?? 1) < 3 } ?? true
        }
        guard let anchor = finishedPage, !finishedPoints.isEmpty, !prelude, let pdfView, let reader else { needsDisplay = true; return }
        reader.undoManager?.beginUndoGrouping()
        defer { reader.undoManager?.endUndoGrouping(); needsDisplay = true }
        if erasing {
            for (target, annotation) in erased where target.annotations.contains(where: { $0 === annotation }) {
                reader.change(annotation, on: target, adding: false)
            }
            for ink in canvasErased { reader.changeCanvas(ink, adding: false) }
        } else {
            let geometry = inkGeometry(finishedPoints, smoothing: smoothInk).map { pdfView.convert($0, from: anchor) }
            let pages = pdfView.visiblePages
            let rects = pages.map { pdfView.convert($0.bounds(for: .cropBox), from: $0) }
            for piece in partitionInk(geometry, rects: rects) {
                if let region = piece.region {
                    let target = pages[region]
                    reader.change(inkAnnotation(points: piece.points.map { pdfView.convert($0, to: target) }, page: target, color: inkColor, smoothing: false), on: target, adding: true)
                } else {
                    reader.changeCanvas(CanvasInk(anchor: anchor, points: piece.points.map { pdfView.convert($0, to: anchor) }, color: inkColor), adding: true)
                }
            }
            reader.undoManager?.setActionName("笔画")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = true
        NSBezierPath(rect: bounds).addClip()
        if let context = NSGraphicsContext.current?.cgContext {
            for page in pdfView.visiblePages {
                let origin = convert(pdfView.convert(NSPoint.zero, from: page), from: pdfView)
                let x = convert(pdfView.convert(NSPoint(x: 1, y: 0), from: page), from: pdfView)
                let y = convert(pdfView.convert(NSPoint(x: 0, y: 1), from: page), from: pdfView)
                context.saveGState()
                context.concatenate(CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                                                     c: y.x - origin.x, d: y.y - origin.y,
                                                     tx: origin.x, ty: origin.y))
                context.clip(to: page.bounds(for: pdfView.displayBox))
                for case let ink as VectorInkAnnotation in page.annotations
                    where ink.rendersInOverlay && ink.shouldDisplay {
                    if let paths = ink.paths { ink.drawVector(paths, in: context) }
                }
                context.restoreGState()
            }
        }
        for ink in reader?.canvasInk ?? [] {
            let path = inkPath(ink.points.map { convert(pdfView.convert($0, from: ink.anchor), from: pdfView) })
            path.lineWidth = inkWidth * pdfView.scaleFactor
            ink.color.setStroke()
            path.stroke()
        }
        if enabled || previewsRegion, let rect = regionViewRect {
            NSColor.systemBlue.withAlphaComponent(0.025).setFill()
            NSBezierPath(rect: rect).fill()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 1
            outline.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.systemBlue.withAlphaComponent(0.7).setStroke()
            outline.stroke()
            ((enabled ? "触控板书写区域" : "书写框预览 · Shift 开始批注") as NSString).draw(at: NSPoint(x: rect.minX + 6, y: rect.maxY + 5), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemBlue])
        }
        if let page, !points.isEmpty, !erasing {
            let path = inkPath(inkGeometry(points, smoothing: smoothInk).map { convert(pdfView.convert($0, from: page), from: pdfView) })
            path.lineWidth = inkWidth * pdfView.scaleFactor
            inkColor.setStroke()
            path.stroke()
        }
        if enabled, erasing, let location = penViewPosition {
            drawErasureFeedback(at: location)
        } else if let location = penViewPosition {
            let drawing = page != nil
            let radius: CGFloat = drawing ? 3 : 6
            let tip = NSBezierPath(ovalIn: NSRect(x: location.x - radius, y: location.y - radius, width: radius * 2, height: radius * 2))
            inkColor.set()
            tip.lineWidth = 1.5
            if drawing { tip.fill() } else { tip.stroke() }
        }
    }

    private func drawErasureFeedback(at location: NSPoint) {
        guard let pdfView else { return }
        let hovering = erasureTargets(at: location)
        let active = page != nil
        let tint = active ? NSColor.systemRed : NSColor.systemOrange
        let annotations = active ? pendingErasure : hovering.annotations
        let canvas = active ? pendingCanvasErasure : hovering.canvas
        let count = annotations.count + canvas.count
        func halo(_ path: NSBezierPath, width: CGFloat) {
            path.lineWidth = width + 6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            tint.withAlphaComponent(0.28).setStroke()
            path.stroke()
            path.lineWidth = width + 1
            tint.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
        for (target, annotation) in annotations {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: convert(pdfView.convert(target.bounds(for: pdfView.displayBox), from: target), from: pdfView)).addClip()
            let origin = convert(pdfView.convert(annotation.bounds.origin, from: target), from: pdfView)
            let x = convert(pdfView.convert(NSPoint(x: annotation.bounds.minX + 1, y: annotation.bounds.minY), from: target), from: pdfView)
            let y = convert(pdfView.convert(NSPoint(x: annotation.bounds.minX, y: annotation.bounds.minY + 1), from: target), from: pdfView)
            let transform = AffineTransform(m11: x.x - origin.x, m12: x.y - origin.y,
                                            m21: y.x - origin.x, m22: y.y - origin.y,
                                            tX: origin.x, tY: origin.y)
            for original in annotation.paths ?? [] {
                let path = original.copy() as! NSBezierPath
                path.transform(using: transform)
                halo(path, width: (annotation.border?.lineWidth ?? inkWidth) * pdfView.scaleFactor)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        for ink in canvas {
            halo(inkPath(ink.points.map { convert(pdfView.convert($0, from: ink.anchor), from: pdfView) }), width: inkWidth * pdfView.scaleFactor)
        }
        let ring = NSBezierPath(ovalIn: NSRect(x: location.x - eraserRadius, y: location.y - eraserRadius,
                                               width: eraserRadius * 2, height: eraserRadius * 2))
        NSColor.white.withAlphaComponent(0.7).setFill()
        ring.fill()
        (count > 0 ? tint : NSColor.secondaryLabelColor).setStroke()
        ring.lineWidth = 1.5
        if !active { ring.setLineDash([3, 2], count: 2, phase: 0) }
        ring.stroke()
        let message = count == 0 ? "橡皮 · 未命中" : (active ? "待擦 \(count) 笔 · 收笔生效" : "预览 \(count) 笔 · 整笔擦除")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = (message as NSString).size(withAttributes: attributes)
        let label = NSRect(x: min(max(bounds.minX + 4, location.x + 16), bounds.maxX - size.width - 16),
                           y: min(max(bounds.minY + 4, location.y + 16), bounds.maxY - size.height - 12),
                           width: size.width + 12, height: size.height + 8)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: label, xRadius: 5, yRadius: 5).fill()
        (message as NSString).draw(at: NSPoint(x: label.minX + 6, y: label.minY + 4), withAttributes: attributes)
    }

    func isNativeNavigation(_ event: NSEvent) -> Bool {
        switch event.type {
        case .scrollWheel, .magnify, .smartMagnify, .beginGesture, .endGesture, .rotate, .swipe: return true
        default: return false
        }
    }

    func prepareNativeNavigation(_ event: NSEvent) {
        guard !movingFrameSequence else { return }
        // Native events may arrive before raw contacts or after all fingers lift.
        // Do not gate navigation on the raw-contact count or drop momentum tails.
        if event.type == .scrollWheel || event.type == .magnify || event.type == .smartMagnify {
            finishStroke(discardGesturePrelude: true)
            interruptForNavigation()
        }
    }

    // Fallback for a gesture whose responder was captured before hit-testing changed.
    override func scrollWheel(with event: NSEvent) {
        guard !movingFrameSequence else { return }
        prepareNativeNavigation(event)
        pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event)
    }
    override func magnify(with event: NSEvent) {
        guard !movingFrameSequence else { return }
        prepareNativeNavigation(event)
        pdfView?.documentView?.enclosingScrollView?.magnify(with: event)
    }

    func forwardNativeNavigation(_ event: NSEvent) {
        guard !movingFrameSequence else { return }
        prepareNativeNavigation(event)
        guard let scroll = pdfView?.documentView?.enclosingScrollView else { return }
        switch event.type {
        case .scrollWheel: scroll.scrollWheel(with: event)
        case .magnify: scroll.magnify(with: event)
        case .smartMagnify: scroll.smartMagnify(with: event)
        case .beginGesture: scroll.beginGesture(with: event)
        case .endGesture: scroll.endGesture(with: event)
        default: break
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if mode == .writing { processContacts(contacts, previewing: event.modifierFlags.contains(.command), pressure: pressureMode ? rawPressure : nil) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { enabled = false } else { super.keyDown(with: event) }
    }
}

final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSPopoverDelegate {
    let pdfView = PDFView()
    let surface = InkSurface(frame: .zero)
    private let annotationButton = NSButton(title: "触控板批注", target: nil, action: nil)
    private let toolControl = NSButton(title: "画笔", target: nil, action: nil)
    private let settingsPopover = NSPopover()
    private let fillButton = NSButton(title: "铺满", target: nil, action: nil)
    private let layoutControl = NSSegmentedControl(labels: ["单栏", "双栏"], trackingMode: .selectOne, target: nil, action: nil)
    private let regionSlider = NSSlider(value: 100, minValue: 40, maxValue: 600, target: nil, action: nil)
    private let regionSizeLabel = NSTextField(labelWithString: "100%")
    private let inkModeControl = NSSegmentedControl(labels: ["轻触即写", "轻压绘画"], trackingMode: .selectOne, target: nil, action: nil)
    private let pressureSlider = NSSlider(value: 30, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let pressureLabel = NSTextField(labelWithString: "力度 30")
    private let releaseButton = NSButton(checkboxWithTitle: "减力收笔", target: nil, action: nil)
    private let smoothButton = NSButton(checkboxWithTitle: "笔迹平滑", target: nil, action: nil)
    private let colorWell = NSColorWell(frame: .zero)
    private let colorChoice = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inkPalette: [NSColor] = [defaultInkColor, .black, .systemRed, .systemGreen, .systemPurple]
    private let status = NSTextField(labelWithString: "阅读模式")
    private let pageLabel = NSTextField(labelWithString: "")
    private var observers = [NSObjectProtocol]()
    private weak var reader: TouchPDFDocument?
    private var fittedInitially = false

    init(reader: TouchPDFDocument) {
        let window = DrawingWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        self.reader = reader
        window.title = "TouchPDF"
        window.minSize = NSSize(width: 900, height: 500)
        window.acceptsMouseMovedEvents = true
        window.surface = surface
        window.delegate = self
        window.center()
        let root = TouchRootView(frame: .zero)
        root.surface = surface
        window.contentView = root
        prepareOverlayInk(reader.pdf)
        pdfView.document = reader.pdf
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysAsBook = false
        pdfView.autoScales = true
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 5
        surface.reader = reader
        surface.pdfView = pdfView
        surface.updateStatus = { [weak self] in self?.updateControls() }

        func button(_ title: String, _ action: Selector) -> NSButton {
            let result = NSButton(title: title, target: self, action: action)
            result.bezelStyle = .rounded
            return result
        }
        annotationButton.setButtonType(.pushOnPushOff)
        annotationButton.bezelStyle = .rounded
        annotationButton.target = self
        annotationButton.action = #selector(toggleAnnotation)
        annotationButton.toolTip = "单独按 Shift 开关批注，X 切换画笔 / 橡皮。开启后轻触定位、加力落笔，无需点击；双指滚动、捏合缩放、三指移框。Esc 返回阅读。"
        toolControl.toolTip = "点击或 X 切换画笔 / 橡皮，不改变批注开关。Shift 开关批注，Esc 返回阅读。"
        toolControl.bezelStyle = .rounded
        toolControl.imagePosition = .imageLeading
        toolControl.target = self
        toolControl.action = #selector(selectTool)
        layoutControl.selectedSegment = 0
        layoutControl.target = self
        layoutControl.action = #selector(selectLayout)
        layoutControl.setAccessibilityLabel("PDF 阅读布局")
        layoutControl.toolTip = "单栏或双栏连续阅读；只改变页面排版，不改变书写框映射。"
        func iconButton(_ title: String, _ symbol: String, _ help: String, _ action: Selector) -> NSButton {
            let control = button(title, action)
            control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            control.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            control.toolTip = help
            control.setAccessibilityLabel(help)
            return control
        }
        func divider() -> NSBox {
            let line = NSBox()
            line.boxType = .separator
            line.widthAnchor.constraint(equalToConstant: 1).isActive = true
            line.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return line
        }
        let bar = NSStackView(views: [
            iconButton("打开 ⌘O", "folder", "打开 PDF · ⌘O", #selector(openPDF)),
            iconButton("", "plus", "新建空白 · ⌘N", #selector(newBlank)),
            iconButton("保存 ⌘S", "square.and.arrow.down", "保存 · ⌘S / 另存为 ⇧⌘S", #selector(savePDF)),
            iconButton("⌘Z", "arrow.uturn.backward", "撤销 · ⌘Z", #selector(undoStroke)), divider(),
            layoutControl, divider(),
            iconButton("", "minus", "缩小 PDF", #selector(zoomOut)),
            iconButton("", "plus.magnifyingglass", "放大 PDF", #selector(zoomIn)),
            button("100%", #selector(actualSize)), button("适合宽度", #selector(fitPage)),
            iconButton("", "questionmark.circle", "快捷键与手势", #selector(showShortcuts))])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY
        regionSlider.target = self
        regionSlider.action = #selector(resizeWritingRegion)
        regionSlider.isContinuous = true
        regionSlider.setAccessibilityLabel("书写框大小")
        regionSlider.toolTip = "[ 缩小 / ] 放大，每次 10%。阅读模式也可调整。40–600%，等比例调整；“铺满”可覆盖整个阅读区，不受触控板长宽比限制。只改变书写框，不缩放 PDF 或已有笔迹。"
        regionSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        regionSizeLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        inkModeControl.selectedSegment = 1
        surface.pressureMode = true
        inkModeControl.target = self
        inkModeControl.action = #selector(selectInkMode)
        inkModeControl.setAccessibilityLabel("落笔方式")
        inkModeControl.toolTip = "轻压绘画：轻触预览，加力落笔，无需点击；可选择减力收笔或只在抬手时收笔。"
        pressureSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        pressureSlider.target = self
        pressureSlider.action = #selector(changePressureThreshold)
        pressureSlider.isContinuous = true
        pressureSlider.setAccessibilityLabel("轻压力度门槛")
        pressureSlider.toolTip = "往左更容易落笔；往右需要更多力度。收笔门槛自动保持为落笔门槛的一半。"
        pressureLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true
        if let saved = UserDefaults.standard.object(forKey: "pressureThreshold") as? NSNumber {
            surface.pressureThreshold = saved.floatValue
        }
        surface.releaseToPreview = UserDefaults.standard.object(forKey: "releaseToPreview") as? Bool ?? true
        surface.smoothInk = UserDefaults.standard.object(forKey: "smoothInk") as? Bool ?? true
        if let components = UserDefaults.standard.array(forKey: "inkColorRGB") as? [Double], components.count == 3,
           components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            surface.inkColor = NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1)
        }
        releaseButton.target = self
        releaseButton.action = #selector(changeReleaseMode)
        releaseButton.toolTip = "勾选：减力即可收笔并继续定位。取消：加力起笔后保持书写，直到抬手。"
        smoothButton.target = self
        smoothButton.action = #selector(changeSmoothing)
        smoothButton.toolTip = "保留细小移动，平滑曲线并保留公式尖角。预览和 PDF 使用相同矢量笔迹，放大时不会变成像素图。只影响新笔画。"
        colorWell.color = surface.inkColor
        colorWell.target = self
        colorWell.action = #selector(changeInkColor)
        colorWell.setAccessibilityLabel("笔颜色")
        colorWell.toolTip = "选择新笔画的颜色。已有笔画保留原颜色。"
        colorWell.widthAnchor.constraint(equalToConstant: 32).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        colorChoice.addItems(withTitles: ["蓝色  1", "黑色  2", "红色  3", "绿色  4", "紫色  5", "自定…"])
        colorChoice.target = self
        colorChoice.action = #selector(chooseInkColor)
        colorChoice.widthAnchor.constraint(equalToConstant: 96).isActive = true
        colorChoice.setAccessibilityLabel("常用笔颜色")
        syncColorChoice()
        NSColorPanel.shared.showsAlpha = false
        let centerButton = iconButton("居中 C", "scope", "书写框居中 · C；阅读模式仅预览", #selector(centerWritingRegion))
        fillButton.bezelStyle = .rounded
        fillButton.setButtonType(.pushOnPushOff)
        fillButton.target = self
        fillButton.action = #selector(toggleFillViewport)
        fillButton.toolTip = "将触控板映射到整个可见阅读区；再次点击恢复等比例书写框。铺满时横纵映射比例可能不同。"
        let settingsButton = iconButton("笔设置", "slider.horizontal.3", "力度、落笔方式与平滑设置", #selector(showPenSettings(_:)))
        let regionBar = NSStackView(views: [annotationButton, toolControl, colorChoice, colorWell, divider(), NSTextField(labelWithString: "书写区 [ ]"), regionSlider, regionSizeLabel, centerButton, fillButton, settingsButton])
        regionBar.orientation = .horizontal
        regionBar.spacing = 8
        regionBar.alignment = .centerY
        let modeRow = NSStackView(views: [NSTextField(labelWithString: "落笔方式"), inkModeControl])
        let pressureRow = NSStackView(views: [pressureSlider, pressureLabel, releaseButton])
        let settings = NSStackView(views: [modeRow, pressureRow, smoothButton])
        settings.orientation = .vertical
        settings.alignment = .leading
        settings.spacing = 16
        settings.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        let settingsController = NSViewController()
        let settingsContainer = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
        settings.translatesAutoresizingMaskIntoConstraints = false
        settingsContainer.addSubview(settings)
        NSLayoutConstraint.activate([
            settings.leadingAnchor.constraint(equalTo: settingsContainer.leadingAnchor),
            settings.topAnchor.constraint(equalTo: settingsContainer.topAnchor),
            settings.trailingAnchor.constraint(lessThanOrEqualTo: settingsContainer.trailingAnchor),
            settings.bottomAnchor.constraint(lessThanOrEqualTo: settingsContainer.bottomAnchor)
        ])
        settingsController.view = settingsContainer
        settingsPopover.contentViewController = settingsController
        settingsPopover.contentSize = NSSize(width: 380, height: 140)
        settingsPopover.behavior = .transient
        settingsPopover.delegate = self
        let separator = NSBox()
        separator.boxType = .separator
        let footer = NSStackView(views: [status, NSView(), pageLabel])
        footer.orientation = .horizontal
        footer.spacing = 12
        status.font = NSFont.systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        pageLabel.font = status.font
        pageLabel.textColor = status.textColor
        for view in [bar, regionBar, separator, pdfView, surface, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12), bar.heightAnchor.constraint(equalToConstant: 30),
            regionBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), regionBar.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6), regionBar.heightAnchor.constraint(equalToConstant: 24),
            regionBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor), separator.trailingAnchor.constraint(equalTo: root.trailingAnchor), separator.topAnchor.constraint(equalTo: regionBar.bottomAnchor, constant: 10), separator.heightAnchor.constraint(equalToConstant: 1),
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor), pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor), pdfView.topAnchor.constraint(equalTo: separator.bottomAnchor), pdfView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            surface.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor), surface.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor), surface.topAnchor.constraint(equalTo: pdfView.topAnchor), surface.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8), footer.heightAnchor.constraint(equalToConstant: 20)
        ])
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, NSWindow.didResignKeyNotification, NSWindow.willStartLiveResizeNotification] {
            let object: Any = name == .PDFViewPageChanged || name == .PDFViewScaleChanged ? pdfView : window
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                if name == NSWindow.didResignKeyNotification { self?.surface.suspendRawInput() }
                else if name == .PDFViewScaleChanged { self?.surface.pdfScaleChanged() }
                else { self?.surface.interruptForNavigation() }
                self?.updateControls()
                self?.surface.viewportChanged()
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let clip = self.pdfView.documentView?.enclosingScrollView?.contentView, note.object as? NSClipView === clip else { return }
            self.surface.viewportChanged()
        })
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func refresh() {
        pdfView.documentView?.needsDisplay = true
        pdfView.needsDisplay = true
        surface.needsDisplay = true
        updateControls()
    }
    private func prepareOverlayInk(_ document: PDFDocument) {
        for index in 0..<document.pageCount {
            for case let ink as VectorInkAnnotation in document.page(at: index)!.annotations where ink.contents == "TouchPDF" {
                ink.rendersInOverlay = true
            }
        }
    }
    private func updateControls() {
        annotationButton.state = surface.enabled ? .on : .off
        annotationButton.title = surface.enabled ? "暂停  ⇧" : "批注  ⇧"
        annotationButton.image = NSImage(systemSymbolName: surface.enabled ? "pause.fill" : "hand.draw", accessibilityDescription: nil)
        annotationButton.imagePosition = .imageLeading
        toolControl.isEnabled = true
        toolControl.title = surface.erasing ? "橡皮 X" : "画笔 X"
        toolControl.image = NSImage(systemSymbolName: surface.erasing ? "eraser" : "pencil.tip", accessibilityDescription: nil)
        toolControl.setAccessibilityLabel(surface.erasing ? "当前橡皮，点击切换画笔" : "当前画笔，点击切换橡皮")
        fillButton.state = surface.fillsViewport ? .on : .off
        layoutControl.selectedSegment = pdfView.displayMode == .twoUpContinuous || pdfView.displayMode == .twoUp ? 1 : 0
        layoutControl.isEnabled = true
        inkModeControl.isEnabled = true
        inkModeControl.selectedSegment = surface.pressureMode ? 1 : 0
        pressureSlider.isEnabled = surface.pressureMode
        pressureSlider.doubleValue = Double(surface.pressureThreshold)
        pressureLabel.stringValue = "力度 \(Int(surface.pressureThreshold))"
        releaseButton.isEnabled = surface.pressureMode
        releaseButton.state = surface.releaseToPreview ? .on : .off
        smoothButton.state = surface.smoothInk ? .on : .off
        regionSlider.isEnabled = true
        regionSlider.doubleValue = Double(surface.regionScale * 100)
        regionSizeLabel.stringValue = surface.fillsViewport ? "铺满" : "\(Int(surface.regionScale * 100))%"
        let releaseHint = surface.releaseToPreview ? "减力收笔" : "抬手收笔"
        status.stringValue = surface.enabled ? (surface.cursorHoldFailed ? "未能固定系统指针，请全部抬手后重试。" : (surface.inputNotice ?? (surface.pressureMode ? "加力落笔 · \(releaseHint) · Shift 暂停调工具 · X 换工具" : "单指书写 · ⌘ 预览 · Shift 暂停调工具 · X 换工具"))) : "阅读 / 调整工具 · Shift 批注 · X 换工具 · [ ] 框大小 · C 居中 · 1–5 颜色"
        if surface.enabled && surface.erasing && !surface.cursorHoldFailed && surface.inputNotice == nil {
            let action = surface.pressureMode ? "轻触预览 · 加力擦除" : "触摸擦除 · ⌘ 预览"
            status.stringValue = "橡皮 · \(action) · 整笔擦除 · X 换笔 · Shift 暂停 · ⌘Z 撤销"
        }
        if let page = pdfView.currentPage, let document = pdfView.document {
            pageLabel.stringValue = "\(document.index(for: page) + 1) / \(document.pageCount) · \(Int(pdfView.scaleFactor * 100))%"
        }
    }
    @objc func openPDF() { surface.resetInput(); NSDocumentController.shared.openDocument(nil) }
    @objc func newBlank() { surface.resetInput(); NSDocumentController.shared.newDocument(nil) }
    @objc func savePDF() { surface.finishStroke(); reader?.save(nil) }
    @objc func toggleAnnotation() { surface.enabled.toggle(); window?.makeFirstResponder(surface.enabled ? surface : pdfView) }
    @objc func selectTool() { surface.finishStroke(); surface.erasing.toggle(); updateControls() }
    @objc func selectLayout() {
        surface.interruptForNavigation()
        pdfView.displayMode = layoutControl.selectedSegment == 1 ? .twoUpContinuous : .singlePageContinuous
        pdfView.layoutDocumentView()
        pdfView.autoScales = false
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, pdfView.scaleFactorForSizeToFit))
        surface.viewportChanged()
        updateControls()
    }
    @objc func selectInkMode() { surface.pressureMode = inkModeControl.selectedSegment == 1 }
    @objc func changePressureThreshold() {
        surface.pressureThreshold = Float(pressureSlider.doubleValue)
        UserDefaults.standard.set(surface.pressureThreshold, forKey: "pressureThreshold")
    }
    @objc func changeReleaseMode() {
        surface.releaseToPreview = releaseButton.state == .on
        UserDefaults.standard.set(surface.releaseToPreview, forKey: "releaseToPreview")
    }
    @objc func changeSmoothing() {
        surface.smoothInk = smoothButton.state == .on
        UserDefaults.standard.set(surface.smoothInk, forKey: "smoothInk")
    }
    @objc func changeInkColor() {
        let color = colorWell.color.usingColorSpace(.sRGB) ?? defaultInkColor
        surface.inkColor = color.withAlphaComponent(1)
        UserDefaults.standard.set([Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)], forKey: "inkColorRGB")
        syncColorChoice()
    }
    @objc func chooseInkColor() {
        guard inkPalette.indices.contains(colorChoice.indexOfSelectedItem) else {
            colorWell.activate(true)
            NSColorPanel.shared.orderFront(nil)
            return
        }
        colorWell.color = inkPalette[colorChoice.indexOfSelectedItem]
        changeInkColor()
    }
    private func syncColorChoice() {
        let color = surface.inkColor.usingColorSpace(.sRGB)!
        let index = inkPalette.firstIndex { candidate in
            let value = candidate.usingColorSpace(.sRGB)!
            return abs(value.redComponent - color.redComponent) < 0.001 && abs(value.greenComponent - color.greenComponent) < 0.001 && abs(value.blueComponent - color.blueComponent) < 0.001
        }
        colorChoice.selectItem(at: index ?? inkPalette.count)
    }
    @objc func undoStroke() { surface.finishStroke(); reader?.undoManager?.undo() }
    @objc func centerWritingRegion() {
        surface.centerRegion()
        surface.previewsRegion = !surface.enabled
        if surface.enabled { window?.makeFirstResponder(surface) }
    }
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        "\(displayName) — TouchPDF \(touchPDFBuild)"
    }
    @objc func resizeWritingRegion() {
        let selectedScale = CGFloat(regionSlider.doubleValue / 100)
        surface.fillsViewport = false
        surface.regionScale = selectedScale
        surface.previewsRegion = !surface.enabled
    }
    func adjustRegionSize(by delta: CGFloat) {
        regionSlider.doubleValue = Double(min(6, max(0.4, surface.regionScale + delta)) * 100)
        resizeWritingRegion()
    }
    func selectPaletteColor(_ index: Int) {
        guard inkPalette.indices.contains(index) else { return }
        colorChoice.selectItem(at: index)
        chooseInkColor()
    }
    @objc func toggleFillViewport() {
        surface.fillsViewport.toggle()
        surface.previewsRegion = !surface.enabled
    }
    @objc func showPenSettings(_ sender: NSButton) {
        if settingsPopover.isShown { settingsPopover.close(); return }
        surface.editingPenSettings = true
        settingsPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) { surface.editingPenSettings = false }
    @objc func actualSize() {
        surface.interruptForNavigation()
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
    }
    @objc func showShortcuts() {
        surface.suspendRawInput()
        let alert = NSAlert()
        alert.messageText = "触控板与键盘操作"
        alert.informativeText = "Shift（单按松开）：开关批注\nEsc：返回阅读\nX：切换当前工具，保持批注开关\n[ / ]：缩小 / 放大书写框\nC：书写框居中\n1–5：蓝、黑、红、绿、紫\n\n⌘O 打开 · ⌘N 新建 · ⌘S 保存\n⇧⌘S 另存为 · ⌘Z 撤销 · ⇧⌘Z 重做\n⌘W 关闭文档 · ⌘Q 退出\n\n先按 Shift 暂停，就能用触控板调整工具栏；调整后再按 Shift 继续。颜色、框大小和居中不会开启批注。\n双指滚动 · 捏合缩放 · 三指移框\n橡皮：虚线圈定位，橙色预览；加力后红色标出待擦笔画，收笔生效。整笔擦除，⌘Z 可撤销。\n输入框中不触发工具快捷键。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
        surface.configureRawInput()
    }
    @objc func zoomIn() { surface.interruptForNavigation(); pdfView.autoScales = false; pdfView.zoomIn(nil) }
    @objc func zoomOut() { surface.interruptForNavigation(); pdfView.autoScales = false; pdfView.zoomOut(nil) }
    @objc func fitPage() { surface.interruptForNavigation(); pdfView.autoScales = true; pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        fitInitially()
    }
    func windowDidBecomeKey(_ notification: Notification) { fitInitially(); surface.configureRawInput() }
    private func fitInitially() {
        if !fittedInitially {
            fittedInitially = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.contentView?.layoutSubtreeIfNeeded()
                self.pdfView.autoScales = false
                self.pdfView.scaleFactor = self.pdfView.scaleFactorForSizeToFit
                self.pdfView.layoutDocumentView()
                if let page = self.pdfView.document?.page(at: 0) {
                    let rect = page.bounds(for: .cropBox)
                    self.pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: rect.minX, y: rect.maxY)))
                }
                self.pdfView.documentView?.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
                self.updateControls()
            }
        }
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { reader?.undoManager }
    func windowWillClose(_ notification: Notification) { surface.suspendRawInput() }
}

final class TouchDocumentController: NSDocumentController {
    private(set) var pendingDocumentOpens = 0
    override func documentClass(forType typeName: String) -> AnyClass? { TouchPDFDocument.self }
    override var defaultType: String? { pdfType }
    override func openDocument(withContentsOf url: URL, display: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        pendingDocumentOpens += 1
        super.openDocument(withContentsOf: url, display: display) { document, alreadyOpen, error in
            self.pendingDocumentOpens -= 1
            completionHandler(document, alreadyOpen, error)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var startupPanel: NSOpenPanel?
    private var resolvingInstances = true
    private var otherInstances: [NSRunningApplication] {
        // Use this bundle's identifier so isolated development builds stay isolated.
        guard let identifier = Bundle.main.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in self?.resolveOtherInstances() }
    }
    private func finishStartup() {
        resolvingInstances = false
        NSApp.activate(ignoringOtherApps: true)
        if NSDocumentController.shared.documents.isEmpty { chooseStartingDocument() }
    }
    private func resolveOtherInstances() {
        let others = otherInstances
        guard !others.isEmpty else { finishStartup(); return }
        let alert = NSAlert()
        alert.messageText = "已有其他 TouchPDF 正在运行"
        alert.informativeText = "本次启动的是 \(touchPDFBuild)。先让其他进程正常退出，避免误用旧版。若出现保存提示，请在对应窗口处理；取消保存退出时，本次启动也可取消。\n\n" + others.map { "PID \($0.processIdentifier) · \($0.bundleURL?.path ?? "未知位置")" }.joined(separator: "\n")
        alert.addButton(withTitle: "请求退出其他版本")
        alert.addButton(withTitle: "取消本次启动")
        guard alert.runModal() == .alertFirstButtonReturn else { quitCurrent(nil); return }
        // terminate() sends a normal quit request. Never use forceTerminate().
        for application in others { _ = application.terminate() }
        waitForOtherInstances(remainingChecks: 8)
    }
    private func waitForOtherInstances(remainingChecks: Int) {
        guard !otherInstances.isEmpty else { finishStartup(); return }
        guard remainingChecks > 0 else {
            let alert = NSAlert()
            alert.messageText = "其他 TouchPDF 尚未退出"
            alert.informativeText = "请完成其他窗口的保存或退出操作。不会强制关闭或丢弃笔迹。"
            alert.addButton(withTitle: "重新检查")
            alert.addButton(withTitle: "取消本次启动")
            if alert.runModal() == .alertFirstButtonReturn { waitForOtherInstances(remainingChecks: 8) }
            else { quitCurrent(nil) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForOtherInstances(remainingChecks: remainingChecks - 1)
        }
    }
    @objc func showBuild(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "TouchPDF \(touchPDFBuild)"
        alert.informativeText = "运行位置：\(Bundle.main.bundleURL.path)\n\nShift：切换批注\nB：笔　E：橡皮　Esc：阅读\n⌘Q：退出当前应用（保留保存提示）"
        alert.runModal()
    }
    @objc func quitCurrent(_ sender: Any?) {
        for document in NSDocumentController.shared.documents {
            for controller in document.windowControllers { (controller as? ReaderWindowController)?.surface.suspendRawInput() }
        }
        // NSDocumentController owns the unsaved-document review. Do not bypass it.
        NSApp.terminate(sender)
        // A cancelled save/quit must leave the current window usable.
        (NSApp.keyWindow?.windowController as? ReaderWindowController)?.surface.configureRawInput()
    }
    @objc func quitAll(_ sender: Any?) {
        for application in otherInstances { _ = application.terminate() }
        quitCurrent(sender)
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // An open panel can be the last window while NSDocumentController is
        // still reading a PDF. Closing that panel must not terminate the app.
        !resolvingInstances && startupPanel == nil &&
            (NSDocumentController.shared as? TouchDocumentController)?.pendingDocumentOpens == 0
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !resolvingInstances, !flag, NSDocumentController.shared.documents.isEmpty { chooseStartingDocument() }
        return true
    }
    private func chooseStartingDocument() {
        guard startupPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开 PDF"
        panel.message = "TouchPDF \(touchPDFBuild) · 选择 PDF，或新建空白画布。"
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        let blankButton = NSButton(title: "新建空白画布", target: self, action: #selector(blankFromPicker))
        blankButton.bezelStyle = .rounded
        blankButton.frame = NSRect(x: 0, y: 4, width: 150, height: 30)
        accessory.addSubview(blankButton)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        startupPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                // Retain the startup guard until the document window exists.
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error {
                        NSApplication.shared.presentError(error)
                        self.startupPanel = nil
                        if NSDocumentController.shared.documents.isEmpty { self.chooseStartingDocument() }
                    } else {
                        self.startupPanel = nil
                    }
                }
            } else {
                // The blank-canvas button also cancels this panel, then creates
                // a document synchronously. Check on the next turn so only an
                // actual Cancel with no open documents exits the application.
                DispatchQueue.main.async {
                    self.startupPanel = nil
                    if NSDocumentController.shared.documents.isEmpty { self.quitCurrent(nil) }
                }
            }
        }
    }
    @objc private func blankFromPicker() {
        startupPanel?.cancel(nil)
        NSDocumentController.shared.newDocument(nil)
    }
    func applicationWillResignActive(_ notification: Notification) {
        for document in NSDocumentController.shared.documents {
            for controller in document.windowControllers { (controller as? ReaderWindowController)?.surface.suspendRawInput() }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        (NSApp.keyWindow?.windowController as? ReaderWindowController)?.surface.configureRawInput()
    }
    func applicationWillTerminate(_ notification: Notification) { RawTrackpadInput.shared.stop(); _ = CGAssociateMouseAndMouseCursorPosition(1) }
    @objc func runChecks(_ sender: Any?) {
        let alert = NSAlert()
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TouchPDF/Checks", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try selfTest(outputURL: directory.appendingPathComponent("verified-annotations.pdf"))
            try "PASS: cross-page canvas, outside/gutter ink, transform tracking, grouped undo/redo, gutter eraser, clipped repeatable PDF export, pressure release/lift latch, threshold/hysteresis, gesture interruption, stream recovery, fine sampling, smoothing, colored vectors, absolute input, cursor restoration, invalid PDF rejection\n".write(to: directory.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
            alert.messageText = "自检通过"
            alert.informativeText = "跨页与页外笔迹、滚动缩放跟随、整笔撤销、页缝擦除、PDF 保存裁切，以及轻压输入与笔迹检查通过。真实触控板手感需另行试用。"
        } catch {
            alert.messageText = "自检失败"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}

func makeMenu() {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu(title: "TouchPDF")
    let about = appMenu.addItem(withTitle: "关于 TouchPDF / 当前版本…", action: #selector(AppDelegate.showBuild(_:)), keyEquivalent: "")
    about.target = NSApplication.shared.delegate
    appMenu.addItem(.separator())
    let quit = appMenu.addItem(withTitle: "退出 TouchPDF", action: #selector(AppDelegate.quitCurrent(_:)), keyEquivalent: "q")
    quit.target = NSApplication.shared.delegate
    let quitAll = appMenu.addItem(withTitle: "退出所有 TouchPDF", action: #selector(AppDelegate.quitAll(_:)), keyEquivalent: "")
    quitAll.target = NSApplication.shared.delegate
    appItem.submenu = appMenu
    menu.addItem(appItem)
    let fileItem = NSMenuItem()
    let file = NSMenu(title: "文件")
    file.addItem(withTitle: "打开…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
    file.addItem(withTitle: "新建空白画布", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
    file.addItem(withTitle: "保存", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
    let saveAs = file.addItem(withTitle: "另存为…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
    saveAs.keyEquivalentModifierMask = [.command, .shift]
    file.addItem(.separator())
    file.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = file
    menu.addItem(fileItem)
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "编辑")
    edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editItem.submenu = edit
    menu.addItem(editItem)
    let toolsItem = NSMenuItem()
    let drawing = NSMenu(title: "批注")
    // Shift alone is a modifier event, handled by DrawingWindow rather than a menu equivalent.
    drawing.addItem(withTitle: "切换触控板批注（Shift）", action: #selector(ReaderWindowController.toggleAnnotation), keyEquivalent: "")
    drawing.addItem(withTitle: "切换画笔 / 橡皮（X）", action: #selector(ReaderWindowController.selectTool), keyEquivalent: "")
    drawing.addItem(withTitle: "书写框居中（C）", action: #selector(ReaderWindowController.centerWritingRegion), keyEquivalent: "")
    toolsItem.submenu = drawing
    menu.addItem(toolsItem)
    let helpItem = NSMenuItem()
    let help = NSMenu(title: "帮助")
    let checks = help.addItem(withTitle: "运行自检", action: #selector(AppDelegate.runChecks(_:)), keyEquivalent: "")
    checks.target = NSApplication.shared.delegate
    helpItem.submenu = help
    menu.addItem(helpItem)
    NSApplication.shared.mainMenu = menu
}

extension InkSurface {
    static func checkEraserFeedback() {
        let document = TouchPDFDocument()
        document.undoManager?.groupsByEvent = false
        let controller = ReaderWindowController(reader: document)
        document.addWindowController(controller)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let surface = controller.surface, viewer = controller.pdfView
        let page = document.pdf.page(at: 0)!
        viewer.autoScales = false
        viewer.scaleFactor = 1
        viewer.layoutDocumentView()
        for offset: CGFloat in [-3, 3] {
            page.addAnnotation(inkAnnotation(points: [NSPoint(x: 90, y: 400 + offset), NSPoint(x: 170, y: 400 + offset)], page: page))
        }
        let outside = CanvasInk(anchor: page, points: [NSPoint(x: -25, y: 390), NSPoint(x: -25, y: 420)], color: .blue)
        document.canvasInk.append(outside)
        surface.pressureMode = true
        surface.enabled = true
        surface.erasing = true
        surface.testRegion(NSRect(x: 80, y: 380, width: 100, height: 40), on: page)
        let contact = TouchContact(identity: "eraser-feedback" as NSString, position: NSPoint(x: 0.5, y: 0.5))
        surface.processContacts([contact], pressure: 0)
        let preview = surface.erasureTargets(at: surface.penViewPosition!)
        precondition(preview.annotations.count == 2 && surface.pendingErasure.isEmpty && page.annotations.count == 2,
                     "hover must identify overlapping strokes without erasing them")
        func feedbackPixels() -> Int {
            let width = Int(surface.bounds.width), height = Int(surface.bounds.height)
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.white.cgColor)
            context.fill(surface.bounds)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            surface.drawErasureFeedback(at: surface.penViewPosition!)
            NSGraphicsContext.restoreGraphicsState()
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<(width * height)).filter { bytes[$0 * 4] > 150 && Int(bytes[$0 * 4]) > Int(bytes[$0 * 4 + 2]) + 60 }.count
        }
        precondition(feedbackPixels() > 150, "hover highlight was not visibly drawn")
        surface.processContacts([contact], pressure: 60)
        precondition(surface.pendingErasure.count == preview.annotations.count && page.annotations.count == 2,
                     "preview and pending erase selection disagree")
        precondition(feedbackPixels() > 150, "pending erase highlight was not visibly drawn")
        surface.processContacts([])
        precondition(page.annotations.isEmpty && surface.pendingErasure.isEmpty)
        document.undoManager?.undo()
        precondition(page.annotations.count == 2, "one undo did not restore all highlighted strokes")
        for scale: CGFloat in [0.6, 2] {
            viewer.scaleFactor = scale
            viewer.layoutDocumentView()
            let hit = surface.convert(viewer.convert(NSPoint(x: 130, y: 400), from: page), from: viewer)
            precondition(surface.erasureTargets(at: hit).annotations.count == 2, "zoom changed preview hit mapping")
        }
        viewer.scaleFactor = 1
        viewer.layoutDocumentView()
        surface.testRegion(NSRect(x: -35, y: 390, width: 20, height: 30), on: page)
        surface.processContacts([contact], pressure: 0)
        precondition(surface.erasureTargets(at: surface.penViewPosition!).canvas.count == 1 && document.canvasInk.count == 1)
        surface.processContacts([contact], pressure: 60)
        precondition(surface.pendingCanvasErasure.count == 1)
        surface.processContacts([])
        precondition(document.canvasInk.isEmpty)
        document.undoManager?.undo()
        precondition(document.canvasInk.count == 1)
        surface.enabled = false
        document.removeWindowController(controller)
        print("PASS: eraser hover and pending highlights rendered, overlapping strokes, preview/commit agreement, zoom, outside ink, grouped undo")
    }
    func checkFullViewportMapping() {
        precondition(fillsViewport)
        precondition(regionViewRect == bounds.insetBy(dx: 2, dy: 2), "full frame left unused space")
        let first = mappedPDFPoint(.zero)!.viewLocation
        let last = mappedPDFPoint(NSPoint(x: 1, y: 1))!.viewLocation
        precondition(first == NSPoint(x: 2, y: 2) && last == NSPoint(x: bounds.maxX - 2, y: bounds.maxY - 2))
        let original = frame.size
        setFrameSize(NSSize(width: 1500, height: 400))
        precondition(regionViewRect == bounds.insetBy(dx: 2, dy: 2), "full frame did not follow resize")
        setFrameSize(original)
    }
    func checkToolChangeDuringStroke(_ controller: ReaderWindowController) {
        let document = reader!
        func count() -> Int {
            (0..<document.pdf.pageCount).reduce(document.canvasInk.count) {
                $0 + document.pdf.page(at: $1)!.annotations.count
            }
        }
        let initialCount = count()
        let contact = TouchContact(identity: "shortcut" as NSString, position: NSPoint(x: 0.5, y: 0.5))
        if erasing { controller.selectTool() }
        if !enabled { controller.toggleAnnotation() }
        processContacts([contact])
        precondition(!points.isEmpty, "shortcut test did not start a stroke")
        controller.selectTool()
        precondition(count() == initialCount + 1, "switching to eraser discarded unfinished ink")
        processContacts([])
        processContacts([contact])
        controller.selectTool()
        precondition(count() == initialCount, "switching to pen lost pending erasure")
        processContacts([])
    }
    private func testRegion(_ rect: NSRect, on page: PDFPage) {
        writingViewRect = convert(pdfView!.convert(rect, from: page), from: pdfView!)
    }

    func checkLightPressure() {
        let document = TouchPDFDocument()
        document.undoManager?.disableUndoRegistration()
        let viewer = PDFView(frame: bounds)
        viewer.document = document.pdf
        viewer.scaleFactor = 1
        viewer.layoutDocumentView()
        viewer.addSubview(self)
        reader = document; pdfView = viewer
        pressureMode = true; enabled = true
        let target = document.pdf.page(at: 0)!
        regionScale = 248 / 440
        testRegion(NSRect(x: 100, y: 180, width: 248, height: 160), on: target)
        func contact(_ id: String, _ x: CGFloat, _ y: CGFloat) -> TouchContact {
            TouchContact(identity: id as NSString, position: NSPoint(x: x, y: y))
        }
        func at(_ x: CGFloat, _ y: CGFloat, _ value: Float) {
            processContacts([contact("a", x, y)], pressure: value)
        }
        at(0.1, 0.1, 9)
        at(0.7, 0.6, 29)
        precondition(points.isEmpty && penPosition != nil, "light contact or preview created ink")
        at(0.7, 0.6, 30)
        precondition(privateDrawing && points.count == 1 && abs(points[0].x - 273.6) < 0.01, "threshold did not start at the current absolute position")
        at(0.8, 0.6, 20)
        precondition(points.count == 2, "hysteresis did not sustain drawing")
        at(0.9, 0.6, 15)
        precondition(!privateDrawing && points.isEmpty && target.annotations.count == 1 && contacts.count == 1, "减力必须在未抬手时收笔")
        at(0.2, 0.2, 29)
        precondition(points.isEmpty, "preview motion joined a stroke")
        at(0.2, 0.2, 30)
        at(0.3, 0.2, 31)
        processContacts([])
        precondition(target.annotations.count == 2 && !privateDrawing, "lift did not commit and clear state")
        precondition(!target.annotations.contains { inkIsNear($0, point: NSPoint(x: 211.6, y: 244), radius: 2) }, "pressure cycles connected across preview")

        // Crossing below Ton but staying above Toff must not split a continuous stroke.
        at(0.5, 0.5, 30)
        for (index, value) in [Float(29), 31, 16, 29, 31].enumerated() { at(0.5 + CGFloat(index + 1) * 0.02, 0.5, value) }
        precondition(target.annotations.count == 2 && points.count == 6)
        at(0.7, 0.5, 15)
        precondition(target.annotations.count == 3 && points.isEmpty)
        processContacts([])

        // A multi-finger gesture cancels the initial dot and blocks the remaining finger.
        at(0.5, 0.5, 60)
        processContacts([contact("a", 0.5, 0.5), contact("b", 0.6, 0.5)], pressure: nil)
        at(0.6, 0.5, 60)
        precondition(points.isEmpty && target.annotations.count == 3, "gesture left a dot or resumed ink")
        processContacts([])
        at(0.1, 0.8, 60)
        at(0.2, 0.8, 60)
        rawInputInterrupted()
        at(0.4, 0.8, 60)
        precondition(points.isEmpty && !privateDrawing && !cursorHeld, "stream loss did not stop drawing/release pointer")
        processContacts([])
        at(0.5, 0.8, 60)
        precondition(points.count == 1, "fresh contact did not recover after interruption")
        processContacts([])

        let count = target.annotations.count
        erasing = true
        at(0.7, 0.6, 9)
        processContacts([])
        precondition(target.annotations.count == count, "eraser preview removed ink")
        at(0.7, 0.6, 31)
        at(0.7, 0.6, 15)
        precondition(target.annotations.count == count - 1, "pressure eraser did not commit on release")
        processContacts([])
        erasing = false
        releaseToPreview = false
        let beforeLatched = target.annotations.count
        at(0.1, 0.3, 9)
        at(0.2, 0.3, 30)
        at(0.3, 0.3, 0)
        precondition(privateDrawing && points.count == 2 && target.annotations.count == beforeLatched, "disabled pressure release did not latch until lift")
        processContacts([])
        precondition(!privateDrawing && points.isEmpty && target.annotations.count == beforeLatched + 1, "latched stroke did not finish on lift")
        at(0.4, 0.3, 9)
        precondition(points.isEmpty, "next contact inherited pressure latch")
        processContacts([])
        at(0.4, 0.3, 30)
        releaseToPreview = true
        at(0.5, 0.3, 30)
        precondition(points.isEmpty && !privateDrawing, "changing release mode resumed ink under an active finger")
        resetInput(); enabled = false; pressureMode = false
        var raw = ProbeTouch()
        raw.state = 4; raw.pressure = 20; raw.normalized.position = ProbePoint(x: 0.5, y: 0.5)
        precondition(MemoryLayout<ProbeTouch>.stride == 96 && MemoryLayout<ProbeTouch>.offset(of: \.pressure) == 52)
        precondition(RawTrackpadInput.valid(raw))
        raw.pressure = .nan
        precondition(!RawTrackpadInput.valid(raw), "invalid raw pressure accepted")
        raw.pressure = 20; raw.normalized.position.x = 2
        precondition(!RawTrackpadInput.valid(raw), "invalid raw coordinate accepted")
    }

    func checkPenSettings() {
        let document = TouchPDFDocument()
        document.undoManager?.disableUndoRegistration()
        let viewer = PDFView(frame: bounds)
        viewer.document = document.pdf
        viewer.minScaleFactor = 0.25; viewer.maxScaleFactor = 5
        viewer.scaleFactor = 2
        viewer.layoutDocumentView()
        viewer.addSubview(self)
        reader = document; pdfView = viewer
        enabled = true
        let target = document.pdf.page(at: 0)!
        testRegion(NSRect(x: 100, y: 180, width: 248, height: 160), on: target)
        regionScale = 1.6
        let oldWidth = regionViewRect!.width
        regionScale = 3
        precondition(regionViewRect!.width > oldWidth * 1.3 && abs(viewer.scaleFactor - 2) < 0.01, "larger region did not expand independently of PDF zoom")
        precondition(bounds.contains(writingViewRect), "large region escaped the viewport")
        testRegion(NSRect(x: 100, y: 180, width: 248, height: 160), on: target)
        viewer.scaleFactor = 5
        viewer.layoutDocumentView()
        viewer.go(to: PDFDestination(page: target, at: NSPoint(x: 100, y: 400)))
        testRegion(NSRect(x: 100, y: 180, width: 100, height: 64.516129), on: target)
        func at(_ x: CGFloat, _ y: CGFloat) {
            processContacts([TouchContact(identity: "pen" as NSString, position: NSPoint(x: x, y: y))])
        }
        at(0.1, 0.1)
        at(0.1004, 0.1)
        precondition(points.count == 2, "fine motion was discarded at high zoom")
        let blue = inkColor
        inkColor = .systemRed
        precondition(points.isEmpty && target.annotations.count == 1 && target.annotations[0].color == blue, "color change recolored the active old stroke")
        processContacts([])
        at(0.2, 0.2)
        at(0.3, 0.3)
        processContacts([])
        precondition(target.annotations.count == 2 && target.annotations[1].color == inkColor, "new stroke did not use selected color")
        enabled = false
    }

    func checkAbsoluteInput() {
        let document = TouchPDFDocument()
        document.pdf = samplePDF()
        document.undoManager?.disableUndoRegistration()
        let pdf = document.pdf
        let viewer = PDFView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        viewer.document = pdf
        viewer.displayMode = .singlePageContinuous
        viewer.minScaleFactor = 0.25
        viewer.maxScaleFactor = 5
        viewer.scaleFactor = 1
        viewer.layoutDocumentView()
        viewer.addSubview(self)
        pdfView = viewer
        reader = document
        requiresPress = false
        enabled = true
        let firstPage = pdf.page(at: 0)!
        regionScale = 248 / 440
        testRegion(NSRect(x: 100, y: 180, width: 248, height: 160), on: firstPage)
        func contact(_ id: String, _ x: CGFloat, _ y: CGFloat) -> TouchContact {
            TouchContact(identity: id as NSString, position: NSPoint(x: x, y: y))
        }
        func near(_ a: NSPoint?, _ b: NSPoint) -> Bool { a.map { hypot($0.x - b.x, $0.y - b.y) < 0.01 } ?? false }
        processContacts([contact("a", 0.2, 0.8)])
        precondition(near(points.first, NSPoint(x: 149.6, y: 308)), "absolute first contact")
        let mouse = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 590, y: 20), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        mouseMoved(with: mouse)
        precondition(near(points.last, NSPoint(x: 149.6, y: 308)), "external pointer changed ink")
        processContacts([contact("a", 0.3, 0.7)])
        processContacts([])
        precondition(firstPage.annotations.count == 1)
        processContacts([contact("a", 0.8, 0.2)])
        precondition(points.count == 1 && near(points.first, NSPoint(x: 298.4, y: 212)), "new contact inherited previous endpoint")
        processContacts([])
        precondition(firstPage.annotations.count == 2)
        precondition(!firstPage.annotations.contains { inkIsNear($0, point: NSPoint(x: 236.4, y: 252), radius: 2) }, "lifted strokes connected")

        // Sequential finger landing must not leave a dot; lifting two of three must not resume writing.
        processContacts([contact("a", 0.5, 0.5)])
        processContacts([contact("a", 0.5, 0.5), contact("b", 0.6, 0.5)])
        processContacts([contact("a", 0.5, 0.5)])
        processContacts([])
        precondition(firstPage.annotations.count == 2 && points.isEmpty)
        processContacts([contact("a", 0.2, 0.2)])
        processContacts([contact("a", 0.6, 0.2)])
        processContacts([contact("a", 0.6, 0.2), contact("b", 0.7, 0.2), contact("c", 0.8, 0.2)])
        precondition(firstPage.annotations.count == 3, "existing stroke lost at gesture switch")
        processContacts([])

        let oldRect = writingViewRect
        processContacts([contact("a", 0.2, 0.4), contact("b", 0.4, 0.4), contact("c", 0.6, 0.4)])
        precondition(movingFrameSequence, "three fingers did not own navigation")
        processContacts([contact("c", 0.7, 0.5), contact("a", 0.3, 0.5), contact("b", 0.5, 0.5)])
        precondition(near(writingViewRect.origin, NSPoint(x: oldRect.minX + 24.8, y: oldRect.minY + 16)), "three-finger movement or identity ordering")
        processContacts([contact("a", 0.3, 0.5)])
        processContacts([])
        precondition(firstPage.annotations.count == 3)
        precondition(!movingFrameSequence, "frame gesture remained locked after all fingers lifted")

        let frameWidth = regionViewRect!.width
        regionScale *= 1.25
        precondition(abs(viewer.scaleFactor - 1) < 0.01 && abs(regionViewRect!.width - frameWidth * 1.25) < 0.01, "region slider changed PDF zoom")
        precondition(firstPage.annotations.count == 3)
        regionScale /= 1.25
        processContacts([contact("a", 0.25, 0.5), contact("b", 0.75, 0.5)])
        processContacts([contact("b", 0.875, 0.5), contact("a", 0.125, 0.5)])
        precondition(abs(viewer.scaleFactor - 1) < 0.01, "raw contact separation must not zoom PDF")
        precondition(abs(regionViewRect!.width - frameWidth) < 0.01, "PDF zoom changed the screen size of the region")
        precondition(inkIsNear(firstPage.annotations[0], point: NSPoint(x: 149.6, y: 308), radius: 1), "scaling moved existing ink")
        let savedRect = writingViewRect
        processContacts([])
        viewer.go(to: PDFDestination(page: firstPage, at: NSPoint(x: 200, y: 450)))
        viewportChanged()
        precondition(writingViewRect == savedRect, "scroll moved the overlay frame")
        firstPage.rotation = 90
        viewer.layoutDocumentView()
        viewportChanged()
        precondition(writingViewRect == savedRect, "page rotation moved the overlay frame")
        firstPage.rotation = 0
        viewer.scaleFactor = 1
        viewer.layoutDocumentView()
        pdfScaleChanged()
        viewer.go(to: PDFDestination(page: firstPage, at: NSPoint(x: 0, y: 792)))
        testRegion(NSRect(x: 100, y: 180, width: 248, height: 160), on: firstPage)
        processContacts([contact("a", 0.4, 0.5)], previewing: true)
        precondition(points.isEmpty && penPosition != nil)
        processContacts([])
        precondition(firstPage.annotations.count == 3, "preview left ink")
        testRegion(NSRect(x: 100, y: 180, width: 248, height: 160), on: firstPage)
        erasing = true
        processContacts([contact("a", 0.2, 0.8)])
        processContacts([contact("a", 0.2, 0.8), contact("b", 0.6, 0.8)])
        processContacts([])
        precondition(firstPage.annotations.count == 3, "gesture prelude erased ink")
        processContacts([contact("a", 0.2, 0.8)])
        processContacts([])
        precondition(firstPage.annotations.count == 2, "touch eraser missed ink")
        erasing = false
        let ordinaryClick = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 300, y: 400), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        mouseDown(with: ordinaryClick)
        let placed = writingViewRect
        let ordinaryDrag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 325, y: 420), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        mouseDragged(with: ordinaryDrag)
        precondition(near(writingViewRect.origin, NSPoint(x: placed.minX + 25, y: placed.minY + 20)), "mouse region drag")
        precondition(firstPage.annotations.count == 2, "mouse left ink")
        moveRegion(by: NSPoint(x: 10000, y: -10000))
        precondition(bounds.contains(writingViewRect), "region escaped viewport")
        let edgeRect = writingViewRect
        viewportChanged()
        precondition(writingViewRect == edgeRect, "edge placement was recentered")

        // Press-to-start uses the current absolute point, then stays latched until finger lift.
        requiresPress = true
        testRegion(NSRect(x: 100, y: 180, width: 248, height: 160), on: firstPage)
        processContacts([contact("a", 0.1, 0.1)])
        processContacts([contact("a", 0.7, 0.6)])
        precondition(points.isEmpty && near(penPosition, NSPoint(x: 273.6, y: 276)), "hover preview left ink")
        setTrackpadPressed(true)
        precondition(points.count == 1 && near(points.first, NSPoint(x: 273.6, y: 276)), "press used hover path or cursor position")
        setTrackpadPressed(false)
        processContacts([contact("a", 0.8, 0.5)])
        precondition(penArmed && points.count == 2 && firstPage.annotations.count == 2, "pressure release ended stroke")
        processContacts([])
        precondition(firstPage.annotations.count == 3 && !penArmed, "finger lift did not commit and disarm")
        processContacts([contact("a", 0.2, 0.3)])
        processContacts([contact("a", 0.3, 0.4)])
        processContacts([])
        precondition(firstPage.annotations.count == 3, "new contact inherited armed state")

        // Pressure and raw touch are separate streams; either may arrive first.
        setTrackpadPressed(true)
        processContacts([contact("a", 0.5, 0.5)])
        precondition(penArmed && points.count == 1, "press before touch was lost")
        setTrackpadPressed(false)
        processContacts([])
        precondition(firstPage.annotations.count == 4)

        processContacts([contact("a", 0.4, 0.4)])
        setTrackpadPressed(true)
        processContacts([contact("a", 0.6, 0.4)])
        processContacts([contact("a", 0.6, 0.4), contact("b", 0.7, 0.4), contact("c", 0.8, 0.4)])
        precondition(firstPage.annotations.count == 5 && !penArmed)
        processContacts([contact("a", 0.6, 0.4)])
        setTrackpadPressed(true)
        precondition(points.isEmpty, "leftover finger or press resumed stroke after gesture")
        processContacts([])

        erasing = true
        processContacts([contact("a", 0.2, 0.8)])
        processContacts([])
        precondition(firstPage.annotations.count == 5 && pendingErasure.isEmpty, "eraser hover removed ink")
        erasing = false
        processContacts([contact("a", 0.4, 0.4)])
        precondition(!handleTrackpadPress(ordinaryClick), "external mouse click armed pen")
        mouseDown(with: ordinaryClick)
        setTrackpadPressed(true)
        precondition(points.isEmpty && !penArmed, "navigation did not block active touch")
        processContacts([])
        processContacts([contact("a", 0.4, 0.4)])
        setTrackpadPressed(true)
        resetInput()
        processContacts([contact("a", 0.5, 0.5)])
        precondition(points.isEmpty && !penArmed && !pressHeld, "cancel did not clear press latch")
        processContacts([])
        enabled = false
        processContacts([contact("a", 0.5, 0.5)])
        precondition(points.isEmpty)
    }

    func checkCrossPageCanvas() throws {
        let document = TouchPDFDocument()
        document.pdf = samplePDF()
        document.undoManager?.groupsByEvent = false
        let controller = ReaderWindowController(reader: document)
        document.addWindowController(controller)
        guard let root = controller.window?.contentView else { preconditionFailure("missing root") }
        root.layoutSubtreeIfNeeded()
        let viewer = controller.pdfView, surface = controller.surface
        surface.pressureMode = false
        viewer.displayMode = .twoUpContinuous
        viewer.autoScales = false
        viewer.scaleFactor = 0.6
        viewer.layoutDocumentView()
        surface.enabled = true
        surface.smoothInk = false
        let left = document.pdf.page(at: 0)!, right = document.pdf.page(at: 1)!
        let lr = surface.convert(viewer.convert(left.bounds(for: .cropBox), from: left), from: viewer)
        let rr = surface.convert(viewer.convert(right.bounds(for: .cropBox), from: right), from: viewer)
        precondition(lr.maxX < rr.minX, "two-up pages must have a real gap")
        let y = max(lr.minY, rr.minY) + min(lr.height, rr.height) / 2
        surface.writingViewRect = NSRect(x: lr.minX - 20, y: y - 20, width: rr.maxX - lr.minX + 40, height: 40)
        let frameBefore = surface.writingViewRect
        func at(_ x: CGFloat, _ normalizedY: CGFloat = 0.5) {
            surface.processContacts([TouchContact(identity: "cross" as NSString, position: NSPoint(x: x, y: normalizedY))])
        }
        at(0)
        precondition(surface.points.count == 1 && surface.penViewPosition != nil, "outside-page start lost")
        at(1) // Deliberately skip both page edges and the whole gutter.
        precondition(surface.points.count == 2 && left.annotations.isEmpty && right.annotations.isEmpty, "crossing split the live stroke")
        surface.processContacts([])
        precondition(left.annotations.count == 1 && right.annotations.count == 1, "crossing did not save both pages")
        precondition(document.canvasInk.count == 3, "outside margins or gutter ink disappeared after lift")
        precondition(surface.writingViewRect == frameBefore, "page boundaries altered overlay mapping")
        // Three-finger input must move across the real two-up gutter, not a page box.
        surface.centerRegion()
        let threeStart = surface.writingViewRect
        func triple(_ offset: CGFloat) -> [TouchContact] {
            [0.2, 0.4, 0.6].enumerated().map { index, x in
                TouchContact(identity: "move-\(index)" as NSString, position: NSPoint(x: x + offset, y: 0.5))
            }
        }
        surface.processContacts(triple(0))
        surface.processContacts(triple(0.1))
        precondition(abs(surface.writingViewRect.midX - threeStart.midX - threeStart.width * 0.1) < 0.01, "three fingers cannot cross the gutter")
        precondition(surface.movingFrameSequence, "three-finger move does not suppress native navigation")
        surface.processContacts(Array(triple(0.1).prefix(2)))
        precondition(surface.movingFrameSequence && surface.points.isEmpty, "leftover fingers escaped move-frame sequence")
        surface.processContacts([])
        precondition(!surface.movingFrameSequence, "frame gesture did not release")
        surface.writingViewRect = frameBefore
        let saved = try document.data(ofType: pdfType)
        let reopened = TouchPDFDocument()
        try reopened.read(from: saved, ofType: pdfType)
        precondition(reopened.canvasInk.isEmpty && reopened.pdf.page(at: 0)!.annotations.count == 1 && reopened.pdf.page(at: 1)!.annotations.count == 1, "PDF export must contain page ink only")
        precondition(document.canvasInk.count == 3, "saving destroyed current canvas ink")
        document.undoManager?.undo()
        precondition(left.annotations.isEmpty && right.annotations.isEmpty && document.canvasInk.isEmpty, "one undo must remove entire cross-page stroke")
        document.undoManager?.redo()
        precondition(left.annotations.count == 1 && right.annotations.count == 1 && document.canvasInk.count == 3, "redo lost cross-page pieces")

        // Session-only ink keeps page-relative geometry during document transforms.
        let gutter = document.canvasInk[1]
        let savedPoints = gutter.points
        let before = viewer.convert(savedPoints[0], from: gutter.anchor)
        let frame = surface.writingViewRect
        viewer.scaleFactor = 0.9
        viewer.layoutDocumentView()
        surface.pdfScaleChanged()
        let after = viewer.convert(savedPoints[0], from: gutter.anchor)
        precondition(gutter.points == savedPoints && after != before, "canvas ink did not follow PDF zoom")
        precondition(surface.writingViewRect == frame, "zoom resized screen overlay")
        let clip = viewer.documentView!.enclosingScrollView!.contentView
        var proposed = clip.bounds
        proposed.origin.y += 50
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        viewer.documentView!.enclosingScrollView!.reflectScrolledClipView(clip)
        precondition(viewer.convert(savedPoints[0], from: gutter.anchor) != after, "canvas ink did not follow PDF scroll")
        viewer.scaleFactor = 0.6
        viewer.layoutDocumentView()
        surface.viewportChanged()

        // Erase in the gutter, then undo just that action.
        surface.erasing = true
        let gutterPoint = surface.convert(viewer.convert(savedPoints[savedPoints.count / 2], from: gutter.anchor), from: viewer)
        surface.writingViewRect = NSRect(x: gutterPoint.x - 10, y: gutterPoint.y - 10, width: 20, height: 20)
        at(0.5)
        surface.processContacts([])
        precondition(document.canvasInk.count == 2, "gutter eraser missed session ink")
        document.undoManager?.undo()
        precondition(document.canvasInk.count == 3, "undo failed to restore gutter ink")
        surface.erasing = false

        // Export clips the *current* canvas, without mutating session ink or
        // accumulating duplicate annotations when the user saves twice.
        document.undoManager?.disableUndoRegistration()
        document.canvasInk.append(CanvasInk(anchor: left, points: [NSPoint(x: -20, y: 100), NSPoint(x: 20, y: 100)], color: .systemRed))
        let exportA = PDFDocument(data: try document.data(ofType: pdfType))!
        let exportB = PDFDocument(data: try document.data(ofType: pdfType))!
        precondition(exportA.page(at: 0)!.annotations.count == 2 && exportB.page(at: 0)!.annotations.count == 2, "repeated save lost or duplicated current-canvas ink")
        precondition(left.annotations.count == 1 && document.canvasInk.count == 4, "export mutated the session")
        let clipped = exportA.page(at: 0)!.annotations.last!
        precondition(inkIsNear(clipped, point: NSPoint(x: 10, y: 100), radius: 1) && !inkIsNear(clipped, point: NSPoint(x: -10, y: 100), radius: 1), "export retained ink outside page")

        surface.moveRegion(by: NSPoint(x: 10000, y: -10000))
        let edge = surface.writingViewRect
        surface.viewportChanged()
        precondition(surface.writingViewRect == edge, "edge frame jumped back to center")
        surface.centerRegion()
        precondition(abs(surface.writingViewRect.midX - surface.bounds.midX) < 0.01 && abs(surface.writingViewRect.midY - surface.bounds.midY) < 0.01, "center action did not center overlay on viewport")
        precondition(controller.windowTitle(forDocumentDisplayName: "test.pdf").contains(touchPDFBuild), "window lacks compiled build identity")
        // The actual root is shared by PDFView and overlay, not page-bound.
        precondition(surface.superview === viewer.superview && surface.superview === root)
        let point = NSPoint(x: surface.frame.midX, y: surface.frame.midY)
        precondition(root.hitTest(point) === surface, "writing overlay not hit-testable")
        surface.passesNavigationEvents = true
        precondition(root.hitTest(point) !== surface, "native navigation cannot reach PDFKit")
        surface.passesNavigationEvents = false
        surface.enabled = false
        document.removeWindowController(controller)
        print("PASS: real two-column sibling overlay, sparse cross-page clipping, gutter/outside ink, transform tracking, grouped undo/redo, eraser, PDF-only export")
    }

    func checkCursorHold() throws {
        defer { holdCursor(false) }
        holdCursor(true)
        guard cursorHeld, !cursorHoldFailed else {
            throw NSError(domain: "TouchPDF", code: 5, userInfo: [NSLocalizedDescriptionKey: "系统未允许固定指针。"])
        }
        resetInput()
        guard !cursorHeld, !cursorHoldFailed else {
            throw NSError(domain: "TouchPDF", code: 6, userInfo: [NSLocalizedDescriptionKey: "系统指针恢复失败。"])
        }
        holdCursor(true)
        enabled = false
        guard !cursorHeld, !cursorHoldFailed else {
            throw NSError(domain: "TouchPDF", code: 7, userInfo: [NSLocalizedDescriptionKey: "退出批注未恢复系统指针。"])
        }
    }
}

extension ReaderWindowController {
    static func checkRetinaInkExport() throws {
        let document = TouchPDFDocument()
        let page = document.pdf.page(at: 0)!
        let ink = inkAnnotation(points: [NSPoint(x: 100, y: 100), NSPoint(x: 220, y: 180)], page: page) as! VectorInkAnnotation
        page.addAnnotation(ink)
        let controller = ReaderWindowController(reader: document)
        document.addWindowController(controller)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        precondition(ink.rendersInOverlay && controller.surface.wantsLayer)
        let exported = PDFDocument(data: try document.data(ofType: pdfType))!
        precondition(ink.rendersInOverlay, "saving failed to restore screen renderer")
        let reopened = exported.page(at: 0)!.annotations[0]
        precondition(reopened.shouldDisplay && reopened.paths?.first?.elementCount == ink.paths?.first?.elementCount)
        let context = CGContext(data: nil, width: 595, height: 842, bitsPerComponent: 8, bytesPerRow: 595 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 595, height: 842))
        exported.page(at: 0)!.draw(with: .cropBox, to: context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let colored = (0..<(595 * 842)).filter { bytes[$0 * 4] < 220 }.count
        precondition(colored > 100, "saved PDF lost its visible annotation appearance")
        document.removeWindowController(controller)
        print("PASS: Retina overlay ownership, visible standard PDF export, renderer restored after save")
    }
    static func checkPausedSettings() {
        let defaults = UserDefaults.standard
        let keys = ["inkColorRGB", "pressureThreshold", "releaseToPreview", "smoothInk"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        } }
        let document = TouchPDFDocument()
        let controller = ReaderWindowController(reader: document)
        document.addWindowController(controller)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        precondition(!controller.surface.enabled && controller.regionSlider.isEnabled && controller.toolControl.isEnabled)
        precondition(controller.inkModeControl.isEnabled && controller.pressureSlider.isEnabled && controller.releaseButton.isEnabled)
        controller.selectTool()
        controller.adjustRegionSize(by: 0.2)
        controller.centerWritingRegion()
        controller.selectPaletteColor(2)
        controller.pressureSlider.doubleValue = 45
        controller.changePressureThreshold()
        precondition(!controller.surface.enabled && !controller.surface.wantsRawInput)
        precondition(controller.surface.erasing && abs(controller.surface.regionScale - 1.2) < 0.001)
        precondition(controller.surface.previewsRegion && controller.surface.pressureThreshold == 45)
        precondition(controller.colorChoice.indexOfSelectedItem == 2)
        controller.toggleAnnotation()
        precondition(controller.surface.enabled && !controller.surface.previewsRegion && controller.surface.erasing)
        precondition(abs(controller.surface.regionScale - 1.2) < 0.001 && controller.colorChoice.indexOfSelectedItem == 2)
        controller.toggleAnnotation()
        controller.toggleFillViewport()
        precondition(controller.surface.fillsViewport && !controller.surface.enabled)
        controller.surface.checkFullViewportMapping()
        controller.adjustRegionSize(by: 10)
        precondition(!controller.surface.fillsViewport && controller.surface.regionScale == 6)
        controller.inkModeControl.selectedSegment = 0
        controller.selectInkMode()
        precondition(!controller.pressureSlider.isEnabled && !controller.releaseButton.isEnabled)
        precondition(controller.regionSlider.isEnabled && controller.toolControl.isEnabled)
        precondition(!document.isDocumentEdited, "changing paused settings edited the PDF")
        document.removeWindowController(controller)
        print("PASS: paused toolbar settings, preview without input capture, resume preserves settings, PDF unchanged")
    }
    static func checkImportedLayouts() throws {
        let source = samplePDF()
        // Include a portrait page with a nonzero crop origin, a landscape page,
        // and a rotated page: imported documents need not look like our demo.
        source.page(at: 0)!.setBounds(NSRect(x: 18, y: 24, width: 576, height: 744), for: .cropBox)
        source.insert(source.page(at: 1)!.copy() as! PDFPage, at: 2)
        source.page(at: 1)!.setBounds(NSRect(x: 0, y: 0, width: 792, height: 612), for: .mediaBox)
        source.page(at: 2)!.rotation = 90
        let document = TouchPDFDocument()
        try document.read(from: source.dataRepresentation()!, ofType: pdfType)
        document.undoManager?.disableUndoRegistration()
        let controller = ReaderWindowController(reader: document)
        document.addWindowController(controller)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.surface.pressureMode = false
        controller.centerWritingRegion()
        for selection in [1, 0, 1] {
            controller.layoutControl.selectedSegment = selection
            controller.selectLayout()
            precondition(controller.pdfView.displayMode == (selection == 1 ? .twoUpContinuous : .singlePageContinuous))
            precondition(controller.pdfView.scaleFactor.isFinite && controller.pdfView.scaleFactor > 0)
            precondition(controller.pdfView.documentView?.enclosingScrollView != nil)
            controller.centerWritingRegion()
        }
        precondition(document.pdf.pageCount == 3 && !document.isDocumentEdited, "layout operations edited imported PDF")
        controller.surface.enabled = false
        document.removeWindowController(controller)
        print("PASS: imported mixed-size/crop/rotation PDF, actual single/two-column actions, center action, no document mutation")
    }
}

func checkShiftShortcuts() {
    var tap = ShiftTap()
    precondition(!tap.changed(.shift, eligible: true))
    precondition(!tap.changed(.shift, eligible: true), "repeat flags toggled")
    precondition(tap.changed([], eligible: true), "Shift release did not toggle")
    precondition(!tap.changed([], eligible: true), "release toggled twice")
    _ = tap.changed(.shift, eligible: true)
    tap.cancel() // typing or clicking while Shift is held
    precondition(!tap.changed([], eligible: true), "Shift chord toggled")
    _ = tap.changed(.shift, eligible: true)
    _ = tap.changed([.shift, .command], eligible: true)
    _ = tap.changed(.shift, eligible: true)
    precondition(!tap.changed([], eligible: true), "Shift-Command chord toggled")
    _ = tap.changed(.shift, eligible: false)
    precondition(!tap.changed([], eligible: true), "field editor's Shift escaped into reader")
    _ = tap.changed(.shift, eligible: true)
    tap.reset()
    precondition(!tap.changed([], eligible: true), "focus loss retained Shift candidate")
    let document = TouchPDFDocument()
    document.undoManager?.disableUndoRegistration()
    let controller = ReaderWindowController(reader: document)
    document.addWindowController(controller)
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    controller.surface.pressureMode = false
    controller.surface.checkToolChangeDuringStroke(controller)
    controller.selectTool()
    precondition(controller.surface.enabled && controller.surface.erasing)
    controller.selectTool()
    precondition(controller.surface.enabled && !controller.surface.erasing)
    controller.toggleAnnotation()
    precondition(!controller.surface.enabled)
    controller.toggleAnnotation()
    precondition(controller.surface.enabled && !controller.surface.erasing)
    controller.surface.enabled = false
    document.removeWindowController(controller)
    print("PASS: lone Shift, chords, text editor/focus suppression, pen/eraser and annotation toggle")
}

func selfTest(outputURL: URL? = nil) throws {
    InkSurface.checkEraserFeedback()
    try ReaderWindowController.checkRetinaInkExport()
    ReaderWindowController.checkPausedSettings()
    checkShiftShortcuts()
    let surface = InkSurface(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
    precondition(!surface.requiresPress, "default handwriting must not require a click")
    surface.checkAbsoluteInput()
    surface.checkLightPressure()
    InkSurface(frame: NSRect(x: 0, y: 0, width: 1200, height: 1000)).checkPenSettings()
    try surface.checkCrossPageCanvas()
    try ReaderWindowController.checkImportedLayouts()
    try surface.checkCursorHold()
    let blank = blankPDF()
    precondition(TouchPDFDocument.readableTypes.contains(pdfType) && TouchPDFDocument.writableTypes.contains(pdfType), "PDF type is not writable in the native Save panel")
    precondition(blank.pageCount == 1 && (blank.page(at: 0)?.string ?? "").isEmpty && blank.page(at: 0)!.annotations.isEmpty)
    precondition(PDFDocument(data: blank.dataRepresentation()!)!.pageCount == 1)
    precondition(distanceToSegment(NSPoint(x: 50, y: 3), .zero, NSPoint(x: 100, y: 0)) == 3)
    let document = TouchPDFDocument()
    document.pdf = samplePDF()
    let page = document.pdf.page(at: 0)!
    let annotation = inkAnnotation(points: [NSPoint(x: 90, y: 600), NSPoint(x: 490, y: 600)], page: page)
    precondition(inkIsNear(annotation, point: NSPoint(x: 300, y: 604), radius: 5))
    precondition(!inkIsNear(annotation, point: NSPoint(x: 300, y: 630), radius: 5))
    document.undoManager?.groupsByEvent = false
    document.undoManager?.beginUndoGrouping()
    document.change(annotation, on: page, adding: true)
    document.undoManager?.endUndoGrouping()
    precondition(page.annotations.count == 1 && document.isDocumentEdited)
    document.undoManager?.undo()
    precondition(page.annotations.isEmpty)
    document.undoManager?.redo()
    precondition(page.annotations.count == 1)
    let data = try document.data(ofType: pdfType)
    let reopened = PDFDocument(data: data)!
    precondition(reopened.pageCount == 2 && reopened.page(at: 0)!.annotations.count == 1)
    let reopenedInk = reopened.page(at: 0)!.annotations[0]
    precondition(reopenedInk.type == "Ink" && inkIsNear(reopenedInk, point: NSPoint(x: 300, y: 600), radius: 2))
    let curvePoints = [NSPoint(x: 90, y: 500), NSPoint(x: 110, y: 520), NSPoint(x: 140, y: 530), NSPoint(x: 170, y: 520), NSPoint(x: 190, y: 500)]
    let geometry = inkGeometry(curvePoints, smoothing: true)
    precondition(geometry.first == curvePoints.first && geometry.last == curvePoints.last && geometry.count > curvePoints.count, "smooth curve lost endpoints or stayed a coarse polyline")
    let cornerPoints = [NSPoint(x: 230, y: 500), NSPoint(x: 260, y: 540), NSPoint(x: 290, y: 500)]
    precondition(inkGeometry(cornerPoints, smoothing: true).contains(cornerPoints[1]), "smoothing rounded a sharp mathematical corner")
    precondition(inkGeometry(curvePoints, smoothing: false) == curvePoints)
    let red = NSColor(srgbRed: 0.85, green: 0.12, blue: 0.15, alpha: 1)
    page.addAnnotation(inkAnnotation(points: curvePoints, page: page, color: red))
    page.addAnnotation(inkAnnotation(points: cornerPoints, page: page, color: .black))
    let finalData = try document.data(ofType: pdfType)
    let finalPage = PDFDocument(data: finalData)!.page(at: 0)!
    let loadedDocument = TouchPDFDocument()
    try loadedDocument.read(from: finalData, ofType: pdfType)
    precondition(loadedDocument.pdf.page(at: 0)!.annotations.allSatisfy { $0 is VectorInkAnnotation }, "reopened ink did not use the antialiased renderer")
    let colored = finalPage.annotations[1]
    let savedColor = colored.color.usingColorSpace(.sRGB)!
    precondition(abs(savedColor.redComponent - 0.85) < 0.01 && abs(savedColor.greenComponent - 0.12) < 0.01, "ink color changed on save/reopen")
    precondition(colored.paths!.first!.elementCount == geometry.count, "PDF serialization changed smooth geometry")
    for point in geometry {
        precondition(inkIsNear(colored, point: point, radius: 0.03), "saved curved ink differs from preview or cannot be erased")
    }
    precondition(inkIsNear(finalPage.annotations[2], point: cornerPoints[1], radius: 0.03), "PDF lost sharp corner")
    let invalid = TouchPDFDocument()
    do { try invalid.read(from: Data("invalid".utf8), ofType: pdfType); preconditionFailure("invalid PDF accepted") } catch {}
    if let outputURL {
        try finalData.write(to: outputURL, options: .atomic)
    } else if let position = CommandLine.arguments.firstIndex(of: "--self-test"), CommandLine.arguments.count > position + 1 {
        try finalData.write(to: URL(fileURLWithPath: CommandLine.arguments[position + 1]), options: .atomic)
    }
    print("PASS: optional pressure release/lift latch, fine motion, colored smoothed vectors and sharp corners after PDF save/reopen, enlarged independent region, threshold/hysteresis, gesture/stream recovery, eraser, raw validation, cursor restoration, absolute input, undo/redo")
}

if CommandLine.arguments.contains("--self-test") {
    _ = NSApplication.shared
    do { try selfTest() } catch { fputs("Self-test failed: \(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let documentController = TouchDocumentController()
    let delegate = AppDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    makeMenu()
    withExtendedLifetime((delegate, documentController)) { app.run() }
}
