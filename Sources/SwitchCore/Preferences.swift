import Foundation

public enum WindowScope: String, Codable, CaseIterable { case currentDesktop, allDesktops }
public enum PanelScreen: String, Codable, CaseIterable { case pointer, activeWindow, main }
public enum MultiDisplayMode: String, Codable, CaseIterable { case combined, grouped, perScreen }
public enum PanelAppearance: String, Codable, CaseIterable { case system, light, dark }
public enum ShortcutModifier: String, Codable, CaseIterable { case command, option, control }

public struct Preferences: Codable, Equatable {
    public var scope: WindowScope = .currentDesktop
    public var screen: PanelScreen = .pointer
    public var multiDisplayMode: MultiDisplayMode = .combined
    public var appearance: PanelAppearance = .system
    public var modifier: ShortcutModifier = .command
    public var shortcutKey: Int = 48
    public var cardWidth: Double = 250
    public var columns: Int = 4
    public var cornerRadius: Double = 10
    public var accentHex: String = "5A9CF8"
    public var showTitles: Bool = true
    public var useBlur: Bool = true
    public var animate: Bool = true
    public var hoverSelect: Bool = false
    public var showDelayMilliseconds: Int = 100
    public var energySavingPreviews: Bool = true
    public var cacheMegabytes: Int = 48
    public var includeMinimized: Bool = false
    public var includeHidden: Bool = false
    public var closeShortcut: Bool = true
    public var excludedBundleIDs: [String] = []

    public init() {}

    public mutating func validate() {
        if !cardWidth.isFinite { cardWidth = 250 }
        if !cornerRadius.isFinite { cornerRadius = 10 }
        cardWidth = min(400, max(160, cardWidth))
        columns = min(6, max(1, columns))
        cornerRadius = min(20, max(4, cornerRadius))
        showDelayMilliseconds = min(500, max(0, showDelayMilliseconds))
        cacheMegabytes = min(256, max(8, cacheMegabytes))
        shortcutKey = [48, 50].contains(shortcutKey) ? shortcutKey : 48
        accentHex = accentHex.replacingOccurrences(of: "#", with: "")
        if accentHex.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) == nil { accentHex = "5A9CF8" }
        excludedBundleIDs = Array(Set(excludedBundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    // Merge older exports with defaults, rather than discarding every setting
    // when a newly added key is absent.
    public static func decode(_ data: Data) throws -> Preferences {
        let incoming = try JSONSerialization.jsonObject(with: data)
        guard let overrides = incoming as? [String: Any] else { throw ConfigurationError.invalidFormat }
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as! [String: Any]
        let merged = defaults.merging(overrides) { _, new in new }
        let payload = try JSONSerialization.data(withJSONObject: merged)
        var preferences = try JSONDecoder().decode(Preferences.self, from: payload)
        preferences.validate()
        return preferences
    }

    public enum ConfigurationError: Error { case invalidFormat }
}
