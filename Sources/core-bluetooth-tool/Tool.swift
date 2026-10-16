//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import Foundation
import Dispatch

@main
enum ToolMain {
    static func main() {
        do {
            var command = try CoreBluetoothTool.parseAsRoot()
            if let asynchronous = command as? AsyncParsableCommand {
                Task {
                    var asynchronous = asynchronous
                    do {
                        try await asynchronous.run()
                        CoreBluetoothTool.exit()
                    } catch { CoreBluetoothTool.exit(withError: error) }
                }
                dispatchMain()
            } else {
                // A blocking Cocoa/run-loop command must begin outside a main-
                // queue Swift task, or its nested loop cannot drain that queue.
                try command.run()
                CoreBluetoothTool.exit()
            }
        } catch { CoreBluetoothTool.exit(withError: error) }
    }
}

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
            L2CAPReflect.self,
        ]
    )
    
    init() {
        
    }
}
