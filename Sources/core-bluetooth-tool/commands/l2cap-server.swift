//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import CoreBluetooth
import Foundation
import CornucopiaCore
import Darwin

fileprivate let l2capServerLog = Cornucopia.Core.Logger(subsystem: "core-bluetooth-tool", category: "l2cap-server")

/// Publishes an L2CAP channel and consumes incoming data blocks while reporting throughput.
struct L2CAPServer: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "l2cap-server",
        abstract: "Publish an L2CAP channel and measure incoming throughput"
    )

    @Argument(help: "Desired PSM. Set to 0 to let CoreBluetooth assign one and print it.")
    private var psm: UInt16

    @Option(name: .shortAndLong, help: "Advertised local name so the client can discover this peripheral.")
    private var name: String?

    @Option(name: .shortAndLong, help: "Require link-layer encryption when publishing the channel.")
    private var encrypted: Bool = false

    func run() throws {
        let expectedPSM: CBL2CAPPSM? = psm == 0 ? nil : psm
        let advertisedName = name ?? Host.current().localizedName ?? "core-bluetooth-tool"

        let server = L2CAPServerSession(
            expectedPSM: expectedPSM,
            advertisedName: advertisedName,
            encrypted: encrypted
        )
        server.start()

        signal(SIGINT, SIG_IGN)
        let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSrc.setEventHandler {
            server.stop()
            Foundation.exit(0)
        }
        sigintSrc.resume()

        let loop = RunLoop.current
        while loop.run(mode: .default, before: Date.distantFuture) {
            loop.run()
        }
    }
}

private final class L2CAPServerSession: NSObject, CBPeripheralManagerDelegate, StreamDelegate {

    private let expectedPSM: CBL2CAPPSM?
    private let advertisedName: String
    private let encryptionRequired: Bool
    private var manager: CBPeripheralManager!
    private var publishedPSM: CBL2CAPPSM?
    private var channel: CBL2CAPChannel?
    private var inputStream: InputStream?
    private var receiveBuffer = Data()

    private var expectedSequence: UInt8?
    private var totalBlocks: Int = 0
    private var totalBytes: Int = 0
    private var droppedBlocks: Int = 0
    private var firstByteTimestamp: Date?
    private var reportTimer: Timer?

    init(expectedPSM: CBL2CAPPSM?, advertisedName: String, encrypted: Bool) {
        self.expectedPSM = expectedPSM
        self.advertisedName = advertisedName
        self.encryptionRequired = encrypted
        super.init()
        self.manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func start() {
        l2capServerLog.info("Starting L2CAP server waiting for incoming L2CAP channels")
    }

    func stop() {
        self.reportTimer?.invalidate()
        if let psm = self.publishedPSM {
            self.manager.unpublishL2CAPChannel(psm)
        }
        self.manager.stopAdvertising()
        self.inputStream?.close()
        self.reportThroughput()
        print("")
        l2capServerLog.info("L2CAP server stopped")
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
            case .poweredOn:
                l2capServerLog.info("Peripheral manager powered on, publishing channel…")
                peripheral.publishL2CAPChannel(withEncryption: encryptionRequired)
                peripheral.startAdvertising([CBAdvertisementDataLocalNameKey: advertisedName])
            case .poweredOff:
                print("Bluetooth is powered off.")
            case .resetting, .unauthorized, .unsupported, .unknown:
                print("Peripheral manager state: \(peripheral.state.rawValue)")
            @unknown default:
                print("Unexpected peripheral manager state.")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error = error {
            print("Error publishing L2CAP channel: \(error.localizedDescription)")
            Foundation.exit(-1)
        }
        self.publishedPSM = PSM
        if let expected = expectedPSM, expected != PSM {
            print("Warning: System assigned PSM \(PSM) which differs from requested \(expected). Client must use \(PSM).")
        } else {
            print("Published L2CAP channel on PSM \(PSM). Waiting for connections…")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error = error {
            print("Failed to open L2CAP channel: \(error.localizedDescription)")
            return
        }
        guard let channel = channel else {
            print("Error: L2CAP channel is nil.")
            return
        }
        self.resetStatistics()
        self.channel = channel
        self.inputStream = channel.inputStream
        self.inputStream?.delegate = self
        self.inputStream?.schedule(in: .current, forMode: .default)
        self.inputStream?.open()
        print("Accepted L2CAP connection from \(channel.peer.identifier).")
        self.reportTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reportThroughput()
        }
    }

    // MARK: StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
            case .hasBytesAvailable:
                guard let input = self.inputStream else { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while input.hasBytesAvailable {
                    let readBytes = input.read(&buffer, maxLength: buffer.count)
                    if readBytes > 0 {
                        self.receiveBuffer.append(contentsOf: buffer[0..<readBytes])
                        self.processBuffer()
                    } else if readBytes < 0 {
                        print("Stream read error: \(String(describing: input.streamError))")
                        return
                    } else {
                        break
                    }
                }
            case .endEncountered:
                print("L2CAP channel closed by peer, waiting for reconnection…")
                self.handleChannelClosed()
            case .errorOccurred:
                print("Stream error: \(String(describing: aStream.streamError)). Waiting for reconnection…")
                self.handleChannelClosed()
            default:
                break
        }
    }

    // MARK: Processing

    private func processBuffer() {
        let headerSize = 3 // 1 byte seq + 2 bytes length (big endian)
        while true {
            let available = self.receiveBuffer.count
            guard available >= headerSize else { return }

            // Extract header safely without assuming a zero start index
            let start = self.receiveBuffer.startIndex
            let seq = self.receiveBuffer[start]
            let lengthHigh = UInt16(self.receiveBuffer[self.receiveBuffer.index(start, offsetBy: 1)])
            let lengthLow = UInt16(self.receiveBuffer[self.receiveBuffer.index(start, offsetBy: 2)])
            let payloadLength = Int((lengthHigh << 8) | lengthLow)
            let totalBlockSize = headerSize + payloadLength
            guard payloadLength >= 0 else {
                print("Invalid payload length \(payloadLength). Dropping buffer.")
                self.receiveBuffer.removeAll()
                return
            }
            guard available >= totalBlockSize else { return } // wait for full block

            let payloadStart = headerSize
            let payloadRangeStart = self.receiveBuffer.index(start, offsetBy: payloadStart)
            let payloadRangeEnd = self.receiveBuffer.index(payloadRangeStart, offsetBy: payloadLength)
            let payload = self.receiveBuffer[payloadRangeStart..<payloadRangeEnd]
            self.receiveBuffer.removeFirst(totalBlockSize)
            self.handleBlock(sequence: seq, payload: Data(payload), fullSize: totalBlockSize)
        }
    }

    private func handleBlock(sequence seq: UInt8, payload: Data, fullSize: Int) {
        if self.firstByteTimestamp == nil {
            self.firstByteTimestamp = Date()
        }
        self.totalBlocks += 1
        self.totalBytes += fullSize

        if let expected = self.expectedSequence, seq != expected {
            let delta = (Int(seq) - Int(expected) + 256) % 256
            if delta != 0 {
                self.droppedBlocks += delta
                print("\nDrop detected: expected \(expected), received \(seq) (\(delta) blocks lost)")
            }
        }
        self.expectedSequence = seq &+ 1
    }

    private func reportThroughput() {
        guard let start = self.firstByteTimestamp else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return }
        let bytesPerSecond = Double(self.totalBytes) / elapsed
        let mbyte = bytesPerSecond / 1_000_000.0
        let rateString: String
        if mbyte >= 1.0 {
            rateString = String(format: "%.2f MByte/s", mbyte)
        } else {
            let kbyte = bytesPerSecond / 1_000.0
            rateString = String(format: "%.2f KByte/s", kbyte)
        }
        let elapsedString = String(format: "%.1f", elapsed)
        self.emitStatus(line: "Received \(self.totalBlocks) blocks / \(self.totalBytes) bytes in \(elapsedString)s -> \(rateString). Dropped: \(self.droppedBlocks)", newline: false)
    }

    private func emitStatus(line: String, newline: Bool) {
        let terminator = newline ? "\n" : "\r"
        print(line, terminator: terminator)
        fflush(stdout)
    }

    private func handleChannelClosed() {
        self.reportThroughput()
        self.reportTimer?.invalidate()
        self.reportTimer = nil
        self.inputStream?.close()
        self.channel = nil
        self.resetStatistics()
        if self.manager.state == .poweredOn && !self.manager.isAdvertising {
            self.manager.startAdvertising([CBAdvertisementDataLocalNameKey: advertisedName])
        }
        self.emitStatus(line: "Waiting for reconnection…", newline: true)
    }

    private func resetStatistics() {
        self.receiveBuffer.removeAll(keepingCapacity: true)
        self.expectedSequence = nil
        self.totalBlocks = 0
        self.totalBytes = 0
        self.droppedBlocks = 0
        self.firstByteTimestamp = nil
    }
}
