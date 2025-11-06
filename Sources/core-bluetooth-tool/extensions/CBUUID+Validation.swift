//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import CoreBluetooth
import Foundation

public extension CBUUID {

    private static let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    static func CC_isValid(string: String) -> Bool {

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Standard 128-bit UUID with hyphenated representation.
        if trimmed.count == 36 {
            return UUID(uuidString: trimmed) != nil
        }

        // Allow 128-bit UUIDs without hyphens as well as 16-bit and 32-bit UUIDs.
        let components = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        switch components.count {
            case 1:
                let value = components[0]
                return isValidHex(value, allowedLengths: [4, 8, 32])
            case 2:
                // Accept 32-bit UUIDs in the form "XXXX-XXXX".
                guard components[0].count == 4, components[1].count == 4 else { return false }
                let joined = components.joined()
                return isValidHex(String(joined), allowedLengths: [8])
            default:
                return false
        }
    }

    private static func isValidHex<S: StringProtocol>(_ value: S, allowedLengths: Set<Int>) -> Bool {
        guard allowedLengths.contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { hexCharacterSet.contains($0) }
    }
}
