import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import SwitchCore

@MainActor final class SettingsWindowController {
    private var window: NSWindow?
    private let store: SettingsStore
    var onCheckPermissions: (() -> Void)?
    init(store: SettingsStore) { self.store = store }
    func show(permissions: Bool = false) {
        if let window {
            if permissions {
                window.contentView = NSHostingView(rootView: SettingsView(store: store, initialTab: "permissions", onCheck: { [weak self] in self?.onCheckPermissions?() }))
            }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let view = SettingsView(store: store, initialTab: permissions ? "permissions" : "general", onCheck: { [weak self] in self?.onCheckPermissions?() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 710, height: 590),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "NativeSwitch 设置"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center(); self.window = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let initialTab: String
    let onCheck: () -> Void
    @State private var tab = "general"
    @State private var accessibility = AXIsProcessTrusted()
    @State private var recording = CGPreflightScreenCaptureAccess()
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var exclusions = ""

    init(store: SettingsStore, initialTab: String, onCheck: @escaping () -> Void) {
        self.store = store; self.initialTab = initialTab; self.onCheck = onCheck
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("通用", systemImage: "keyboard") }.tag("general")
            windows.tabItem { Label("窗口", systemImage: "macwindow.on.rectangle") }.tag("windows")
            appearance.tabItem { Label("外观", systemImage: "paintpalette") }.tag("appearance")
            performance.tabItem { Label("预览与性能", systemImage: "speedometer") }.tag("performance")
            rules.tabItem { Label("排除规则", systemImage: "line.3.horizontal.decrease.circle") }.tag("rules")
            permissions.tabItem { Label("权限", systemImage: "lock.shield") }.tag("permissions")
        }
        .padding(16)
        .frame(width: 710, height: 590)
        .onAppear { exclusions = store.value.excludedBundleIDs.joined(separator: "\n"); checkPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in checkPermissions() }
    }

    private var general: some View {
        Form {
            Section("切换快捷键") {
                Picker("修饰键", selection: $store.value.modifier) {
                    Text("⌘ Command").tag(ShortcutModifier.command)
                    Text("⌥ Option").tag(ShortcutModifier.option)
                    Text("⌃ Control").tag(ShortcutModifier.control)
                }
                Picker("按键", selection: $store.value.shortcutKey) {
                    Text("Tab").tag(48); Text("`（反引号）").tag(50)
                }
                Text("按住修饰键，再按切换键前进；加 Shift 后退。松开修饰键确认，Esc 取消；方向键也可选择窗口。")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("允许用修饰键 + W 关闭选中的窗口", isOn: $store.value.closeShortcut)
            }
            Section("启动与操作") {
                Toggle("登录后自动启动", isOn: Binding(get: { login }, set: setLogin))
                Toggle("鼠标悬停时选中卡片", isOn: $store.value.hoverSelect)
                Text("点击卡片直接切换。退出或暂停 NativeSwitch 后，系统原有快捷键恢复。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("导入配置…", action: importPreferences)
                    Button("导出配置…", action: exportPreferences)
                    Spacer()
                    Button("恢复默认设置") { store.reset(); exclusions = "" }
                }
            }
        }.formStyle(.grouped)
    }

    private var windows: some View {
        Form {
            Section("显示哪些窗口") {
                Picker("桌面范围", selection: $store.value.scope) {
                    Text("当前桌面").tag(WindowScope.currentDesktop)
                    Text("所有桌面（包含全屏窗口）").tag(WindowScope.allDesktops)
                }
                Toggle("包含最小化窗口", isOn: $store.value.includeMinimized)
                Toggle("包含隐藏应用的窗口", isOn: $store.value.includeHidden)
                Text("最小化窗口显示上次快照或应用图标。当前桌面模式下，只保留已确认属于当前桌面的窗口；不确定桌面归属的隐藏窗口可在“所有桌面”中查看。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("面板位置") {
                Picker("多屏展示", selection: $store.value.multiDisplayMode) {
                    Text("合并显示（默认）").tag(MultiDisplayMode.combined)
                    Text("在一个面板内按屏幕分组").tag(MultiDisplayMode.grouped)
                    Text("每个屏幕只显示自己的窗口").tag(MultiDisplayMode.perScreen)
                }
                Picker("显示在", selection: $store.value.screen) {
                    Text("鼠标所在屏幕").tag(PanelScreen.pointer)
                    Text("当前窗口所在屏幕").tag(PanelScreen.activeWindow)
                    Text("主屏幕").tag(PanelScreen.main)
                }
                .disabled(store.value.multiDisplayMode == .perScreen)
                if store.value.multiDisplayMode == .perScreen {
                    Text("各屏同时显示自己的窗口。Tab、方向键和松开修饰键的确认操作跟随鼠标所在屏幕；移动鼠标不会丢失其他屏幕的选择。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("同一应用的多个窗口分别显示，按最近使用顺序排列；一次切换过程中顺序保持稳定。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var appearance: some View {
        Form {
            Section("Win11 风格面板") {
                Picker("主题", selection: $store.value.appearance) {
                    Text("跟随系统").tag(PanelAppearance.system)
                    Text("浅色").tag(PanelAppearance.light)
                    Text("深色").tag(PanelAppearance.dark)
                }
                ColorPicker("选中框颜色", selection: Binding(get: { Color(nsColor: NSColor(hex: store.value.accentHex)) }, set: { store.value.accentHex = NSColor($0).rgbHex }), supportsOpacity: false)
                LabeledContent("卡片宽度") {
                    Slider(value: $store.value.cardWidth, in: 160...400, step: 10)
                    Text("\(Int(store.value.cardWidth)) pt").monospacedDigit().frame(width: 60)
                }
                Stepper("每行最多 \(store.value.columns) 个窗口", value: $store.value.columns, in: 1...6)
                LabeledContent("卡片圆角") {
                    Slider(value: $store.value.cornerRadius, in: 4...20, step: 1)
                    Text("\(Int(store.value.cornerRadius)) pt").monospacedDigit().frame(width: 60)
                }
                Toggle("显示窗口标题", isOn: $store.value.showTitles)
                Toggle("背景毛玻璃", isOn: $store.value.useBlur)
                Toggle("面板淡入动画", isOn: $store.value.animate)
                Text("卡片左上角始终使用应用自己的图标。窗口多时按页展示，继续按 Tab 会自动翻页。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var performance: some View {
        Form {
            Section("预览更新") {
                Text("每次打开面板，可见窗口各截图一次；翻到新页面时补齐预览。同一轮切换中不重复截图，停留时不持续采集。")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("电池供电或低电量模式时降低预览分辨率", isOn: $store.value.energySavingPreviews)
                Text("优先显示已有缩略图，截图在后台逐张更新。省电时使用 1 倍分辨率，降低像素处理开销；窗口内容仍完整居中显示。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("响应与内存") {
                integerSlider("面板显示延迟", value: $store.value.showDelayMilliseconds, range: 0...500, step: 10, suffix: "ms")
                Text("快速按下并松开快捷键，直接切回上一个窗口；稍作停留才显示面板。设为 0 可立即显示。")
                    .font(.callout).foregroundStyle(.secondary)
                integerSlider("截图缓存上限", value: $store.value.cacheMegabytes, range: 8...256, step: 8, suffix: "MB")
                Text("此上限控制缩略图缓存，应用与系统的总内存占用还包含界面和临时捕获缓冲区。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var rules: some View {
        Form {
            Section("不在切换器中显示的应用") {
                Text("每行填写一个应用标识，例如 com.apple.Safari。")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $exclusions).font(.system(.body, design: .monospaced)).frame(height: 150)
                    .onChange(of: exclusions) { _, new in
                        store.value.excludedBundleIDs = new.components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    }
                Button("从正在运行的应用中选择…", action: chooseExcludedApp)
            }
        }.formStyle(.grouped)
    }

    private var permissions: some View {
        Form {
            Section("辅助功能") {
                LabeledContent("状态", value: accessibility ? "已授权" : "未授权")
                Text("用于接管切换快捷键，以及选中、恢复和关闭其他应用的窗口。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("请求授权") {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                    }
                    Button("打开系统设置") { privacySettings("Privacy_Accessibility") }
                }
            }
            Section("屏幕录制") {
                LabeledContent("状态", value: recording ? "已授权" : "未授权")
                Text("用于获取窗口缩略图。截图只在本机内存中处理，不保存到硬盘，也不上传。未授权时仍可使用图标切换。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("请求授权") { _ = CGRequestScreenCaptureAccess(); checkPermissions() }
                    Button("打开系统设置") { privacySettings("Privacy_ScreenCapture") }
                }
            }
            Section {
                Button("重新检测权限") { checkPermissions() }
                Text("授权后回到这里检测。如果系统要求重新启动应用，请先退出，再打开 NativeSwitch。首次试用时，请先退出 HyperSwitch，避免两个应用争用同一快捷键。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func integerSlider(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Double, suffix: String) -> some View {
        LabeledContent(title) {
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }), in: Double(range.lowerBound)...Double(range.upperBound), step: step)
            Text("\(value.wrappedValue) \(suffix)").monospacedDigit().frame(width: 66)
        }
    }
    private func checkPermissions() { accessibility = AXIsProcessTrusted(); recording = CGPreflightScreenCaptureAccess(); onCheck() }
    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            login = SMAppService.mainApp.status == .enabled
            if enabled && SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { showError("修改开机启动失败：\(error.localizedDescription)") }
    }
    private func importPreferences() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.importFile(url); exclusions = store.value.excludedBundleIDs.joined(separator: "\n") }
        catch { showError("配置文件无效：\(error.localizedDescription)") }
    }
    private func exportPreferences() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "NativeSwitch.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportFile(url) } catch { showError("导出失败：\(error.localizedDescription)") }
    }
    private func chooseExcludedApp() {
        let menu = NSMenu()
        for app in NSWorkspace.shared.runningApplications.filter({ $0.activationPolicy == .regular }).sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            let item = NSMenuItem(title: "\(app.localizedName ?? id) · \(id)", action: nil, keyEquivalent: "")
            item.representedObject = id; item.image = app.icon
            if let image = item.image?.copy() as? NSImage { image.size = NSSize(width: 16, height: 16); item.image = image }
            menu.addItem(item)
        }
        let picker = NSAlert(); picker.messageText = "选择要排除的应用"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28)); popup.menu = menu
        picker.accessoryView = popup; picker.addButton(withTitle: "添加"); picker.addButton(withTitle: "取消")
        if picker.runModal() == .alertFirstButtonReturn, let id = popup.selectedItem?.representedObject as? String {
            var list = store.value.excludedBundleIDs; list.append(id)
            store.value.excludedBundleIDs = Array(Set(list)).sorted(); exclusions = store.value.excludedBundleIDs.joined(separator: "\n")
        }
    }
}
