//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import Foundation
import CoreBluetooth

var scanner = Scanner()

struct Scan: ParsableCommand {
    
    public static let configuration = CommandConfiguration(abstract: "Scan BLE devices")
    
    @Argument(help: "Specify an entity to scan for, either service, service.characteristic, or service.characteristic.descriptor. If you're running macOS Big Sur or older, there's also support for scanning by device, device.service, device.service.characteristic, and device.service.characteristic.descriptor")
    private var entity: String?
    
    func loop() {
        let loop = RunLoop.current
        while loop.run(mode: .default, before: Date.distantFuture) {
            loop.run()
        }
    }

    func run() throws {

        if self.entity == nil {
            // scan for everything
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 12 {
                print("""
NOTE: It looks like you're running on macOS Monterey or later. This means, we can no longer scan without
specifying a concrete service to look for. This is due to a change in Apple's frameworks that treats a command line
process to be a 'background process', thus the CoreBluetooth background scanning rules (no wildcard scanning) apply.

Apple continues to devalue the operating system command line, which is a very very sad trend.
Please complain by using their feedback reporter. Not that I think it helps though…

""")
            }
            scanner.scan()
            self.loop()
            return
        }
        
        let components = entity!.components(separatedBy: ".")
        switch components.count {
            case 1:
                let a = components[0]
                switch a.count {
                    case 4: scanner.command = .scanService(CBUUID(string: a))
                    case 36: scanner.command = .scanPeripheral(UUID(uuidString: a)!)
                    default:
                        print("Argument error: \(a) is not a valid peripheral or service ID")
                        Foundation.exit(-1)
                }
            case 2:
                fallthrough
            case 3:
                fallthrough
            default:
                fatalError("???")
        }

        scanner.scan()
        self.loop()
    }
}

class Scanner: NSObject {
    
    enum Command: Equatable {
        case scanAll
        case scanService(CBUUID)
        case scanServiceCharacteristic(CBUUID, CBUUID)
        case scanServiceCharacteristicDescriptor(CBUUID, CBUUID, CBUUID)
        case scanPeripheral(UUID)
        case scanPeripheralService(CBUUID, CBUUID)
        case scanPeripheralServiceCharacteristic(CBUUID, CBUUID, CBUUID)
        case scanPeripheralServiceCharacteristicDescriptor(CBUUID, CBUUID, CBUUID, CBUUID)
    }
    
    let queue = DispatchQueue(label: "CoreBluetoothQ")
    var services: [CBUUID] = []
    var characteristicIdentifier: CBUUID?
    var descriptorIdentifier: CBUUID?
    var peripheralIdentifier: UUID?

    var command: Command = .scanAll {
        didSet {
            #if DEBUG
            print("Command \(self.command)")
            #endif
            switch self.command {
                case let .scanService(uuid):
                    self.services = [uuid]
                case let .scanServiceCharacteristic(suuid, cuuid):
                    self.services = [suuid]
                    self.characteristicIdentifier = cuuid
                case let .scanPeripheral(uuid):
                    self.peripheralIdentifier = uuid
                default:
                    fatalError("not yet implemented")
            }
        }
    }

    var manager: CBCentralManager!
    var peripherals: [UUID: CBPeripheral] = [:]
    
    func scan() {
        self.manager = CBCentralManager()
        self.manager.delegate = self
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
                print("Error: Bluetooth not supported on this device.")
                Foundation.exit(-1)
            case .unauthorized:
                print("Error: Bluetooth usage not authorized.")
                Foundation.exit(-1)
            case .poweredOff:
                print("Error: Bluetooth not powered on. Please power on Bluetooth and try again.")
                Foundation.exit(-1)
            case .poweredOn:
                print("BLE powered on, scanning for \(self.services)...")
                let peripherals = central.retrieveConnectedPeripherals(withServices: self.services)
                peripherals.forEach { self.centralManager(central, didDiscover: $0, advertisementData: [:], rssi: 42.0) }
                central.scanForPeripherals(withServices: self.services, options: nil)
            @unknown default:
                break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        #if DEBUG
        print("Discovered: \(peripheral)")
        #endif
        let identifier = peripheral.identifier
        guard self.peripherals[identifier] == nil else { return }
        
        let name = peripheral.name ?? "(Unknown)"
        print("(P) \(identifier)\t\(name)")
        self.peripherals[identifier] = peripheral

        if self.peripheralIdentifier == nil {
            central.connect(peripheral, options: nil)
        } else if identifier == self.peripheralIdentifier {
            print("Connecting to \(identifier)...")
            central.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }
}

extension Scanner: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Can't discover services for \(peripheral): \(error)")
            Foundation.exit(-1)
        }
        peripheral.services?.forEach { service in
            let primary = service.isPrimary ? "PRIMARY" : ""
            print("(S) \(service.uuid)\t\(primary)")

            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Can't discover characteristics for \(peripheral).\(service): \(error)")
            return
        }

        service.characteristics?.forEach { characteristic in
            
            print("(C) \(service.uuid).\(characteristic.uuid)")

        }
    }
}
