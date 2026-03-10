//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import Foundation

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct CoreBluetoothTool: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "core-bluetooth-tool",
        abstract: "CoreBluetooth command-line tool for scanning and more",
        subcommands: [
            Scan.self,
            Monitor.self,
            Bridge.self,
            Autobridge.self,
            L2CAPServer.self,
            L2CAPClient.self,
        ]
    )
    
    init() {
        
    }
}
