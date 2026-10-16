import Foundation
import XCTest
@testable import L2CAPBenchKit

final class BenchProtocolTests: XCTestCase {
    func testParserReassemblesSplitAndCoalescedFrames() throws {
        let first = try BenchFrame(type: BenchMessage.hello, payload: BenchHello(identity: "S3").encoded())
        let second = try BenchFrame(type: BenchMessage.config, payload: Data([1, 0, 64, 0, 64, 0, 0, 0, 2]))
        var parser = BenchFrameParser()
        let combined = first.encoded() + second.encoded()
        XCTAssertEqual(try parser.append(Data(combined.prefix(2))), [])
        XCTAssertEqual(try parser.append(Data(combined.dropFirst(2))), [first, second])
    }

    func testParserRejectsOversizedPayloadBeforeBufferingIt() throws {
        var parser = BenchFrameParser()
        XCTAssertThrowsError(try parser.append(Data([BenchFrame.magic, BenchMessage.ping, 0x13, 0x85]))) {
            XCTAssertEqual($0 as? BenchProtocolError, .payloadTooLarge)
        }
    }

    func testPingPatternAndResponse() throws {
        let sequence: UInt32 = 0x01020304
        let token: UInt32 = 0xAABBCCDD
        var request = Data([1, 2, 3, 4, 0xAA, 0xBB, 0xCC, 0xDD])
        for index in 0..<56 {
            request.append(BenchPing.patternByte(sequence: sequence, token: token, index: index))
        }
        let ping = try BenchPing(payload: request, expectedSize: 64)
        let reply = try ping.response(size: 32, turnaroundMicroseconds: 42)
        XCTAssertEqual(reply.count, 32)
        XCTAssertEqual(Array(reply.prefix(12)), [1, 2, 3, 4, 0xAA, 0xBB, 0xCC, 0xDD, 0, 0, 0, 42])
    }

    func testRejectsCorruptedPatternAndMismatchedEchoSizes() throws {
        XCTAssertThrowsError(try BenchPing(payload: Data([0, 0, 0, 0, 0, 0, 0, 0, 1]), expectedSize: 9))
        XCTAssertThrowsError(try BenchConfig(payload: Data([1, 0, 64, 0, 32, 0, 0, 0, 1])))
    }

    func testStreamReceiptsAnd64BitClockRoundTrip() throws {
        var receiver = BenchStreamReceiver(token: 0xAABBCCDD, count: 2, size: 64)
        try receiver.receive(BenchStream.payload(sequence: 0, token: 0xAABBCCDD, size: 64), atMicroseconds: 0x100000001)
        try receiver.receive(BenchStream.payload(sequence: 1, token: 0xAABBCCDD, size: 64), atMicroseconds: 0x100000002)
        try receiver.end(BenchStream.endPayload(token: 0xAABBCCDD, count: 2))
        let receipt = try BenchStreamSummary(payload: receiver.summary.encoded())
        XCTAssertTrue(receipt.matches(token: 0xAABBCCDD, count: 2, size: 64))
        XCTAssertEqual(receipt.firstMicroseconds, 0x100000001)
        XCTAssertThrowsError(try receiver.receive(BenchStream.payload(sequence: 1, token: 0xAABBCCDD, size: 64), atMicroseconds: 200))
    }

    func testStreamRejectsGapsDuplicatesTokenAndDataErrors() throws {
        for bad in [try BenchStream.payload(sequence: 0, token: 42, size: 64),
                    try BenchStream.payload(sequence: 1, token: 7, size: 64),
                    try BenchStream.payload(sequence: 1, token: 42, size: 65)] {
            var receiver = BenchStreamReceiver(token: 42, count: 2, size: 64)
            try receiver.receive(BenchStream.payload(sequence: 0, token: 42, size: 64), atMicroseconds: 100)
            XCTAssertThrowsError(try receiver.receive(bad, atMicroseconds: 200))
            XCTAssertThrowsError(try receiver.end(BenchStream.endPayload(token: 42, count: 2)))
        }
        var receiver = BenchStreamReceiver(token: 42, count: 2, size: 64)
        XCTAssertThrowsError(try receiver.receive(BenchStream.payload(sequence: 1, token: 42, size: 64), atMicroseconds: 100))
        var corrupt = try BenchStream.payload(sequence: 0, token: 42, size: 64); corrupt[63] ^= 1
        XCTAssertThrowsError(try receiver.receive(corrupt, atMicroseconds: 200))
        XCTAssertThrowsError(try BenchStreamSummary(payload: Data([0])))
    }
}
