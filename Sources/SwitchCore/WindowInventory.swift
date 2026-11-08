import Foundation

/// Reconcile WindowServer surfaces with an app's top-level Accessibility
/// windows. A child control can have its own surface without being a window
/// the user can switch to (for example, Chromium's find-in-page bar).
public enum WindowInventory {
    public struct ServerWindow {
        public let id: UInt32?
        public let title: String
        public let frame: CGRect
        public init(id: UInt32? = nil, title: String, frame: CGRect) { self.id = id; self.title = title; self.frame = frame }
    }

    public struct AccessibilityWindow {
        public let title: String
        public let frame: CGRect?
        public let role: String?
        public let subrole: String?
        public let canBecomeMain: Bool?
        public let knownServerID: UInt32?
        public init(title: String, frame: CGRect?, role: String?, subrole: String?, canBecomeMain: Bool? = nil,
                    knownServerID: UInt32? = nil) {
            self.title = title; self.frame = frame; self.role = role; self.subrole = subrole
            self.canBecomeMain = canBecomeMain; self.knownServerID = knownServerID
        }

        fileprivate var eligible: Bool {
            guard let frame, frame.width >= 50, frame.height >= 40 else { return false }
            return canBecomeMain != false && (role == nil || role == "AXWindow") &&
                subrole != "AXFloatingWindow" && subrole != "AXSystemFloatingWindow"
        }
    }

    public struct Match: Equatable {
        public let serverIndex: Int?
        public let accessibilityIndex: Int?
        public init(serverIndex: Int?, accessibilityIndex: Int?) {
            self.serverIndex = serverIndex; self.accessibilityIndex = accessibilityIndex
        }
    }

    /// nil means the AX request failed or permission is missing. An empty
    /// array means the app successfully reported no top-level windows.
    public static func reconcile(server: [ServerWindow], accessibility: [AccessibilityWindow]?,
                                 applicationName: String = "") -> [Match] {
        let indices = server.indices.filter { server[$0].frame.width >= 50 && server[$0].frame.height >= 40 }
        guard let accessibility else { return indices.map { Match(serverIndex: $0, accessibilityIndex: nil) } }
        var paired: [Int: Int] = [:], used: Set<Int> = []
        func claim(_ index: Int, _ candidates: [Int]) {
            if candidates.count == 1, let candidate = candidates.first {
                paired[index] = candidate; used.insert(candidate)
            }
        }
        // A confirmed AX element / WindowServer ID association survives moves,
        // resizing and display-origin changes. Resolve these before geometry
        // so another surface at the old coordinates cannot steal the target.
        for index in indices {
            guard let id = server[index].id else { continue }
            claim(index, accessibility.indices.filter { !used.contains($0) && accessibility[$0].knownServerID == id })
        }
        let serverTitles = server.map { matchingTitle($0.title, applicationName: applicationName) }
        let axTitles = accessibility.map { matchingTitle($0.title, applicationName: applicationName) }
        // WindowServer can already have the post-unplug frame while the app
        // still exposes the old AX frame. Only pair titles unique on BOTH
        // sides; duplicate/empty titles must never choose an arbitrary window.
        for index in indices where paired[index] == nil && !serverTitles[index].isEmpty {
            let title = serverTitles[index]
            guard indices.filter({ paired[$0] == nil && serverTitles[$0] == title }).count == 1 else { continue }
            claim(index, accessibility.indices.filter { !used.contains($0) && axTitles[$0] == title })
        }
        for index in indices where paired[index] == nil {
            let window = server[index]
            let matches = accessibility.indices.filter { candidate in
                guard !used.contains(candidate), let frame = accessibility[candidate].frame else { return false }
                return abs(frame.minX - window.frame.minX) < 3 && abs(frame.minY - window.frame.minY) < 3 &&
                    abs(frame.width - window.frame.width) < 3 && abs(frame.height - window.frame.height) < 3
            }
            let exact = matches.filter { axTitles[$0] == serverTitles[index] }
            claim(index, exact.count == 1 ? exact : matches)
        }
        var result = indices.compactMap { index -> Match? in
            guard let candidate = paired[index], accessibility[candidate].eligible else { return nil }
            return Match(serverIndex: index, accessibilityIndex: candidate)
        }
        for index in accessibility.indices where !used.contains(index) && accessibility[index].eligible {
            result.append(Match(serverIndex: nil, accessibilityIndex: index))
        }
        return result
    }

    private static func matchingTitle(_ title: String, applicationName: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !applicationName.isEmpty {
            for separator in [" - ", " — "] {
                let suffix = separator + applicationName
                if title.hasSuffix(suffix) { return String(title.dropLast(suffix.count)) }
            }
        }
        return title
    }
}
