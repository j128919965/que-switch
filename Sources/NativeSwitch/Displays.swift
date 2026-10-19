import AppKit
import SwitchCore

struct DisplayContext {
    let id: UInt32
    let screen: NSScreen
    let geometry: DisplayGeometry
    let name: String

    static func current() -> [DisplayContext] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        return screens.enumerated().compactMap { index, screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            let frame = DisplayGeometry.quartzFrame(appKitFrame: screen.frame, primaryTop: primary.frame.maxY)
            return DisplayContext(id: id, screen: screen, geometry: DisplayGeometry(id: id, frame: frame),
                                  name: "屏幕 \(index + 1) · \(screen.localizedName)")
        }
    }
}
