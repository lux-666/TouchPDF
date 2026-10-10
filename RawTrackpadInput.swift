import AppKit

// Only one key document owns the private device. All PDF changes stay on the main thread.
final class RawTrackpadInput {
    static let shared = RawTrackpadInput()
    private weak var surface: InkSurface?
    private var timer: Timer?
    private var startedAt: UInt64 = 0
    private var lastFrameAt: UInt64 = 0
    private var dropped: UInt64 = 0
    private var invalid: UInt64 = 0
    private var stalled = false
    private var publicTouchBeganAt: UInt64 = 0

    func observePublicContacts(_ active: Bool, from target: InkSurface) {
        guard surface === target else { return }
        if !active { publicTouchBeganAt = 0 }
        else if publicTouchBeganAt == 0 { publicTouchBeganAt = probe_now() }
    }

    func activate(_ next: InkSurface) {
        guard next.wantsRawInput else { deactivate(next); return }
        if surface === next { return }
        stop()
        guard probe_start() else {
            next.rawInputUnavailable()
            return
        }
        surface = next
        next.rawInputAvailable()
        startedAt = probe_now()
        lastFrameAt = 0
        stalled = false
        publicTouchBeganAt = 0
        dropped = probe_dropped()
        invalid = probe_invalid()
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func deactivate(_ target: InkSurface) {
        if surface === target { stop() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let previous = surface
        surface = nil
        probe_stop()
        previous?.resetInput()
    }

    private func poll() {
        guard let surface, surface.wantsRawInput else { stop(); return }
        let newDropped = probe_dropped(), newInvalid = probe_invalid()
        if newDropped != dropped || newInvalid != invalid { surface.rawInputInterrupted() }
        dropped = newDropped; invalid = newInvalid
        var frame = ProbeFrame()
        while probe_read(&frame) {
            let now = probe_now()
            guard frame.sampledNanoseconds >= startedAt else { continue }
            guard now >= frame.sampledNanoseconds, now - frame.sampledNanoseconds <= 150_000_000 else {
                surface.rawInputInterrupted()
                continue
            }
            lastFrameAt = frame.sampledNanoseconds
            stalled = false
            let values = withUnsafeBytes(of: frame.touches) {
                Array($0.bindMemory(to: ProbeTouch.self).prefix(Int(frame.count)))
            }
            guard values.allSatisfy(Self.valid) else { surface.rawInputInterrupted(); continue }
            let active = values.filter { [1, 3, 4, 5].contains($0.state) }
            let contacts = active.map {
                TouchContact(identity: NSNumber(value: $0.identifier), position: NSPoint(x: CGFloat($0.normalized.position.x), y: CGFloat($0.normalized.position.y)))
            }
            surface.receiveRawContacts(contacts, pressure: active.count == 1 ? active[0].pressure : nil)
        }
        let now = probe_now()
        // Device start is not proof of a working stream. AppKit can confirm a real contact.
        if publicTouchBeganAt != 0, now - publicTouchBeganAt > 500_000_000,
           lastFrameAt == 0 || now - lastFrameAt > 500_000_000 {
            stop()
            surface.rawInputUnavailable()
            return
        }
        // A stalled callback stream must never leave a stroke or the global pointer held.
        if !stalled, lastFrameAt != 0, now - lastFrameAt > 250_000_000, surface.hasActiveContacts {
            stalled = true
            surface.rawInputInterrupted()
        }
    }

    static func valid(_ touch: ProbeTouch) -> Bool {
        (0...7).contains(touch.state)
        && touch.normalized.position.x.isFinite && touch.normalized.position.y.isFinite
        && (-0.01...1.01).contains(touch.normalized.position.x)
        && (-0.01...1.01).contains(touch.normalized.position.y)
        && touch.pressure.isFinite && (0...10000).contains(touch.pressure)
    }
}
