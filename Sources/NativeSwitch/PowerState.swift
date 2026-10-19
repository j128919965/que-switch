import Foundation
import IOKit.ps

enum PowerState {
    // Sample only when a switcher invocation begins; no polling or background
    // power assertions are needed to choose the thumbnail resolution.
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return type as String == kIOPSBatteryPowerValue
    }
}
