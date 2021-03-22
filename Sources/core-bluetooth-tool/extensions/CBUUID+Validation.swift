//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import CoreBluetooth

public extension CBUUID {

    static private var regex: NSRegularExpression = try! NSRegularExpression(pattern: "([a-fA-F0-9]{4})|([a-fA-F0-9]{4}-[a-fA-F0-9]{4})|([0-9a-fA-F]{8}\\-[0-9a-fA-F]{4}\\-[0-9a-fA-F]{4}\\-[0-9a-fA-F]{4}\\-[0-9a-fA-F]{12})", options: [])

    static func CC_isValid(string: String) -> Bool {

        guard let _ = regex.firstMatch(in: string, options: [], range: NSRange(string.startIndex..<string.endIndex, in: string)) else { return false }
        return true
    }
}
