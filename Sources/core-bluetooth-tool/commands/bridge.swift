//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import CoreBluetooth
import CornucopiaStreams
import Foundation
import os.log

fileprivate var log = OSLog(subsystem: "core-bluetooth-tool", category: "bridge")

var streamBridge: StreamBridge!

@available(macOS 10.15, *)
struct Bridge: AsyncParsableCommand {

    public static let configuration = CommandConfiguration(abstract: "Create a bridge between a Bluetooth LE device and a PTY")

    @Argument(help: "Service UUID")
    private var uuid: String

    @Argument(help: "Device UUID")
    private var device: String = ""

    @Option(name: .shortAndLong, help: "The filename to write the PTY path to.")
    var fileName: String?

    func run() async throws {

        guard CBUUID.CC_isValid(string: self.uuid) else {
            print("Argument error: '\(self.uuid)' is not a valid Bluetooth UUID. Valid are 16-bit, 32-bit, and 128-bit values.")
            Foundation.exit(-1)
        }

        if !device.isEmpty {
            guard device.count == 36, let _ = UUID(uuidString: device) else {
                print("Argument error: '\(device)' is not a valid BLE device UUID. Please use the scan subcommand to find device UUIDs.")
                Foundation.exit(-1)
            }
        }

        streamBridge = self.createBridge()
        try await self.connectBLE()

        let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSrc.setEventHandler {
            Foundation.exit(0)
        }
        sigintSrc.resume()

        while true {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            await Task.yield()
        }
    }
}

private extension Bridge {

    func createBridge() -> StreamBridge {
        let (master, slave) = self.openPty()
        return StreamBridge(masterHandle: master, slaveHandle: slave) {
            let bleStreams = (streamBridge.bleInputStream, streamBridge.bleOutputStream)
            streamBridge = self.createBridge()
            streamBridge.bleInputStream = bleStreams.0
            streamBridge.bleOutputStream = bleStreams.1
        }
    }

    func openPty() -> (master: FileHandle, slave: FileHandle) {
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) != -1 else {
            print("Error: Can't open pty: \(errno)")
            Foundation.exit(-1)
        }
        let slaveNameCString = ttyname(slave)
        let slaveName = String(cString: slaveNameCString!)
        self.dumpPtyName(slaveName)

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        return (masterHandle, slaveHandle)
    }

    func dumpPtyName(_ pty: String) {
        print("Created \(pty). Ready to communicate.")
        guard let path = self.fileName else { return }
        let url = URL(fileURLWithPath: path)
        let data = pty.data(using: .utf8)!
        do {
            try data.write(to: url)
            print("Wrote \(pty) to \(url)")
        } catch {
            print("Can't pty path write to \(url): \(error)")
        }
    }

    func connectBLE() async throws {
        let uuid = CBUUID(string: self.uuid)
        let url: URL
        if self.device.isEmpty {
            print("Scanning for devices with service UUID \(uuid)…")
            url = URL(string: "ble://\(uuid)")!
        } else {
            let peer = UUID(uuidString: self.device)!
            print("Scanning for device \(peer) providing service \(uuid)…")
            url = URL(string: "ble://\(uuid)/\(peer)")!
        }

        do {
            let streams = try await Cornucopia.Streams.connect(url: url)
            print("Connected to BLE device via \(url).")
            await MainActor.run {
                streamBridge.bleInputStream = streams.0
                streamBridge.bleOutputStream = streams.1
            }
        } catch {
            print("Error: Can't connect to \(url): \(error)")
            Foundation.exit(-1)
        }
    }
}

class StreamBridge: NSObject, StreamDelegate {

    var masterHandle: FileHandle!
    var slaveHandle: FileHandle!
    var ptyCloseHandler: (()->())?

    var ptyInputStream: InputStream? {
        didSet {
            os_log("Opening PTY input stream...", log: log, type: .debug)
            self.ptyInputStream?.schedule(in: RunLoop.main, forMode: .default)
            self.ptyInputStream?.delegate = self
            self.ptyInputStream?.open()
        }
    }
    var ptyOutputStream: OutputStream? {
        didSet {
            os_log("Opening PTY output stream...", log: log, type: .debug)
            self.ptyOutputStream?.schedule(in: RunLoop.main, forMode: .default)
            self.ptyOutputStream?.delegate = self
            self.ptyOutputStream?.open()
        }
    }

    var bleInputStream: InputStream? {
        didSet {
            self.bleInputStream?.schedule(in: RunLoop.main, forMode: .default)
            self.bleInputStream?.delegate = self
            self.bleInputStream?.open()
        }
    }
    var bleOutputStream: OutputStream? {
        didSet {
            self.bleOutputStream?.schedule(in: RunLoop.main, forMode: .default)
            self.bleOutputStream?.delegate = self
            self.bleOutputStream?.open()
        }
    }

    init(masterHandle: FileHandle, slaveHandle: FileHandle, ptyCloseHandler: @escaping(()->())) {
        self.ptyCloseHandler = ptyCloseHandler
        super.init()
        self.createPtyStreams(masterHandle: masterHandle, slaveHandle: slaveHandle)
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {

        switch (aStream, eventCode) {

            case (self.ptyInputStream, .hasBytesAvailable):
                self.bridge(from: self.ptyInputStream!, to: self.bleOutputStream)

            case (self.bleInputStream, .hasBytesAvailable):
                self.bridge(from: self.bleInputStream!, to: self.ptyOutputStream)

            case (_, .errorOccurred):
                os_log("Stream error: %@", log: log, type: .error, aStream.streamError?.localizedDescription ?? "unknown")

            case (_, .endEncountered):
                if aStream == self.ptyInputStream || aStream == self.ptyOutputStream {
                    os_log("PTY stream end encountered, recreating bridge...", log: log, type: .debug)
                    self.ptyCloseHandler?()
                }

            default:
                break
        }
    }

    private func bridge(from: InputStream, to: OutputStream?) {
        guard let to = to else { return }
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let bytesRead = from.read(&buffer, maxLength: bufferSize)
        if bytesRead > 0 {
            to.write(buffer, maxLength: bytesRead)
        }
    }

    func createPtyStreams(masterHandle: FileHandle, slaveHandle: FileHandle) {
        self.masterHandle = masterHandle
        self.slaveHandle = slaveHandle
        DispatchQueue.main.async {
            self.ptyInputStream = FileHandleInputStream(fileHandle: masterHandle)
            self.ptyOutputStream = FileHandleOutputStream(fileHandle: masterHandle)
        }
    }

}
