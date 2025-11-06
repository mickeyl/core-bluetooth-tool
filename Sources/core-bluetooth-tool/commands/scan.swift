//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import Foundation
import Chalk
import CoreBluetooth
import CornucopiaCore

let logger = Cornucopia.Core.Logger(subsystem: "core-bluetooth-tool", category: "scan")

var scanner = Scanner()

struct Scan: ParsableCommand {
    
    public static let configuration = CommandConfiguration(abstract: "Scan BLE devices")
    
    @Argument(help: ArgumentHelp("Target to scan", discussion: """
Provide a dot-separated path that uses real BLE UUIDs:
- `<serviceUUID>` optionally followed by `.characteristicUUID` and `.descriptorUUID`
- `device.<peripheralUUID>` optionally followed by `.serviceUUID`, `.characteristicUUID`, and `.descriptorUUID`

UUID components may be 16-bit, 32-bit, or 128-bit hexadecimal identifiers.
"""))
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
        
        var components = entity!.components(separatedBy: ".").filter { !$0.isEmpty }
        if components.isEmpty {
            print("Argument error: entity must not contain empty components.")
            Foundation.exit(-1)
        }

        if components.first?.lowercased() == "device" {
            components.removeFirst()
            self.configureDeviceScan(with: components)
        } else {
            self.configureServiceScan(with: components)
        }

        scanner.scan()
        self.loop()
    }
}

private extension Scan {

    func configureServiceScan(with components: [String]) {

        switch components.count {
            case 1:
                let service = components[0]
                guard CBUUID.CC_isValid(string: service) else {
                    print("Argument error: \(service) is not a valid service UUID (must be 16-bit, 32-bit, or 128-bit).")
                    Foundation.exit(-1)
                }
                scanner.command = .scanService(CBUUID(string: service))

            case 2:
                let service = components[0]
                let characteristic = components[1]
                guard CBUUID.CC_isValid(string: service) else {
                    print("Argument error: \(service) is not a valid service UUID (must be 16-bit, 32-bit, or 128-bit).")
                    Foundation.exit(-1)
                }
                guard CBUUID.CC_isValid(string: characteristic) else {
                    print("Argument error: \(characteristic) is not a valid characteristic UUID (must be 16-bit, 32-bit, or 128-bit).")
                    Foundation.exit(-1)
                }
                scanner.command = .scanServiceCharacteristic(CBUUID(string: service), CBUUID(string: characteristic))

            case 3:
                let service = components[0]
                let characteristic = components[1]
                let descriptor = components[2]
                guard CBUUID.CC_isValid(string: service) else {
                    print("Argument error: \(service) is not a valid service UUID (must be 16-bit, 32-bit, or 128-bit).")
                    Foundation.exit(-1)
                }
                guard CBUUID.CC_isValid(string: characteristic) else {
                    print("Argument error: \(characteristic) is not a valid characteristic UUID (must be 16-bit, 32-bit, or 128-bit).")
                    Foundation.exit(-1)
                }
                guard CBUUID.CC_isValid(string: descriptor) else {
                    print("Argument error: \(descriptor) is not a valid descriptor UUID (must be 16-bit, 32-bit, or 128-bit).")
                    Foundation.exit(-1)
                }
                scanner.command = .scanServiceCharacteristicDescriptor(CBUUID(string: service), CBUUID(string: characteristic), CBUUID(string: descriptor))

            default:
                print("Argument error: Unsupported number of service components (expected up to 3, got \(components.count)). Use <serviceUUID>[.<characteristicUUID>[.<descriptorUUID>]].")
                Foundation.exit(-1)
        }
    }

    func configureDeviceScan(with components: [String]) {

        guard !components.isEmpty else {
            print("Argument error: device scan requires at least the device UUID.")
            Foundation.exit(-1)
        }

        let device = components[0]
        guard let deviceUUID = UUID(uuidString: device) else {
            print("Argument error: \(device) is not a valid BLE device UUID.")
            Foundation.exit(-1)
        }

        switch components.count {
            case 1:
                scanner.command = .scanPeripheral(deviceUUID)
            case 2:
                let service = components[1]
                guard CBUUID.CC_isValid(string: service) else {
                    print("Argument error: \(service) is not a valid service UUID (must be 16-bit, 32-bit, or 128-bit).")
                    Foundation.exit(-1)
                }
                scanner.command = .scanPeripheralService(deviceUUID, CBUUID(string: service))
            case 3:
                let service = components[1]
                let characteristic = components[2]
                guard CBUUID.CC_isValid(string: service) else {
                    print("Argument error: \(service) is not a valid service UUID (must be 16-bit, 32-bit, or 128-bit).")
                    Foundation.exit(-1)
                }
                guard CBUUID.CC_isValid(string: characteristic) else {
                    print("Argument error: \(characteristic) is not a valid characteristic UUID (must be 16-bit, 32-bit, or 128-bit).")
                    Foundation.exit(-1)
                }
                scanner.command = .scanPeripheralServiceCharacteristic(deviceUUID, CBUUID(string: service), CBUUID(string: characteristic))
            case 4:
                let service = components[1]
                let characteristic = components[2]
                let descriptor = components[3]
                guard CBUUID.CC_isValid(string: service) else {
                    print("Argument error: \(service) is not a valid service UUID (must be 16-bit, 32-bit, or 128-bit).")
                    Foundation.exit(-1)
                }
                guard CBUUID.CC_isValid(string: characteristic) else {
                    print("Argument error: \(characteristic) is not a valid characteristic UUID (must be 16-bit, 32-bit, or 128-bit).")
                    Foundation.exit(-1)
                }
                guard CBUUID.CC_isValid(string: descriptor) else {
                    print("Argument error: \(descriptor) is not a valid descriptor UUID (must be 16-bit, 32-bit, or 128-bit).")
                    Foundation.exit(-1)
                }
                scanner.command = .scanPeripheralServiceCharacteristicDescriptor(deviceUUID, CBUUID(string: service), CBUUID(string: characteristic), CBUUID(string: descriptor))
            default:
                print("Argument error: Unsupported number of device components (expected up to 4, got \(components.count)). Use device.<peripheralUUID>[.<serviceUUID>[.<characteristicUUID>[.<descriptorUUID>]]].")
                Foundation.exit(-1)
        }
    }
}

class Scanner: NSObject {
    
    enum Command: Equatable {
        case scanAll
        case scanService(CBUUID)
        case scanServiceCharacteristic(CBUUID, CBUUID)
        case scanServiceCharacteristicDescriptor(CBUUID, CBUUID, CBUUID)
        case scanPeripheral(UUID)
        case scanPeripheralService(UUID, CBUUID)
        case scanPeripheralServiceCharacteristic(UUID, CBUUID, CBUUID)
        case scanPeripheralServiceCharacteristicDescriptor(UUID, CBUUID, CBUUID, CBUUID)
    }

    let queue = DispatchQueue(label: "CoreBluetoothQ")
    var services: [CBUUID]? = nil
    var requestedServiceIdentifier: CBUUID?
    var characteristicIdentifier: CBUUID?
    var descriptorIdentifier: CBUUID?
    var peripheralIdentifier: UUID?

    var command: Command = .scanAll {
        didSet {
            #if DEBUG
            print("Command \(self.command)")
            #endif
            switch self.command {
                case .scanAll:
                    self.services = nil
                    self.requestedServiceIdentifier = nil
                    self.characteristicIdentifier = nil
                    self.descriptorIdentifier = nil
                    self.peripheralIdentifier = nil
                case let .scanService(uuid):
                    self.services = [uuid]
                    self.requestedServiceIdentifier = uuid
                    self.characteristicIdentifier = nil
                    self.descriptorIdentifier = nil
                    self.peripheralIdentifier = nil
                case let .scanServiceCharacteristic(serviceUUID, characteristicUUID):
                    self.services = [serviceUUID]
                    self.requestedServiceIdentifier = serviceUUID
                    self.characteristicIdentifier = characteristicUUID
                    self.descriptorIdentifier = nil
                    self.peripheralIdentifier = nil
                case let .scanServiceCharacteristicDescriptor(serviceUUID, characteristicUUID, descriptorUUID):
                    self.services = [serviceUUID]
                    self.requestedServiceIdentifier = serviceUUID
                    self.characteristicIdentifier = characteristicUUID
                    self.descriptorIdentifier = descriptorUUID
                    self.peripheralIdentifier = nil
                case let .scanPeripheral(peripheralUUID):
                    self.peripheralIdentifier = peripheralUUID
                    self.services = nil
                    self.requestedServiceIdentifier = nil
                    self.characteristicIdentifier = nil
                    self.descriptorIdentifier = nil
                case let .scanPeripheralService(peripheralUUID, serviceUUID):
                    self.peripheralIdentifier = peripheralUUID
                    self.services = nil
                    self.requestedServiceIdentifier = serviceUUID
                    self.characteristicIdentifier = nil
                    self.descriptorIdentifier = nil
                case let .scanPeripheralServiceCharacteristic(peripheralUUID, serviceUUID, characteristicUUID):
                    self.peripheralIdentifier = peripheralUUID
                    self.services = nil
                    self.requestedServiceIdentifier = serviceUUID
                    self.characteristicIdentifier = characteristicUUID
                    self.descriptorIdentifier = nil
                case let .scanPeripheralServiceCharacteristicDescriptor(peripheralUUID, serviceUUID, characteristicUUID, descriptorUUID):
                    self.peripheralIdentifier = peripheralUUID
                    self.services = nil
                    self.requestedServiceIdentifier = serviceUUID
                    self.characteristicIdentifier = characteristicUUID
                    self.descriptorIdentifier = descriptorUUID
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
                let scanDescription: String
                if let peripheralIdentifier = self.peripheralIdentifier {
                    scanDescription = "device \(peripheralIdentifier.uuidString)"
                } else if let services = self.services, !services.isEmpty {
                    scanDescription = services.map { $0.uuidString }.joined(separator: ", ")
                } else {
                    scanDescription = "all services"
                }
                print("BLE powered on, scanning for \(scanDescription)...")
                if let services = self.services {
                    let peripherals = central.retrieveConnectedPeripherals(withServices: services)
                    peripherals.forEach { self.centralManager(central, didDiscover: $0, advertisementData: [:], rssi: 42.0) }
                }
                central.scanForPeripherals(withServices: self.services, options: nil)
            @unknown default:
                break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        logger.trace("Discovered: \(peripheral)")
        let identifier = peripheral.identifier

        if let expected = self.peripheralIdentifier, expected != identifier {
            return
        }

        guard self.peripherals[identifier] == nil else { return }
        
        print("(P) \(identifier, color: .magenta)\t\(peripheral.CC_name, color: .blue)")
        self.peripherals[identifier] = peripheral

        if self.peripheralIdentifier == nil {
            central.connect(peripheral, options: nil)
        } else {
            print("Connecting to \(identifier)...")
            central.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        let servicesToDiscover = self.requestedServiceIdentifier.map { [$0] }
        peripheral.discoverServices(servicesToDiscover)
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
            print("(S) \(peripheral.identifier, color: .magenta)\t\(peripheral.CC_name, color: .blue)\t\(service.uuid.uuidString, color: .yellow)\t\(primary)")

            let characteristicsToDiscover = self.characteristicIdentifier.map { [$0] }
            peripheral.discoverCharacteristics(characteristicsToDiscover, for: service)
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
            print("(C) \(peripheral.identifier, color: .magenta)\t\(peripheral.CC_name, color: .blue)\t\(service.uuid.uuidString, color: .yellow).\(characteristic.uuid.uuidString, color: .cyan)\t\(p)")
            peripheral.discoverDescriptors(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Can't discover descriptors for \(peripheral).\(characteristic.service!).\(characteristic): \(error)")
            return
        }
        characteristic.descriptors?.forEach { descriptor in
            print("(D) \(peripheral.identifier, color: .magenta)\t\(peripheral.CC_name, color: .blue)\t\(characteristic.service!.uuid.uuidString, color: .yellow).\(characteristic.uuid.uuidString, color: .cyan).\(descriptor.uuid.uuidString, color: .red)")
        }
    }
}

extension CBPeripheral {

    var CC_name: String { self.name ?? "N/A" }
}
