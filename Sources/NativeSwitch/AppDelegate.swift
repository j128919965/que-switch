import AppKit
import SwitchCore
import WindowPreviews

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = SettingsStore()
    let catalog = WindowCatalog()
    let keyboard = KeyboardTap()
    let previews = PreviewService()
    let panel = SwitcherPanel()
    private lazy var settingsWindow = SettingsWindowController(store: store)
    private var statusItem: NSStatusItem?
    private var session: WorkspaceSession?
    private var sessionRecords: [WindowKey: WindowRecord] = [:]
    private var presentations: [WindowKey: PreviewPresentation] = [:]
    private var displayWork: DispatchWorkItem?
    private var sessionScreen: NSScreen?
    private var sessionDisplays: [DisplayContext] = []
    private var screenPanels: [UInt32: SwitcherPanel] = [:]
    private var pointerMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var paused = false
    private var lastFailure: String?
    private var interactionActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        store.onChange = { [weak self] preferences in
            guard let self else { return }
            self.cancel(); self.previews.configure(preferences); self.updateReadiness(); self.catalog.refresh()
        }
        catalog.onChange = { [weak self] records in
            guard let self else { return }
            self.previews.prune(keeping: Set(records.map(\.key)))
            self.updateReadiness()
            guard var session = self.session else { return }
            let lookup = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            for key in session.keys {
                if let record = lookup[key] { self.sessionRecords[key] = record }
                else { session.remove(key); self.sessionRecords.removeValue(forKey: key) }
            }
            let geometry = self.sessionDisplays.map(\.geometry)
            session.refreshMembership(Dictionary(self.sessionRecords.values.compactMap { record in
                DisplayGeometry.owner(of: record.frame, displays: geometry).map { (record.key, $0) }
            }, uniquingKeysWith: { first, _ in first }))
            self.session = session
            if session.keys.isEmpty { self.cancel() }
            else if self.isPanelVisible { self.updatePanel() }
        }
        keyboard.onInput = { [weak self] input in self?.handle(input) }
        keyboard.onUnavailable = { [weak self] in self?.lastFailure = "无法接管快捷键，请检查辅助功能权限并重新启动应用。" }
        wire(panel)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { self.cancel(); self.catalog.refresh() }
            }
        settingsWindow.onCheckPermissions = { [weak self] in
            self?.keyboard.start(); self?.updateReadiness(); self?.catalog.refresh()
        }
        previews.configure(store.value)
        catalog.start(); keyboard.start(); updateReadiness()
        let firstRun = !UserDefaults.standard.bool(forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if firstRun || !AXIsProcessTrusted() { settingsWindow.show(permissions: true) }
    }

    private func wire(_ panel: SwitcherPanel) {
        panel.onSelect = { [weak self] key, commit in
            guard let self else { return }
            self.session?.select(key)
            if commit { self.commit() } else { self.updatePanel() }
        }
        panel.onClose = { [weak self] key in self?.closeWindow(key) }
    }

    func applicationWillTerminate(_ notification: Notification) { cancel(); keyboard.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show(); return true
    }

    private func updateReadiness() {
        keyboard.configure(store.value, ready: AXIsProcessTrusted() && !catalog.ordered(using: store.value).isEmpty, enabled: !paused)
        statusItem?.button?.appearsDisabled = paused || !AXIsProcessTrusted()
    }

    private func handle(_ input: SwitchInput) {
        if case .begin = input { } else { focusPointerScreen(update: false) }
        switch input {
        case .begin(let reverse): begin(reverse: reverse)
        case .step(let delta): session?.move(delta); if isPanelVisible { updatePanel() }
        case .row(let delta):
            let columns = session?.mode == .perScreen ? screenPanels[session!.activeDisplay]?.columns ?? 1 : panel.columns
            session?.move(delta * columns); if isPanelVisible { updatePanel() }
        case .commit: commit()
        case .cancel: cancel()
        case .close: if let key = session?.selected { closeWindow(key) }
        }
    }

    private func begin(reverse: Bool) {
        guard !paused else { return }
        if let old = interactionActivity { ProcessInfo.processInfo.endActivity(old) }
        interactionActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "User is switching windows")
        let records = catalog.ordered(using: store.value)
        sessionDisplays = DisplayContext.current()
        guard !records.isEmpty, let first = sessionDisplays.first else { cancel(); return }
        let geometry = sessionDisplays.map(\.geometry)
        let assignments = records.map { DisplayWindow(key: $0.key, displayID: DisplayGeometry.owner(of: $0.frame, displays: geometry) ?? first.id) }
        let pointer = sessionDisplays.first { $0.screen.frame.contains(NSEvent.mouseLocation) }?.id ?? first.id
        session = WorkspaceSession(windows: assignments, displayOrder: sessionDisplays.map(\.id),
                                   pointerDisplay: pointer, mode: store.value.multiDisplayMode, reverse: reverse)
        sessionRecords = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        presentations = [:]
        sessionScreen = chosenScreen(records: records)
        if store.value.multiDisplayMode == .perScreen { monitorPointer() }
        catalog.refresh()
        let work = DispatchWorkItem { [weak self] in self?.displayPanel() }
        displayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(store.value.showDelayMilliseconds), execute: work)
    }

    private func chosenScreen(records: [WindowRecord]) -> NSScreen? {
        if store.value.screen == .main { return NSScreen.screens.first }
        if store.value.screen == .activeWindow, let record = records.first,
           let primary = NSScreen.screens.first {
            let point = NSPoint(x: record.frame.midX, y: primary.frame.maxY - record.frame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return screen }
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private var orderedSessionRecords: [WindowRecord] { session?.keys.compactMap { sessionRecords[$0] } ?? [] }
    private var isPanelVisible: Bool { panel.isVisible || screenPanels.values.contains(where: \.isVisible) }
    private var allPanels: [SwitcherPanel] { [panel] + Array(screenPanels.values) }

    private func monitorPointer() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.focusPointerScreen() }) { pointerMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.focusPointerScreen(); return event }) { pointerMonitors.append(monitor) }
    }

    private func focusPointerScreen(update: Bool = true) {
        guard session?.mode == .perScreen,
              let display = sessionDisplays.first(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }),
              session?.activeDisplay != display.id else { return }
        session?.focus(display.id)
        if update, isPanelVisible { updatePanel() }
    }

    private func renderPanels() -> (visible: [WindowRecord], changed: Bool) {
        guard let session else { return ([], false) }
        if session.mode == .perScreen {
            var visible: [WindowRecord] = [], changed = false
            for display in sessionDisplays {
                guard let panel = screenPanels[display.id] else { continue }
                let result = panel.update(records: session.keys(on: display.id).compactMap { sessionRecords[$0] },
                    selected: session.selected(on: display.id), preferences: store.value, previews: presentations,
                    screen: display.screen, caption: display.name, active: session.activeDisplay == display.id)
                visible += result.visible; changed = changed || result.changed
            }
            return (visible, changed)
        }
        guard let screen = sessionScreen else { return ([], false) }
        let groups: [WindowPanelGroup] = session.mode == .grouped ? sessionDisplays.map { display in
            let windows = orderedSessionRecords.filter { session.membership[$0.key] == display.id }
            return WindowPanelGroup(displayID: display.id, title: "\(display.name) · \(windows.count) 个窗口", records: windows)
        } : []
        return panel.update(records: orderedSessionRecords, selected: session.selected, preferences: store.value,
                            previews: presentations, screen: screen, groups: groups)
    }

    private func displayPanel() {
        guard let session, let screen = sessionScreen, !session.keys.isEmpty else { return }
        panel.reset()
        if session.mode == .perScreen {
            for display in sessionDisplays {
                let panel = SwitcherPanel(); wire(panel); screenPanels[display.id] = panel
            }
        }
        let result = renderPanels()
        preparePresentations(for: result.visible)
        if session.mode == .perScreen { screenPanels.values.forEach { $0.present(animated: store.value.animate) } }
        else { panel.present(animated: store.value.animate) }
        let selected = session.selected.flatMap { sessionRecords[$0] }
        let backingScale = session.mode == .perScreen ? sessionDisplays.map { $0.screen.backingScaleFactor }.max() ?? screen.backingScaleFactor : screen.backingScaleFactor
        let scale = PreviewBudget(backingScale: backingScale, onBattery: PowerState.onBattery,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, saveEnergy: store.value.energySavingPreviews).pixelScale
        previews.begin(records: result.visible.map(\.snapshot), selected: selected?.snapshot, preferences: store.value,
                       pixelSize: CGSize(width: store.value.cardWidth * scale,
                                         height: store.value.cardWidth * 0.61 * scale)) { [weak self] key, image, status in
            guard let self, self.session != nil, self.presentations[key] != nil else { return }
            if let image { self.presentations[key] = PreviewPresentation(image: image, status: status) }
            else { self.presentations[key]?.status = status }
            if let presentation = self.presentations[key] { self.allPanels.forEach { $0.setPreview(presentation, for: key) } }
        }
    }

    private func updatePanel() {
        guard let session else { return }
        let result = renderPanels()
        if result.changed { preparePresentations(for: result.visible) }
        previews.updateVisible(result.visible.map(\.snapshot), selected: session.selected.flatMap { sessionRecords[$0]?.snapshot })
    }

    private func preparePresentations(for visible: [WindowRecord]) {
        let keys = Set(visible.map(\.key))
        presentations = presentations.filter { keys.contains($0.key) }
        for record in visible {
            if presentations[record.key] == nil {
                presentations[record.key] = PreviewPresentation(image: previews.cached(record.key),
                    status: record.minimized ? "最小化 · 上次快照" : "正在刷新…")
            }
            if let presentation = presentations[record.key] { allPanels.forEach { $0.setPreview(presentation, for: record.key) } }
        }
    }

    private func commit() {
        guard let key = session?.selected, let record = sessionRecords[key] else { cancel(); return }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Activate selected window")
        cancel()
        catalog.activate(record) { [weak self] success in
            defer { ProcessInfo.processInfo.endActivity(activity) }
            guard let self else { return }
            if success { self.catalog.touch(key); self.lastFailure = nil }
            else { self.lastFailure = "未能选中这个窗口，请检查辅助功能权限，或等待该应用恢复响应。"; NSSound.beep() }
            self.catalog.refresh()
        }
    }

    private func closeWindow(_ key: WindowKey) {
        guard let record = sessionRecords[key] else { return }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Close selected window")
        // Dismiss before closing so an application's unsaved-document dialog
        // remains visible and receives the user's attention.
        cancel()
        catalog.activate(record) { [weak self] _ in
            guard let self else { ProcessInfo.processInfo.endActivity(activity); return }
            self.catalog.close(record) { success in
                defer { ProcessInfo.processInfo.endActivity(activity) }
                if !success { NSSound.beep() }
                self.catalog.refresh()
            }
        }
    }

    private func cancel() {
        displayWork?.cancel(); displayWork = nil; session = nil
        keyboard.endSession(); previews.stop(); panel.dismiss(); panel.reset()
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerMonitors.removeAll()
        screenPanels.values.forEach { $0.dismiss(); $0.reset(); $0.close() }; screenPanels.removeAll()
        sessionDisplays = []
        sessionRecords.removeAll(); presentations.removeAll(); sessionScreen = nil
        if let activity = interactionActivity { ProcessInfo.processInfo.endActivity(activity); interactionActivity = nil }
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "NativeSwitch")
        item.button?.toolTip = "NativeSwitch — 窗口切换器"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        cancel(); menu.removeAllItems()
        func add(_ title: String, _ selector: Selector?, key: String = "") {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        add("NativeSwitch · \(catalog.ordered(using: store.value).count) 个窗口", nil)
        if !AXIsProcessTrusted() { add("需要辅助功能权限", #selector(openPermissions)) }
        if let lastFailure { add(lastFailure, nil) }
        menu.addItem(.separator())
        add("设置…", #selector(openSettings), key: ",")
        add("权限与首次使用…", #selector(openPermissions))
        add(paused ? "恢复切换" : "暂停切换", #selector(togglePause))
        add("清空截图缓存（\(previews.cacheBytes / 1_024 / 1_024) MB）", #selector(clearCache))
        menu.addItem(.separator())
        add("关于 NativeSwitch", #selector(about))
        add("退出 NativeSwitch", #selector(quit), key: "q")
    }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func openPermissions() { settingsWindow.show(permissions: true) }
    @objc private func togglePause() { paused.toggle(); cancel(); updateReadiness() }
    @objc private func clearCache() { previews.clearCache() }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "NativeSwitch", .applicationVersion: "0.3.0",
            .credits: NSAttributedString(string: "原生 macOS 窗口切换器\nSwift · AppKit · ScreenCaptureKit\n窗口截图仅在本机内存中处理。")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
