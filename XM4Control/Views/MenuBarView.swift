import SwiftUI

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
}

struct MenuBarView: View {
    @Bindable var bluetooth: BluetoothManager
    @AppStorage("headphoneMACAddress") private var macAddress: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with connection status
            headerSection

            Divider()
                .padding(.vertical, 4)

            if bluetooth.isConnected {
                // Mode controls
                modeControlsSection

                Divider()
                    .padding(.vertical, 4)
            }

            // Bottom actions
            bottomActionsSection
        }
        .padding(8)
        .frame(width: 280)
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            Image(systemName: "headphones")
                .font(.title2)
                .foregroundStyle(bluetooth.isConnected ? .green : .secondary)

            Text("Sony WH-1000XM4")
                .font(.headline)

            Spacer()

            if bluetooth.isConnecting {
                ProgressView()
                    .scaleEffect(0.7)
            } else if bluetooth.isConnected {
                // Battery on the right
                HStack(spacing: 4) {
                    Image(systemName: bluetooth.headphoneState.batteryIcon)
                        .foregroundStyle(bluetooth.headphoneState.batteryColor)
                    Text(bluetooth.headphoneState.batteryDisplayString)
                        .font(.callout)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var modeControlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ModeButton(
                    title: "ANC",
                    icon: "ear.fill",
                    isSelected: bluetooth.headphoneState.currentMode == .noiseCancelling
                ) {
                    bluetooth.setNoiseCancelling()
                }

                ModeButton(
                    title: "Ambient",
                    icon: "ear",
                    isSelected: bluetooth.headphoneState.currentMode == .ambient
                ) {
                    bluetooth.setAmbient()
                }

                ModeButton(
                    title: "Off",
                    icon: "ear.trianglebadge.exclamationmark",
                    isSelected: bluetooth.headphoneState.currentMode == .off
                ) {
                    bluetooth.setOff()
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var bottomActionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if bluetooth.isConnected {
                HoverButton(icon: "xmark.circle", title: "Disconnect") {
                    bluetooth.disconnect()
                }
            } else {
                HoverButton(icon: "link", title: "Connect") {
                    if !macAddress.isEmpty {
                        bluetooth.connect(macAddress: macAddress)
                    } else {
                        openSettings()
                    }
                }
                .disabled(macAddress.isEmpty)
            }

            Divider()
                .padding(.vertical, 4)

            HoverButton(icon: "gear", title: "Settings...") {
                openSettings()
            }

            HoverButton(icon: "power", title: "Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - Mode Button

struct ModeButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.2) : (isHovered ? Color.secondary.opacity(0.1) : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Hover Button

struct HoverButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

#Preview {
    MenuBarView(bluetooth: BluetoothManager())
}
