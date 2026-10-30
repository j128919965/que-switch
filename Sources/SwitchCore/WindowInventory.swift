import Foundation

/// Reconcile WindowServer surfaces with an app's top-level Accessibility
/// windows. A child control can have its own surface without being a window
/// the user can switch to (for example, Chromium's find-in-page bar).
public enum WindowInventory {
    public struct ServerWindow {
        public let title: String
        public let frame: CGRect
        public init(title: String, frame: CGRect) { self.title = title; self.frame = frame }
    }

    public struct AccessibilityWindow {
        public let title: String
        public let frame: CGRect?
        public let role: String?
        public let subrole: String?
        public let canBecomeMain: Bool?
        public init(title: String, frame: CGRect?, role: String?, subrole: String?, canBecomeMain: Bool? = nil) {
            self.title = title; self.frame = frame; self.role = role; self.subrole = subrole
            self.canBecomeMain = canBecomeMain
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
    public static func reconcile(server: [ServerWindow], accessibility: [AccessibilityWindow]?) -> [Match] {
        var result: [Match] = [], used: Set<Int> = []
        for (index, window) in server.enumerated() where window.frame.width >= 50 && window.frame.height >= 40 {
            guard let accessibility else {
                result.append(Match(serverIndex: index, accessibilityIndex: nil)); continue
            }
            let matches = accessibility.indices.filter { candidate in
                guard !used.contains(candidate), let frame = accessibility[candidate].frame else { return false }
                return abs(frame.minX - window.frame.minX) < 3 && abs(frame.minY - window.frame.minY) < 3 &&
                    abs(frame.width - window.frame.width) < 3 && abs(frame.height - window.frame.height) < 3
            }
            let exact = matches.filter { accessibility[$0].title == window.title }
            // Ambiguous windows remain accessible through the AX-only path;
            // never associate an arbitrary surface with an activation target.
            guard let candidate = exact.count == 1 ? exact.first : (matches.count == 1 ? matches.first : nil) else { continue }
            used.insert(candidate)
            if accessibility[candidate].eligible {
                result.append(Match(serverIndex: index, accessibilityIndex: candidate))
            }
        }
        if let accessibility {
            for index in accessibility.indices where !used.contains(index) && accessibility[index].eligible {
                result.append(Match(serverIndex: nil, accessibilityIndex: index))
            }
        }
        return result
    }
}
