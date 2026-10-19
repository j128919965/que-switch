import Foundation

public struct WindowKey: Hashable, Codable, CustomStringConvertible {
    public let pid: Int32
    public let token: String
    public init(pid: Int32, token: String) { self.pid = pid; self.token = token }
    public var description: String { "\(pid):\(token)" }
}

public struct RecencyOrder {
    private var sequence: UInt64 = 0
    private var timestamps: [WindowKey: UInt64] = [:]
    public init() {}
    public mutating func touch(_ key: WindowKey) { sequence += 1; timestamps[key] = sequence }
    public mutating func prune(keeping keys: Set<WindowKey>) { timestamps = timestamps.filter { keys.contains($0.key) } }
    public func ordered(_ frontToBack: [WindowKey]) -> [WindowKey] {
        let positions = Dictionary(frontToBack.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return Array(Set(frontToBack)).sorted {
            let a = timestamps[$0] ?? 0, b = timestamps[$1] ?? 0
            return a == b ? positions[$0]! < positions[$1]! : a > b
        }
    }
}

public struct SwitchSession {
    public private(set) var keys: [WindowKey]
    public private(set) var index: Int
    public var selected: WindowKey? { keys.isEmpty ? nil : keys[index] }
    public init(keys: [WindowKey], reverse: Bool = false) {
        self.keys = keys
        self.index = keys.count < 2 ? 0 : (reverse ? keys.count - 1 : 1)
    }
    public mutating func move(_ delta: Int) {
        guard !keys.isEmpty else { return }
        index = ((index + delta) % keys.count + keys.count) % keys.count
    }
    public mutating func select(_ key: WindowKey) {
        if let index = keys.firstIndex(of: key) { self.index = index }
    }
    public mutating func remove(_ key: WindowKey) {
        guard let removed = keys.firstIndex(of: key) else { return }
        keys.remove(at: removed)
        if removed < index { index -= 1 }
        index = keys.isEmpty ? 0 : min(index, keys.count - 1)
    }
}

/// A screenshot may finish after Command is released. Only results from the
/// active invocation can enter the cache or update its cards.
public struct CaptureEpoch {
    public private(set) var session: UInt64 = 0
    public private(set) var active = false
    public init() {}
    public mutating func begin() { session += 1; active = true }
    public mutating func end() { active = false; session += 1 }
    public func accepts(session: UInt64) -> Bool { active && self.session == session }
}
