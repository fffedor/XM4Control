import Foundation
@preconcurrency import IOBluetooth
import os

private let logger = Logger(subsystem: "com.xm4control", category: "Bluetooth")

@Observable
@MainActor
final class BluetoothManager: NSObject {
    // Connection state
    var isConnected = false
    var isConnecting = false
    var connectionError: String?

    // Headphone state
    var headphoneState = HeadphoneState()

    // Private state
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var channelDelegate: RFCOMMChannelDelegate?
    private var lastAckSeq: UInt32 = 0  // Track the last ACK sequence from headphones
    private var receiveBuffer = Data()
    private var isProcessingBuffer = false
    private var pendingData: [Data] = []

    // Task management for proper cancellation
    private var statusRequestTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?

    // Mode change tracking - ignore stale notifications after command
    private var lastModeCommandTime: Date = .distantPast
    private static let notificationCooldown: TimeInterval = 3.0  // Ignore notifications for 3s after command

    // MARK: - Connection

    func connect(macAddress: String, channelID: UInt8? = nil) {
        guard !isConnecting && !isConnected else { return }

        isConnecting = true
        connectionError = nil
        headphoneState.reset()

        // Normalize MAC address format
        let normalizedMAC = macAddress.replacingOccurrences(of: "-", with: ":").uppercased()

        logger.info("Connecting to \(normalizedMAC)...")

        // Cancel any existing connection attempt
        connectionTask?.cancel()

        // Run blocking Bluetooth operations on background thread
        connectionTask = Task.detached { [weak self] in
            guard let self = self else { return }

            guard let bluetoothDevice = IOBluetoothDevice(addressString: normalizedMAC) else {
                await MainActor.run {
                    self.connectionError = "Device not found. Check MAC address and pairing."
                    self.isConnecting = false
                }
                logger.error("Device not found: \(normalizedMAC)")
                return
            }

            // Discover RFCOMM channel if not specified (blocking SDP query)
            let rfcommChannel = channelID ?? self.discoverRFCOMMChannel(device: bluetoothDevice)

            logger.info("Using RFCOMM channel: \(rfcommChannel)")

            // Create delegate on main actor
            let delegate = await MainActor.run {
                self.device = bluetoothDevice
                let del = RFCOMMChannelDelegate(manager: self)
                self.channelDelegate = del
                return del
            }

            // Open RFCOMM channel asynchronously - result comes via delegate
            var channelRef: IOBluetoothRFCOMMChannel?
            let result = bluetoothDevice.openRFCOMMChannelAsync(
                &channelRef,
                withChannelID: rfcommChannel,
                delegate: delegate
            )

            // Store the channel reference immediately
            let openedChannel = channelRef

            await MainActor.run {
                // Store channel even if result indicates pending - delegate will confirm
                self.channel = openedChannel

                if result != kIOReturnSuccess && result != kIOReturnNotOpen {
                    // Real error (not just "pending")
                    self.connectionError = "Failed to open RFCOMM channel (error: \(result))"
                    self.isConnecting = false
                    logger.error("Failed to open RFCOMM: \(result)")
                } else {
                    logger.info("RFCOMM open initiated, waiting for delegate callback...")
                }
            }
        }
    }

    /// Called by delegate when channel open completes
    func onChannelOpenComplete(channel: IOBluetoothRFCOMMChannel, error: IOReturn) {
        if error == kIOReturnSuccess {
            self.channel = channel
            self.isConnecting = false
            self.isConnected = true
            logger.info("Connected successfully on channel \(channel.getID()), MTU: \(channel.getMTU())")

            // Request initial status after short delay
            statusRequestTask?.cancel()
            statusRequestTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self.requestStatus()
            }
        } else {
            self.connectionError = "Connection failed (error: \(error))"
            self.isConnecting = false
            logger.error("RFCOMM channel open failed: \(error)")
        }
    }

    func disconnect() {
        logger.info("Disconnecting...")

        // Cancel pending tasks
        statusRequestTask?.cancel()
        statusRequestTask = nil
        connectionTask?.cancel()
        connectionTask = nil

        channel?.close()
        channel = nil

        device?.closeConnection()
        device = nil

        channelDelegate = nil
        isConnected = false
        isConnecting = false
        lastAckSeq = 0

        // Clear and release buffer memory
        receiveBuffer.removeAll(keepingCapacity: false)
        pendingData.removeAll(keepingCapacity: false)

        headphoneState.reset()
    }

    private nonisolated func discoverRFCOMMChannel(device: IOBluetoothDevice) -> UInt8 {
        logger.info("Performing SDP query...")

        // Create UUID for Sony control service
        let sonyUUID = IOBluetoothSDPUUID(bytes: SonyProtocol.serviceUUIDBytes, length: 16)

        // Perform SDP query (this is a blocking call on the background thread)
        let result = device.performSDPQuery(nil)
        if result != kIOReturnSuccess {
            logger.warning("SDP query returned status: \(result)")
        }

        // Try to find service by Sony UUID first
        if let sonyService = device.getServiceRecord(for: sonyUUID) {
            var channelID: BluetoothRFCOMMChannelID = 0
            if sonyService.getRFCOMMChannelID(&channelID) == kIOReturnSuccess && channelID > 0 {
                logger.info("Found Sony service on channel: \(channelID)")
                return channelID
            }
        }

        // Fallback: Collect all RFCOMM channels and pick the best one
        if let services = device.services {
            var channels: [UInt8] = []
            for case let service as IOBluetoothSDPServiceRecord in services {
                var channelID: BluetoothRFCOMMChannelID = 0
                if service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess && channelID > 0 {
                    channels.append(channelID)
                    logger.info("Found RFCOMM channel: \(channelID)")
                }
            }

            // Prefer channel 9 if available (Sony control protocol common default)
            if channels.contains(9) {
                logger.info("Using Sony control channel 9")
                return 9
            }
            // Otherwise use highest channel (control channels are usually higher numbered)
            if let highest = channels.max(), highest > 2 {
                logger.info("Using highest channel: \(highest)")
                return highest
            }
        }

        // Fallback to channel 9
        logger.info("Falling back to channel 9")
        return 9
    }

    // MARK: - Sending Commands

    private func send(dataType: UInt8, payload: Data) {
        guard let channel = channel, isConnected else {
            logger.warning("Cannot send: not connected")
            return
        }

        // Use the last ACK sequence number from headphones as per protocol requirement
        let seq = lastAckSeq
        let message = SonyProtocol.encode(dataType: dataType, seq: seq, payload: payload)

        let payloadHex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        let messageHex = message.map { String(format: "%02X", $0) }.joined(separator: " ")
        logger.info("<<< SEND type=\(String(format: "%02X", dataType), privacy: .public) seq=\(seq) payload=[\(payloadHex, privacy: .public)]")
        logger.info("<<< RAW: \(messageHex, privacy: .public)")

        let result = writeData(message, to: channel)

        if result != kIOReturnSuccess {
            logger.error("Failed to send message: \(result)")
        }
    }

    private func sendACK(seq: UInt32) {
        guard let channel = channel else { return }

        let ackMessage = SonyProtocol.makeACK(seq: seq)
        _ = writeData(ackMessage, to: channel)
    }

    /// Safely write data to RFCOMM channel using proper buffer handling
    private func writeData(_ data: Data, to channel: IOBluetoothRFCOMMChannel) -> IOReturn {
        var bytes = [UInt8](data)
        return bytes.withUnsafeMutableBytes { buffer in
            channel.writeSync(buffer.baseAddress, length: UInt16(data.count))
        }
    }

    // MARK: - Public Commands

    func setNoiseCancelling() {
        setMode(.noiseCancelling)
    }

    func setAmbient() {
        setMode(.ambient)
    }

    func setOff() {
        setMode(.off)
    }

    private func setMode(_ mode: ANCMode) {
        logger.info("setMode called: \(mode.displayName, privacy: .public)")

        // Record time to ignore stale notifications
        lastModeCommandTime = Date()

        // Send the command
        let payload = SonyProtocol.makeASCPayload(mode: mode)
        send(dataType: DataType.dataMDR.rawValue, payload: payload)

        // Trust the command worked - update UI immediately
        // Sony firmware has a bug where notifications lag behind actual state
        headphoneState.currentMode = mode
    }

    func requestStatus() {
        // Clear cooldown to allow fresh status to update UI
        lastModeCommandTime = .distantPast

        // Log channel state
        if let ch = channel {
            logger.info("Channel state - ID: \(ch.getID()), isOpen: \(ch.isOpen()), MTU: \(ch.getMTU())")
        } else {
            logger.warning("Channel is nil!")
            return
        }

        // Cancel any pending status request
        statusRequestTask?.cancel()

        // Send commands with delays to allow proper ACK handling
        statusRequestTask = Task {
            // Send ASC (ambient sound control) get command
            let ascCmd = Data(Cmd.ascGet)
            logger.info("Sending ASC GET: \(ascCmd.map { String(format: "%02X", $0) }.joined(separator: " "), privacy: .public)")
            send(dataType: DataType.dataMDR.rawValue, payload: ascCmd)

            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }

            // Send battery get command - XM4 uses single battery format (over-ear, not TWS)
            let batCmd = Data(Cmd.batteryGetSingle)  // [0x10, 0x00] for single battery
            logger.info("Sending Battery GET: \(batCmd.map { String(format: "%02X", $0) }.joined(separator: " "), privacy: .public)")
            send(dataType: DataType.dataMDR.rawValue, payload: batCmd)
        }
    }

    // MARK: - Receiving Data

    nonisolated func onDataReceived(_ data: Data) {
        Task { @MainActor in
            // Queue incoming data to handle rapid successive calls
            pendingData.append(data)

            // Only process if not already processing (prevents race condition)
            guard !isProcessingBuffer else { return }
            isProcessingBuffer = true

            // Process all pending data
            while !pendingData.isEmpty {
                let dataToProcess = pendingData.removeFirst()
                receiveBuffer.append(dataToProcess)
                processBuffer()
            }

            isProcessingBuffer = false
        }
    }

    nonisolated func onChannelClosed() {
        Task { @MainActor in
            logger.info("RFCOMM channel closed")
            isConnected = false
            channel = nil
        }
    }

    private func processBuffer() {
        while true {
            // Find start marker
            guard let startIndex = receiveBuffer.firstIndex(of: SonyProtocol.startMarker) else {
                receiveBuffer.removeAll(keepingCapacity: false)
                return
            }

            // Find end marker after start
            let searchStart = receiveBuffer.index(after: startIndex)
            guard searchStart < receiveBuffer.endIndex,
                  let endIndex = receiveBuffer[searchStart...].firstIndex(of: SonyProtocol.endMarker) else {
                // No complete packet yet, remove garbage before start marker
                if startIndex > receiveBuffer.startIndex {
                    receiveBuffer.removeSubrange(receiveBuffer.startIndex..<startIndex)
                }
                return
            }

            // Extract packet
            let packet = Data(receiveBuffer[startIndex...endIndex])
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...endIndex)

            // Decode and handle
            if let decoded = SonyProtocol.decode(packet) {
                handleMessage(dataType: decoded.dataType, seq: decoded.seq, payload: decoded.payload)
            }
        }
    }

    private func handleMessage(dataType: UInt8, seq: UInt32, payload: Data) {
        // Send ACK for non-ACK messages, or track ACK sequence
        if dataType != DataType.ack.rawValue {
            sendACK(seq: seq)
        } else {
            // Track the sequence number from received ACK
            logger.info(">>> ACK received, seq=\(seq)")
            lastAckSeq = seq
            return  // ACK messages have no payload to process
        }

        // Handle MDR data
        if (dataType == DataType.dataMDR.rawValue || dataType == DataType.dataMDR2.rawValue),
           payload.count >= 2 {
            let cmd = Array(payload.prefix(2))
            let data = Data(payload.dropFirst(2))

            // Log commands for debugging (except frequent notifications)
            let isBatteryCmd = cmd[0] == 0x11 || cmd[0] == 0x13  // RET/NTFY_BATTERY_LEVEL
            let isASCCmd = cmd == Cmd.ascRet || cmd == Cmd.ascNotify  // ASC status updates
            if !isASCCmd && !isBatteryCmd {
                let cmdHex = cmd.map { String(format: "%02X", $0) }.joined()
                let dataHex = data.prefix(10).map { String(format: "%02X", $0) }.joined(separator: " ")
                logger.info("CMD: \(cmdHex, privacy: .public) data=[\(dataHex, privacy: .public)]")
            }

            if cmd == Cmd.ascRet || cmd == Cmd.ascNotify {
                handleASCResponse(data)
            } else if cmd[0] == 0x11 || cmd[0] == 0x13 {
                // Battery response - pass cmd[1] as battery type along with data
                let batteryType = cmd[1]
                handleBatteryResponse(batteryType: batteryType, data: data)
            } else if cmd == Cmd.dseeRet {
                handleDSEEResponse(data)
            } else if cmd == Cmd.connectNotify {
                // Connection notification from headphones - request status
                logger.info("Received connect notification, requesting status...")
                requestStatus()
            } else if cmd == Cmd.readyNotify {
                // Ready/Init complete notification - headphones are ready for commands
                logger.info("Received ready notification, headphones initialized")
                // Request status after receiving ready notification
                requestStatus()
            } else if cmd == Cmd.capabilityNotify {
                // Capability notification - headphones reporting supported features
                let dataHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                logger.info("Received capability notification: \(dataHex, privacy: .public)")
                // This is informational, no action needed
            } else {
                let cmdHex = cmd.map { String(format: "%02X", $0) }.joined()
                let dataHex = data.prefix(10).map { String(format: "%02X", $0) }.joined(separator: " ")
                logger.info("Unhandled MDR command: \(cmdHex, privacy: .public), data: \(dataHex, privacy: .public)")
            }
        }
    }

    private func handleASCResponse(_ data: Data) {
        guard let mode = SonyProtocol.parseASCResponse(data) else {
            return
        }

        // Ignore stale notifications during cooldown after user command
        // Sony firmware sends delayed notifications that don't reflect actual state
        let timeSinceCommand = Date().timeIntervalSince(lastModeCommandTime)
        if timeSinceCommand < Self.notificationCooldown {
            logger.info("ASC response (ignored, cooldown): \(mode.displayName, privacy: .public)")
            return
        }

        logger.info("ASC response: \(mode.displayName, privacy: .public)")

        // Update to actual headphone state (external changes like button on headphones)
        if headphoneState.currentMode != mode {
            headphoneState.currentMode = mode
        }
    }

    private func handleBatteryResponse(batteryType: UInt8, data: Data) {
        if let battery = SonyProtocol.parseBatteryResponse(batteryType: batteryType, data: data) {
            // Only log if battery level changed
            let oldLevel = headphoneState.batteryLevel
            let oldCharging = headphoneState.isCharging

            headphoneState.leftBatteryLevel = battery.left
            headphoneState.rightBatteryLevel = battery.right
            headphoneState.isCharging = battery.isCharging

            if headphoneState.batteryLevel != oldLevel || headphoneState.isCharging != oldCharging {
                logger.info("Battery: \(battery.left)%, charging: \(battery.isCharging)")
            }
        }
    }

    private func handleDSEEResponse(_ data: Data) {
        if let enabled = SonyProtocol.parseDSEEResponse(data) {
            headphoneState.dseeEnabled = enabled
            logger.info("DSEE: \(enabled)")
        }
    }
}

// MARK: - RFCOMM Channel Delegate

private final class RFCOMMChannelDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate, @unchecked Sendable {
    weak var manager: BluetoothManager?

    init(manager: BluetoothManager) {
        self.manager = manager
        super.init()
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        Task { @MainActor in
            manager?.onChannelOpenComplete(channel: rfcommChannel, error: error)
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let data = Data(bytes: dataPointer, count: dataLength)
        manager?.onDataReceived(data)
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        logger.info("RFCOMM channel closed by remote")
        manager?.onChannelClosed()
    }

    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        if error != kIOReturnSuccess {
            logger.error("Write failed: \(error)")
        }
    }
}
