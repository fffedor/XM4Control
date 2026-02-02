import SwiftUI

@main
struct XM4ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("headphoneMACAddress") private var macAddress: String = ""

    var body: some Scene {
        Window("Settings", id: "settings") {
            SettingsView(macAddress: $macAddress)
        }
        .windowResizability(.contentSize)
    }
}
