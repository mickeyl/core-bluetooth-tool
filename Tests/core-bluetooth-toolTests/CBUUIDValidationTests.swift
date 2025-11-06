import CoreBluetooth
import Foundation
import Testing
@testable import core_bluetooth_tool

@Suite("CBUUID Validation")
struct CBUUIDValidationTests {

    @Test("accepts valid 16-bit UUID")
    func accepts16BitUUID() async throws {
        #expect(CBUUID.CC_isValid(string: "180D"))
    }

    @Test("accepts valid 32-bit UUID")
    func accepts32BitUUID() async throws {
        #expect(CBUUID.CC_isValid(string: "12345678"))
    }

    @Test("accepts valid 32-bit UUID with hyphen")
    func acceptsHyphenated32BitUUID() async throws {
        #expect(CBUUID.CC_isValid(string: "1234-5678"))
    }

    @Test("accepts valid 128-bit UUID")
    func accepts128BitUUID() async throws {
        #expect(CBUUID.CC_isValid(string: "12345678-1234-5678-9ABC-DEF012345678"))
    }

    @Test("rejects strings with invalid length")
    func rejectsInvalidLength() async throws {
        #expect(!CBUUID.CC_isValid(string: "12345"))
    }

    @Test("rejects strings with invalid characters")
    func rejectsInvalidCharacters() async throws {
        #expect(!CBUUID.CC_isValid(string: "ZZZZ"))
    }

    @Test("rejects embedded UUID when additional characters provided")
    func rejectsEmbeddedUUID() async throws {
        #expect(!CBUUID.CC_isValid(string: "180D-extra"))
    }
}
