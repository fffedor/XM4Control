import SwiftUI
import ServiceManagement
@preconcurrency import IOBluetooth

/// Represents a paired Bluetooth device
struct PairedDevice: Identifiable, Hashable {
    let id: String  // MAC address
    let name: String
    let isConnected: Bool

    var displayName: String {
        if isConnected {
            return "\(name) (Connected)"
        }
        return name
    }
}

struct SettingsView: View {
    @Binding var macAddress: String
    @AppStorage("autoConnect") private var autoConnect: Bool = true
    @AppStorage("cycleModes") private var cycleModes: String = "noiseCancelling,ambient,off"

    @State private var editedMACAddress: String = ""
    @State private var pairedDevices: [PairedDevice] = []
    @State private var selectedDeviceID: String = ""
    @State private var showManualEntry: Bool = false
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    // All available modes for cycling
    private let allModes: [(id: String, name: String)] = [
        ("noiseCancelling", "Noise Cancelling"),
        ("ambient", "Ambient"),
        ("off", "Off")
    ]

    private var selectedModes: Set<String> {
        Set(cycleModes.split(separator: ",").map(String.init))
    }

    private func toggleMode(_ modeId: String) {
        var modes = selectedModes
        if modes.contains(modeId) {
            modes.remove(modeId)
        } else {
            modes.insert(modeId)
        }
        // Ensure at least 2 modes are selected
        if modes.count >= 2 {
            // Preserve order based on allModes
            cycleModes = allModes.filter { modes.contains($0.id) }.map(\.id).joined(separator: ",")
        }
    }

    var body: some View {
        Form {
            // Device Selection
            Section {
                if showManualEntry {
                    TextField("MAC Address", text: $editedMACAddress, prompt: Text("XX:XX:XX:XX:XX:XX"))
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: editedMACAddress) { _, newValue in
                            let normalized = newValue.uppercased().replacingOccurrences(of: "-", with: ":")
                            if normalized.count == 17 {  // Valid MAC format
                                macAddress = normalized
                            }
                        }
                } else {
                    Picker("Headphones", selection: $selectedDeviceID) {
                        Text("Select a device...").tag("")
                        ForEach(pairedDevices) { device in
                            Text(device.displayName).tag(device.id)
                        }
                    }
                    .onChange(of: selectedDeviceID) { _, newValue in
                        if !newValue.isEmpty {
                            macAddress = newValue
                        }
                    }

                    if !selectedDeviceID.isEmpty {
                        LabeledContent("MAC Address") {
                            Text(selectedDeviceID)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                HStack {
                    Button("Refresh Devices") {
                        loadPairedDevices()
                    }
                    Spacer()
                    Button(showManualEntry ? "Show Device List" : "Enter Manually") {
                        showManualEntry.toggle()
                    }
                }
                .buttonStyle(.link)
            } header: {
                Text("Device")
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            print("Failed to update login item: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Auto-connect on launch", isOn: $autoConnect)
            } header: {
                Text("Preferences")
            }

            Section {
                ForEach(allModes, id: \.id) { mode in
                    Toggle(mode.name, isOn: Binding(
                        get: { selectedModes.contains(mode.id) },
                        set: { _ in toggleMode(mode.id) }
                    ))
                    .disabled(selectedModes.contains(mode.id) && selectedModes.count <= 2)
                }
            } header: {
                Text("Right-Click Cycle Modes")
            } footer: {
                Text("Right-click the menu bar icon to cycle through selected modes. At least 2 modes must be selected.")
            }

            Section {
            } footer: {
                HStack {
                    Link("@fffedor", destination: URL(string: "https://github.com/fffedor")!)
                    Text("(2026)")
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 580)
        .onAppear {
            editedMACAddress = macAddress
            loadPairedDevices()
            if !macAddress.isEmpty {
                selectedDeviceID = macAddress.uppercased()
            }
        }
    }

    private func loadPairedDevices() {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            pairedDevices = []
            return
        }

        pairedDevices = devices.compactMap { device -> PairedDevice? in
            guard let address = device.addressString?.uppercased(),
                  let name = device.name, !name.isEmpty else {
                return nil
            }
            return PairedDevice(
                id: address,
                name: name,
                isConnected: device.isConnected()
            )
        }
        // Sort: XM4/XM5 devices first, then connected devices, then alphabetically
        .sorted { lhs, rhs in
            let lhsIsSony = lhs.name.contains("XM4") || lhs.name.contains("XM5") || lhs.name.contains("WH-1000")
            let rhsIsSony = rhs.name.contains("XM4") || rhs.name.contains("XM5") || rhs.name.contains("WH-1000")
            if lhsIsSony != rhsIsSony { return lhsIsSony }
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            return lhs.name < rhs.name
        }
    }
}

#Preview {
    SettingsView(macAddress: .constant("AC:80:0A:11:22:33"))
}
