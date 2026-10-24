import Foundation

public struct DisplayWindow {
    public let key: WindowKey
    public let displayID: UInt32
    public init(key: WindowKey, displayID: UInt32) { self.key = key; self.displayID = displayID }
}

/// One immutable ordering per invocation, with independent selections on each
/// display. Moving the pointer changes the receiver, never another display's
/// saved selection. An empty display deliberately has no activation target.
public struct WorkspaceSession {
    public let mode: MultiDisplayMode
    public private(set) var activeDisplay: UInt32
    public private(set) var membership: [WindowKey: UInt32]
    private let displayOrder: [UInt32]
    private var global: SwitchSession
    private var local: [UInt32: SwitchSession]

    public init(windows: [DisplayWindow], displayOrder: [UInt32], pointerDisplay: UInt32,
                mode: MultiDisplayMode, reverse: Bool = false, currentWindow: WindowKey? = nil) {
        self.mode = mode; activeDisplay = pointerDisplay
        self.displayOrder = displayOrder
        membership = Dictionary(windows.map { ($0.key, $0.displayID) }, uniquingKeysWith: { first, _ in first })
        let ordered = mode == .grouped
            ? displayOrder.flatMap { id in windows.filter { $0.displayID == id }.map(\.key) }
            : windows.map(\.key)
        global = SwitchSession(keys: ordered, reverse: reverse)
        // Skip the actual current window, not an assumed first item. When the
        // foreground window is excluded or on another display, select the
        // first eligible MRU window rather than skipping it too.
        let keys = windows.map(\.key)
        if let target = reverse ? keys.last : (keys.first { $0 != currentWindow } ?? keys.first) { global.select(target) }
        local = [:]
        for id in displayOrder {
            let keys = windows.filter { $0.displayID == id }.map(\.key)
            var session = SwitchSession(keys: keys, reverse: reverse)
            if let target = reverse ? keys.last : (keys.first { $0 != currentWindow } ?? keys.first) { session.select(target) }
            local[id] = session
        }
    }

    public var keys: [WindowKey] { global.keys }
    public var selected: WindowKey? { mode == .perScreen ? local[activeDisplay]?.selected : global.selected }
    public var activeKeys: [WindowKey] { mode == .perScreen ? keys(on: activeDisplay) : global.keys }
    public func keys(on display: UInt32) -> [WindowKey] { local[display]?.keys ?? [] }
    public func selected(on display: UInt32) -> WindowKey? { local[display]?.selected }
    public mutating func focus(_ display: UInt32) { if mode == .perScreen, local[display] != nil { activeDisplay = display } }
    public mutating func move(_ delta: Int) {
        if mode == .perScreen { local[activeDisplay]?.move(delta) } else { global.move(delta) }
    }
    public mutating func select(_ key: WindowKey) {
        guard let display = membership[key] else { return }
        if mode == .perScreen { activeDisplay = display; local[display]?.select(key) }
        else { global.select(key) }
    }
    public mutating func remove(_ key: WindowKey) {
        if let display = membership.removeValue(forKey: key) { local[display]?.remove(key) }
        global.remove(key)
    }

    public mutating func refreshMembership(_ assignments: [WindowKey: UInt32]) {
        let oldSelection = global.selected
        for key in global.keys { if let display = assignments[key] { membership[key] = display } }
        for display in displayOrder {
            let selected = local[display]?.selected
            let keys = global.keys.filter { membership[$0] == display }
            var replacement = SwitchSession(keys: keys)
            if let selected, keys.contains(selected) { replacement.select(selected) }
            else if let first = keys.first { replacement.select(first) }
            local[display] = replacement
        }
        if mode == .grouped {
            let ordered = displayOrder.flatMap { display in global.keys.filter { membership[$0] == display } }
            global = SwitchSession(keys: ordered)
            if let oldSelection { global.select(oldSelection) }
        }
    }
}
