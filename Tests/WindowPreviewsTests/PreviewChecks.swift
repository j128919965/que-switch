import Foundation
import CoreGraphics
import SwitchCore
import WindowPreviews

private enum CheckFailure: Error { case failed(String), capture }
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ reason: String) throws {
    guard actual == expected else { throw CheckFailure.failed("\(reason): got \(actual), expected \(expected)") }
}

private actor FakeScreenshots: SnapshotCapturing {
    private var calls: [WindowKey] = []
    private var active = 0
    private var maximumActive = 0
    private var completed = 0
    private let failing: Set<WindowKey>
    init(failing: Set<WindowKey> = []) { self.failing = failing }
    func image(for record: SnapshotWindow, session: UInt64, size: CGSize) async throws -> CGImage {
        calls.append(record.key); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1; completed += 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        if failing.contains(record.key) { throw CheckFailure.capture }
        let bitmap = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return bitmap.makeImage()!
    }
    func statistics() -> (keys: [WindowKey], maximum: Int, completed: Int) { (calls, maximumActive, completed) }
}

@main @MainActor enum PreviewChecks {
    static func waitFor(_ reason: String, until predicate: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CheckFailure.failed("Timed out: \(reason)")
    }

    static func main() async throws {
        let a = SnapshotWindow(key: WindowKey(pid: 1, token: "a"), windowID: 1)
        let b = SnapshotWindow(key: WindowKey(pid: 1, token: "b"), windowID: 2)
        let c = SnapshotWindow(key: WindowKey(pid: 2, token: "c"), windowID: 3)
        let size = CGSize(width: 500, height: 305)
        let source = FakeScreenshots()
        let previews = PreviewService(source: source, hasPermission: { true })
        var delivered: [WindowKey] = []
        previews.begin(records: [a, b], selected: b, preferences: Preferences(), pixelSize: size) { key, image, _ in
            if image != nil { delivered.append(key) }
        }
        try await waitFor("first visible page") { delivered.count == 2 }
        try expect(await source.statistics().keys, [b.key, a.key], "Capture selected card first")
        for i in 0..<500 { previews.updateVisible([a, b], selected: i % 2 == 0 ? a : b) }
        try await Task.sleep(nanoseconds: 150_000_000)
        try expect(await source.statistics().keys.count, 2, "Tab, metadata updates and idle hold must not capture again")
        previews.updateVisible([c], selected: c)
        try await waitFor("new page") { delivered.count == 3 }
        previews.updateVisible([a, b], selected: a)
        try await Task.sleep(nanoseconds: 80_000_000)
        try expect(await source.statistics().keys.count, 3, "Returning to a captured page reuses its snapshots")
        try expect(previews.cached(a.key) != nil, true, "Snapshots remain available for revisiting pages")
        previews.stop()
        print("PASS: actual preview service captures once per visible window, never on idle hold or repeated Tab")

        let slowSource = FakeScreenshots()
        let switching = PreviewService(source: slowSource, hasPermission: { true })
        var accepted: [WindowKey] = []
        switching.begin(records: [a, c], selected: a, preferences: Preferences(), pixelSize: size) { key, _, _ in accepted.append(key) }
        try await waitFor("outstanding old screenshot") { await slowSource.statistics().keys.count == 1 }
        switching.stop()
        switching.begin(records: [b], selected: b, preferences: Preferences(), pixelSize: size) { key, _, _ in accepted.append(key) }
        try await waitFor("new invocation") { accepted.count == 1 }
        try expect(accepted, [b.key], "Released invocation must not deliver late screenshots")
        try expect(switching.cached(a.key) == nil, true, "Stale results cannot enter the cache")
        try expect(await slowSource.statistics().maximum, 1, "Fast release/reopen must never overlap OS screenshot requests")
        switching.stop()
        print("PASS: rapid reopen rejects stale results and preserves a single screenshot worker")

        let stoppedSource = FakeScreenshots()
        let stopped = PreviewService(source: stoppedSource, hasPermission: { true })
        var stoppedDeliveries = 0
        stopped.begin(records: [a, b, c], selected: a, preferences: Preferences(), pixelSize: size) { _, _, _ in stoppedDeliveries += 1 }
        try await waitFor("first request before Escape") { await stoppedSource.statistics().keys.count == 1 }
        stopped.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        try expect(await stoppedSource.statistics().keys.count, 1, "Escape drops all queued screenshots")
        try expect(stoppedDeliveries, 0, "Closed panel never receives images")
        print("PASS: release/Escape discards queued work and late callbacks")

        let failingSource = FakeScreenshots(failing: [a.key])
        let failing = PreviewService(source: failingSource, hasPermission: { true })
        var failures = 0
        failing.begin(records: [a], selected: a, preferences: Preferences(), pixelSize: size) { _, _, status in
            if status != nil { failures += 1 }
        }
        try await waitFor("capture failure") { failures == 1 }
        for _ in 0..<100 { failing.updateVisible([a], selected: a) }
        try await Task.sleep(nanoseconds: 80_000_000)
        try expect(await failingSource.statistics().keys.count, 1, "A failing window cannot cause a retry storm")
        failing.stop()
        let denied = PreviewService(source: failingSource, hasPermission: { false })
        denied.begin(records: [b], selected: b, preferences: Preferences(), pixelSize: size) { _, _, _ in }
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(await failingSource.statistics().keys.count, 1, "No screen capture without permission")
        denied.stop()
        print("PASS: capture failures and missing permissions do not trigger repeated requests")
        print("All 4 preview integration check groups passed; no real windows were captured.")
    }
}
