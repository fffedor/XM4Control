import SwiftUI
import AppKit
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var iconObservationTask: Task<Void, Never>?

    let bluetooth = BluetoothManager()

    @AppStorage("headphoneMACAddress") private var macAddress: String = ""
    @AppStorage("autoConnect") private var autoConnect: Bool = true

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Close any auto-opened windows (like Settings)
        for window in NSApp.windows {
            if window.title == "Settings" {
                window.close()
            }
        }

        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        setupNotifications()

        // Auto-connect if enabled
        if autoConnect && !macAddress.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(1))
                bluetooth.connect(macAddress: macAddress)
            }
        }

        // Observe state changes reactively (no polling)
        startIconObservation()
    }

    private func startIconObservation() {
        iconObservationTask?.cancel()
        iconObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }

                // Capture current state and update icon
                let isConnected = self.bluetooth.isConnected
                let currentMode = self.bluetooth.headphoneState.currentMode
                self.updateStatusItemIcon(isConnected: isConnected, mode: currentMode)

                // Wait for state changes using observation tracking
                await withCheckedContinuation { continuation in
                    _ = withObservationTracking {
                        // Access the properties we want to observe
                        _ = self.bluetooth.isConnected
                        _ = self.bluetooth.headphoneState.currentMode
                    } onChange: {
                        // Resume when any observed property changes
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .openSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openSettingsWindow()
        }
    }

    private func openSettingsWindow() {
        popover.performClose(nil)

        // Find existing settings window or let SwiftUI create it
        if let window = NSApp.windows.first(where: { $0.title == "Settings" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Trigger SwiftUI to create the window
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "ear.fill", accessibilityDescription: "XM4 Control")
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 300)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView(bluetooth: bluetooth))
    }

    private func setupEventMonitor() {
        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click: cycle modes
            cycleToNextMode()
        } else {
            // Left-click: toggle popover
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Request fresh status when opening
            if bluetooth.isConnected {
                bluetooth.requestStatus()
            }
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)

            // Make sure the popover's window becomes key
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func cycleToNextMode() {
        guard bluetooth.isConnected else { return }

        let cycleModes = UserDefaults.standard.string(forKey: "cycleModes") ?? "noiseCancelling,ambient,off"
        let modeOrder = cycleModes.split(separator: ",").map(String.init)
        guard modeOrder.count >= 2 else { return }

        let currentMode = bluetooth.headphoneState.currentMode
        let currentModeId = modeIdFromANCMode(currentMode)

        // Find current index and get next mode
        if let currentIndex = modeOrder.firstIndex(of: currentModeId) {
            let nextIndex = (currentIndex + 1) % modeOrder.count
            applyMode(modeOrder[nextIndex])
        } else {
            // Current mode not in cycle list, start from first
            applyMode(modeOrder[0])
        }
    }

    private func modeIdFromANCMode(_ mode: ANCMode) -> String {
        switch mode {
        case .noiseCancelling: return "noiseCancelling"
        case .ambient: return "ambient"
        case .wind, .off: return "off"
        case .unknown: return ""
        }
    }

    private func applyMode(_ modeId: String) {
        switch modeId {
        case "noiseCancelling":
            bluetooth.setNoiseCancelling()
        case "ambient":
            bluetooth.setAmbient()
        case "off":
            bluetooth.setOff()
        default:
            break
        }
    }

    private func updateStatusItemIcon(isConnected: Bool, mode: ANCMode) {
        guard let button = statusItem.button else { return }

        let iconName: String
        if !isConnected {
            iconName = "ear.fill"
        } else {
            switch mode {
            case .ambient:
                iconName = "ear"
            case .noiseCancelling, .wind, .off, .unknown:
                iconName = "ear.fill"
            }
        }

        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "XM4 Control")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up observation task
        iconObservationTask?.cancel()
        iconObservationTask = nil

        // Clean up event monitor
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
