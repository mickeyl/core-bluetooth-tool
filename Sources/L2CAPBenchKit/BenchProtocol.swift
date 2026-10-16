import Foundation

public enum BenchProtocolError: Error, Equatable {
    case invalidMagic
    case payloadTooLarge
    case invalidHello
    case invalidConfig
    case invalidPing
    case invalidPattern
    case invalidStream
}

public struct BenchFrame: Equatable {
    public static let magic: UInt8 = 0xB7
    public static let maximumPayload = 4996

    public let type: UInt8
    public let payload: Data

    public init(type: UInt8, payload: Data) throws {
        guard payload.count <= Self.maximumPayload else { throw BenchProtocolError.payloadTooLarge }
        self.type = type
        self.payload = payload
    }

    public func encoded() -> Data {
        let length = UInt16(payload.count)
        var bytes = Data([Self.magic, type, UInt8(length >> 8), UInt8(truncatingIfNeeded: length)])
        bytes.append(payload)
        return bytes
    }
}

public enum BenchMessage {
    public static let hello: UInt8 = 0x01
    public static let config: UInt8 = 0x02
    public static let ping: UInt8 = 0x03
    public static let helloReply: UInt8 = 0x81
    public static let configReply: UInt8 = 0x82
    public static let pingReply: UInt8 = 0x83
    public static let abort: UInt8 = 0x7F
    public static let stream: UInt8 = 4
    public static let streamEnd: UInt8 = 5
    public static let streamStart: UInt8 = 6
    public static let streamFinish: UInt8 = 7
    public static let streamEndReply: UInt8 = 0x85
    public static let streamStartReply: UInt8 = 0x86
    public static let streamFinishReply: UInt8 = 0x87
}

public struct BenchFrameParser {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [BenchFrame] {
        buffer.append(bytes)
        var frames: [BenchFrame] = []
        while buffer.count >= 4 {
            guard buffer[0] == BenchFrame.magic else { throw BenchProtocolError.invalidMagic }
            let length = (Int(buffer[2]) << 8) | Int(buffer[3])
            guard length <= BenchFrame.maximumPayload else { throw BenchProtocolError.payloadTooLarge }
            guard buffer.count >= length + 4 else { break }
            frames.append(try BenchFrame(type: buffer[1], payload: Data(buffer[4..<(length + 4)])))
            buffer = Data(buffer.dropFirst(length + 4))
        }
        return frames
    }
}

public struct BenchHello {
    public static let version: UInt8 = 2
    public let identity: String

    public init(identity: String) { self.identity = identity }

    public init(payload: Data) throws {
        guard payload.first == Self.version,
              let identity = String(data: Data(payload.dropFirst()), encoding: .utf8)
        else { throw BenchProtocolError.invalidHello }
        self.identity = identity
    }

    public func encoded() -> Data {
        var bytes = Data([Self.version])
        bytes.append(contentsOf: identity.utf8)
        return bytes
    }
}

public struct BenchConfig {
    public enum Pattern: UInt8 { case echo = 1, request = 2, streamTX = 3, streamRX = 4, duplex = 5 }

    public let pattern: Pattern
    public let requestSize: Int
    public let responseSize: Int
    public let count: UInt32

    // All sizes count the message payload, excluding the four-byte frame header.
    public init(payload: Data) throws {
        guard payload.count == 9, let pattern = Pattern(rawValue: payload[0]) else {
            throw BenchProtocolError.invalidConfig
        }
        let requestSize = (Int(payload[1]) << 8) | Int(payload[2])
        let responseSize = (Int(payload[3]) << 8) | Int(payload[4])
        let count = readUInt32(payload, at: 5)
        guard requestSize >= 8, requestSize <= BenchFrame.maximumPayload,
              responseSize >= 12, responseSize <= BenchFrame.maximumPayload,
              count > 0, count <= 4096, (pattern != .echo || requestSize == responseSize)
        else { throw BenchProtocolError.invalidConfig }
        self.pattern = pattern
        self.requestSize = requestSize
        self.responseSize = responseSize
        self.count = count
    }
}

public struct BenchStreamSummary {
    public var token: UInt32
    public var frames: UInt32 = 0
    public var bytes: UInt64 = 0
    public var firstMicroseconds: UInt64 = 0
    public var lastMicroseconds: UInt64 = 0
    public var errors: UInt32 = 0

    public init(token: UInt32) { self.token = token }

    public init(payload: Data) throws {
        guard payload.count == 36 else { throw BenchProtocolError.invalidStream }
        token = readUInt32(payload, at: 0)
        frames = readUInt32(payload, at: 4)
        bytes = readUInt64(payload, at: 8)
        firstMicroseconds = readUInt64(payload, at: 16)
        lastMicroseconds = readUInt64(payload, at: 24)
        errors = readUInt32(payload, at: 32)
        guard firstMicroseconds <= lastMicroseconds else { throw BenchProtocolError.invalidStream }
    }

    public func matches(token: UInt32, count: UInt32, size: Int) -> Bool {
        self.token == token && frames == count && bytes == UInt64(count) * UInt64(size) && errors == 0 &&
            firstMicroseconds <= lastMicroseconds
    }

    public func encoded() -> Data {
        var data = Data()
        appendUInt32(token, to: &data); appendUInt32(frames, to: &data)
        appendUInt64(bytes, to: &data); appendUInt64(firstMicroseconds, to: &data)
        appendUInt64(lastMicroseconds, to: &data); appendUInt32(errors, to: &data)
        return data
    }
}

public struct BenchStreamReceiver {
    public private(set) var summary: BenchStreamSummary
    public private(set) var ended = false
    private let size: Int
    private let count: UInt32

    public init(token: UInt32, count: UInt32, size: Int) {
        summary = BenchStreamSummary(token: token); self.count = count; self.size = size
    }

    public mutating func receive(_ payload: Data, atMicroseconds now: UInt64) throws {
        do {
            let ping = try BenchPing(payload: payload, expectedSize: size)
            guard !ended, ping.sequence == summary.frames, ping.sequence < count,
                  ping.token == summary.token else { throw BenchProtocolError.invalidStream }
            if summary.frames == 0 { summary.firstMicroseconds = now }
            summary.lastMicroseconds = now; summary.frames += 1; summary.bytes += UInt64(payload.count)
        } catch {
            summary.errors += 1
            throw error
        }
    }

    public mutating func end(_ payload: Data) throws {
        guard !ended, payload.count == 8, readUInt32(payload, at: 0) == summary.token,
              readUInt32(payload, at: 4) == count,
              summary.matches(token: summary.token, count: count, size: size) else {
            summary.errors += 1
            throw BenchProtocolError.invalidStream
        }
        ended = true
    }
}

public enum BenchStream {
    public static func token(from payload: Data) throws -> UInt32 {
        guard payload.count == 4 else { throw BenchProtocolError.invalidStream }
        return readUInt32(payload, at: 0)
    }
    public static func tokenPayload(_ token: UInt32) -> Data {
        var data = Data(); appendUInt32(token, to: &data); return data
    }
    public static func endPayload(token: UInt32, count: UInt32) -> Data {
        var data = tokenPayload(token); appendUInt32(count, to: &data); return data
    }
    public static func payload(sequence: UInt32, token: UInt32, size: Int) throws -> Data {
        guard size >= 8, size <= BenchFrame.maximumPayload else { throw BenchProtocolError.invalidStream }
        var data = Data(); data.reserveCapacity(size)
        appendUInt32(sequence, to: &data); appendUInt32(token, to: &data)
        for i in 0..<(size - 8) { data.append(BenchPing.patternByte(sequence: sequence, token: token, index: i)) }
        return data
    }
}

private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    UInt64(readUInt32(data, at: offset)) << 32 | UInt64(readUInt32(data, at: offset + 4))
}
private func appendUInt64(_ value: UInt64, to bytes: inout Data) {
    appendUInt32(UInt32(truncatingIfNeeded: value >> 32), to: &bytes)
    appendUInt32(UInt32(truncatingIfNeeded: value), to: &bytes)
}

public struct BenchPing {
    public let sequence: UInt32
    public let token: UInt32

    public init(payload: Data, expectedSize: Int) throws {
        guard payload.count == expectedSize, payload.count >= 8 else {
            throw BenchProtocolError.invalidPing
        }
        sequence = readUInt32(payload, at: 0)
        token = readUInt32(payload, at: 4)
        for index in 8..<payload.count {
            guard payload[index] == Self.patternByte(sequence: sequence, token: token, index: index - 8)
            else { throw BenchProtocolError.invalidPattern }
        }
    }

    public func response(size: Int, turnaroundMicroseconds: UInt32) throws -> Data {
        guard size >= 12, size <= BenchFrame.maximumPayload else { throw BenchProtocolError.invalidPing }
        var bytes = Data()
        bytes.reserveCapacity(size)
        appendUInt32(sequence, to: &bytes)
        appendUInt32(token, to: &bytes)
        appendUInt32(turnaroundMicroseconds, to: &bytes)
        for index in 0..<(size - 12) {
            bytes.append(Self.patternByte(sequence: sequence, token: token, index: index))
        }
        return bytes
    }

    public static func patternByte(sequence: UInt32, token: UInt32, index: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: sequence &+ token &+ UInt32(index))
    }
}

private func readUInt32(_ bytes: Data, at offset: Int) -> UInt32 {
    (UInt32(bytes[offset]) << 24) |
    (UInt32(bytes[offset + 1]) << 16) |
    (UInt32(bytes[offset + 2]) << 8) |
    UInt32(bytes[offset + 3])
}

private func appendUInt32(_ value: UInt32, to bytes: inout Data) {
    bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    bytes.append(UInt8(truncatingIfNeeded: value >> 16))
    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    bytes.append(UInt8(truncatingIfNeeded: value))
}
