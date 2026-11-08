import AppKit
import ApplicationServices
import SwitchCore
import WindowPreviews

struct WindowRecord {
    var snapshot: SnapshotWindow { SnapshotWindow(key: key, windowID: windowID, minimized: minimized) }
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
/// records plus one WindowServer metadata snapshot resolve focus at invocation.
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
    private var auxiliaryWindows: Set<WindowKey> = [] // main thread only
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
                if name == NSWorkspace.didActivateApplicationNotification { self.synchronizeFocus() }
                self.refresh()
            })
        }
        // Our settings window belongs to an accessory app, so the regular-app
        // AX scan intentionally excludes it. Follow its native lifecycle instead.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard notification.object is SettingsWindow else { return }
                // willClose arrives before isVisible changes.
                DispatchQueue.main.async {
                    if name == NSWindow.didBecomeKeyNotification { self?.synchronizeFocus() }
                    self?.refresh()
                }
            })
        }
        refresh()
    }

    func refresh() {
        pending?.cancel()
        let local = localWindowRecords()
        let work = DispatchWorkItem { [weak self] in self?.scan(localWindows: local) }
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

    var focusedWindow: WindowKey? { recency.focused }

    /// No AX IPC, screenshots, or full catalog scan on the input path. Resolve
    /// the foreground app's front window by its WindowServer ID even when its
    /// AX reference could not be matched during the last background scan.
    func synchronizeFocus() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let known = Set(records.map(\.key))
        let lookup = Dictionary(records.compactMap { record in record.windowID.map {
            (WindowKey(pid: record.pid, token: String($0)), record.key)
        } }, uniquingKeysWith: { first, _ in first })
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let frontToBack = raw.compactMap { item -> WindowKey? in
            guard let owner = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner == pid,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width >= 50, frame.height >= 40 else { return nil }
            let key = WindowKey(pid: owner, token: String(id))
            guard !auxiliaryWindows.contains(key) else { return nil }
            return lookup[key] ?? key
        }
        recency.observe(frontmostPID: pid, frontToBack: frontToBack, known: known)
    }

    private func localWindowRecords() -> [WindowRecord] {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let pid = ProcessInfo.processInfo.processIdentifier
        return NSApp.windows.compactMap { window in
            guard window is SettingsWindow, window.isVisible || window.isMiniaturized, window.windowNumber > 0 else { return nil }
            let id = CGWindowID(window.windowNumber)
            return WindowRecord(key: WindowKey(pid: pid, token: String(id)), windowID: id, pid: pid,
                appName: "NativeSwitch", bundleID: Bundle.main.bundleIdentifier ?? "com.que.NativeSwitch", title: window.title,
                frame: DisplayGeometry.quartzFrame(appKitFrame: window.frame, primaryTop: primaryTop),
                minimized: window.isMiniaturized, hidden: NSApp.isHidden, onDesktop: window.isOnActiveSpace,
                accessibilityElement: nil, icon: NSApp.applicationIconImage)
        }
    }

    private func localWindow(for record: WindowRecord) -> NSWindow? {
        guard record.pid == ProcessInfo.processInfo.processIdentifier, let id = record.windowID,
              let window = NSApp.window(withWindowNumber: Int(id)), window is SettingsWindow,
              window.isVisible || window.isMiniaturized else { return nil }
        return window
    }

    private func installObserver(for pid: pid_t, app: AXUIElement) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, context in
            guard let context else { return }
            let catalog = Unmanaged<WindowCatalog>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                if notification as String == kAXFocusedWindowChangedNotification || notification as String == kAXApplicationActivatedNotification {
                    catalog.synchronizeFocus()
                }
                catalog.refresh()
            }
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

    private func scan(localWindows: [WindowRecord]) {
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
        var output: [WindowRecord] = localWindows
        var auxiliary: Set<WindowKey> = []
        for application in apps {
            let pid = application.processIdentifier
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.12)
            let appWindows = trusted ? axValue(app, kAXWindowsAttribute as CFString) as? [AXUIElement] : nil
            if trusted { installObserver(for: pid, app: app) }
            let cgWindows = raw.filter {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
                ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
                ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0
            }
            let axInfo = appWindows?.map { element in
                let old = previous.first { $0.pid == pid && $0.accessibilityElement.map { CFEqual($0, element) } == true }
                return (element: element, title: axValue(element, kAXTitleAttribute as CFString) as? String ?? "",
                 frame: axFrame(element), minimized: axValue(element, kAXMinimizedAttribute as CFString) as? Bool ?? false,
                 role: axValue(element, kAXRoleAttribute as CFString) as? String,
                 subrole: axValue(element, kAXSubroleAttribute as CFString) as? String,
                 canBecomeMain: axCanBecomeMain(element), old: old)
            }
            let server = cgWindows.compactMap { item -> (id: CGWindowID, title: String, frame: CGRect)? in
                guard let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
                return (id, item[kCGWindowName as String] as? String ?? "", frame)
            }
            let matches = WindowInventory.reconcile(server: server.map { .init(id: $0.id, title: $0.title, frame: $0.frame) },
                accessibility: axInfo?.map { .init(title: $0.title, frame: $0.frame, role: $0.role, subrole: $0.subrole,
                    canBecomeMain: $0.canBecomeMain, knownServerID: $0.old?.windowID) },
                applicationName: application.localizedName ?? "")
            if appWindows != nil {
                let retained = Set(matches.compactMap(\.serverIndex))
                for index in server.indices where !retained.contains(index) {
                    auxiliary.insert(WindowKey(pid: pid, token: String(server[index].id)))
                }
            }
            for match in matches {
                let candidate = match.accessibilityIndex.flatMap { axInfo?[$0] }
                if let candidate { observe(candidate.element, pid: pid) }
                if let index = match.serverIndex {
                    let window = server[index]
                    let key = WindowKey(pid: pid, token: String(window.id))
                    if visibleIDs.contains(window.id) { knownDesktop[key] = desktopGeneration }
                    output.append(WindowRecord(key: key, windowID: window.id, pid: pid,
                        appName: application.localizedName ?? "应用", bundleID: application.bundleIdentifier ?? "",
                        title: window.title.isEmpty ? (candidate?.title.isEmpty == false ? candidate!.title : application.localizedName ?? "窗口") : window.title,
                        frame: window.frame, minimized: candidate?.minimized ?? false, hidden: application.isHidden,
                        onDesktop: visibleIDs.contains(window.id), accessibilityElement: candidate?.element, icon: application.icon))
                    continue
                }
                guard let candidate, let frame = candidate.frame else { continue }
                let old = candidate.old
                let key = old?.key ?? WindowKey(pid: pid, token: "ax-\(CFHash(candidate.element))")
                // A minimized/hidden window has no public Space ID. Keep its
                // last known desktop membership; unknown ones appear only in
                // the all-desktops scope.
                output.append(WindowRecord(key: key, windowID: old?.windowID, pid: pid,
                    appName: application.localizedName ?? "应用", bundleID: application.bundleIdentifier ?? "",
                    title: candidate.title.isEmpty ? application.localizedName ?? "窗口" : candidate.title,
                    frame: frame, minimized: candidate.minimized, hidden: application.isHidden,
                    onDesktop: knownDesktop[key] == desktopGeneration, accessibilityElement: candidate.element, icon: application.icon))
            }
        }
        output.sort { (zOrder[$0.windowID ?? 0] ?? Int.max) < (zOrder[$1.windowID ?? 0] ?? Int.max) }
        previous = output
        let retainedKeys = Set(output.map(\.key))
        knownDesktop = knownDesktop.filter { retainedKeys.contains($0.key) }
        let result = output
        let excluded = auxiliary.subtracting(retainedKeys)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.records = result
            self.auxiliaryWindows = excluded
            self.recency.prune(keeping: Set(result.map(\.key)))
            // Read focus now; a slow scan's earlier focus sample must never
            // overwrite a newer foreground-window observation.
            self.synchronizeFocus()
            self.onChange?(result)
        }
    }

    /// Chromium child windows can report AXStandardWindow just like their
    /// owner. AXMain writability distinguishes those non-main child controls;
    /// a false current AXMain value alone would also hide background windows.
    private func axCanBecomeMain(_ element: AXUIElement) -> Bool? {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXMainAttribute as CFString, &settable) == .success else { return nil }
        return settable.boolValue
    }

    func activate(_ record: WindowRecord, completion: @escaping (Bool) -> Void) {
        if record.pid == ProcessInfo.processInfo.processIdentifier {
            guard let window = localWindow(for: record) else { completion(false); return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            if NSApp.isHidden { NSApp.unhide(nil) }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            completion(true); return
        }
        // Bring the app forward immediately. Slow AX messaging must not delay
        // this first visible response or wait for an unrelated catalog scan.
        guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated else { completion(false); return }
        if app.isHidden { app.unhide() }
        app.activate(options: [])
        actionQueue.async {
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
            AXUIElementSetMessagingTimeout(window, 0.2)
            if record.minimized { AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, window)
            DispatchQueue.main.async { completion(raised == .success) }
        }
    }

    func close(_ record: WindowRecord, completion: @escaping (Bool) -> Void) {
        if record.pid == ProcessInfo.processInfo.processIdentifier {
            guard let window = localWindow(for: record) else { completion(false); return }
            window.performClose(nil)
            completion(!window.isVisible && !window.isMiniaturized); return
        }
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
