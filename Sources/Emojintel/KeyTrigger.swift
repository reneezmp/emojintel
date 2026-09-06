import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// The event tap: detects a lone `fn` (or Right ⌘) tap, and routes navigation keys while
/// the pill is open.
///
/// Two facts drive this design, both established in Phase 0:
///
///  1. `fn` emits **flagsChanged**, never keyDown/keyUp — modifier keys don't generate
///     key events. A tap masking only keyDown|keyUp never fires at all.
///  2. The first AX call into an app takes 22–354ms. That must NOT happen inside this
///     callback: a slow callback trips kCGEventTapDisabledByTimeout and the tap dies
///     silently. So the callback does state-machine work only and hands off async.
final class KeyTrigger {

    enum Trigger { case fn, rightCommand }

    static let kFn: Int64 = 63
    static let kRightCmd: Int64 = 54
    static let kLeft: Int64 = 123, kRight: Int64 = 124
    static let kReturn: Int64 = 36, kEscape: Int64 = 53, kTab: Int64 = 48
    static let digits: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4]   // 1...5

    /// Set by the coordinator. All are invoked on the main queue, never inline.
    var onTrigger: ((Trigger) -> Void)?
    var onNavigate: ((Int) -> Void)?      // -1 / +1
    var onCommit: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onSelectIndex: ((Int) -> Void)?

    /// Read by the callback to decide whether to swallow navigation keys.
    var pillIsOpen = false
    private(set) var isPaused = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastFlags: CGEventFlags = []
    private var armed: Int64?
    private var watchdog: Timer?

    // MARK: - Lifecycle

    @discardableResult
    func install() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyTrigger>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startWatchdog()
        return true
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if let tap { CGEvent.tapEnable(tap: tap, enable: !paused) }
    }

    /// macOS disables taps on timeout, on some user input, and around Secure Input.
    /// Without this the app stops working after a while with no visible cause.
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap, !self.isPaused else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                NSLog("Emojintel: event tap was disabled; re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    // MARK: - Callback  (must stay fast: no AX, no allocation-heavy work)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard !isPaused else { return pass }

        let kc = event.getIntegerValueField(.keyboardEventKeycode)

        // INVARIANT: flagsChanged is NEVER swallowed. Returning nil for a modifier event
        // desyncs modifier state in the receiving app.
        if type == .flagsChanged {
            let changed = event.flags.rawValue ^ lastFlags.rawValue
            let goingDown = (event.flags.rawValue & changed) != 0
            lastFlags = event.flags

            if goingDown {
                armed = (kc == Self.kFn || kc == Self.kRightCmd) ? kc : nil
            } else {
                if let a = armed, a == kc {
                    let trigger: Trigger = (kc == Self.kFn) ? .fn : .rightCommand
                    DispatchQueue.main.async { [weak self] in self?.onTrigger?(trigger) }
                }
                armed = nil
            }
            return pass
        }

        guard type == .keyDown else { return pass }

        // Any real key means a modifier was being held, not tapped.
        armed = nil

        // INVARIANT: when the pill is closed the tap is pure observation.
        guard pillIsOpen else { return pass }

        // INVARIANT: exactly these keycodes are swallowed, and only while the pill is open.
        switch kc {
        case Self.kLeft:
            DispatchQueue.main.async { [weak self] in self?.onNavigate?(-1) }
            return nil
        case Self.kRight, Self.kTab:
            DispatchQueue.main.async { [weak self] in self?.onNavigate?(1) }
            return nil
        case Self.kReturn:
            DispatchQueue.main.async { [weak self] in self?.onCommit?() }
            return nil
        case Self.kEscape:
            DispatchQueue.main.async { [weak self] in self?.onDismiss?() }
            return nil
        default:
            if let i = Self.digits[kc] {
                DispatchQueue.main.async { [weak self] in self?.onSelectIndex?(i) }
                return nil
            }
            // Anything else dismisses the pill and PASSES THROUGH, so typing isn't eaten.
            DispatchQueue.main.async { [weak self] in self?.onDismiss?() }
            return pass
        }
    }
}
