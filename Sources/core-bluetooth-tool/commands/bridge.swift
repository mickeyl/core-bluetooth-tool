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

struct Bridge: ParsableCommand {

    public static let configuration = CommandConfiguration(abstract: "Establish a serial bridge via a pseudo-TTY")

    @Argument(help: "Service UUID")
    private var uuid: String

    @Argument(help: "Device UUID")
    private var device: String = ""

    @Option(name: .shortAndLong, help: "The filename to write the PTY path to.")
    var fileName: String?

    func run() throws {

        guard CBUUID.CC_isValid(string: self.uuid) else {
            print("Argument error: '\(self.uuid)' is not a valid Bluetooth UUID. Valid are 16-bit, 32-bit, and 128-bit values.")
            Foundation.exit(-1)
        }

        if !device.isEmpty {
            guard device.count == 36, let _ = UUID(uuidString: device) else {
                print("Argument error: '\(device.count) is not a valid BLE device UUID. Please use the scan subcommand to find device UUIDs.")
                Foundation.exit(-1)
            }
        }

        streamBridge = self.createBridge()
        self.connectBLE()

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

    func connectBLE() {
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

        Stream.CC_getStreamPair(to: url) { result in
            guard case .success(let streams) = result else {
                print("Error: Can't build stream: \(result)")
                Foundation.exit(-1)
            }
            let deviceName = streams.0.CC_meta?.name ?? "Unknown"
            print("Connected to BLE device '\(deviceName)'.")
            streamBridge.bleInputStream = streams.0
            streamBridge.bleOutputStream = streams.1
        }
    }
}

class StreamBridge: NSObject, StreamDelegate {

    var masterHandle: FileHandle!
    var slaveHandle: FileHandle!
    var ptyCloseHandler: ()->()?

    var ptyInputStream: InputStream? {
        didSet {
            os_log("Opening PTY input stream...", log: log, type: .debug)
            self.ptyInputStream?.schedule(in: RunLoop.current, forMode: .default)
            self.ptyInputStream?.delegate = self
            self.ptyInputStream?.open()
        }
    }
    var ptyOutputStream: OutputStream? {
        didSet {
            os_log("Opening PTY output stream...", log: log, type: .debug)
            self.ptyOutputStream?.schedule(in: RunLoop.current, forMode: .default)
            self.ptyOutputStream?.delegate = self
            self.ptyOutputStream?.open()
        }
    }

    var bleInputStream: InputStream? {
        didSet {
            self.bleInputStream?.delegate = self
            self.bleInputStream?.open()
        }
    }
    var bleOutputStream: OutputStream? {
        didSet {
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
        #if DEBUG
        os_log("Stream %@, event %@", log: log, type: .debug, aStream.description, eventCode.description)
        #endif

        switch (aStream, eventCode) {

            case (ptyInputStream, .hasBytesAvailable):
                let bufferSize = 1024
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                let readBytes = ptyInputStream!.read(buffer, maxLength: bufferSize)
                guard readBytes > 0 else {
                    self.ptyInputStream?.close()
                    self.ptyOutputStream?.close()
                    print("PTY did close. Reopening...")
                    self.ptyCloseHandler()
                    return
                }
                guard let outputStream = bleOutputStream else {
                    os_log("BLE output stream not yet connected. Swallowing character...", log: log, type: .debug)
                    return
                }
                outputStream.write(buffer, maxLength: readBytes)

            case (bleInputStream, .hasBytesAvailable):
                let bufferSize = 1024
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                let readBytes = bleInputStream!.read(buffer, maxLength: bufferSize)
                guard readBytes > 0 else {
                    fatalError("BLE EOF?")
                }
                guard let outputStream = ptyOutputStream else {
                    os_log("PTY output stream not yet connected… swallowing character", log: log, type: .debug)
                    return
                }
                outputStream.write(buffer, maxLength: readBytes)

            default:
                break

        }
    }
}

private extension StreamBridge {

    func createPtyStreams(masterHandle: FileHandle, slaveHandle: FileHandle) {

        self.masterHandle = masterHandle
        self.slaveHandle = slaveHandle
        DispatchQueue.main.async {
            self.ptyInputStream = FileHandleInputStream(fileHandle: masterHandle)
            self.ptyOutputStream = FileHandleOutputStream(fileHandle: masterHandle)
        }
    }

}
