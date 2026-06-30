import Foundation

/// Pure framing for the Sony WH-1000XM control protocol (the layer shared by every command,
/// identical across the V1/XM4 and V2/XM5 dialects). No IOBluetooth — bytes in, bytes out.
///
/// Frame: 0x3E start, then ESCAPED (type, seq, 4-byte big-endian length, payload, checksum),
/// then 0x3C end. Checksum = sum(type, seq, length, payload) & 0xFF, computed BEFORE escaping.
/// Escape: each of 0x3E/0x3C/0x3D becomes 0x3D followed by (byte & 0xEF); unescape ORs 0x10
/// back in. Constants verified against Gadgetbridge Message.java.
public enum SonyMessageType: UInt8, Sendable, Equatable {
    case ack = 0x01
    case command1 = 0x0C
    case command2 = 0x0E
}

public struct SonyFrame: Sendable, Equatable {
    public let type: SonyMessageType
    public let seq: UInt8
    public let payload: [UInt8]
    public init(type: SonyMessageType, seq: UInt8, payload: [UInt8]) {
        self.type = type
        self.seq = seq
        self.payload = payload
    }
}

public enum SonyFraming {
    private static let start: UInt8 = 0x3E
    private static let end: UInt8 = 0x3C
    private static let escape: UInt8 = 0x3D
    private static let escapeMask: UInt8 = 0xEF

    public static func encode(type: SonyMessageType, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count)
        var body: [UInt8] = [type.rawValue, seq]
        body.append(UInt8((length >> 24) & 0xFF))
        body.append(UInt8((length >> 16) & 0xFF))
        body.append(UInt8((length >> 8) & 0xFF))
        body.append(UInt8(length & 0xFF))
        body.append(contentsOf: payload)
        let checksum = UInt8(body.reduce(0) { ($0 + Int($1)) } & 0xFF)
        body.append(checksum)

        var out: [UInt8] = [start]
        for byte in body {
            if byte == start || byte == end || byte == escape {
                out.append(escape)
                out.append(byte & escapeMask)
            } else {
                out.append(byte)
            }
        }
        out.append(end)
        return out
    }

    public static func decode(_ bytes: [UInt8]) -> SonyFrame? {
        guard bytes.count >= 9, bytes.first == start, bytes.last == end else { return nil }

        // Unescape the interior (between the markers).
        var body: [UInt8] = []
        var i = 1
        let lastIndex = bytes.count - 1
        while i < lastIndex {
            let byte = bytes[i]
            if byte == escape {
                guard i + 1 < lastIndex else { return nil }
                body.append(bytes[i + 1] | 0x10)
                i += 2
            } else {
                body.append(byte)
                i += 1
            }
        }

        // body = type, seq, len[4], payload..., checksum
        guard body.count >= 7 else { return nil }
        let stated = body.removeLast()
        let computed = UInt8(body.reduce(0) { ($0 + Int($1)) } & 0xFF)
        guard stated == computed else { return nil }

        guard let type = SonyMessageType(rawValue: body[0]) else { return nil }
        let seq = body[1]
        let length = Int(body[2]) << 24 | Int(body[3]) << 16 | Int(body[4]) << 8 | Int(body[5])
        let payload = Array(body[6...])
        guard payload.count == length else { return nil }
        return SonyFrame(type: type, seq: seq, payload: payload)
    }
}
