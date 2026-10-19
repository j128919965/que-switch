import AppKit
import SwitchCore

struct PreviewPresentation {
    var image: CGImage?
    var status: String?
}

private final class WindowCard: NSView {
    let record: WindowRecord
    private let appIcon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let preview = NSImageView()
    private let placeholder = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    var onSelect: (() -> Void)?
    var onHover: (() -> Void)?
    var onClose: (() -> Void)?
    private var tracking: NSTrackingArea?
    var selected = false { didSet { updateColors() } }
    var active = true { didSet { updateColors() } }
    private let preferences: Preferences

    init(record: WindowRecord, preferences: Preferences, frame: NSRect) {
        self.record = record; self.preferences = preferences
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = preferences.cornerRadius; layer?.borderWidth = 2
        appIcon.image = record.icon; appIcon.imageScaling = .scaleProportionallyUpOrDown
        // This is the application's own icon, never a page favicon or a
        // generated monogram. Multiple windows of one app share it.
        appIcon.toolTip = record.appName
        title.stringValue = preferences.showTitles ? record.title : record.appName
        title.font = .systemFont(ofSize: 12); title.lineBreakMode = .byTruncatingTail
        title.toolTip = "\(record.appName) — \(record.title)"
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭窗口")
        closeButton.isBordered = false; closeButton.bezelStyle = .inline
        closeButton.target = self; closeButton.action = #selector(closeWindow)
        closeButton.toolTip = "关闭此窗口"; closeButton.setAccessibilityLabel("关闭 \(record.title)")
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignCenter
        preview.wantsLayer = true; preview.layer?.cornerRadius = 5; preview.layer?.masksToBounds = true
        placeholder.image = record.icon; placeholder.imageScaling = .scaleProportionallyUpOrDown
        badge.font = .systemFont(ofSize: 11); badge.textColor = .secondaryLabelColor
        badge.alignment = .center; badge.wantsLayer = true; badge.layer?.cornerRadius = 4
        for view in [preview, placeholder, appIcon, title, closeButton, badge] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("\(record.appName)，\(record.title)\(record.minimized ? "，已最小化" : "")")
        updateColors(); layout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    override func layout() {
        super.layout()
        let top = bounds.height - 33
        appIcon.frame = NSRect(x: 11, y: top + 4, width: 18, height: 18)
        closeButton.frame = NSRect(x: bounds.width - 30, y: top + 2, width: 23, height: 23)
        title.frame = NSRect(x: 36, y: top + 5, width: max(20, bounds.width - 70), height: 18)
        preview.frame = NSRect(x: 9, y: 9, width: bounds.width - 18, height: max(20, top - 11))
        placeholder.frame = NSRect(x: preview.frame.midX - 24, y: preview.frame.midY - 24, width: 48, height: 48)
        badge.sizeToFit()
        badge.frame = NSRect(x: max(12, bounds.width - badge.frame.width - 22), y: 15, width: min(bounds.width - 28, badge.frame.width + 10), height: 19)
    }
    func setPreview(_ presentation: PreviewPresentation) {
        preview.image = presentation.image.map { NSImage(cgImage: $0, size: .zero) }
        placeholder.isHidden = presentation.image != nil
        badge.stringValue = presentation.status ?? ""
        badge.isHidden = presentation.status == nil
        needsLayout = true
    }
    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.borderColor = (selected ? (active ? NSColor(hex: preferences.accentHex) : NSColor(hex: dark ? "626978" : "AEB5C6")) : .clear).cgColor
        layer?.backgroundColor = (selected ? NSColor(hex: dark ? "303440" : "F4F5F8") : .clear).cgColor
        preview.layer?.backgroundColor = NSColor(hex: dark ? "1D222C" : "FFFFFF").cgColor
        badge.layer?.backgroundColor = NSColor(hex: dark ? "252832" : "E8EBF1").cgColor
        title.textColor = NSColor(hex: dark ? "F1F3F9" : "20242D")
        badge.textColor = NSColor(hex: dark ? "AEB5C6" : "626978")
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        self.tracking = tracking; addTrackingArea(tracking)
    }
    override func mouseEntered(with event: NSEvent) { if preferences.hoverSelect { onHover?() } }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    @objc private func closeWindow() { onClose?() }
}

struct WindowPanelGroup {
    let displayID: UInt32
    let title: String
    let records: [WindowRecord]
}

private struct PanelRow {
    var title: String?
    var records: [WindowRecord]
    var height: CGFloat
}

final class SwitcherPanel: NSPanel {
    private let backdrop = NSVisualEffectView()
    private let surface = NSView()
    private let footer = NSTextField(labelWithString: "")
    private let keysHint = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "此屏幕没有可切换的窗口")
    private var groupLabels: [NSTextField] = []
    private var cards: [WindowKey: WindowCard] = [:]
    private var pageKeys: [WindowKey] = []
    private var pageContent: [String] = []
    private var pageHeaders: [String] = []
    private(set) var columns = 1
    private var pageCapacity = 1
    private var preferences = Preferences()
    private var screenFrame = NSRect.zero
    var onSelect: ((WindowKey, Bool) -> Void)?
    var onClose: ((WindowKey) -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true; hidesOnDeactivate = false
        title = "窗口切换器"
        level = .popUpMenu; animationBehavior = .none; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        acceptsMouseMovedEvents = true
        backdrop.material = .hudWindow; backdrop.blendingMode = .behindWindow; backdrop.state = .active
        backdrop.wantsLayer = true; backdrop.layer?.cornerRadius = 18; backdrop.layer?.masksToBounds = true
        surface.wantsLayer = true; surface.layer?.cornerRadius = 18; surface.layer?.masksToBounds = true
        contentView = backdrop; backdrop.addSubview(surface)
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor; footer.lineBreakMode = .byTruncatingMiddle
        keysHint.font = .systemFont(ofSize: 11); keysHint.textColor = .secondaryLabelColor; keysHint.alignment = .right
        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.lineBreakMode = .byTruncatingTail
        emptyLabel.font = .systemFont(ofSize: 13); emptyLabel.alignment = .center
        for label in [footer, keysHint, captionLabel, emptyLabel] { surface.addSubview(label) }
        setAccessibilityLabel("窗口切换器")
    }

    func reset() {
        pageKeys = []; pageContent = []; pageHeaders = []
        cards.values.forEach { $0.removeFromSuperview() }; cards.removeAll()
        groupLabels.forEach { $0.removeFromSuperview() }; groupLabels.removeAll()
    }

    @discardableResult
    func update(records: [WindowRecord], selected: WindowKey?, preferences: Preferences,
                previews: [WindowKey: PreviewPresentation], screen: NSScreen,
                groups: [WindowPanelGroup] = [], caption: String? = nil, active: Bool = true) -> (visible: [WindowRecord], changed: Bool) {
        self.preferences = preferences
        let visibleFrame = screen.visibleFrame
        screenFrame = visibleFrame
        switch preferences.appearance {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        let cardWidth = min(preferences.cardWidth, visibleFrame.width - 64)
        let gap: CGFloat = 12, padding: CGFloat = 18, footerHeight: CGFloat = 32
        let captionHeight: CGFloat = caption == nil ? 0 : 28
        let cardHeight = cardWidth * 0.61 + 42
        columns = max(1, min(preferences.columns, records.count, Int((visibleFrame.width - 64) / (cardWidth + gap))))
        let available = max(cardHeight + 36, visibleFrame.height * 0.78 - padding * 2 - footerHeight - captionHeight)
        var pages: [[PanelRow]] = [], rows: [PanelRow] = []
        var used: CGFloat = 0
        func finishPage() {
            if !rows.isEmpty { pages.append(rows) }
            rows = []; used = 0
        }
        func add(_ row: PanelRow) {
            if !rows.isEmpty { used += gap }
            rows.append(row); used += row.height
        }
        let sections: [(String?, [WindowRecord])] = groups.isEmpty ? [(nil, records)] : groups.filter { !$0.records.isEmpty }.map { ($0.title, $0.records) }
        for (title, windows) in sections {
            var start = 0
            while start < windows.count {
                let needsHeader = title != nil && (start == 0 || rows.isEmpty)
                let required = cardHeight + (needsHeader ? 24 + gap : 0) + (rows.isEmpty ? 0 : gap)
                if used + required > available, !rows.isEmpty { finishPage(); continue }
                if needsHeader { add(PanelRow(title: title, records: [], height: 24)) }
                let end = min(windows.count, start + columns)
                add(PanelRow(title: nil, records: Array(windows[start..<end]), height: cardHeight))
                start = end
            }
        }
        finishPage()
        if pages.isEmpty { pages = [[PanelRow(title: nil, records: [], height: 100)]] }
        let index = records.firstIndex { $0.key == selected } ?? 0
        let page = pages.firstIndex { $0.contains { $0.records.contains { $0.key == selected } } } ?? 0
        let visibleRows = pages[page]
        let shown = visibleRows.flatMap(\.records)
        pageCapacity = shown.count
        let width = padding * 2 + CGFloat(columns) * cardWidth + CGFloat(columns - 1) * gap
        // Use the tallest page's height to avoid moving the panel each time
        // Tab crosses a screen group or the last, partially filled page.
        let contentHeight = pages.map { $0.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(0, $0.count - 1)) * gap }.max() ?? 100
        let height = padding * 2 + contentHeight + footerHeight + captionHeight
        let panelFrame = NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2 + 18, width: width, height: height)
        let contentSignature = shown.map { "\($0.title)|\($0.minimized)|\($0.hidden)" }
        let headers = visibleRows.compactMap(\.title)
        let changed = shown.map(\.key) != pageKeys || contentSignature != pageContent || headers != pageHeaders || frame.size != panelFrame.size
        setFrame(panelFrame, display: false)
        backdrop.frame = NSRect(origin: .zero, size: panelFrame.size); surface.frame = backdrop.bounds
        let blur = preferences.useBlur && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        backdrop.state = blur ? .active : .inactive
        let dark = backdrop.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        surface.layer?.backgroundColor = NSColor(hex: dark ? "252832" : "E8EBF1").withAlphaComponent(blur ? 0.85 : 1).cgColor
        let muted = NSColor(hex: dark ? "AEB5C6" : "626978")
        footer.textColor = muted; keysHint.textColor = muted; emptyLabel.textColor = muted
        captionLabel.textColor = active ? NSColor(hex: preferences.accentHex) : muted
        captionLabel.stringValue = caption.map { "\($0) · \(active ? "正在操作" : "移到此屏操作")" } ?? ""
        title = caption.map { "窗口切换器 · \($0)" } ?? "窗口切换器"
        captionLabel.isHidden = caption == nil
        captionLabel.frame = NSRect(x: padding + 3, y: height - padding - 20, width: width - padding * 2 - 6, height: 20)
        emptyLabel.isHidden = !records.isEmpty
        emptyLabel.frame = NSRect(x: padding, y: padding + footerHeight + 40, width: width - padding * 2, height: 22)
        if changed {
            cards.values.forEach { $0.removeFromSuperview() }; cards.removeAll()
            groupLabels.forEach { $0.removeFromSuperview() }; groupLabels.removeAll()
            pageKeys = shown.map(\.key)
            pageContent = contentSignature
            pageHeaders = headers
            var top = height - padding - captionHeight
            for row in visibleRows {
                top -= row.height
                if let title = row.title {
                    let label = NSTextField(labelWithString: title)
                    label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = muted
                    label.frame = NSRect(x: padding + 3, y: top + 2, width: width - padding * 2 - 6, height: 20)
                    surface.addSubview(label); groupLabels.append(label)
                }
                for (col, record) in row.records.enumerated() {
                    let rect = NSRect(x: padding + CGFloat(col) * (cardWidth + gap), y: top, width: cardWidth, height: cardHeight)
                    let card = WindowCard(record: record, preferences: preferences, frame: rect)
                    card.onSelect = { [weak self] in self?.onSelect?(record.key, true) }
                    card.onHover = { [weak self] in self?.onSelect?(record.key, false) }
                    card.onClose = { [weak self] in self?.onClose?(record.key) }
                    cards[record.key] = card; surface.addSubview(card)
                }
                top -= gap
            }
        }
        for record in shown {
            cards[record.key]?.active = active
            cards[record.key]?.selected = record.key == selected
            cards[record.key]?.setPreview(previews[record.key] ?? PreviewPresentation(image: nil, status: "正在刷新…"))
        }
        let current = records.first { $0.key == selected }
        footer.stringValue = "\(records.isEmpty ? 0 : index + 1) / \(records.count) · \(current?.appName ?? "")"
        let modifier = preferences.modifier == .command ? "⌘" : (preferences.modifier == .option ? "⌥" : "⌃")
        let keyName = preferences.shortcutKey == 48 ? "Tab" : "`"
        keysHint.stringValue = width < 400 ? "松开 \(modifier) 确认 · Esc 取消" : "\(keyName) 切换 · 松开 \(modifier) 确认 · Esc 取消"
        let hintWidth = min(width * 0.66, keysHint.intrinsicContentSize.width)
        keysHint.frame = NSRect(x: width - padding - hintWidth, y: padding - 2, width: hintWidth, height: 18)
        footer.frame = NSRect(x: padding + 3, y: padding - 2, width: max(0, width - padding * 2 - hintWidth - 12), height: 18)
        return (shown, changed)
    }

    func setPreview(_ presentation: PreviewPresentation, for key: WindowKey) { cards[key]?.setPreview(presentation) }

    func present(animated: Bool) {
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = animate ? 0 : 1
        orderFrontRegardless()
        if animate { NSAnimationContext.runAnimationGroup { context in context.duration = 0.08; animator().alphaValue = 1 } }
    }

    func dismiss() { orderOut(nil); alphaValue = 1 }
}
