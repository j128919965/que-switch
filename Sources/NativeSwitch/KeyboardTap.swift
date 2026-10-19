import AppKit
import SwitchCore

enum SwitchInput { case begin(Bool), step(Int), row(Int), commit, cancel, close }

/// This callback runs on its own run loop and never queries windows, captures
/// images, waits for the main thread, or writes preferences.
final class KeyboardTap {
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var thread: Thread?
    private var preferences = Preferences()
    private var ready = false
    private var enabled = true
    private var switching = false
    private var consumedKeyUps: Set<Int64> = []
    var onInput: ((SwitchInput) -> Void)?
    var onUnavailable: (() -> Void)?

    func configure(_ preferences: Preferences, ready: Bool, enabled: Bool) {
        lock.lock()
        let shouldCancel = switching && (!enabled || self.preferences.modifier != preferences.modifier || self.preferences.shortcutKey != preferences.shortcutKey)
        self.preferences = preferences; self.ready = ready; self.enabled = enabled
        if shouldCancel { switching = false }
        lock.unlock()
        if shouldCancel { emit(.cancel) }
    }

    func endSession() { lock.lock(); switching = false; lock.unlock() }

    func start() {
        guard AXIsProcessTrusted(), thread == nil else { return }
        let worker = Thread { [weak self] in
            guard let self else { return }
            let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            let callback: CGEventTapCallBack = { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeyboardTap>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                DispatchQueue.main.async { self.thread = nil; self.onUnavailable?() }; return
            }
            let loop = CFRunLoopGetCurrent()!
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
            self.lock.lock(); self.tap = tap; self.runLoop = loop; self.lock.unlock()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            CFMachPortInvalidate(tap)
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        worker.name = "NativeSwitch keyboard"; worker.qualityOfService = .userInteractive
        thread = worker; worker.start()
    }

    func stop() {
        lock.lock(); let loop = runLoop; switching = false; lock.unlock()
        if let loop { CFRunLoopStop(loop) }
    }

    private func emit(_ input: SwitchInput) { DispatchQueue.main.async { [weak self] in self?.onInput?(input) } }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let port = tap; switching = false; lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            emit(.cancel)
            return Unmanaged.passUnretained(event)
        }
        lock.lock(); defer { lock.unlock() }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, consumedKeyUps.remove(key) != nil { return nil }
        guard enabled else { return Unmanaged.passUnretained(event) }
        let primary: CGEventFlags
        switch preferences.modifier {
        case .command: primary = .maskCommand
        case .option: primary = .maskAlternate
        case .control: primary = .maskControl
        }
        if type == .flagsChanged, switching, !event.flags.contains(primary) {
            switching = false; emit(.commit)
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl])
        if key == Int64(preferences.shortcutKey), modifiers == primary {
            guard ready || switching else { return Unmanaged.passUnretained(event) }
            let reverse = event.flags.contains(.maskShift)
            consumedKeyUps.insert(key)
            if switching { emit(.step(reverse ? -1 : 1)) }
            else { switching = true; emit(.begin(reverse)) }
            return nil
        }
        guard switching else { return Unmanaged.passUnretained(event) }
        let input: SwitchInput?
        switch key {
        case 53: switching = false; input = .cancel
        case 36, 76: switching = false; input = .commit
        case 123: input = .step(-1)
        case 124: input = .step(1)
        case 125: input = .row(1)
        case 126: input = .row(-1)
        case 13 where preferences.closeShortcut && event.flags.contains(primary): input = .close
        default: input = nil
        }
        if let input { consumedKeyUps.insert(key); emit(input); return nil }
        return Unmanaged.passUnretained(event)
    }
}
