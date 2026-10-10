import AppKit
import PDFKit
import UniformTypeIdentifiers

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
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard contents == "TouchPDF", let paths else { super.draw(with: box, in: context); return }
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
    }

    override func data(ofType typeName: String) throws -> Data {
        for controller in windowControllers {
            (controller as? ReaderWindowController)?.surface.finishStroke()
        }
        guard let data = pdf.dataRepresentation() else {
            throw NSError(domain: "TouchPDF", code: 4, userInfo: [NSLocalizedDescriptionKey: "PDF 保存失败，未写入文件。"])
        }
        return data
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController(reader: self))
    }

    func change(_ annotation: PDFAnnotation, on page: PDFPage, adding: Bool) {
        if adding { page.addAnnotation(annotation) } else { page.removeAnnotation(annotation) }
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

// A held cursor may be above a toolbar button. Active trackpad presses belong to the pen.
final class DrawingWindow: NSWindow {
    weak var surface: InkSurface?
    override func sendEvent(_ event: NSEvent) {
        if surface?.handleTrackpadPress(event) == true { return }
        super.sendEvent(event)
    }
}

final class InkSurface: NSView {
    weak var reader: TouchPDFDocument?
    weak var pdfView: PDFView?
    var updateStatus: (() -> Void)?
    var enabled = false {
        didSet {
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
    var regionScale: CGFloat = 1 {
        didSet { interruptForNavigation(); resizeRegion(); updateStatus?() }
    }
    private(set) var cursorHoldFailed = false
    private var cursorHeld = false
    private enum Mode { case idle, writing, pinching, panning, blocked }
    private var mode = Mode.idle
    private var contacts = [TouchContact]()
    private var hadMultipleContacts = false
    private var touchScrollSequence = false
    private var regionPage: PDFPage?
    private var writingRect = NSRect.zero
    private var padAspect: CGFloat = 1.55
    private var penPosition: NSPoint?
    private var penArmed = false
    private var pressHeld = false
    private var privateDrawing = false
    private var rawPressure: Float = 0
    private var privateInputAvailable = false
    private var page: PDFPage?
    private var points = [NSPoint]()
    private var pendingErasure = [PDFAnnotation]()
    private var strokeStartedAt: TimeInterval = 0
    private var mouseDragLocation: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        // AppKit pressure begins at normal click; it does not provide a pre-click light-force threshold.
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryGeneric)
        setAccessibilityLabel("PDF 触控板批注区域")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit {
        RawTrackpadInput.shared.deactivate(self)
        if cursorHeld { _ = CGAssociateMouseAndMouseCursorPosition(1) }
    }
    override var acceptsFirstResponder: Bool { true }

    var wantsRawInput: Bool { enabled && pressureMode && window?.isKeyWindow == true && NSApp.isActive }
    var hasActiveContacts: Bool { !contacts.isEmpty }
    var usingRawPressure: Bool { pressureMode && privateInputAvailable }

    override func hitTest(_ point: NSPoint) -> NSView? {
        enabled && bounds.contains(convert(point, from: superview)) ? self : nil
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
        penPosition = nil
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
        guard enabled, window?.isKeyWindow == true else { return }
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
           let point = mappedPoint(touch.normalizedPosition) {
            extendStroke(to: point)
        }
        receiveTouches(event)
    }

    private func processContacts(_ next: [TouchContact], previewing: Bool = false, pressure: Float? = nil) {
        guard enabled else { return }
        let sameFingers = contacts.count == next.count && contacts.allSatisfy { previous in next.contains { previous.identity.isEqual($0.identity) } }
        defer { contacts = next; needsDisplay = true; updateStatus?() }
        if next.isEmpty {
            finishStroke()
            penArmed = false; pressHeld = false; privateDrawing = false; rawPressure = 0
            mode = .idle
            hadMultipleContacts = false
            penPosition = nil
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
            hadMultipleContacts = true; touchScrollSequence = true
        }
        switch next.count {
        case 1:
            guard !hadMultipleContacts, mode != .blocked, let point = mappedPoint(next[0].position) else {
                finishStroke(); mode = .blocked; penPosition = nil; return
            }
            if mode != .writing || !sameFingers { finishStroke(); penArmed = false; privateDrawing = false }
            mode = .writing
            penPosition = point
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
            if page == nil { page = regionPage; strokeStartedAt = ProcessInfo.processInfo.systemUptime }
            extendStroke(to: point)
        case 2:
            finishStroke(discardGesturePrelude: true)
            penPosition = nil
            if mode == .pinching, sameFingers {
                let previous = separation(contacts), current = separation(next)
                if previous > 0.015 && current > 0.015 { zoomPDF(by: current / previous) }
            }
            mode = .pinching
        case 3:
            finishStroke(discardGesturePrelude: true)
            penPosition = nil
            if mode == .panning, sameFingers, let rect = regionViewRect {
                let previous = centroid(contacts), current = centroid(next)
                moveRegion(by: NSPoint(x: (current.x - previous.x) * rect.width, y: (current.y - previous.y) * rect.height))
            }
            mode = .panning
        default:
            finishStroke(discardGesturePrelude: true); mode = .blocked; penPosition = nil
        }
    }

    private func centroid(_ values: [TouchContact]) -> NSPoint {
        NSPoint(x: values.reduce(0) { $0 + $1.position.x } / CGFloat(values.count), y: values.reduce(0) { $0 + $1.position.y } / CGFloat(values.count))
    }
    private func separation(_ values: [TouchContact]) -> CGFloat {
        hypot((values[0].position.x - values[1].position.x) * padAspect, values[0].position.y - values[1].position.y)
    }

    func resetInput() {
        holdCursor(false)
        finishStroke()
        contacts = []; mode = .idle; hadMultipleContacts = false; penPosition = nil
        penArmed = false; pressHeld = false
        privateDrawing = false; rawPressure = 0
        touchScrollSequence = false
        mouseDragLocation = nil
        needsDisplay = true
    }
    func interruptForNavigation() {
        finishStroke()
        penArmed = false; pressHeld = false
        privateDrawing = false; rawPressure = 0
        if !contacts.isEmpty { mode = .blocked; hadMultipleContacts = true }
        penPosition = nil
        needsDisplay = true
    }

    private var regionViewRect: NSRect? {
        guard let pdfView, let regionPage else { return nil }
        return convert(pdfView.convert(writingRect, from: regionPage), from: pdfView)
    }
    private var pageAspect: CGFloat {
        (regionPage?.rotation ?? 0) % 180 == 0 ? padAspect : 1 / padAspect
    }

    private func ensureRegion() {
        if let rect = regionViewRect, bounds.insetBy(dx: 12, dy: 20).contains(rect) { return }
        placeRegion(at: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    func viewportChanged() {
        if enabled, contacts.isEmpty { ensureRegion() }
        needsDisplay = true
    }

    func pdfScaleChanged() {
        if mode == .writing { interruptForNavigation() }
        resizeRegion()
        viewportChanged()
    }

    private func resizeRegion() {
        guard let pdfView, let regionPage else { return }
        let center = NSPoint(x: writingRect.midX, y: writingRect.midY)
        let pageBounds = regionPage.bounds(for: .cropBox)
        let screenWidth = min(440 * regionScale, max(40, bounds.width - 24), max(40, bounds.height - 60) * padAspect)
        let pageWidth = screenWidth / max(pdfView.scaleFactor, 0.1) / (regionPage.rotation % 180 == 0 ? 1 : padAspect)
        let width = min(pageWidth, max(1, pageBounds.width - 4), max(1, pageBounds.height - 4) * pageAspect)
        writingRect = NSRect(x: center.x - width / 2, y: center.y - width / pageAspect / 2, width: width, height: width / pageAspect)
        clampRegion()
        needsDisplay = true
    }

    private func placeRegion(at location: NSPoint) {
        guard let pdfView else { return }
        let position = pdfView.convert(location, from: self)
        guard let target = pdfView.page(for: position, nearest: true) else { return }
        let center = pdfView.convert(position, to: target)
        regionPage = target
        writingRect = NSRect(origin: center, size: .zero)
        resizeRegion()
    }

    private func clampRegion() {
        guard let regionPage else { return }
        let limit = regionPage.bounds(for: .cropBox).insetBy(dx: 2, dy: 2)
        writingRect.size.width = min(writingRect.width, limit.width)
        writingRect.size.height = min(writingRect.height, limit.height)
        writingRect.origin.x = max(limit.minX, min(limit.maxX - writingRect.width, writingRect.minX))
        writingRect.origin.y = max(limit.minY, min(limit.maxY - writingRect.height, writingRect.minY))
    }

    private func moveRegion(by delta: NSPoint) {
        guard let pdfView, let regionPage, let rect = regionViewRect else { return }
        let origin = pdfView.convert(pdfView.convert(NSPoint(x: rect.midX, y: rect.midY), from: self), to: regionPage)
        let moved = pdfView.convert(pdfView.convert(NSPoint(x: rect.midX + delta.x, y: rect.midY + delta.y), from: self), to: regionPage)
        writingRect.origin.x += moved.x - origin.x
        writingRect.origin.y += moved.y - origin.y
        clampRegion()
        needsDisplay = true
    }

    private func mappedPoint(_ normalized: NSPoint) -> NSPoint? {
        guard let pdfView, let regionPage, let rect = regionViewRect else { return nil }
        // Both NSTouch and this non-flipped view have their origin at the lower left.
        let location = NSPoint(x: rect.minX + max(0, min(1, normalized.x)) * rect.width, y: rect.minY + max(0, min(1, normalized.y)) * rect.height)
        return pdfView.convert(pdfView.convert(location, from: self), to: regionPage)
    }

    private func zoomPDF(by factor: CGFloat) {
        guard let pdfView else { return }
        let scroll = pdfView.documentView?.enclosingScrollView
        let clip = scroll?.contentView
        let center = NSPoint(x: writingRect.midX, y: writingRect.midY)
        let oldAnchor = regionPage.map { pdfView.convert(center, from: $0) }
        let oldLocation = oldAnchor.flatMap { pdfView.documentView?.convert($0, from: pdfView) }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, pdfView.scaleFactor * factor))
        pdfView.layoutDocumentView()
        pdfScaleChanged()
        if let regionPage, let oldLocation, let clip, let documentView = pdfView.documentView {
            let location = documentView.convert(pdfView.convert(center, from: regionPage), from: pdfView)
            var proposed = clip.bounds
            proposed.origin.x += location.x - oldLocation.x
            proposed.origin.y += location.y - oldLocation.y
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            scroll?.reflectScrolledClipView(clip)
        }
        needsDisplay = true
    }

    private func extendStroke(to point: NSPoint) {
        guard let pdfView, let page else { return }
        guard page.bounds(for: .cropBox).insetBy(dx: -0.01, dy: -0.01).contains(point) else { interruptForNavigation(); return }
        if erasing {
            // Defer removal until lift, so adding a second finger can cancel a gesture's initial eraser contact.
            if let annotation = page.annotations.reversed().first(where: { inkIsNear($0, point: point, radius: 10 / max(pdfView.scaleFactor, 0.1)) }) {
                if !pendingErasure.contains(where: { $0 === annotation }) { pendingErasure.append(annotation) }
            }
        }
        if points.last.map({ hypot($0.x - point.x, $0.y - point.y) * pdfView.scaleFactor > 0.08 }) ?? true {
            points.append(point)
        }
        needsDisplay = true
    }

    func finishStroke(discardGesturePrelude: Bool = false) {
        let finishedPage = page, finishedPoints = points, erased = pendingErasure
        page = nil
        points = []
        pendingErasure = []
        // Fingers land one at a time: discard a tiny, recent dot when it was the start of a multi-finger gesture.
        let prelude = discardGesturePrelude && ProcessInfo.processInfo.systemUptime - strokeStartedAt < 0.12 && finishedPoints.allSatisfy { point in
            finishedPoints.first.map { hypot(point.x - $0.x, point.y - $0.y) * (pdfView?.scaleFactor ?? 1) < 3 } ?? true
        }
        if let finishedPage, !finishedPoints.isEmpty, !prelude {
            if erasing {
                for annotation in erased where finishedPage.annotations.contains(where: { $0 === annotation }) {
                    reader?.change(annotation, on: finishedPage, adding: false)
                }
            } else {
                reader?.change(inkAnnotation(points: finishedPoints, page: finishedPage, color: inkColor, smoothing: smoothInk), on: finishedPage, adding: true)
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard enabled, let pdfView else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = true
        NSBezierPath(rect: bounds).addClip()
        if let rect = regionViewRect {
            NSColor.systemBlue.withAlphaComponent(0.025).setFill()
            NSBezierPath(rect: rect).fill()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 1
            outline.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.systemBlue.withAlphaComponent(0.7).setStroke()
            outline.stroke()
            ("触控板书写区域" as NSString).draw(at: NSPoint(x: rect.minX + 6, y: rect.maxY + 5), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemBlue])
        }
        if let page, !points.isEmpty, !erasing {
            let path = inkPath(inkGeometry(points, smoothing: smoothInk).map { convert(pdfView.convert($0, from: page), from: pdfView) })
            path.lineWidth = inkWidth * pdfView.scaleFactor
            inkColor.setStroke()
            path.stroke()
        }
        if let regionPage, let penPosition {
            let location = convert(pdfView.convert(penPosition, from: regionPage), from: pdfView)
            let drawing = page != nil
            let radius: CGFloat = drawing ? 3 : 6
            let tip = NSBezierPath(ovalIn: NSRect(x: location.x - radius, y: location.y - radius, width: radius * 2, height: radius * 2))
            (erasing ? NSColor.systemBlue : inkColor).set()
            tip.lineWidth = 1.5
            if drawing { tip.fill() } else { tip.stroke() }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Raw contacts own multi-finger gestures; their scroll/momentum events must not also move the PDF.
        if event.phase.contains(.began) { touchScrollSequence = !contacts.isEmpty }
        if contacts.count >= 2 || (touchScrollSequence && (event.phase != [] || event.momentumPhase != [])) { return }
        interruptForNavigation()
        if event.modifierFlags.contains(.command) { zoomPDF(by: exp(event.scrollingDeltaY * 0.01)); return }
        if let scroll = pdfView?.documentView?.enclosingScrollView { scroll.scrollWheel(with: event) }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {} // Raw two-finger separation already performs the zoom.

    override func flagsChanged(with event: NSEvent) {
        if mode == .writing { processContacts(contacts, previewing: event.modifierFlags.contains(.command), pressure: pressureMode ? rawPressure : nil) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { enabled = false } else { super.keyDown(with: event) }
    }
}

final class ReaderWindowController: NSWindowController, NSWindowDelegate {
    let pdfView = PDFView()
    let surface = InkSurface(frame: .zero)
    private let annotationButton = NSButton(title: "触控板批注", target: nil, action: nil)
    private let toolControl = NSSegmentedControl(labels: ["笔", "橡皮"], trackingMode: .selectOne, target: nil, action: nil)
    private let regionSlider = NSSlider(value: 100, minValue: 40, maxValue: 300, target: nil, action: nil)
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
        window.minSize = NSSize(width: 810, height: 500)
        window.acceptsMouseMovedEvents = true
        window.surface = surface
        window.delegate = self
        window.center()
        let root = TouchRootView(frame: .zero)
        root.surface = surface
        window.contentView = root
        pdfView.document = reader.pdf
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
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
        annotationButton.toolTip = "开启后轻触定位、加力落笔，无需点击；双指缩放、三指移框。Esc 返回阅读。"
        toolControl.selectedSegment = 0
        toolControl.target = self
        toolControl.action = #selector(selectTool)
        let bar = NSStackView(views: [button("打开", #selector(openPDF)), button("新建空白", #selector(newBlank)), button("保存", #selector(savePDF)), annotationButton, toolControl, button("撤销", #selector(undoStroke)), NSTextField(labelWithString: "PDF"), button("−", #selector(zoomOut)), button("＋", #selector(zoomIn)), button("适合宽度", #selector(fitPage))])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY
        regionSlider.target = self
        regionSlider.action = #selector(resizeWritingRegion)
        regionSlider.isContinuous = true
        regionSlider.setAccessibilityLabel("书写框大小")
        regionSlider.toolTip = "40–300%，最大可扩展到当前页面和视窗允许的范围。只改变书写框，不缩放 PDF 或已有笔迹。"
        regionSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        regionSizeLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
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
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        colorChoice.addItems(withTitles: ["蓝色", "黑色", "红色", "绿色", "紫色", "自定…"])
        colorChoice.target = self
        colorChoice.action = #selector(chooseInkColor)
        colorChoice.widthAnchor.constraint(equalToConstant: 80).isActive = true
        colorChoice.setAccessibilityLabel("常用笔颜色")
        syncColorChoice()
        NSColorPanel.shared.showsAlpha = false
        let regionBar = NSStackView(views: [NSTextField(labelWithString: "书写框大小"), regionSlider, regionSizeLabel, NSTextField(labelWithString: "笔颜色"), colorChoice, colorWell, smoothButton])
        regionBar.orientation = .horizontal
        regionBar.spacing = 10
        regionBar.alignment = .centerY
        let inputBar = NSStackView(views: [NSTextField(labelWithString: "落笔方式"), inkModeControl, pressureSlider, pressureLabel, releaseButton])
        inputBar.orientation = .horizontal
        inputBar.spacing = 10
        inputBar.alignment = .centerY
        let footer = NSStackView(views: [status, NSView(), pageLabel])
        footer.orientation = .horizontal
        footer.spacing = 12
        status.font = NSFont.systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        pageLabel.font = status.font
        pageLabel.textColor = status.textColor
        for view in [bar, regionBar, inputBar, pdfView, surface, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12), bar.heightAnchor.constraint(equalToConstant: 30),
            regionBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), regionBar.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6), regionBar.heightAnchor.constraint(equalToConstant: 24),
            regionBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
            inputBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), inputBar.topAnchor.constraint(equalTo: regionBar.bottomAnchor, constant: 6), inputBar.heightAnchor.constraint(equalToConstant: 24), inputBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor), pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor), pdfView.topAnchor.constraint(equalTo: inputBar.bottomAnchor, constant: 8), pdfView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
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
    private func updateControls() {
        annotationButton.state = surface.enabled ? .on : .off
        annotationButton.title = surface.enabled ? "批注：开" : "触控板批注"
        toolControl.isEnabled = surface.enabled
        inkModeControl.isEnabled = surface.enabled
        inkModeControl.selectedSegment = surface.pressureMode ? 1 : 0
        pressureSlider.isEnabled = surface.enabled && surface.pressureMode
        pressureSlider.doubleValue = Double(surface.pressureThreshold)
        pressureLabel.stringValue = "力度 \(Int(surface.pressureThreshold))"
        releaseButton.isEnabled = surface.enabled && surface.pressureMode
        releaseButton.state = surface.releaseToPreview ? .on : .off
        smoothButton.state = surface.smoothInk ? .on : .off
        regionSlider.isEnabled = surface.enabled
        regionSlider.doubleValue = Double(surface.regionScale * 100)
        regionSizeLabel.stringValue = "\(Int(surface.regionScale * 100))%"
        let releaseHint = surface.releaseToPreview ? "减力收笔" : "抬手收笔"
        status.stringValue = surface.enabled ? (surface.cursorHoldFailed ? "未能固定系统指针，请全部抬手后重试。" : (surface.inputNotice ?? (surface.pressureMode ? "轻触定位 · 加力落笔 · \(releaseHint) · 双指缩放 · 三指移框 · 指针固定" : "单指写 · 双指缩放 PDF · 三指移框 · 按住 ⌘ 预览 · 触控时指针固定"))) : "阅读模式 · 开启“触控板批注”即可勾画"
        if let page = pdfView.currentPage, let document = pdfView.document {
            pageLabel.stringValue = "\(document.index(for: page) + 1) / \(document.pageCount) · \(Int(pdfView.scaleFactor * 100))%"
        }
    }
    @objc func openPDF() { surface.resetInput(); NSDocumentController.shared.openDocument(nil) }
    @objc func newBlank() { surface.resetInput(); NSDocumentController.shared.newDocument(nil) }
    @objc func savePDF() { surface.finishStroke(); reader?.save(nil) }
    @objc func toggleAnnotation() { surface.enabled.toggle(); window?.makeFirstResponder(surface.enabled ? surface : pdfView) }
    @objc func selectTool() { surface.finishStroke(); surface.erasing = toolControl.selectedSegment == 1 }
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
    @objc func resizeWritingRegion() { surface.regionScale = CGFloat(regionSlider.doubleValue / 100) }
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
    override func documentClass(forType typeName: String) -> AnyClass? { TouchPDFDocument.self }
    override var defaultType: String? { pdfType }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var startupPanel: NSOpenPanel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            if NSDocumentController.shared.documents.isEmpty { self?.chooseStartingDocument() }
        }
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, NSDocumentController.shared.documents.isEmpty { chooseStartingDocument() }
        return true
    }
    private func chooseStartingDocument() {
        guard startupPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "打开 PDF"
        panel.message = "选择要阅读或批注的 PDF，也可以新建空白画布。"
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        let blankButton = NSButton(title: "新建空白画布", target: self, action: #selector(blankFromPicker))
        blankButton.bezelStyle = .rounded
        blankButton.frame = NSRect(x: 0, y: 4, width: 150, height: 30)
        accessory.addSubview(blankButton)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        startupPanel = panel
        panel.begin { [weak self] response in
            self?.startupPanel = nil
            if response == .OK, let url = panel.url {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApplication.shared.presentError(error) }
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
            try "PASS: optional pressure release and lift latch, threshold/hysteresis, preview separation, gesture interruption, stream recovery, eraser, fine sampling at zoom, enlarged region independent of PDF zoom, corner-preserving vector smoothing, colored ink geometry after PDF save/reopen, absolute input, cursor restoration, undo/redo, invalid PDF rejection\n".write(to: directory.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
            alert.messageText = "自检通过"
            alert.informativeText = "减力收笔开关、抬手收笔、细小移动采样、平滑曲线与公式尖角、彩色矢量笔迹保存重开、扩大书写框与独立缩放检查通过。"
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
    appMenu.addItem(withTitle: "退出 TouchPDF", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
    let helpItem = NSMenuItem()
    let help = NSMenu(title: "帮助")
    let checks = help.addItem(withTitle: "运行自检", action: #selector(AppDelegate.runChecks(_:)), keyEquivalent: "")
    checks.target = NSApplication.shared.delegate
    helpItem.submenu = help
    menu.addItem(helpItem)
    NSApplication.shared.mainMenu = menu
}

extension InkSurface {
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
        regionPage = document.pdf.page(at: 0)!
        regionScale = 248 / 440
        writingRect = NSRect(x: 100, y: 180, width: 248, height: 160)
        let target = regionPage!
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
        regionPage = target
        writingRect = NSRect(x: 100, y: 180, width: 248, height: 160)
        regionScale = 1.6
        let oldWidth = regionViewRect!.width
        regionScale = 3
        precondition(regionViewRect!.width > oldWidth * 1.3 && abs(viewer.scaleFactor - 2) < 0.01, "larger region did not expand independently of PDF zoom")
        precondition(target.bounds(for: .cropBox).contains(writingRect), "large region escaped the page")
        writingRect = NSRect(x: 100, y: 180, width: 248, height: 160)
        viewer.scaleFactor = 5
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
        regionPage = firstPage
        regionScale = 248 / 440
        writingRect = NSRect(x: 100, y: 180, width: 248, height: 160)
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

        let oldRect = writingRect
        processContacts([contact("a", 0.2, 0.4), contact("b", 0.4, 0.4), contact("c", 0.6, 0.4)])
        processContacts([contact("c", 0.7, 0.5), contact("a", 0.3, 0.5), contact("b", 0.5, 0.5)])
        precondition(near(writingRect.origin, NSPoint(x: oldRect.minX + 24.8, y: oldRect.minY + 16)), "three-finger movement or identity ordering")
        processContacts([contact("a", 0.3, 0.5)])
        processContacts([])
        precondition(firstPage.annotations.count == 3)

        let frameWidth = regionViewRect!.width
        regionScale *= 1.25
        precondition(abs(viewer.scaleFactor - 1) < 0.01 && abs(regionViewRect!.width - frameWidth * 1.25) < 0.01, "region slider changed PDF zoom")
        precondition(firstPage.annotations.count == 3)
        regionScale /= 1.25
        processContacts([contact("a", 0.25, 0.5), contact("b", 0.75, 0.5)])
        processContacts([contact("b", 0.875, 0.5), contact("a", 0.125, 0.5)])
        precondition(abs(viewer.scaleFactor - 1.5) < 0.01, "raw pinch zoom")
        precondition(abs(regionViewRect!.width - frameWidth) < 0.01, "PDF zoom changed the screen size of the region")
        precondition(inkIsNear(firstPage.annotations[0], point: NSPoint(x: 149.6, y: 308), radius: 1), "scaling moved existing ink")
        let savedRect = writingRect
        processContacts([])
        viewer.go(to: PDFDestination(page: firstPage, at: NSPoint(x: 200, y: 450)))
        precondition(near(mappedPoint(NSPoint(x: 0.8, y: 0.2)), NSPoint(x: savedRect.minX + savedRect.width * 0.8, y: savedRect.minY + savedRect.height * 0.2)), "zoom/scroll changed PDF coordinates")
        firstPage.rotation = 90
        viewer.layoutDocumentView()
        precondition(near(mappedPoint(NSPoint(x: 0.5, y: 0.5)), NSPoint(x: savedRect.midX, y: savedRect.midY)), "rotated page conversion")
        firstPage.rotation = 0
        viewer.scaleFactor = 1
        viewer.layoutDocumentView()
        pdfScaleChanged()
        viewer.go(to: PDFDestination(page: firstPage, at: NSPoint(x: 0, y: 792)))
        processContacts([contact("a", 0.4, 0.5)], previewing: true)
        precondition(points.isEmpty && penPosition != nil)
        processContacts([])
        precondition(firstPage.annotations.count == 3, "preview left ink")
        writingRect = NSRect(x: 100, y: 180, width: 248, height: 160)
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
        let placed = writingRect
        let ordinaryDrag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 325, y: 420), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        mouseDragged(with: ordinaryDrag)
        precondition(near(writingRect.origin, NSPoint(x: placed.minX + 25 / viewer.scaleFactor, y: placed.minY + 20 / viewer.scaleFactor)), "mouse region drag")
        precondition(firstPage.annotations.count == 2, "mouse left ink")
        moveRegion(by: NSPoint(x: 10000, y: -10000))
        precondition(firstPage.bounds(for: .cropBox).contains(writingRect), "region escaped page")

        // Press-to-start uses the current absolute point, then stays latched until finger lift.
        requiresPress = true
        writingRect = NSRect(x: 100, y: 180, width: 248, height: 160)
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

func selfTest(outputURL: URL? = nil) throws {
    let surface = InkSurface(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
    precondition(!surface.requiresPress, "default handwriting must not require a click")
    surface.checkAbsoluteInput()
    surface.checkLightPressure()
    InkSurface(frame: NSRect(x: 0, y: 0, width: 1200, height: 1000)).checkPenSettings()
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
