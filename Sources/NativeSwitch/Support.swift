import AppKit
import ApplicationServices
import Combine
import SwitchCore

extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0x5A9CF8
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var rgbHex: String {
        guard let c = usingColorSpace(.sRGB) else { return "5A9CF8" }
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

final class SettingsStore: ObservableObject {
    @Published var value: Preferences { didSet { save() } }
    var onChange: ((Preferences) -> Void)?
    init() {
        value = UserDefaults.standard.data(forKey: "preferences")
            .flatMap { try? Preferences.decode($0) } ?? Preferences()
    }
    private func save() {
        var validated = value
        validated.validate()
        guard let data = try? JSONEncoder().encode(validated) else { return }
        UserDefaults.standard.set(data, forKey: "preferences")
        onChange?(validated)
    }
    func reset() { value = Preferences() }
    func importFile(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count <= 128 * 1024 else { throw Preferences.ConfigurationError.invalidFormat }
        value = try Preferences.decode(data)
    }
    func exportFile(_ url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

func axValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &result) == .success ? result : nil
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = axValue(element, kAXPositionAttribute as CFString),
          let size = axValue(element, kAXSizeAttribute as CFString),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}

func privacySettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
}

func showError(_ message: String) {
    let alert = NSAlert(); alert.messageText = "NativeSwitch"; alert.informativeText = message
    alert.alertStyle = .warning; alert.addButton(withTitle: "好"); alert.runModal()
}
