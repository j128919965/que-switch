import Foundation
import CoreGraphics
import SwitchCore

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ reason: String) throws {
    if actual != expected { throw CheckFailure(description: "\(reason): got \(actual), expected \(expected)") }
}

/// Runs with Apple's Command Line Tools alone; no XCTest/Xcode dependency.
@main enum CoreChecks {
    static func main() throws {
        let a = WindowKey(pid: 10, token: "1"), b = WindowKey(pid: 10, token: "2"), c = WindowKey(pid: 20, token: "3")
        var order = RecencyOrder()
        try expect(order.ordered([a, b, c]), [a, b, c], "Initial WindowServer order")
        order.touch(b); order.touch(c); order.touch(a)
        try expect(order.ordered([c, b, a]), [a, c, b], "MRU must track windows within the same app independently")
        order.prune(keeping: [b, c])
        try expect(order.ordered([a, b, c]), [c, b, a], "Terminated windows must not keep recency")
        print("PASS: window-level recency")

        var session = SwitchSession(keys: [a, b, c])
        try expect(session.selected, b, "Fast toggle selects previous window")
        session.move(1); try expect(session.selected, c, "Forward cycle")
        session.move(1); try expect(session.selected, a, "Forward wrap")
        session.move(-1); try expect(session.selected, c, "Reverse wrap")
        session.remove(a); try expect(session.selected, c, "Removing an earlier card preserves selection")
        session.remove(c); try expect(session.selected, b, "Closing selected card selects remaining window")
        session.remove(b); session.move(-10); try expect(session.selected, nil, "Empty session")
        try expect(SwitchSession(keys: [a, b, c], reverse: true).selected, c, "Reverse initial selection")
        print("PASS: fast toggle, reverse, wrap and closing during a session")

        var epoch = CaptureEpoch(); epoch.begin()
        let firstSession = epoch.session, firstSelection = epoch.selection
        epoch.select()
        try expect(epoch.accepts(session: firstSession), true, "Other cards may finish their one-shot capture")
        try expect(epoch.accepts(session: firstSession, selection: firstSelection), false, "Late live frame must not overwrite a new selection")
        epoch.end()
        try expect(epoch.accepts(session: firstSession), false, "Command release invalidates in-flight captures")
        epoch.begin()
        try expect(epoch.accepts(session: firstSession), false, "A previous invocation cannot reopen the panel")
        print("PASS: stale-frame and session cancellation guards")

        let data = Data(#"{"cardWidth":9999,"previewFPS":0,"cacheMegabytes":-1,"accentHex":"oops","excludedBundleIDs":[" com.apple.Safari ","com.apple.Safari",""]}"#.utf8)
        let p = try Preferences.decode(data)
        try expect(p.cardWidth, 400, "Imported card size is bounded")
        try expect(p.previewFPS, 1, "Imported frame rate is bounded")
        try expect(p.cacheMegabytes, 8, "Imported cache is bounded")
        try expect(p.accentHex, "5A9CF8", "Invalid color uses default")
        try expect(p.scope, .currentDesktop, "Older exports retain new defaults")
        try expect(p.multiDisplayMode, .combined, "Old configurations keep the original combined display mode")
        try expect(p.excludedBundleIDs, ["com.apple.Safari"], "Normalize exclusions")
        do {
            _ = try Preferences.decode(Data("[]".utf8))
            throw CheckFailure(description: "Invalid configuration was accepted")
        } catch is Preferences.ConfigurationError { }
        print("PASS: configuration migration, validation and invalid-file rejection")
        let displays = [
            DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            DisplayGeometry(id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)),
            DisplayGeometry(id: 3, frame: CGRect(x: -1280, y: 0, width: 1280, height: 800)),
            DisplayGeometry(id: 4, frame: CGRect(x: 0, y: -1200, width: 1600, height: 1200))
        ]
        try expect(DisplayGeometry.owner(of: CGRect(x: 1500, y: 40, width: 600, height: 700), displays: displays), 2, "External display ownership")
        try expect(DisplayGeometry.owner(of: CGRect(x: 1300, y: 40, width: 500, height: 700), displays: displays), 2, "Spanning window belongs to its largest overlap, exactly once")
        try expect(DisplayGeometry.owner(of: CGRect(x: -1100, y: 40, width: 600, height: 700), displays: displays), 3, "Display left of primary with negative coordinates")
        let upper = DisplayGeometry.quartzFrame(appKitFrame: CGRect(x: 0, y: 900, width: 1600, height: 1200), primaryTop: 900)
        try expect(upper, displays[3].frame, "Vertically stacked display coordinate conversion")
        try expect(DisplayGeometry.owner(of: CGRect(x: 100, y: -1000, width: 600, height: 700), displays: displays), 4, "Display above primary")
        try expect(DisplayGeometry.owner(of: CGRect(x: 4000, y: 0, width: 100, height: 100), displays: displays), 2, "Off-screen window falls back to nearest display")
        print("PASS: multi-display geometry, spanning windows and negative origins")

        let portrait = PreviewGeometry.outputSize(window: CGSize(width: 720, height: 900), limit: CGSize(width: 500, height: 305))
        try expect(portrait, CGSize(width: 244, height: 305), "Portrait output preserves the whole window's aspect ratio")
        let crop = PreviewGeometry.cropRect(content: CGRect(x: 0, y: 0, width: 122, height: 152.5), scaleFactor: 2, surface: CGSize(width: 500, height: 305))
        try expect(crop, CGRect(x: 0, y: 0, width: 244, height: 305), "Strip capture surface padding at Retina scale")
        let centered = PreviewGeometry.centeredFrame(image: crop!.size, in: CGRect(x: 0, y: 0, width: 500, height: 305))
        try expect(centered.minX, 128, "Snapped window has equal left and right gutters")
        try expect(centered.maxX, 372, "Portrait preview remains centered")
        try expect(PreviewGeometry.cropRect(content: .zero, scaleFactor: 0, surface: CGSize(width: 500, height: 305)), nil, "Malformed metadata does not crop away the image")
        print("PASS: portrait framing, capture padding and centered presentation")

        let d = WindowKey(pid: 30, token: "4")
        let assignments = [DisplayWindow(key: a, displayID: 1), DisplayWindow(key: b, displayID: 1), DisplayWindow(key: c, displayID: 2), DisplayWindow(key: d, displayID: 2)]
        var workspace = WorkspaceSession(windows: assignments, displayOrder: [1, 2, 3], pointerDisplay: 1, mode: .perScreen)
        try expect(workspace.selected, b, "Initial toggle stays on pointer's screen")
        workspace.focus(2); try expect(workspace.selected, c, "Other screen begins with its most recent window")
        workspace.move(1); try expect(workspace.selected, d, "Tab changes only active screen")
        workspace.focus(1); try expect(workspace.selected, b, "Moving pointer restores this screen's selection")
        workspace.focus(2); try expect(workspace.selected, d, "Other screen selection remains untouched")
        workspace.focus(3); try expect(workspace.selected, nil, "An empty screen must never activate a window on another screen")
        workspace.focus(2); workspace.remove(d); try expect(workspace.selected, c, "Closed target stays within its screen")
        workspace.refreshMembership([c: 1])
        try expect(workspace.selected, nil, "Moving the last window away leaves no stale activation target")
        try expect(workspace.keys(on: 1), [a, b, c], "Moving a window updates its monitor membership without duplication")
        print("PASS: independent per-screen selection, pointer routing, empty screens and moved windows")

        var grouped = WorkspaceSession(windows: [DisplayWindow(key: a, displayID: 2), DisplayWindow(key: b, displayID: 1), DisplayWindow(key: c, displayID: 2), DisplayWindow(key: d, displayID: 1)], displayOrder: [1, 2], pointerDisplay: 1, mode: .grouped)
        try expect(grouped.keys, [b, d, a, c], "Screen groups preserve each screen's recency order")
        try expect(grouped.selected, b, "Grouping preserves initial global MRU toggle")
        grouped.move(1); try expect(grouped.selected, d, "Cycling follows displayed groups")
        grouped.select(c); grouped.refreshMembership([b: 2])
        try expect(grouped.keys, [d, b, a, c], "Moved windows join the correct group")
        try expect(grouped.selected, c, "Regrouping preserves the current selected window")
        print("PASS: grouped ordering, cycling and selection preservation")
        print("All 8 check groups passed.")
    }
}
