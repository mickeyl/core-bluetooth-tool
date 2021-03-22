//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import Foundation
import CoreBluetooth

var scanner = Scanner()

struct Scan: ParsableCommand {
    
    public static let configuration = CommandConfiguration(abstract: "Scan BLE devices")
    
    @Option(help: "Scan for a specific service UUID")
    private var uuid: String?

    func run() throws {
        if let uuid = self.uuid {
            let service = CBUUID(string: uuid)
            scanner = Scanner(service: service)
        } else {
            scanner = Scanner()
        }
        scanner.scan()

        let loop = RunLoop.current
        while loop.run(mode: .default, before: Date.distantFuture) {
            loop.run()
        }
    }
}

class Scanner: NSObject {
    
    let queue = DispatchQueue(label: "CoreBluetoothQ")
    let services: [CBUUID]

    var manager: CBCentralManager!
    var peripherals: [UUID: CBPeripheral] = [:]

    init(service: CBUUID? = nil) {
        self.services = service != nil ? [service!] : []
    }
    
    func scan() {
        self.manager = CBCentralManager(delegate: self, queue: self.queue)
    }
}

extension Scanner: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
            
            case .unknown:
                break
            case .resetting:
                break
            case .unsupported:
                break
            case .unauthorized:
                break
            case .poweredOff:
                print("Error: Bluetooth not powered on. Please power on Bluetooth and try again.")
                Foundation.exit(-1)
            case .poweredOn:
                print("Scanning…")
                central.scanForPeripherals(withServices: self.services, options: nil)
                let peripherals = central.retrieveConnectedPeripherals(withServices: [])
                peripherals.forEach { self.centralManager(central, didDiscover: $0, advertisementData: [:], rssi: 42.0) }
            @unknown default:
                break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let identifier = peripheral.identifier
        guard let _ = self.peripherals[identifier] else {
            let name = peripheral.name ?? "(Unknown)"
            print("\(identifier)\t\(name)")
            self.peripherals[identifier] = peripheral
            return
        }
    }
}
