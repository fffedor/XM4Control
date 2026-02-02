import Foundation

// MARK: - Protocol Constants

enum SonyProtocol {
    static let startMarker: UInt8 = 0x3E  // '>' (62)
    static let endMarker: UInt8 = 0x3C    // '<' (60)
    static let escapeByte: UInt8 = 0x3D   // '=' (61)

    // Service UUID for Sony headphones control protocol
    static let serviceUUID = "96CC203E-5068-46AD-B32D-E316F5E069BA"
    static let serviceUUIDBytes: [UInt8] = [
        0x96, 0xCC, 0x20, 0x3E, 0x50, 0x68, 0x46, 0xAD,
        0xB3, 0x2D, 0xE3, 0x16, 0xF5, 0xE0, 0x69, 0xBA
    ]
}

// MARK: - Data Types

enum DataType: UInt8 {
    case data = 0x00
    case ack = 0x01
    case dataMDR = 0x0C    // Main settings commands (V1)
    case dataCommon = 0x0D
    case dataMDR2 = 0x0E   // V2 - for XM5 / WF-XM4/5
    case shotMDR = 0x1C
}

// MARK: - Commands

enum Cmd {
    // Ambient Sound Control (NC/ASM)
    static let ascGet: [UInt8] = [0x66, 0x02]
    static let ascRet: [UInt8] = [0x67, 0x02]
    static let ascSet: [UInt8] = [0x68, 0x02]
    static let ascNotify: [UInt8] = [0x69, 0x02]

    // Battery commands (from Sony APK analysis)
    // COMMON_GET_BATTERY_LEVEL = 0x10, COMMON_RET_BATTERY_LEVEL = 0x11, COMMON_NTFY_BATTERY_LEVEL = 0x13
    // BatteryInquiredType: BATTERY=0x00, LEFT_RIGHT_BATTERY=0x01, CRADLE_BATTERY=0x02
    static let batteryGet: [UInt8] = [0x10, 0x01]      // GET_BATTERY_LEVEL with LEFT_RIGHT_BATTERY
    static let batteryRet: [UInt8] = [0x11, 0x01]      // RET_BATTERY_LEVEL for left/right
    static let batteryNotify: [UInt8] = [0x13, 0x01]   // NTFY_BATTERY_LEVEL for left/right
    static let batteryGetSingle: [UInt8] = [0x10, 0x00] // GET for single battery
    static let batteryRetSingle: [UInt8] = [0x11, 0x00] // RET for single battery

    // Equalizer
    static let eqGet: [UInt8] = [0x66, 0x06]
    static let eqRet: [UInt8] = [0x67, 0x06]
    static let eqSet: [UInt8] = [0x68, 0x06]

    // DSEE Extreme
    static let dseeGet: [UInt8] = [0x66, 0x0A]
    static let dseeRet: [UInt8] = [0x67, 0x0A]
    static let dseeSet: [UInt8] = [0x68, 0x0A]

    // Connection/Init notifications (sent by headphones)
    static let connectNotify: [UInt8] = [0xA5, 0x01]   // Connection established
    static let initNotify: [UInt8] = [0x00, 0x00]      // Init message
    static let readyNotify: [UInt8] = [0x85, 0x01]     // Ready/Init complete notification
    static let capabilityNotify: [UInt8] = [0xA9, 0x01] // Capability/feature notification
}

// MARK: - ANC Mode

enum ANCMode: Equatable {
    case noiseCancelling
    case ambient
    case wind
    case off
    case unknown

    var displayName: String {
        switch self {
        case .noiseCancelling:
            return "Noise Cancelling"
        case .ambient:
            return "Ambient"
        case .wind:
            return "Wind Reduction"
        case .off:
            return "Off"
        case .unknown:
            return "Unknown"
        }
    }
}

// MARK: - Protocol Encoding/Decoding

extension SonyProtocol {

    /// Escape special bytes in the packet body
    /// Escape codes: 60 -> [61, 44], 61 -> [61, 45], 62 -> [61, 46]
    static func escape(_ data: Data) -> Data {
        var result = Data()
        for byte in data {
            switch byte {
            case 0x3C:  // '<' (60) -> [61, 44]
                result.append(contentsOf: [0x3D, 0x2C])
            case 0x3D:  // '=' (61) -> [61, 45]
                result.append(contentsOf: [0x3D, 0x2D])
            case 0x3E:  // '>' (62) -> [61, 46]
                result.append(contentsOf: [0x3D, 0x2E])
            default:
                result.append(byte)
            }
        }
        return result
    }

    /// Remove escape sequences from packet body
    /// Escape codes: [61, 44] -> 60, [61, 45] -> 61, [61, 46] -> 62
    static func unescape(_ data: Data) -> Data {
        var result = Data()
        var i = 0
        while i < data.count {
            if data[i] == 0x3D && i + 1 < data.count {
                // Escape sequence found
                switch data[i + 1] {
                case 0x2C:  // 44 -> '<' (60)
                    result.append(0x3C)
                case 0x2D:  // 45 -> '=' (61)
                    result.append(0x3D)
                case 0x2E:  // 46 -> '>' (62)
                    result.append(0x3E)
                default:
                    // Unknown escape, keep as-is
                    result.append(data[i])
                    result.append(data[i + 1])
                }
                i += 2
            } else {
                result.append(data[i])
                i += 1
            }
        }
        return result
    }

    /// Encode a message with the Sony protocol format
    /// Format: START_MARKER | escaped(dataType + seq[1] + size[4] + payload + checksum) | END_MARKER
    static func encode(dataType: UInt8, seq: UInt32, payload: Data) -> Data {
        // Build raw body: dataType(1) + seq(1) + size(4 BE) + payload
        var rawBody = Data()
        rawBody.append(dataType)

        // Sequence number as 1 byte (masked)
        rawBody.append(UInt8(seq & 0xFF))

        // Payload size as big-endian 4 bytes
        let size = UInt32(payload.count)
        rawBody.append(UInt8((size >> 24) & 0xFF))
        rawBody.append(UInt8((size >> 16) & 0xFF))
        rawBody.append(UInt8((size >> 8) & 0xFF))
        rawBody.append(UInt8(size & 0xFF))

        // Payload
        rawBody.append(payload)

        // Checksum: sum of all bytes, truncated to UInt8
        let checksum = UInt8(rawBody.reduce(0) { ($0 + UInt32($1)) } & 0xFF)
        rawBody.append(checksum)

        // Escape the body
        let escaped = escape(rawBody)

        // Build final packet
        var packet = Data([startMarker])
        packet.append(escaped)
        packet.append(endMarker)

        return packet
    }

    /// Decode a Sony protocol message
    /// Returns (dataType, seq, payload) or nil if invalid
    static func decode(_ data: Data) -> (dataType: UInt8, seq: UInt32, payload: Data)? {
        guard data.count >= 2 else { return nil }
        guard data.first == startMarker && data.last == endMarker else { return nil }

        let inner = unescape(Data(data.dropFirst().dropLast()))
        guard inner.count >= 7 else { return nil }  // dataType(1) + seq(1) + size(4) + checksum(1)

        let dataType = inner[0]

        // Sequence number (1 byte)
        let seq = UInt32(inner[1])

        // Payload size (4 bytes BE)
        let size = Int(UInt32(inner[2]) << 24 | UInt32(inner[3]) << 16 | UInt32(inner[4]) << 8 | UInt32(inner[5]))

        guard inner.count >= 6 + size + 1 else { return nil }

        let payload = Data(inner[6..<(6 + size)])
        let checksum = inner[6 + size]

        // Verify checksum
        let expectedChecksum = UInt8(inner[0..<(6 + size)].reduce(0) { ($0 + UInt32($1)) } & 0xFF)
        guard checksum == expectedChecksum else { return nil }

        return (dataType, seq, payload)
    }

    /// Create an ACK packet
    static func makeACK(seq: UInt32) -> Data {
        return encode(dataType: DataType.ack.rawValue, seq: seq, payload: Data())
    }

    /// Build ANC control payload
    /// Format: [NCASM_SET_PARAM, NC_ASM_INQUIRED_TYPE, NC_ASM_EFFECT, NC_ASM_SETTING_TYPE,
    ///          NC_DUAL_SINGLE_VALUE, ASM_SETTING_TYPE, ASM_ID, ASM_LEVEL]
    ///
    /// Constants from SonyHeadphonesClient:
    /// - NCASM_SET_PARAM = 0x68
    /// - NC_ASM_INQUIRED_TYPE: 0=NO_USE, 1=NC, 2=NC_AND_ASM, 3=ASM
    /// - NC_ASM_EFFECT: 0=OFF, 1=ON
    /// - NC_ASM_SETTING_TYPE: 0=ON_OFF, 1=LEVEL_ADJUSTMENT, 2=DUAL_SINGLE_OFF
    /// - NC_DUAL_SINGLE_VALUE: 0=OFF, 1=SINGLE (wind), 2=DUAL (NC)
    /// - ASM_SETTING_TYPE: 0=ON_OFF, 1=LEVEL_ADJUSTMENT
    /// - ASM_ID: 0=NORMAL, 1=VOICE
    /// - ASM_LEVEL: 0-19 for ambient, 0xFF for disabled
    static func makeASCPayload(mode: ANCMode) -> Data {
        let ncAsmEffect: UInt8
        let ncAsmSettingType: UInt8
        let ncDualSingleValue: UInt8
        let asmSettingType: UInt8
        let asmId: UInt8
        let asmLevel: UInt8

        switch mode {
        case .noiseCancelling:
            ncAsmEffect = 0x01           // ON
            ncAsmSettingType = 0x02      // DUAL_SINGLE_OFF
            ncDualSingleValue = 0x02     // DUAL (full NC)
            asmSettingType = 0x00        // ON_OFF
            asmId = 0x00                 // NORMAL
            asmLevel = 0x00              // Not used for NC
        case .ambient:
            ncAsmEffect = 0x01           // ON
            ncAsmSettingType = 0x01      // LEVEL_ADJUSTMENT
            ncDualSingleValue = 0x00     // OFF (no NC in ambient mode)
            asmSettingType = 0x01        // LEVEL_ADJUSTMENT
            asmId = 0x00                 // NORMAL (no focus on voice)
            asmLevel = 19                // Max level
        case .wind:
            ncAsmEffect = 0x01           // ON
            ncAsmSettingType = 0x02      // DUAL_SINGLE_OFF
            ncDualSingleValue = 0x01     // SINGLE (wind reduction)
            asmSettingType = 0x00        // ON_OFF
            asmId = 0x00                 // NORMAL
            asmLevel = 0x00              // Not used for wind
        case .off, .unknown:
            ncAsmEffect = 0x00           // OFF
            ncAsmSettingType = 0x00      // ON_OFF
            ncDualSingleValue = 0x00     // OFF
            asmSettingType = 0x00        // ON_OFF
            asmId = 0x00                 // NORMAL
            asmLevel = 0x00              // Not used when off
        }

        // Format: [0x68, 0x02, effect, settingType, dualSingle, asmSettingType, asmId, asmLevel]
        let bytes: [UInt8] = [
            0x68,                   // NCASM_SET_PARAM
            0x02,                   // NC_ASM_INQUIRED_TYPE: NOISE_CANCELLING_AND_AMBIENT_SOUND_MODE
            ncAsmEffect,
            ncAsmSettingType,
            ncDualSingleValue,
            asmSettingType,
            asmId,
            asmLevel
        ]
        return Data(bytes)
    }

    /// Parse ASC response data (after the command bytes)
    /// Format from Sony APK (b0.java - NOISE_CANCELLING_AND_AMBIENT_SOUND_MODE):
    /// [NcAsmEffect, NcAsmSettingType, NcDualSingleValue, AsmSettingType, AsmId, AsmLevel]
    ///
    /// NcAsmEffect: OFF=0, ON=1
    /// NcAsmSettingType: ON_OFF=0, LEVEL_ADJ=1, DUAL_SINGLE_OFF=2
    /// NcDualSingleValue: OFF=0, SINGLE=1 (wind), DUAL=2 (full NC)
    /// AsmSettingType: ON_OFF=0, LEVEL_ADJ=1
    /// AsmId: NORMAL=0, VOICE=1
    /// AsmLevel: 0-19
    static func parseASCResponse(_ data: Data) -> ANCMode? {
        guard data.count >= 6 else { return nil }

        let ncAsmEffect = data[0]           // 0=OFF, 1=ON
        // let ncAsmSettingType = data[1]   // Not needed for mode detection
        let ncDualSingleValue = data[2]     // 0=OFF, 1=SINGLE(wind), 2=DUAL(NC)
        let asmSettingType = data[3]        // 0=ON_OFF, 1=LEVEL_ADJ

        // If overall effect is off, return off
        if ncAsmEffect == 0x00 {
            return .off
        }

        // Check NC mode first (NcDualSingleValue)
        switch ncDualSingleValue {
        case 0x02:  // DUAL - Full noise cancelling
            return .noiseCancelling
        case 0x01:  // SINGLE - Wind reduction mode
            return .wind
        case 0x00:  // OFF - NC is off, check if ambient is active
            if asmSettingType == 0x01 {  // LEVEL_ADJUSTMENT - Ambient mode active
                return .ambient
            }
            // ASM is also off
            return .off
        default:
            return .unknown
        }
    }

    /// Parse battery response data (from Sony APK analysis)
    /// batteryType: 0x00=BATTERY (single), 0x01=LEFT_RIGHT_BATTERY
    /// For LEFT_RIGHT_BATTERY: data = [leftLevel, leftCharge, rightLevel, rightCharge]
    /// For BATTERY (single): data = [level, charge]
    /// BatteryChargingStatus: NOT_CHARGING=0x00, CHARGING=0x01
    static func parseBatteryResponse(batteryType: UInt8, data: Data) -> (left: Int, right: Int, isCharging: Bool)? {
        if batteryType == 0x01 && data.count >= 4 {
            // LEFT_RIGHT_BATTERY: [leftLevel, leftCharge, rightLevel, rightCharge]
            let leftLevel = Int(data[0])
            let leftCharging = data[1] == 0x01
            let rightLevel = Int(data[2])
            let rightCharging = data[3] == 0x01
            let isCharging = leftCharging || rightCharging
            return (leftLevel, rightLevel, isCharging)
        } else if batteryType == 0x00 && data.count >= 2 {
            // BATTERY (single): [level, charge]
            let level = Int(data[0])
            let charging = data[1] == 0x01
            return (level, level, charging)
        }

        // Fallback: try to parse as left/right if we have enough data
        if data.count >= 4 {
            let leftLevel = Int(data[0])
            let rightLevel = Int(data[2])
            let isCharging = data[1] == 0x01 || data[3] == 0x01
            return (leftLevel, rightLevel, isCharging)
        }

        return nil
    }

    /// Parse DSEE response data
    static func parseDSEEResponse(_ data: Data) -> Bool? {
        guard data.count >= 2 else { return nil }
        return data[1] != 0
    }
}
