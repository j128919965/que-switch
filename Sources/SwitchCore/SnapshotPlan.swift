import Foundation

/// Each visible window gets at most one capture attempt per invocation.
/// Selection and metadata notifications may reprioritize pending work, but
/// cannot restart finished captures. Leaving a page drops its pending work.
public struct SnapshotPlan {
    private var active = false
    private var attempted: Set<WindowKey> = []
    private var pending: [WindowKey] = []
    public init() {}
    public mutating func begin() { active = true; attempted.removeAll(); pending.removeAll() }
    public mutating func end() { active = false; attempted.removeAll(); pending.removeAll() }
    public mutating func update(visible: [WindowKey], selected: WindowKey?) {
        guard active else { return }
        var seen = attempted
        let ordered = selected.flatMap { visible.contains($0) ? [$0] : nil } ?? []
        pending = (ordered + visible).filter { seen.insert($0).inserted }
    }
    public mutating func next() -> WindowKey? {
        guard active, !pending.isEmpty else { return nil }
        let key = pending.removeFirst()
        attempted.insert(key)
        return key
    }
}

public struct PreviewBudget {
    public let pixelScale: Double
    public init(backingScale: Double, onBattery: Bool, lowPowerMode: Bool, saveEnergy: Bool) {
        let scale = backingScale.isFinite ? min(2, max(1, backingScale)) : 1
        pixelScale = saveEnergy && (onBattery || lowPowerMode) ? 1 : scale
    }
}
