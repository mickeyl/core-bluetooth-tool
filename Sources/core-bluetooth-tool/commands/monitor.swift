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
    var beaconTimestamps: [Date] = []
    var pulsePhase: Int
    var isConnectable: Bool
    var primaryService: String?
    
    init(identifier: UUID, name: String, rssi: NSNumber, isConnectable: Bool, primaryService: String? = nil) {
        self.identifier = identifier
        self.name = name
        self.rssi = rssi
        self.lastSeen = Date()
        self.beaconTimestamps = [Date()]
        self.pulsePhase = 0
        self.isConnectable = isConnectable
        self.primaryService = primaryService
    }
    
    func updateBeacon(rssi: NSNumber, isConnectable: Bool, primaryService: String? = nil) {
        self.rssi = rssi
        let now = Date()
        self.lastSeen = now
        self.beaconTimestamps.append(now)
        
        // Keep only last 20 timestamps to avoid memory growth
        if self.beaconTimestamps.count > 20 {
            self.beaconTimestamps.removeFirst()
        }
        
        self.pulsePhase = (self.pulsePhase + 1) % 4
        self.isConnectable = isConnectable
        if let service = primaryService {
            self.primaryService = service
        }
    }
    
    var signalStrengthIcon: String {
        let rssiValue = rssi.intValue
        switch rssiValue {
        case -50...0:
            return "🟢"
        case -70...(-51):
            return "🟡"
        case -85...(-71):
            return "🟠"
        default:
            return "🔴"
        }
    }
    
    var primaryServiceDisplay: String {
        guard let service = primaryService else { return "---" }
        // Display short form of UUID (4 or 8 chars)
        if service.count == 4 {
            return service.uppercased()
        } else if service.count >= 8 {
            return String(service.prefix(8)).uppercased()
        } else {
            return service.uppercased()
        }
    }
    
    var connectableIcon: String {
        return isConnectable ? "🔗" : "🚫"
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
    
    var beaconInterval: String {
        let now = Date()
        let timeSinceLastBeacon = now.timeIntervalSince(lastSeen)
        
        guard beaconTimestamps.count >= 2 else {
            return "---"
        }
        
        // Calculate intervals between consecutive beacons
        var intervals: [TimeInterval] = []
        for i in 1..<beaconTimestamps.count {
            let interval = beaconTimestamps[i].timeIntervalSince(beaconTimestamps[i-1])
            intervals.append(interval)
        }
        
        guard !intervals.isEmpty else {
            return "---"
        }
        
        let sortedIntervals = intervals.sorted()
        let minInterval = sortedIntervals.first!
        let maxInterval = max(sortedIntervals.last!, timeSinceLastBeacon)
        
        // Calculate median (nominal) interval
        let median: TimeInterval
        let count = sortedIntervals.count
        if count % 2 == 0 {
            median = (sortedIntervals[count/2 - 1] + sortedIntervals[count/2]) / 2.0
        } else {
            median = sortedIntervals[count/2]
        }
        
        let nominalInterval = max(median, timeSinceLastBeacon)
        
        return "\(formatInterval(minInterval))<\(formatInterval(nominalInterval))<\(formatInterval(maxInterval))"
    }
    
    private func formatInterval(_ interval: TimeInterval) -> String {
        if interval >= 10.0 {
            return "\(Int(interval))s"
        } else if interval >= 1.0 {
            return String(format: "%.1fs", interval)
        } else {
            let ms = interval * 1000
            if ms < 1.0 {
                return "<1ms"
            } else if ms < 10.0 {
                return String(format: "%.0fms", ms)
            } else {
                return "\(Int(ms))ms"
            }
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
        let sortedDevices = devices.values.sorted { device1, device2 in
            if device1.isConnectable != device2.isConnectable {
                return device1.isConnectable && !device2.isConnectable
            }
            return device1.rssi.intValue > device2.rssi.intValue
        }
        
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
        print("══════════════════════════════════════════════════════════════════════════════════════════════")
        
        print("\u{001B}[2K", terminator: "")
        print("Signal │ Service │ Conn │ Device ID │ Name                     │ RSSI │ Interval Range  │ Last")
        
        print("\u{001B}[2K", terminator: "")
        print("───────┼─────────┼──────┼───────────┼──────────────────────────┼──────┼─────────────────┼─────")
        
        for device in sortedDevices.prefix(maxDevices) {
            print("\u{001B}[2K", terminator: "")
            let deviceIdShort = String(device.identifier.uuidString.prefix(8)).padding(toLength: 8, withPad: " ", startingAt: 0)
            let deviceName = String(device.name.prefix(24)).padding(toLength: 24, withPad: " ", startingAt: 0)
            let rssiStr = String(device.rssi.intValue).padding(toLength: 4, withPad: " ", startingAt: 0)
            let intervalStr = device.beaconInterval.padding(toLength: 15, withPad: " ", startingAt: 0)
            let ageStr = device.ageString.padding(toLength: 4, withPad: " ", startingAt: 0)
            
            print("  \(device.signalStrengthIcon)   │ \(device.primaryServiceDisplay.padding(toLength: 7, withPad: " ", startingAt: 0), color: .yellow) │  \(device.connectableIcon)  │ \(deviceIdShort, color: .magenta)  │ \(deviceName, color: .blue) │ \(rssiStr, color: getRSSIColor(device.rssi.intValue)) │ \(intervalStr) │ \(ageStr)")
        }
        print("\u{001B}[2K", terminator: "")
        print("───────┴─────────┴──────┴───────────┴──────────────────────────┴──────┴─────────────────┴─────")
        
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
        case -50...0:
            return .green
        case -70...(-51):
            return .yellow
        case -85...(-71):
            return .red
        default:
            return .magenta  // More readable than white for very weak signals
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
        let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool ?? false
        
        // Extract primary service from advertising data
        let primaryService = extractPrimaryService(from: advertisementData)
        
        if let existingDevice = devices[identifier] {
            existingDevice.updateBeacon(rssi: RSSI, isConnectable: isConnectable, primaryService: primaryService)
            if existingDevice.name == "Unknown" && name != "Unknown" {
                existingDevice.name = name
            }
        } else {
            devices[identifier] = DeviceEntry(identifier: identifier, name: name, rssi: RSSI, isConnectable: isConnectable, primaryService: primaryService)
        }
    }
    
    private func extractPrimaryService(from advertisementData: [String: Any]) -> String? {
        // Try to get service UUIDs from advertisement data
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], 
           let firstService = serviceUUIDs.first {
            return firstService.uuidString
        }
        
        // Check for overflow service UUIDs (truncated list)
        if let overflowUUIDs = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID],
           let firstService = overflowUUIDs.first {
            return firstService.uuidString
        }
        
        return nil
    }
}
