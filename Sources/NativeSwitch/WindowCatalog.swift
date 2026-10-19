import AppKit
import ApplicationServices
import SwitchCore

struct WindowRecord {
    let key: WindowKey
    let windowID: CGWindowID?
    let pid: pid_t
    let appName: String
    let bundleID: String
    let title: String
    let frame: CGRect
    let minimized: Bool
    let hidden: Bool
    let onDesktop: Bool
    let accessibilityElement: AXUIElement?
    let icon: NSImage?
}

/// Window metadata is collected on a serial queue. Only lightweight cached
/// records are read when the global shortcut arrives.
final class WindowCatalog {
    private let queue = DispatchQueue(label: "com.que.NativeSwitch.catalog", qos: .userInitiated)
    private let actionQueue = DispatchQueue(label: "com.que.NativeSwitch.activate", qos: .userInteractive)
    private var pending: DispatchWorkItem?
    private var previous: [WindowRecord] = [] // catalog queue only
    private var observers: [pid_t: AXObserver] = [:] // catalog queue only
    private var subscribedWindows: Set<String> = []
    private var desktopGeneration: UInt64 = 0
    private var knownDesktop: [WindowKey: UInt64] = [:]
    private var notificationTokens: [NSObjectProtocol] = []
    private var recency = RecencyOrder() // main thread only
    private var lastFocused: WindowKey?
    private(set) var records: [WindowRecord] = [] // main thread only
    var onChange: (([WindowRecord]) -> Void)?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.activeSpaceDidChangeNotification {
                    self.queue.async { self.desktopGeneration += 1 }
                }
                self.refresh()
            })
        }
        refresh()
    }

    func refresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(40), execute: work)
    }

    func ordered(using preferences: Preferences) -> [WindowRecord] {
        let eligible = records.filter {
            !preferences.excludedBundleIDs.contains($0.bundleID) &&
            (preferences.includeMinimized || !$0.minimized) &&
            (preferences.includeHidden || !$0.hidden) &&
            (preferences.scope == .allDesktops || $0.onDesktop)
        }
        let mapping = Dictionary(eligible.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return recency.ordered(eligible.map(\.key)).compactMap { mapping[$0] }
    }

    func touch(_ key: WindowKey) { recency.touch(key); lastFocused = key }

    private func installObserver(for pid: pid_t, app: AXUIElement) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let catalog = Unmanaged<WindowCatalog>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { catalog.refresh() }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        observers[pid] = observer
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification, kAXApplicationActivatedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func observe(_ window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        let identifier = "\(pid):\(CFHash(window))"
        guard subscribedWindows.insert(identifier).inserted else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                     kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(observer, window, name as CFString, context)
        }
    }

    private func scan() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
        let livePIDs = Set(apps.map(\.processIdentifier))
        for pid in Array(observers.keys) where !livePIDs.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
            subscribedWindows = subscribedWindows.filter { !$0.hasPrefix("\(pid):") }
        }
        let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let visibleIDs = Set(visible.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        let zOrder = Dictionary(raw.enumerated().compactMap { index, item -> (UInt32, Int)? in
            guard let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return (id, index)
        }, uniquingKeysWith: min)
        let trusted = AXIsProcessTrusted()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var output: [WindowRecord] = []
        var focusedKey: WindowKey?
        for application in apps {
            let pid = application.processIdentifier
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.12)
            let appWindows = trusted ? (axValue(app, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []) : []
            let focused = pid == frontPID ? axValue(app, kAXFocusedWindowAttribute as CFString) : nil
            if trusted { installObserver(for: pid, app: app) }
            let cgWindows = raw.filter {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
                ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
                ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0
            }
            var usedAX: Set<Int> = []
            let axInfo = appWindows.map { element in
                (element, axValue(element, kAXTitleAttribute as CFString) as? String ?? "",
                 axFrame(element), axValue(element, kAXMinimizedAttribute as CFString) as? Bool ?? false)
            }
            for item in cgWindows {
                guard let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: bounds), frame.width >= 50, frame.height >= 40 else { continue }
                let title = item[kCGWindowName as String] as? String ?? ""
                let matches = axInfo.enumerated().filter { index, candidate in
                    guard !usedAX.contains(index), let axBounds = candidate.2 else { return false }
                    return abs(axBounds.minX - frame.minX) < 3 && abs(axBounds.minY - frame.minY) < 3 &&
                        abs(axBounds.width - frame.width) < 3 && abs(axBounds.height - frame.height) < 3
                }
                let exact = matches.filter { $0.element.1 == title }
                // Public Accessibility APIs expose no WindowServer ID. Avoid
                // raising an arbitrary window when both title and bounds collide.
                let match = exact.count == 1 ? exact.first : (matches.count == 1 ? matches.first : nil)
                if let match { usedAX.insert(match.offset); observe(match.element.0, pid: pid) }
                let key = WindowKey(pid: pid, token: String(id))
                if visibleIDs.contains(id) { knownDesktop[key] = desktopGeneration }
                let element = match?.element.0
                if let element, let focused, CFEqual(element, focused) { focusedKey = key }
                output.append(WindowRecord(key: key, windowID: id, pid: pid,
                    appName: application.localizedName ?? "应用", bundleID: application.bundleIdentifier ?? "",
                    title: title.isEmpty ? (match?.element.1.isEmpty == false ? match!.element.1 : application.localizedName ?? "窗口") : title,
                    frame: frame, minimized: match?.element.3 ?? false, hidden: application.isHidden,
                    onDesktop: visibleIDs.contains(id), accessibilityElement: element, icon: application.icon))
            }
            for (index, candidate) in axInfo.enumerated() where !usedAX.contains(index) {
                guard let frame = candidate.2, frame.width >= 50, frame.height >= 40,
                      (axValue(candidate.0, kAXSubroleAttribute as CFString) as? String) != kAXFloatingWindowSubrole else { continue }
                observe(candidate.0, pid: pid)
                let old = previous.first { $0.pid == pid && $0.accessibilityElement.map { CFEqual($0, candidate.0) } == true }
                let key = old?.key ?? WindowKey(pid: pid, token: "ax-\(CFHash(candidate.0))")
                if let focused, CFEqual(candidate.0, focused) { focusedKey = key }
                // A minimized/hidden window has no public Space ID. Keep its
                // last known desktop membership; unknown ones appear only in
                // the all-desktops scope.
                output.append(WindowRecord(key: key, windowID: old?.windowID, pid: pid,
                    appName: application.localizedName ?? "应用", bundleID: application.bundleIdentifier ?? "",
                    title: candidate.1.isEmpty ? application.localizedName ?? "窗口" : candidate.1,
                    frame: frame, minimized: candidate.3, hidden: application.isHidden,
                    onDesktop: knownDesktop[key] == desktopGeneration, accessibilityElement: candidate.0, icon: application.icon))
            }
        }
        output.sort { (zOrder[$0.windowID ?? 0] ?? Int.max) < (zOrder[$1.windowID ?? 0] ?? Int.max) }
        previous = output
        let retainedKeys = Set(output.map(\.key))
        knownDesktop = knownDesktop.filter { retainedKeys.contains($0.key) }
        let result = output, focused = focusedKey
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.records = result
            self.recency.prune(keeping: Set(result.map(\.key)))
            if let focused, focused != self.lastFocused { self.recency.touch(focused); self.lastFocused = focused }
            self.onChange?(result)
        }
    }

    func activate(_ record: WindowRecord, completion: @escaping (Bool) -> Void) {
        actionQueue.async {
            guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated else {
                DispatchQueue.main.async { completion(false) }; return
            }
            let root = AXUIElementCreateApplication(record.pid)
            AXUIElementSetMessagingTimeout(root, 0.2)
            var window = record.accessibilityElement
            if window == nil {
                let candidates = (axValue(root, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []).filter {
                    (axValue($0, kAXTitleAttribute as CFString) as? String) == record.title && axFrame($0) == record.frame
                }
                if candidates.count == 1 { window = candidates[0] }
            }
            guard let window else { DispatchQueue.main.async { completion(false) }; return }
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            DispatchQueue.main.async {
                if app.isHidden { app.unhide() }
                app.activate(options: [])
                self.actionQueue.async {
                    let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, window)
                    DispatchQueue.main.async { completion(raised == .success) }
                }
            }
        }
    }

    func close(_ record: WindowRecord, completion: @escaping (Bool) -> Void) {
        actionQueue.async {
            guard let window = record.accessibilityElement,
                  let close = axValue(window, kAXCloseButtonAttribute as CFString), CFGetTypeID(close) == AXUIElementGetTypeID() else {
                DispatchQueue.main.async { completion(false) }; return
            }
            let result = AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
            DispatchQueue.main.async { completion(result == .success) }
        }
    }
}
