//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import CoreBluetooth
import Foundation
import CornucopiaCore
import Darwin

fileprivate let l2capClientLog = Cornucopia.Core.Logger(subsystem: "core-bluetooth-tool", category: "l2cap-client")

/// Connects to a peripheral by name and pushes sequenced random blocks over an L2CAP channel.
struct L2CAPClient: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "l2cap-client",
        abstract: "Open an L2CAP channel to a peripheral and send numbered blocks"
    )

    @Argument(help: "PSM provided by the server.")
    private var psm: UInt16

    @Argument(help: "Peripheral name to connect to (local name from advertisement).")
    private var deviceName: String

    @Option(name: .shortAndLong, help: "Random payload bytes per block (sequence number is added automatically).")
    private var payloadLength: Int = 244

    @Option(name: .shortAndLong, help: "Number of blocks to send before exiting (0 = run until interrupted).")
    private var blocks: Int = 0

    func run() throws {
        let client = L2CAPClientSession(
            psm: psm,
            targetName: deviceName,
            payloadLength: payloadLength,
            targetBlocks: blocks == 0 ? nil : blocks
        )
        client.start()

        signal(SIGINT, SIG_IGN)
        let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSrc.setEventHandler {
            client.stop()
            Foundation.exit(0)
        }
        sigintSrc.resume()

        let loop = RunLoop.current
        while loop.run(mode: .default, before: Date.distantFuture) {
            loop.run()
        }
    }
}

private final class L2CAPClientSession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, StreamDelegate {

    private let psm: CBL2CAPPSM
    private let targetName: String
    private let payloadLength: Int
    private let targetBlocks: Int?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private var outputStream: OutputStream?
    private var inputStream: InputStream?

    private var pendingWrite = Data()
    private var sequence: UInt8 = 0
    private var sentBlocks: Int = 0
    private var isSending = false
    private var isScanning = false
    private var totalBytesSent: Int = 0
    private var firstByteTimestamp: Date?
    private var reportTimer: Timer?

    init(psm: CBL2CAPPSM, targetName: String, payloadLength: Int, targetBlocks: Int?) {
        self.psm = psm
        self.targetName = targetName
        self.payloadLength = payloadLength
        self.targetBlocks = targetBlocks
        super.init()
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    func start() {
        l2capClientLog.info("Starting L2CAP client for device '\(self.targetName)' on PSM \(self.psm)")
        self.startScanningIfPossible()
    }

    func stop() {
        self.central.stopScan()
        self.isScanning = false
        if let peripheral = self.peripheral {
            self.central.cancelPeripheralConnection(peripheral)
        }
        self.outputStream?.close()
        self.inputStream?.close()
        self.reportTimer?.invalidate()
        self.reportTimer = nil
        self.reportThroughput(newline: true)
        l2capClientLog.info("L2CAP client stopped")
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
            case .poweredOn:
                self.startScanningIfPossible()
            case .poweredOff:
                print("Bluetooth is powered off.")
            case .resetting, .unauthorized, .unsupported, .unknown:
                print("Central state: \(central.state.rawValue)")
            @unknown default:
                print("Unexpected central state.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let matches = (peripheral.name?.caseInsensitiveCompare(self.targetName) == .orderedSame) ||
                      (advName?.caseInsensitiveCompare(self.targetName) == .orderedSame)
        guard matches else { return }

        l2capClientLog.info("Found matching peripheral \(peripheral.identifier.uuidString), connecting…")
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        central.stopScan()
        self.isScanning = false
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        l2capClientLog.info("Connected, opening L2CAP channel on PSM \(self.psm)")
        peripheral.openL2CAPChannel(self.psm)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        self.peripheral = nil
        self.restartScanning()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Disconnected from peripheral \(peripheral.identifier). Waiting for it to reappear…")
        self.handleChannelLoss()
        self.peripheral = nil
        self.restartScanning()
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error = error {
            print("Failed to open L2CAP channel: \(error.localizedDescription)")
            return
        }
        guard let channel = channel else {
            print("Error: channel is nil.")
            return
        }
        self.channel = channel
        self.outputStream = channel.outputStream
        self.inputStream = channel.inputStream

        self.outputStream?.delegate = self
        self.outputStream?.schedule(in: .current, forMode: .default)
        self.outputStream?.open()

        self.inputStream?.delegate = self
        self.inputStream?.schedule(in: .current, forMode: .default)
        self.inputStream?.open()

        print("Opened L2CAP channel to \(peripheral.identifier). Sending blocks…")
        self.reportTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reportThroughput()
        }
        self.pumpWrites()
    }

    // MARK: StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch (aStream, eventCode) {
            case (_, .errorOccurred):
                print("Stream error: \(String(describing: aStream.streamError)). Restarting scan…")
                self.handleChannelLoss()
            case (_, .endEncountered):
                print("Channel closed by peer. Restarting scan…")
                self.handleChannelLoss()
            case (_, .hasSpaceAvailable):
                self.pumpWrites()
            default:
                break
        }
    }

    // MARK: Sending

    private func pumpWrites() {
        guard let out = self.outputStream else { return }
        guard !isSending else { return }
        self.isSending = true
        defer { self.isSending = false }

        while out.hasSpaceAvailable {
            if self.pendingWrite.isEmpty {
                guard self.shouldContinueSending() else {
                    print("Completed sending \(self.sentBlocks) blocks.")
                    self.reportThroughput(newline: true)
                    self.stop()
                    return
                }
                self.pendingWrite = self.nextBlock()
            }

            let written = self.pendingWrite.withUnsafeBytes {
                out.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: self.pendingWrite.count)
            }

            if written <= 0 {
                return
            }

            if written < self.pendingWrite.count {
                self.pendingWrite.removeFirst(written)
                if self.firstByteTimestamp == nil { self.firstByteTimestamp = Date() }
                self.totalBytesSent += written
                return
            } else {
                self.pendingWrite.removeAll(keepingCapacity: true)
                self.sentBlocks += 1
                if self.firstByteTimestamp == nil { self.firstByteTimestamp = Date() }
                self.totalBytesSent += written
            }
        }
    }

    private func shouldContinueSending() -> Bool {
        if let limit = targetBlocks {
            return sentBlocks < limit
        }
        return true
    }

    private func nextBlock() -> Data {
        var block = Data(capacity: payloadLength + 3)
        block.append(sequence)
        sequence &+= 1

        let lengthValue = UInt16(payloadLength)
        block.append(UInt8((lengthValue & 0xFF00) >> 8))
        block.append(UInt8(lengthValue & 0x00FF))

        var payload = [UInt8](repeating: 0, count: payloadLength)
        for i in 0..<payloadLength {
            payload[i] = UInt8.random(in: 0...255)
        }
        block.append(contentsOf: payload)
        return block
    }

    private func reportThroughput(newline: Bool = false) {
        guard let start = self.firstByteTimestamp else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return }
        let bytesPerSecond = Double(self.totalBytesSent) / elapsed
        let mbyte = bytesPerSecond / 1_000_000.0
        let rateString: String
        if mbyte >= 1.0 {
            rateString = String(format: "%.2f MByte/s", mbyte)
        } else {
            let kbyte = bytesPerSecond / 1_000.0
            rateString = String(format: "%.2f KByte/s", kbyte)
        }
        let elapsedString = String(format: "%.1f", elapsed)
        self.emitStatus(line: "Sent \(self.sentBlocks) blocks / \(self.totalBytesSent) bytes in \(elapsedString)s -> \(rateString)", newline: newline)
    }

    private func emitStatus(line: String, newline: Bool) {
        let terminator = newline ? "\n" : "\r"
        print(line, terminator: terminator)
        fflush(stdout)
    }

    // MARK: Helpers

    private func startScanningIfPossible() {
        guard self.central.state == .poweredOn else { return }
        guard !self.isScanning else { return }
        l2capClientLog.info("Central powered on, scanning for '\(self.targetName)'…")
        self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        self.isScanning = true
    }

    private func restartScanning() {
        self.startScanningIfPossible()
    }

    private func handleChannelLoss() {
        self.reportThroughput(newline: true)
        self.teardownChannel()
        if let peripheral = self.peripheral {
            self.central.cancelPeripheralConnection(peripheral)
        }
        self.peripheral = nil
        self.restartScanning()
    }

    private func teardownChannel() {
        self.outputStream?.close()
        self.inputStream?.close()
        self.outputStream = nil
        self.inputStream = nil
        self.channel = nil
        self.pendingWrite.removeAll(keepingCapacity: true)
        self.isSending = false
        self.reportTimer?.invalidate()
        self.reportTimer = nil
        self.firstByteTimestamp = nil
        self.totalBytesSent = 0
        self.sentBlocks = 0
    }
}
