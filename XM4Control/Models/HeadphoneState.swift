import Foundation
import SwiftUI

@Observable
final class HeadphoneState {
    var currentMode: ANCMode = .unknown
    var leftBatteryLevel: Int?
    var rightBatteryLevel: Int?
    var isCharging: Bool = false
    var dseeEnabled: Bool = false

    /// Returns the minimum battery level of left/right (what you'd want to display)
    var batteryLevel: Int? {
        switch (leftBatteryLevel, rightBatteryLevel) {
        case (.some(let left), .some(let right)):
            return min(left, right)
        case (.some(let left), .none):
            return left
        case (.none, .some(let right)):
            return right
        case (.none, .none):
            return nil
        }
    }

    var batteryDisplayString: String {
        guard let level = batteryLevel else { return "—" }
        let chargingIndicator = isCharging ? " ⚡" : ""
        return "\(level)%\(chargingIndicator)"
    }

    var batteryIcon: String {
        guard let level = batteryLevel else { return "battery.0" }

        if isCharging {
            return "battery.100.bolt"
        }

        switch level {
        case 0..<15:
            return "battery.0"
        case 15..<40:
            return "battery.25"
        case 40..<65:
            return "battery.50"
        case 65..<90:
            return "battery.75"
        default:
            return "battery.100"
        }
    }

    var batteryColor: Color {
        guard let level = batteryLevel else { return .secondary }

        if isCharging {
            return .green
        }

        switch level {
        case 0..<15:
            return .red
        case 15..<30:
            return .orange
        default:
            return .green
        }
    }

    func reset() {
        currentMode = .unknown
        leftBatteryLevel = nil
        rightBatteryLevel = nil
        isCharging = false
        dseeEnabled = false
    }
}
