//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import Foundation
import CoreBluetooth

var scanner = Scanner()

struct Scan: ParsableCommand {
    
    public static let configuration = CommandConfiguration(abstract: "Scan BLE devices")
    
    @Argument(help: "Specify an entity to scan for, either service, device, device.service, device.service.characteristic, or device.service.characteristic.descriptor")
    private var entity: String?
    
    func loop() {
        let loop = RunLoop.current
        while loop.run(mode: .default, before: Date.distantFuture) {
            loop.run()
        }
    }

    func run() throws {
        
        guard let entity = self.entity, !entity.isEmpty else {
            // scan for everything
            scanner.scan()
            self.loop()
            return
        }
        
        let components = entity.components(separatedBy: ".")
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
        case scanPeripheral(UUID)
        case scanPeripheralService(CBUUID, CBUUID)
        case scanPeripheralServiceCharacteristic(CBUUID, CBUUID, CBUUID)
        case scanPeripheralServiceCharacteristicDescriptor(CBUUID, CBUUID, CBUUID, CBUUID)
    }
    
    let queue = DispatchQueue(label: "CoreBluetoothQ")
    var services: [CBUUID] = []
    var peripheralIdentifier: UUID?

    var command: Command = .scanAll {
        didSet {
            print("Command \(self.command)")
            switch self.command {
                case let .scanService(uuid):
                    self.services = [uuid]
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
                print("Error: Bluetooth not supported on this device.")
                Foundation.exit(-1)
            case .unauthorized:
                print("Error: Bluetooth usage not authorized.")
                Foundation.exit(-1)
            case .poweredOff:
                print("Error: Bluetooth not powered on. Please power on Bluetooth and try again.")
                Foundation.exit(-1)
            case .poweredOn:
                print("BLE powered on, scanning...")
                central.scanForPeripherals(withServices: self.services, options: nil)
                let peripherals = central.retrieveConnectedPeripherals(withServices: [])
                peripherals.forEach { self.centralManager(central, didDiscover: $0, advertisementData: [:], rssi: 42.0) }
            @unknown default:
                break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {

        let identifier = peripheral.identifier
        guard self.peripherals[identifier] == nil else { return }
        
        let name = peripheral.name ?? "(Unknown)"
        if self.command == .scanAll {
            print("\(identifier)\t\(name)")
        }
        self.peripherals[identifier] = peripheral

        if identifier == self.peripheralIdentifier {
            print("Connecting to \(identifier)...")
            central.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {

        print("\(peripheral.identifier) connected, scanning for services...")
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
        print("Did discover services: \(peripheral.services)")
    }
    
}
