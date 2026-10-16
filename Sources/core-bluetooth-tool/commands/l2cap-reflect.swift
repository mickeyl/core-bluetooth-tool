import ArgumentParser
import AppKit
import CoreBluetooth
import Darwin
import Foundation
import L2CAPBenchKit

/// Reflector for the L2CAP benchmark protocol. The ESP DUT owns all run timing.
struct L2CAPReflect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "l2cap-reflect",
        abstract: "Serve framed L2CAP echo and asymmetric request benchmarks"
    )

    @Option(name: .long, help: "Advertised BLE name.")
    private var name = "L2CAP-Bench-Mac"

    @Flag(name: .long, help: "Require link-layer encryption.")
    private var encrypted = false

    @Option(name: .long, help: "Act as BLE Central and connect to the named ESP benchmark peripheral.")
    private var connect: String?

    func run() throws {
        runApplication()
    }

    private func runApplication() {
        precondition(Thread.isMainThread, "The BLE reflector must run on the main thread")
        setbuf(stdout, nil)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let reflector = L2CAPReflectSession(name: name, encrypted: encrypted, connectTo: connect)
        reflector.start()

        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler {
            reflector.stop()
            Foundation.exit(0)
        }
        signalSource.resume()

        DispatchQueue.main.async {
            if CBManager.authorization == .notDetermined {
                application.activate(ignoringOtherApps: true)
            }
        }

        withExtendedLifetime((reflector, signalSource)) {
            application.run()
        }
    }
}

private final class L2CAPReflectSession: NSObject, CBPeripheralManagerDelegate,
    CBCentralManagerDelegate, CBPeripheralDelegate, StreamDelegate {
    private static let serviceUUID = CBUUID(string: "e7100001-61b3-4b3d-8b4d-7e3b51e2c001")
    private static let psmUUID = CBUUID(string: "e7100002-61b3-4b3d-8b4d-7e3b51e2c001")

    private struct PendingWrite {
        var bytes: Data
        var offset = 0
        var requestReceivedAtNs: UInt64?
    }

    private let advertisedName: String
    private let encrypted: Bool
    private let targetName: String?
    private var manager: CBPeripheralManager?
    private var central: CBCentralManager?
    private var remote: CBPeripheral?
    private var running = true
    private var publishedPSM: CBL2CAPPSM?
    private var channel: CBL2CAPChannel?
    private var input: InputStream?
    private var output: OutputStream?
    private var parser = BenchFrameParser()
    private var config: BenchConfig?
    private var expectedSequence: UInt32 = 0
    private var writes: [PendingWrite] = []
    private var receivedFrames = 0
    private var sentFrames = 0
    private var receivedBytes = 0
    private var sentBytes = 0
    private var errors = 0
    private var streamToken: UInt32?
    private var streamReceiver: BenchStreamReceiver?
    private var streamSendNext: UInt32?
    private var streamAcknowledged = false

    init(name: String, encrypted: Bool, connectTo: String?) {
        advertisedName = name
        self.encrypted = encrypted
        targetName = connectTo
        super.init()
        if connectTo != nil {
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            manager = CBPeripheralManager(delegate: self, queue: nil)
        }
    }

    func start() {
        print("Starting L2CAP benchmark reflector: \(targetName.map { "Central connecting to \($0)" } ?? "Peripheral \(advertisedName)")…")
        if let central = central {
            emitJSON("central-start", ["state": central.state.rawValue, "scanning": central.isScanning,
                                       "authorization": CBManager.authorization.rawValue,
                                       "main_thread": Thread.isMainThread])
            if central.state == .poweredOn { scan() }
        }
    }

    func stop() {
        running = false
        closeChannel()
        manager?.stopAdvertising()
        manager?.removeAllServices()
        if let psm = publishedPSM { manager?.unpublishL2CAPChannel(psm) }
        central?.stopScan()
        if let remote = remote { central?.cancelPeripheralConnection(remote) }
        print("L2CAP reflector stopped")
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            peripheral.publishL2CAPChannel(withEncryption: encrypted)
        case .poweredOff:
            print("Bluetooth is powered off")
        default:
            print("Peripheral manager state: \(peripheral.state.rawValue)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error = error {
            reportError("L2CAP publish failed: \(error)")
            return
        }
        publishedPSM = PSM
        let value = Data([UInt8(truncatingIfNeeded: PSM), UInt8(truncatingIfNeeded: PSM >> 8)])
        let psmCharacteristic = CBMutableCharacteristic(
            type: Self.psmUUID, properties: .read, value: value, permissions: .readable
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [psmCharacteristic]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService, error: Error?) {
        if let error = error {
            reportError("GATT service publish failed: \(error)")
            return
        }
        guard service.uuid == Self.serviceUUID else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: advertisedName,
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]
        ])
        print("Published L2CAP PSM \(publishedPSM ?? 0); advertising \(advertisedName)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == Self.psmUUID, let psm = publishedPSM else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        request.value = Data([UInt8(truncatingIfNeeded: psm), UInt8(truncatingIfNeeded: psm >> 8)])
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            reportError("Advertising failed: \(error)")
        } else {
            print("CoreBluetooth confirmed advertising")
            emitJSON("advertising", ["name": advertisedName, "psm": publishedPSM ?? 0])
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didOpen channel: CBL2CAPChannel?, error: Error?) {
        attach(channel, error: error)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emitJSON("central-state", ["state": central.state.rawValue, "scanning": central.isScanning])
        if central.state == .poweredOn { scan() }
        else { print("Central manager state: \(central.state.rawValue)") }
    }

    private func scan() {
        guard running, central?.state == .poweredOn else { return }
        central?.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        emitJSON("scanning", ["service": Self.serviceUUID.uuidString])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard remote == nil, name == targetName else { return }
        remote = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
        print("Connecting to \(name ?? "ESP") at \(RSSI) dBm")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        reportError("GAP connect failed: \(String(describing: error))")
        remote = nil
        scan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        closeChannel()
        remote = nil
        scan()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            reportError("PSM service discovery failed: \(String(describing: error))")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.psmUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == Self.psmUUID }) else {
            reportError("PSM characteristic discovery failed: \(String(describing: error))")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.psmUUID else { return }
        guard error == nil, let value = characteristic.value, value.count == 2 else {
            reportError("PSM read failed: \(String(describing: error))")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        let bytes = Array(value)
        peripheral.openL2CAPChannel(UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        attach(channel, error: error)
    }

    private func attach(_ channel: CBL2CAPChannel?, error: Error?) {
        if let error = error {
            reportError("L2CAP open failed: \(error)")
            return
        }
        guard let channel = channel else { return }
        closeChannel()
        self.channel = channel
        parser = BenchFrameParser()
        config = nil
        receivedFrames = 0
        sentFrames = 0
        receivedBytes = 0
        sentBytes = 0
        errors = 0
        input = channel.inputStream
        output = channel.outputStream
        input?.delegate = self
        output?.delegate = self
        input?.schedule(in: .main, forMode: .default)
        output?.schedule(in: .main, forMode: .default)
        input?.open()
        output?.open()
        print("L2CAP connection with \(channel.peer.identifier)")
        emitJSON("connected", ["peer": channel.peer.identifier.uuidString,
                               "gap_role": targetName == nil ? "peripheral" : "central"])
    }

    func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        guard stream === input || stream === output else { return }
        switch eventCode {
        case .hasBytesAvailable:
            guard stream === input, let input = input else { return }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let count = input.read(&bytes, maxLength: bytes.count)
                if count < 0 {
                    reportError("L2CAP read failed: \(String(describing: input.streamError))")
                    closeChannel()
                    return
                }
                if count == 0 { break }
                receivedBytes += count
                do {
                    for frame in try parser.append(Data(bytes.prefix(count))) {
                        receivedFrames += 1
                        try handle(frame)
                    }
                } catch {
                    reportError("Invalid L2CAP frame: \(error)")
                    closeChannel()
                    return
                }
            }
        case .hasSpaceAvailable:
            if stream === output { drainWrites() }
        case .endEncountered, .errorOccurred:
            print("L2CAP channel closed: \(String(describing: stream.streamError))")
            closeChannel()
            if let remote = remote { central?.cancelPeripheralConnection(remote) }
        default:
            break
        }
    }

    private func handle(_ frame: BenchFrame) throws {
        let receivedAtNs = DispatchTime.now().uptimeNanoseconds
        switch frame.type {
        case BenchMessage.hello:
            let hello = try BenchHello(payload: frame.payload)
            emitJSON("hello", ["dut": hello.identity])
            let identity = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) \(macModel())"
            try enqueue(BenchFrame(type: BenchMessage.helloReply,
                                   payload: BenchHello(identity: identity).encoded()))
        case BenchMessage.config:
            guard streamToken == nil else { throw BenchProtocolError.invalidStream }
            let newConfig = try BenchConfig(payload: frame.payload)
            config = newConfig
            expectedSequence = 0
            emitJSON("config", ["pattern": newConfig.pattern.rawValue,
                                "request_size": newConfig.requestSize,
                                "response_size": newConfig.responseSize,
                                "count": newConfig.count])
            try enqueue(BenchFrame(type: BenchMessage.configReply, payload: Data([0])))
        case BenchMessage.ping:
            guard let config = config, config.pattern == .echo || config.pattern == .request else {
                throw BenchProtocolError.invalidConfig
            }
            let ping = try BenchPing(payload: frame.payload, expectedSize: config.requestSize)
            guard ping.sequence == expectedSequence, ping.sequence < config.count else {
                throw BenchProtocolError.invalidPing
            }
            expectedSequence += 1
            let reply = try BenchFrame(type: BenchMessage.pingReply,
                                       payload: ping.response(size: config.responseSize,
                                                              turnaroundMicroseconds: 0))
            enqueue(reply, requestReceivedAtNs: receivedAtNs)
        case BenchMessage.streamStart:
            guard let config = config, config.pattern.rawValue >= 3, streamToken == nil else {
                throw BenchProtocolError.invalidStream
            }
            let token = try BenchStream.token(from: frame.payload)
            streamToken = token
            streamReceiver = config.pattern != .streamRX
                ? BenchStreamReceiver(token: token, count: config.count, size: config.requestSize) : nil
            streamAcknowledged = config.pattern == .streamTX
            try enqueue(BenchFrame(type: BenchMessage.streamStartReply, payload: frame.payload))
            if config.pattern != .streamTX { streamSendNext = 0; drainWrites() }
        case BenchMessage.stream:
            guard streamToken != nil, streamReceiver != nil else { throw BenchProtocolError.invalidStream }
            try streamReceiver?.receive(frame.payload, atMicroseconds: receivedAtNs / 1_000)
        case BenchMessage.streamEnd:
            guard streamToken != nil, streamReceiver != nil else { throw BenchProtocolError.invalidStream }
            try streamReceiver?.end(frame.payload)
            try enqueue(BenchFrame(type: BenchMessage.streamEndReply, payload: streamReceiver!.summary.encoded()))
        case BenchMessage.streamEndReply:
            guard let token = streamToken, let config = config, !streamAcknowledged,
                  streamSendNext == nil else { throw BenchProtocolError.invalidStream }
            let summary = try BenchStreamSummary(payload: frame.payload)
            guard summary.matches(token: token, count: config.count, size: config.responseSize) else {
                throw BenchProtocolError.invalidStream
            }
            streamAcknowledged = true
        case BenchMessage.streamFinish:
            guard let token = streamToken, try BenchStream.token(from: frame.payload) == token,
                  streamAcknowledged, streamSendNext == nil,
                  streamReceiver == nil || streamReceiver!.ended else { throw BenchProtocolError.invalidStream }
            emitJSON("stream-complete", ["token": token, "rx_frames": streamReceiver?.summary.frames ?? 0,
                                         "rx_errors": streamReceiver?.summary.errors ?? 0,
                                         "tx_confirmed": streamAcknowledged])
            streamToken = nil; streamReceiver = nil
            try enqueue(BenchFrame(type: BenchMessage.streamFinishReply, payload: frame.payload))
        case BenchMessage.abort:
            reportError("DUT aborted: \(String(data: frame.payload, encoding: .utf8) ?? "unknown")")
            closeChannel()
        default:
            try enqueue(BenchFrame(type: BenchMessage.abort,
                                   payload: Data("unsupported message type \(frame.type)".utf8)))
        }
    }

    private func enqueue(_ frame: BenchFrame, requestReceivedAtNs: UInt64? = nil) {
        writes.append(PendingWrite(bytes: frame.encoded(),
                                   requestReceivedAtNs: requestReceivedAtNs))
        drainWrites()
    }

    private func drainWrites() {
        guard let output = output else { return }
        while output.hasSpaceAvailable {
            if writes.isEmpty, let sequence = streamSendNext, let token = streamToken, let config = config {
                do {
                    let frame: BenchFrame
                    if sequence < config.count {
                        frame = try BenchFrame(type: BenchMessage.stream,
                            payload: BenchStream.payload(sequence: sequence, token: token, size: config.responseSize))
                        streamSendNext = sequence + 1
                    } else {
                        frame = try BenchFrame(type: BenchMessage.streamEnd,
                            payload: BenchStream.endPayload(token: token, count: config.count))
                        streamSendNext = nil
                    }
                    writes.append(PendingWrite(bytes: frame.encoded()))
                } catch {
                    reportError("Stream generation failed: \(error)"); closeChannel(); return
                }
            }
            guard !writes.isEmpty else { break }
            var pending = writes.removeFirst()
            if pending.offset == 0, let receivedAtNs = pending.requestReceivedAtNs {
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - receivedAtNs
                let microseconds = UInt32(min(elapsedNs / 1_000, UInt64(UInt32.max)))
                // Frame header (4) + sequence (4) + token (4) precede turnaround.
                pending.bytes[12] = UInt8(truncatingIfNeeded: microseconds >> 24)
                pending.bytes[13] = UInt8(truncatingIfNeeded: microseconds >> 16)
                pending.bytes[14] = UInt8(truncatingIfNeeded: microseconds >> 8)
                pending.bytes[15] = UInt8(truncatingIfNeeded: microseconds)
            }
            let remaining = pending.bytes.count - pending.offset
            let written = pending.bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return output.write(base.advanced(by: pending.offset), maxLength: remaining)
            }
            if written < 0 {
                reportError("L2CAP write failed: \(String(describing: output.streamError))")
                closeChannel()
                return
            }
            pending.offset += written
            sentBytes += written
            if pending.offset < pending.bytes.count {
                writes.insert(pending, at: 0)
                return
            }
            sentFrames += 1
        }
    }

    private func closeChannel() {
        guard channel != nil else { return }
        emitJSON("disconnected", ["rx_frames": receivedFrames, "tx_frames": sentFrames,
                                  "rx_bytes": receivedBytes, "tx_bytes": sentBytes,
                                  "errors": errors])
        input?.delegate = nil
        output?.delegate = nil
        input?.close()
        output?.close()
        input?.remove(from: .main, forMode: .default)
        output?.remove(from: .main, forMode: .default)
        input = nil
        output = nil
        channel = nil
        writes.removeAll()
        config = nil
        streamToken = nil; streamReceiver = nil; streamSendNext = nil; streamAcknowledged = false
        parser = BenchFrameParser()
    }

    private func reportError(_ message: String) {
        errors += 1
        print(message)
        emitJSON("error", ["message": message])
    }

    private func emitJSON(_ event: String, _ fields: [String: Any]) {
        var object = fields
        object["event"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print("BENCH_PEER \(line)")
    }

    private func macModel() -> String {
        var length: size_t = 0
        guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: length)
        let result = bytes.withUnsafeMutableBufferPointer {
            sysctlbyname("hw.model", $0.baseAddress, &length, nil, 0)
        }
        return result == 0 ? String(cString: bytes) : "unknown"
    }
}
