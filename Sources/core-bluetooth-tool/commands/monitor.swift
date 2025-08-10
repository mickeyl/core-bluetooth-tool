//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import Foundation
import Chalk
import CoreBluetooth

var deviceMonitor = DeviceMonitor()

struct Monitor: ParsableCommand {
    
    public static let configuration = CommandConfiguration(abstract: "Monitor BLE devices in a live table view")
    
    @Argument(help: "Specify a service UUID to filter devices")
    private var serviceUUID: String?
    
    @Option(name: .shortAndLong, help: "Maximum number of devices to display (default: 30)")
    private var maxDevices: Int = 30
    
    func run() throws {
        if let uuid = serviceUUID {
            guard CBUUID.CC_isValid(string: uuid) else {
                print("Argument error: '\(uuid)' is not a valid Bluetooth UUID. Valid are 16-bit, 32-bit, and 128-bit values.")
                Foundation.exit(-1)
            }
            deviceMonitor.serviceFilter = CBUUID(string: uuid)
        }
        
        deviceMonitor.maxDevices = maxDevices
        deviceMonitor.startMonitoring()
        
        signal(SIGINT, SIG_IGN)
        let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSrc.setEventHandler {
            deviceMonitor.cleanup()
            Foundation.exit(0)
        }
        sigintSrc.resume()
        
        let loop = RunLoop.current
        while loop.run(mode: .default, before: Date.distantFuture) {
            loop.run()
        }
    }
}

class DeviceEntry {
    let identifier: UUID
    var name: String
    var rssi: NSNumber
    var lastSeen: Date
    var beaconCount: Int
    var pulsePhase: Int
    
    init(identifier: UUID, name: String, rssi: NSNumber) {
        self.identifier = identifier
        self.name = name
        self.rssi = rssi
        self.lastSeen = Date()
        self.beaconCount = 1
        self.pulsePhase = 0
    }
    
    func updateBeacon(rssi: NSNumber) {
        self.rssi = rssi
        self.lastSeen = Date()
        self.beaconCount += 1
        self.pulsePhase = (self.pulsePhase + 1) % 4
    }
    
    var signalStrengthIcon: String {
        let rssiValue = rssi.intValue
        switch rssiValue {
        case -40...0:
            return "📶"
        case -60...(-41):
            return "📶"
        case -80...(-61):
            return "📱"
        default:
            return "📵"
        }
    }
    
    var pulseIcon: String {
        let pulseChars = ["⚫", "🔴", "🟠", "🟡"]
        return pulseChars[pulsePhase]
    }
    
    var ageString: String {
        let age = Date().timeIntervalSince(lastSeen)
        if age < 1 {
            return "now"
        } else if age < 60 {
            return "\(Int(age))s"
        } else {
            return "\(Int(age/60))m"
        }
    }
}

class DeviceMonitor: NSObject {
    
    private var manager: CBCentralManager!
    private var devices: [UUID: DeviceEntry] = [:]
    private var displayTimer: Timer?
    private var isFirstDisplay = true
    var serviceFilter: CBUUID?
    var maxDevices: Int = 30
    
    func startMonitoring() {
        self.manager = CBCentralManager()
        self.manager.delegate = self
        
        print("\u{001B}[?25l")
        print("\u{001B}[2J")
        print("\u{001B}[H")
        
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            self.updateDisplay()
        }
    }
    
    func cleanup() {
        print("\u{001B}[?25h")
        displayTimer?.invalidate()
    }
    
    private func updateDisplay() {
        let sortedDevices = devices.values.sorted { $0.rssi.intValue > $1.rssi.intValue }
        
        if !isFirstDisplay {
            print("\u{001B}[H")
        }
        isFirstDisplay = false
        
        print("\u{001B}[2K", terminator: "")
        if let filter = serviceFilter {
            print("📡 BLE Device Monitor (Service: \(filter, color: .yellow)) - \(Date(), color: .white)")
        } else {
            print("📡 BLE Device Monitor - \(Date(), color: .white)")
        }
        
        print("\u{001B}[2K", terminator: "")
        print("══════════════════════════════════════════════════════════════════════════════════════════════════")
        
        print("\u{001B}[2K", terminator: "")
        print("Signal │ Pulse │ Device ID                              │ Name             │ RSSI │ Beacons │ Last")
        
        print("\u{001B}[2K", terminator: "")
        print("───────┼───────┼────────────────────────────────────────┼──────────────────┼──────┼─────────┼─────")
        
        for device in sortedDevices.prefix(maxDevices) {
            print("\u{001B}[2K", terminator: "")
            let deviceIdFull = device.identifier.uuidString.padding(toLength: 36, withPad: " ", startingAt: 0)
            let deviceName = String(device.name.prefix(16)).padding(toLength: 16, withPad: " ", startingAt: 0)
            let rssiStr = String(device.rssi.intValue).padding(toLength: 4, withPad: " ", startingAt: 0)
            let beaconStr = String(device.beaconCount).padding(toLength: 7, withPad: " ", startingAt: 0)
            let ageStr = device.ageString.padding(toLength: 4, withPad: " ", startingAt: 0)
            
            print("  \(device.signalStrengthIcon)   │   \(device.pulseIcon)  │ \(deviceIdFull, color: .magenta)   │ \(deviceName, color: .blue) │ \(rssiStr, color: getRSSIColor(device.rssi.intValue)) │ \(beaconStr) │ \(ageStr)")
        }
        print("\u{001B}[2K", terminator: "")
        print("───────┴───────┴────────────────────────────────────────┴──────────────────┴──────┴─────────┴─────")
        
        print("\u{001B}[2K", terminator: "")
        let notShownCount = max(0, devices.count - maxDevices)
        if notShownCount > 0 {
            print("Devices \(devices.count, color: .green) (\(notShownCount) not shown) │ Press Ctrl+C to exit")
        } else {
            print("Devices: \(devices.count, color: .green) │ Press Ctrl+C to exit")
        }
        
        print("\u{001B}[K", terminator: "")
    }
    
    private func getRSSIColor(_ rssi: Int) -> Chalk.Color {
        switch rssi {
        case -40...0:
            return .green
        case -60...(-41):
            return .yellow
        case -80...(-61):
            return .red
        default:
            return .white
        }
    }
}

extension DeviceMonitor: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .unknown, .resetting:
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
            let services = serviceFilter != nil ? [serviceFilter!] : nil
            central.scanForPeripherals(withServices: services, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true
            ])
        @unknown default:
            break
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let identifier = peripheral.identifier
        let name = peripheral.name ?? "Unknown"
        
        if let existingDevice = devices[identifier] {
            existingDevice.updateBeacon(rssi: RSSI)
            if existingDevice.name == "Unknown" && name != "Unknown" {
                existingDevice.name = name
            }
        } else {
            devices[identifier] = DeviceEntry(identifier: identifier, name: name, rssi: RSSI)
        }
    }
}
