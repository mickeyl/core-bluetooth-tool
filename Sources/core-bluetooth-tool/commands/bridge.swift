//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import CoreBluetooth
import CornucopiaStreams
import Foundation

var streamBridge: StreamBridge!

struct Bridge: ParsableCommand {

    public static let configuration = CommandConfiguration(abstract: "Establish a serial bridge via a pseudo-TTY")

    @Argument(help: "Service UUID")
    private var uuid: String

    func run() throws {

        guard CBUUID.CC_isValid(string: self.uuid) else {
            print("Argument error: '\(self.uuid)' is not a valid Bluetooth UUID. Valid are 16-bit, 32-bit, and 128-bit values.")
            Foundation.exit(-1)
        }

        streamBridge = self.openPty()

        let uuid = CBUUID(string: self.uuid)
        print("Scanning for a device with service UUID '\(uuid)'…")
        let url = URL(string: "ble://\(uuid)")!

        Stream.CC_getStreamPair(to: url) { result in
            guard case .success(let streams) = result else {
                print("Error: Can't build stream: \(result)")
                Foundation.exit(-1)
            }
            let deviceName = streams.0.CC_name ?? "Unknown"
            print("Connected to BLE device '\(deviceName)'.")
            streamBridge.bleInputStream = streams.0
            streamBridge.bleOutputStream = streams.1
        }

        let loop = RunLoop.current
        while loop.run(mode: .default, before: Date.distantFuture) {
            loop.run()
        }
    }

    func openPty() -> StreamBridge {

        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) != -1 else {
            print("Error: Can't open pty: \(errno)")
            Foundation.exit(-1)
        }
        let slaveNameCString = ttyname(slave)
        let slaveName = String(cString: slaveNameCString!)
        print("Created \(slaveName). Ready to communicate.")

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        return StreamBridge(masterHandle: masterHandle, slaveHandle: slaveHandle)
    }
}

class StreamBridge: NSObject, StreamDelegate {

    var masterHandle: FileHandle!
    var slaveHandle: FileHandle!

    var ptyInputStream: InputStream? {
        didSet {
            print("opening pty input stream…")
            self.ptyInputStream?.schedule(in: RunLoop.current, forMode: .default)
            self.ptyInputStream?.delegate = self
            self.ptyInputStream?.open()
        }
    }
    var ptyOutputStream: OutputStream? {
        didSet {
            print("opening pty output stream…")
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

    init(masterHandle: FileHandle, slaveHandle: FileHandle) {
        super.init()

        self.masterHandle = masterHandle
        self.slaveHandle = slaveHandle
        DispatchQueue.main.async {
            self.ptyInputStream = FileHandleInputStream(fileHandle: masterHandle)
            self.ptyOutputStream = FileHandleOutputStream(fileHandle: masterHandle)
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        print("stream \(aStream) event \(eventCode)")

        switch (aStream, eventCode) {

            case (ptyInputStream, .hasBytesAvailable):
                let bufferSize = 1024
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                let readBytes = ptyInputStream!.read(buffer, maxLength: bufferSize)
                guard readBytes > 0 else {
                    fatalError("PTY EOF?")
                }
                guard let outputStream = bleOutputStream else {
                    print("BLE output stream not yet connected… swallowing character")
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
                    print("PTY output stream not yet connected… swallowing character")
                    return
                }
                outputStream.write(buffer, maxLength: readBytes)

            default:
                break

        }
    }

}
