import Foundation

indirect enum MessagePackValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([String: MessagePackValue])

    var intValue: Int? {
        switch self {
        case .int(let value): Int(exactly: value)
        case .uint(let value): Int(exactly: value)
        case .double(let value): Int(value)
        default: nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [MessagePackValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var displayValue: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .uint(let value): String(value)
        case .double(let value): String(format: "%g", value)
        case .string(let value): value
        case .binary(let data): "0x" + data.hexString
        case .array(let values): "[" + values.map(\.displayValue).joined(separator: ", ") + "]"
        case .map(let values):
            "{"
                + values.sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \($0.value.displayValue)" }
                .joined(separator: ", ") + "}"
        }
    }
}

enum MessagePackError: Error, LocalizedError {
    case truncated
    case unsupported(UInt8)
    case invalidUTF8
    case nonStringMapKey
    case collectionTooLarge(Int)
    case nestingTooDeep
    case trailingBytes

    var errorDescription: String? {
        switch self {
        case .truncated: "Truncated MessagePack payload"
        case .unsupported(let byte): String(format: "Unsupported MessagePack marker 0x%02X", byte)
        case .invalidUTF8: "Invalid UTF-8 in MessagePack string"
        case .nonStringMapKey: "Only string-keyed MessagePack maps are supported"
        case .collectionTooLarge(let count): "MessagePack collection is too large (\(count) elements)"
        case .nestingTooDeep: "MessagePack nesting limit exceeded"
        case .trailingBytes: "MessagePack payload contains trailing bytes"
        }
    }
}

enum MessagePack {
    static func encode(_ value: MessagePackValue?) -> Data {
        guard let value else { return Data() }
        var output = Data()
        append(value, to: &output)
        return output
    }

    static func decode(_ data: Data) throws -> MessagePackValue {
        var decoder = Decoder(bytes: Array(data))
        let value = try decoder.decodeValue(depth: 0)
        guard decoder.isAtEnd else { throw MessagePackError.trailingBytes }
        return value
    }

    private static func append(_ value: MessagePackValue, to output: inout Data) {
        switch value {
        case .null:
            output.append(0xC0)
        case .bool(let value):
            output.append(value ? 0xC3 : 0xC2)
        case .int(let value):
            appendSigned(value, to: &output)
        case .uint(let value):
            appendUnsigned(value, to: &output)
        case .double(let value):
            output.append(0xCB)
            appendBigEndian(value.bitPattern, to: &output)
        case .string(let value):
            let bytes = Data(value.utf8)
            appendStringHeader(bytes.count, to: &output)
            output.append(bytes)
        case .binary(let value):
            if value.count <= 0xFF {
                output.append(0xC4)
                output.append(UInt8(value.count))
            } else if value.count <= 0xFFFF {
                output.append(0xC5)
                appendBigEndian(UInt16(value.count), to: &output)
            } else {
                output.append(0xC6)
                appendBigEndian(UInt32(value.count), to: &output)
            }
            output.append(value)
        case .array(let values):
            if values.count <= 15 {
                output.append(0x90 | UInt8(values.count))
            } else if values.count <= 0xFFFF {
                output.append(0xDC)
                appendBigEndian(UInt16(values.count), to: &output)
            } else {
                output.append(0xDD)
                appendBigEndian(UInt32(values.count), to: &output)
            }
            values.forEach { append($0, to: &output) }
        case .map(let values):
            let sorted = values.sorted { $0.key < $1.key }
            if sorted.count <= 15 {
                output.append(0x80 | UInt8(sorted.count))
            } else if sorted.count <= 0xFFFF {
                output.append(0xDE)
                appendBigEndian(UInt16(sorted.count), to: &output)
            } else {
                output.append(0xDF)
                appendBigEndian(UInt32(sorted.count), to: &output)
            }
            for (key, value) in sorted {
                append(.string(key), to: &output)
                append(value, to: &output)
            }
        }
    }

    private static func appendSigned(_ value: Int64, to output: inout Data) {
        if value >= 0 {
            appendUnsigned(UInt64(value), to: &output)
        } else if value >= -32 {
            output.append(UInt8(bitPattern: Int8(value)))
        } else if value >= Int64(Int8.min) {
            output.append(0xD0)
            output.append(UInt8(bitPattern: Int8(value)))
        } else if value >= Int64(Int16.min) {
            output.append(0xD1)
            appendBigEndian(UInt16(bitPattern: Int16(value)), to: &output)
        } else if value >= Int64(Int32.min) {
            output.append(0xD2)
            appendBigEndian(UInt32(bitPattern: Int32(value)), to: &output)
        } else {
            output.append(0xD3)
            appendBigEndian(UInt64(bitPattern: value), to: &output)
        }
    }

    private static func appendUnsigned(_ value: UInt64, to output: inout Data) {
        if value <= 0x7F {
            output.append(UInt8(value))
        } else if value <= UInt64(UInt8.max) {
            output.append(0xCC)
            output.append(UInt8(value))
        } else if value <= UInt64(UInt16.max) {
            output.append(0xCD)
            appendBigEndian(UInt16(value), to: &output)
        } else if value <= UInt64(UInt32.max) {
            output.append(0xCE)
            appendBigEndian(UInt32(value), to: &output)
        } else {
            output.append(0xCF)
            appendBigEndian(value, to: &output)
        }
    }

    private static func appendStringHeader(_ count: Int, to output: inout Data) {
        if count <= 31 {
            output.append(0xA0 | UInt8(count))
        } else if count <= 0xFF {
            output.append(0xD9)
            output.append(UInt8(count))
        } else if count <= 0xFFFF {
            output.append(0xDA)
            appendBigEndian(UInt16(count), to: &output)
        } else {
            output.append(0xDB)
            appendBigEndian(UInt32(count), to: &output)
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to output: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { output.append(contentsOf: $0) }
    }

    private struct Decoder {
        private static let maximumCollectionCount = 4_096
        private static let maximumNestingDepth = 64

        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index == bytes.count }

        mutating func decodeValue(depth: Int) throws -> MessagePackValue {
            guard depth <= Self.maximumNestingDepth else {
                throw MessagePackError.nestingTooDeep
            }
            let marker = try readByte()
            switch marker {
            // MoshiPack exposes positive fixints as signed numeric values in the
            // same way as the Android implementation's Number conversion.
            case 0x00...0x7F: return .int(Int64(marker))
            case 0x80...0x8F: return try decodeMap(count: Int(marker & 0x0F), depth: depth)
            case 0x90...0x9F: return try decodeArray(count: Int(marker & 0x0F), depth: depth)
            case 0xA0...0xBF: return try decodeString(count: Int(marker & 0x1F))
            case 0xC0: return .null
            case 0xC2: return .bool(false)
            case 0xC3: return .bool(true)
            case 0xC4: return .binary(try readData(count: Int(readByte())))
            case 0xC5: return .binary(try readData(count: Int(readInteger(UInt16.self))))
            case 0xC6: return .binary(try readData(count: Int(readInteger(UInt32.self))))
            case 0xCA: return .double(Double(Float(bitPattern: try readInteger(UInt32.self))))
            case 0xCB: return .double(Double(bitPattern: try readInteger(UInt64.self)))
            case 0xCC: return .uint(UInt64(try readByte()))
            case 0xCD: return .uint(UInt64(try readInteger(UInt16.self)))
            case 0xCE: return .uint(UInt64(try readInteger(UInt32.self)))
            case 0xCF: return .uint(try readInteger(UInt64.self))
            case 0xD0: return .int(Int64(Int8(bitPattern: try readByte())))
            case 0xD1: return .int(Int64(Int16(bitPattern: try readInteger(UInt16.self))))
            case 0xD2: return .int(Int64(Int32(bitPattern: try readInteger(UInt32.self))))
            case 0xD3: return .int(Int64(bitPattern: try readInteger(UInt64.self)))
            case 0xD9: return try decodeString(count: Int(readByte()))
            case 0xDA: return try decodeString(count: Int(readInteger(UInt16.self)))
            case 0xDB: return try decodeString(count: Int(readInteger(UInt32.self)))
            case 0xDC: return try decodeArray(count: Int(readInteger(UInt16.self)), depth: depth)
            case 0xDD: return try decodeArray(count: Int(readInteger(UInt32.self)), depth: depth)
            case 0xDE: return try decodeMap(count: Int(readInteger(UInt16.self)), depth: depth)
            case 0xDF: return try decodeMap(count: Int(readInteger(UInt32.self)), depth: depth)
            case 0xE0...0xFF: return .int(Int64(Int8(bitPattern: marker)))
            default: throw MessagePackError.unsupported(marker)
            }
        }

        private mutating func decodeArray(count: Int, depth: Int) throws -> MessagePackValue {
            try validateCollection(count: count, minimumBytesPerElement: 1)
            var values: [MessagePackValue] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try decodeValue(depth: depth + 1)) }
            return .array(values)
        }

        private mutating func decodeMap(count: Int, depth: Int) throws -> MessagePackValue {
            try validateCollection(count: count, minimumBytesPerElement: 2)
            var values: [String: MessagePackValue] = [:]
            for _ in 0..<count {
                guard case .string(let key) = try decodeValue(depth: depth + 1) else {
                    throw MessagePackError.nonStringMapKey
                }
                values[key] = try decodeValue(depth: depth + 1)
            }
            return .map(values)
        }

        private func validateCollection(count: Int, minimumBytesPerElement: Int) throws {
            guard count <= Self.maximumCollectionCount else {
                throw MessagePackError.collectionTooLarge(count)
            }
            guard count <= (bytes.count - index) / minimumBytesPerElement else {
                throw MessagePackError.truncated
            }
        }

        private mutating func decodeString(count: Int) throws -> MessagePackValue {
            let data = try readData(count: count)
            guard let value = String(data: data, encoding: .utf8) else {
                throw MessagePackError.invalidUTF8
            }
            return .string(value)
        }

        private mutating func readByte() throws -> UInt8 {
            guard index < bytes.count else { throw MessagePackError.truncated }
            defer { index += 1 }
            return bytes[index]
        }

        private mutating func readData(count: Int) throws -> Data {
            guard count >= 0, index + count <= bytes.count else { throw MessagePackError.truncated }
            defer { index += count }
            return Data(bytes[index..<(index + count)])
        }

        private mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let count = MemoryLayout<T>.size
            guard index + count <= bytes.count else { throw MessagePackError.truncated }
            var value: T = 0
            for byte in bytes[index..<(index + count)] {
                value = (value << 8) | T(byte)
            }
            index += count
            return value
        }
    }
}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
