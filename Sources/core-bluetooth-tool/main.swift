//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser

struct CoreBluetoothTool: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "core-bluetooth-tool",
        abstract: "CoreBluetooth command-line tool for scanning and more",
        subcommands: [
            Scan.self,
            Bridge.self,
        ]
    )
    
    init() {
        
    }
}

CoreBluetoothTool.main()
