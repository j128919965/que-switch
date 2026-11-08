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
        let firstSession = epoch.session
        try expect(epoch.accepts(session: firstSession), true, "Other cards may finish their one-shot capture")
        epoch.end()
        try expect(epoch.accepts(session: firstSession), false, "Command release invalidates in-flight captures")
        epoch.begin()
        try expect(epoch.accepts(session: firstSession), false, "A previous invocation cannot reopen the panel")
        print("PASS: stale-frame and session cancellation guards")

        let data = Data(#"{"cardWidth":9999,"livePreview":true,"previewFPS":30,"cacheMegabytes":-1,"accentHex":"oops","excludedBundleIDs":[" com.apple.Safari ","com.apple.Safari",""]}"#.utf8)
        let p = try Preferences.decode(data)
        try expect(p.cardWidth, 400, "Imported card size is bounded")
        try expect(p.energySavingPreviews, true, "Old configurations enable energy-saving snapshots")
        let exported = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        try expect(exported["livePreview"] == nil && exported["previewFPS"] == nil, true, "Legacy live settings cannot enable continuous recording")
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
        var workspace = WorkspaceSession(windows: assignments, displayOrder: [1, 2, 3], pointerDisplay: 1, mode: .perScreen, currentWindow: a)
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

        var grouped = WorkspaceSession(windows: [DisplayWindow(key: a, displayID: 2), DisplayWindow(key: b, displayID: 1), DisplayWindow(key: c, displayID: 2), DisplayWindow(key: d, displayID: 1)], displayOrder: [1, 2], pointerDisplay: 1, mode: .grouped, currentWindow: a)
        try expect(grouped.keys, [b, d, a, c], "Screen groups preserve each screen's recency order")
        try expect(grouped.selected, b, "Grouping preserves initial global MRU toggle")
        grouped.move(1); try expect(grouped.selected, d, "Cycling follows displayed groups")
        grouped.select(c); grouped.refreshMembership([b: 2])
        try expect(grouped.keys, [d, b, a, c], "Moved windows join the correct group")
        try expect(grouped.selected, c, "Regrouping preserves the current selected window")
        print("PASS: grouped ordering, cycling and selection preservation")
        var snapshots = SnapshotPlan(); snapshots.begin()
        snapshots.update(visible: [a, b, c], selected: b)
        try expect(snapshots.next(), b, "Selected preview is captured first")
        snapshots.update(visible: [a, b, c], selected: c)
        try expect(snapshots.next(), c, "Tab reprioritizes pending screenshots")
        snapshots.update(visible: [a], selected: a)
        try expect(snapshots.next(), a, "Leaving a page discards invisible pending work")
        for _ in 0..<500 { snapshots.update(visible: [a, b, c], selected: a) }
        try expect(snapshots.next(), nil, "Metadata changes and Tab never restart completed captures")
        snapshots.end(); snapshots.update(visible: [a], selected: a)
        try expect(snapshots.next(), nil, "No screenshots may start after Command release")
        snapshots.begin(); snapshots.update(visible: [a], selected: a)
        try expect(snapshots.next(), a, "A new invocation gets a fresh screenshot")
        print("PASS: on-demand snapshots, metadata deduplication and stop guards")

        try expect(PreviewBudget(backingScale: 2, onBattery: false, lowPowerMode: false, saveEnergy: true).pixelScale, 2, "Retina quality on AC")
        try expect(PreviewBudget(backingScale: 2, onBattery: true, lowPowerMode: false, saveEnergy: true).pixelScale, 1, "Battery mode uses one quarter of Retina's pixels")
        try expect(PreviewBudget(backingScale: 2, onBattery: false, lowPowerMode: true, saveEnergy: true).pixelScale, 1, "Low Power Mode also conserves preview work")
        try expect(PreviewBudget(backingScale: 2, onBattery: true, lowPowerMode: true, saveEnergy: false).pixelScale, 2, "User may retain full preview resolution")
        print("PASS: battery and Low Power Mode preview budgets")
        let chatGPT = WindowKey(pid: 40, token: "chat"), edge = WindowKey(pid: 50, token: "edge"), edgeOther = WindowKey(pid: 50, token: "edge-other"), code = WindowKey(pid: 60, token: "code")
        let known: Set<WindowKey> = [chatGPT, edge, edgeOther, code]
        var focus = RecencyOrder()
        focus.touch(code); focus.touch(chatGPT)
        focus.observe(frontmostPID: edge.pid, frontToBack: [chatGPT, edge, code, edgeOther], known: known)
        try expect(focus.ordered([chatGPT, code, edge, edgeOther]), [edge, chatGPT, code, edgeOther], "Foreground Edge must precede an old ChatGPT MRU entry even without an AX match")
        focus.observe(frontmostPID: edge.pid, frontToBack: [edgeOther, edge, chatGPT, code], known: known)
        try expect(focus.focused, edgeOther, "Mouse focus within the same application is window-specific")
        focus.observe(frontmostPID: edge.pid, frontToBack: [chatGPT, code, edgeOther, edge], known: known)
        try expect(focus.ordered([chatGPT, code, edge, edgeOther]), [edgeOther, edge, chatGPT, code], "Another app's old window order cannot steal foreground focus")
        let unknown = WindowKey(pid: edge.pid, token: "new-edge")
        focus.observe(frontmostPID: edge.pid, frontToBack: [unknown, edgeOther, edge], known: known)
        try expect(focus.focused, nil, "An unknown new window must not be confused with another window of that app")
        focus.observe(frontmostPID: edge.pid, frontToBack: [edge, edgeOther], known: known)
        focus.observe(frontmostPID: edgeOther.pid, frontToBack: [edgeOther, edge], known: known)
        try expect(focus.ordered([edge, chatGPT, code, edgeOther]), [edgeOther, edge, chatGPT, code], "Returning from an unknown window restores real foreground MRU")
        print("PASS: foreground focus reconciliation, same-app windows and stale-order rejection")

        let repaired = focus.ordered([chatGPT, code, edge, edgeOther])
        let repairedWindows = repaired.map { DisplayWindow(key: $0, displayID: ($0 == edge || $0 == edgeOther) ? 1 : 2) }
        for mode in MultiDisplayMode.allCases {
            let invocation = WorkspaceSession(windows: repairedWindows, displayOrder: [2, 1], pointerDisplay: 1, mode: mode, currentWindow: focus.focused)
            try expect(invocation.selected, edge, "First Tab selects the previous real window in \(mode)")
        }
        let otherScreen = WorkspaceSession(windows: repairedWindows, displayOrder: [1, 2], pointerDisplay: 2, mode: .perScreen, currentWindow: edgeOther)
        try expect(otherScreen.selected, chatGPT, "A different pointer screen selects its first MRU window")
        let excludedCurrent = WorkspaceSession(windows: repairedWindows.filter { $0.key != edge && $0.key != edgeOther }, displayOrder: [1, 2], pointerDisplay: 2, mode: .combined, currentWindow: edgeOther)
        try expect(excludedCurrent.selected, chatGPT, "An excluded current window must not cause the first eligible item to be skipped")
        let frozen = WorkspaceSession(windows: repairedWindows, displayOrder: [1, 2], pointerDisplay: 1, mode: .combined, currentWindow: edgeOther)
        focus.observe(frontmostPID: code.pid, frontToBack: [code, chatGPT, edgeOther, edge], known: known)
        try expect(frozen.keys, repaired, "Focus updates cannot reorder an invocation already being cycled")
        try expect(frozen.selected, edge, "Focus updates cannot move the current selection")
        print("PASS: focus-aware initial Tab target, display modes, excluded current windows and immutable sessions")
        let browserFrame = CGRect(x: 0, y: 25, width: 1200, height: 850)
        let findFrame = CGRect(x: 750, y: 110, width: 430, height: 60)
        let smallFrame = CGRect(x: 100, y: 150, width: 300, height: 200)
        let browserSurfaces: [WindowInventory.ServerWindow] = [
            .init(title: "在页面上查找", frame: findFrame),
            .init(title: "Edge page", frame: browserFrame),
            .init(title: "在页面上查找", frame: smallFrame)
        ]
        let browserWindows: [WindowInventory.AccessibilityWindow] = [
            .init(title: "Edge page", frame: browserFrame, role: "AXWindow", subrole: "AXStandardWindow"),
            .init(title: "在页面上查找", frame: smallFrame, role: "AXWindow", subrole: "AXStandardWindow")
        ]
        let browserInventory = WindowInventory.reconcile(server: browserSurfaces, accessibility: browserWindows)
        try expect(browserInventory, [.init(serverIndex: 1, accessibilityIndex: 0), .init(serverIndex: 2, accessibilityIndex: 1)],
            "A CG-only find bar is excluded while both real Edge windows remain, even with the same title or a small frame")
        let findWindow = WindowInventory.AccessibilityWindow(title: "在页面上查找", frame: findFrame,
            role: "AXWindow", subrole: "AXStandardWindow", canBecomeMain: false)
        let realWindows = browserWindows.map {
            WindowInventory.AccessibilityWindow(title: $0.title, frame: $0.frame, role: $0.role, subrole: $0.subrole, canBecomeMain: true)
        }
        try expect(WindowInventory.reconcile(server: browserSurfaces, accessibility: realWindows + [findWindow]), browserInventory,
            "Edge's find bar can also report AXStandardWindow; it cannot become main, whereas background browser windows can")
        try expect(WindowInventory.reconcile(server: [], accessibility: [findWindow]), [],
            "An AX-only child find bar must also be excluded")
        try expect(WindowInventory.reconcile(server: browserSurfaces, accessibility: nil).count, 3,
            "Missing AX permission or an unsuccessful query retains the WindowServer fallback")
        try expect(WindowInventory.reconcile(server: browserSurfaces, accessibility: []).count, 0,
            "An app reporting no top-level windows cannot contribute child surfaces")
        print("PASS: child-surface exclusion, genuine small windows and unavailable AX fallback")

        let dialogWindows: [WindowInventory.AccessibilityWindow] = [
            .init(title: "Inspector", frame: browserFrame, role: "AXWindow", subrole: "AXFloatingWindow"),
            .init(title: "Save", frame: smallFrame, role: "AXWindow", subrole: "AXDialog"),
            .init(title: "Sheet", frame: smallFrame, role: "AXSheet", subrole: nil),
            .init(title: "Hidden document", frame: findFrame, role: "AXWindow", subrole: "AXStandardWindow")
        ]
        try expect(WindowInventory.reconcile(server: [.init(title: "Inspector", frame: browserFrame), .init(title: "Save", frame: smallFrame)], accessibility: dialogWindows),
            [.init(serverIndex: 1, accessibilityIndex: 1), .init(serverIndex: nil, accessibilityIndex: 3)],
            "Floating surfaces and sheets are excluded on both paths; independent dialogs and AX-only hidden/minimized windows remain")
        let ambiguous = [browserWindows[0], browserWindows[0]]
        try expect(WindowInventory.reconcile(server: [.init(title: "Edge page", frame: browserFrame)], accessibility: ambiguous),
            [.init(serverIndex: nil, accessibilityIndex: 0), .init(serverIndex: nil, accessibilityIndex: 1)],
            "Ambiguous geometry must never associate a screenshot with an arbitrary AX activation target")
        print("PASS: consistent AX eligibility, independent dialogs and ambiguous matches")
        let relocatedFrame = CGRect(x: 80, y: 30, width: 1000, height: 740)
        let unplugged = WindowInventory.reconcile(server: [.init(title: "Edge page", frame: relocatedFrame)],
            accessibility: [browserWindows[0]])
        try expect(unplugged, [.init(serverIndex: 0, accessibilityIndex: 0)],
            "After display unplug, a uniquely titled real window must retain its live server ID despite stale AX geometry")
        let edgeTitle = WindowInventory.AccessibilityWindow(title: "Edge page - Microsoft Edge", frame: browserFrame,
            role: "AXWindow", subrole: "AXStandardWindow", canBecomeMain: true)
        try expect(WindowInventory.reconcile(server: [.init(id: 100, title: "Edge page", frame: relocatedFrame)],
            accessibility: [edgeTitle], applicationName: "Microsoft Edge"), unplugged,
            "A recreated AX reference with Edge's app-name suffix must regain its screenshot ID without stale geometry")
        let twins: [WindowInventory.AccessibilityWindow] = [
            .init(title: "same tab", frame: browserFrame, role: "AXWindow", subrole: "AXStandardWindow", knownServerID: 100),
            .init(title: "same tab", frame: relocatedFrame, role: "AXWindow", subrole: "AXStandardWindow", knownServerID: 200)
        ]
        let swapped = WindowInventory.reconcile(server: [.init(id: 200, title: "same tab", frame: browserFrame),
            .init(id: 100, title: "same tab", frame: relocatedFrame)], accessibility: twins)
        try expect(swapped, [.init(serverIndex: 0, accessibilityIndex: 1), .init(serverIndex: 1, accessibilityIndex: 0)],
            "Confirmed IDs take precedence when same-title windows move into each other's old frames")
        let staleChild = WindowInventory.AccessibilityWindow(title: "在页面上查找 - Microsoft Edge", frame: browserFrame,
            role: "AXWindow", subrole: "AXStandardWindow", canBecomeMain: false)
        try expect(WindowInventory.reconcile(server: [.init(title: "在页面上查找", frame: findFrame)],
            accessibility: [staleChild], applicationName: "Microsoft Edge"), [],
            "Title-based recovery cannot reintroduce the child find bar")
        let duplicateServers: [WindowInventory.ServerWindow] = [
            .init(title: "Edge page", frame: relocatedFrame), .init(title: "Edge page", frame: findFrame)
        ]
        try expect(WindowInventory.reconcile(server: duplicateServers, accessibility: [browserWindows[0]]),
            [.init(serverIndex: nil, accessibilityIndex: 0)], "Nonunique server titles cannot invent a screenshot association")
        try expect(DisplayGeometry.owner(of: relocatedFrame, displays: [displays[0]]), 1,
            "A recovered window uses its current server frame on the remaining display")
        print("PASS: window identity across display geometry changes")
        print("All 15 check groups passed.")
    }
}
