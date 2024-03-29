//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import Foundation
import Chalk
import CoreBluetooth

var scanner = Scanner()

struct Scan: ParsableCommand {
    
    public static let configuration = CommandConfiguration(abstract: "Scan BLE devices")
    
    @Argument(help: "Specify an entity to scan for, either service, service.characteristic, or service.characteristic.descriptor. If you're running macOS Catalina or older, there's also support for scanning by device, device.service, device.service.characteristic, and device.service.characteristic.descriptor")
    private var entity: String?
    
    func loop() {

        signal(SIGINT, SIG_IGN)
        let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSrc.setEventHandler {
            Foundation.exit(0)
        }
        sigintSrc.resume()
        let loop = RunLoop.current
        while loop.run(mode: .default, before: Date.distantFuture) {
            loop.run()
        }
    }

    func run() throws {

        if self.entity == nil {
            // scan for everything
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            if osVersion.majorVersion == 12 && osVersion.minorVersion < 3 {
                print("""
NOTE: It looks like you're running on macOS Monterey 12.0, 12.1, or 12.2. These versions were
treating command line processes like 'background processes', hence the CoreBluetooth background scanning rules
(no wildcard scanning) applied. This meant that you could not scan for devices without specifying
a concrete service UUID. Thankfully this has been reverted starting with macOS 12.3.

If you did complain with Apple, thanks a lot for helping!

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
        
        print("(P) \(identifier, color: .magenta)\t\(peripheral.CC_name, color: .blue)")
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
            print("(S) \(peripheral.identifier, color: .magenta)\t\(peripheral.CC_name, color: .blue)\t\(service.uuid, color: .yellow)\t\(primary)")

            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Can't discover characteristics for \(peripheral).\(service): \(error)")
            return
        }

        service.characteristics?.forEach { characteristic in

            var properties: [String] = []
            if characteristic.properties.contains(.broadcast) { properties.append("Broadcast") }
            if characteristic.properties.contains(.read) { properties.append("Read") }
            if characteristic.properties.contains(.writeWithoutResponse) {
                if characteristic.properties.contains(.authenticatedSignedWrites) {
                    properties.append("Write w/o Response [SIGNED]")
                } else {
                    properties.append("Write w/o Response")
                }
            }
            if characteristic.properties.contains(.write) {
                if characteristic.properties.contains(.authenticatedSignedWrites) {
                    properties.append("Write [SIGNED]")
                } else {
                    properties.append("Write")
                }
            }
            if characteristic.properties.contains(.notify) {
                if characteristic.properties.contains(.notifyEncryptionRequired) {
                    properties.append("Notify [ENCRYPTED]")
                } else {
                    properties.append("Notify")
                }
            }
            if characteristic.properties.contains(.indicate) {
                if characteristic.properties.contains(.indicateEncryptionRequired) {
                    properties.append("Indicate [ENCRYPTED]")
                } else {
                    properties.append("Indicate")
                }
            }
            if characteristic.properties.contains(.extendedProperties) {
                properties.append("Extended")
            }
            let p = properties.joined(separator: ", ")
            print("(C) \(peripheral.identifier, color: .magenta)\t\(peripheral.CC_name, color: .blue)\t\(service.uuid, color: .yellow).\(characteristic.uuid, color: .cyan)\t\(p)")
            peripheral.discoverDescriptors(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Can't discover descriptors for \(peripheral).\(characteristic.service!).\(characteristic): \(error)")
            return
        }
        characteristic.descriptors?.forEach { descriptor in
            print("(D) \(peripheral.identifier, color: .magenta)\t\(peripheral.CC_name, color: .blue)\t\(characteristic.service!.uuid, color: .yellow).\(characteristic.uuid, color: .cyan).\(descriptor.uuid, color: .red)")
        }
    }
}

extension CBPeripheral {

    var CC_name: String { self.name ?? "N/A" }
}
