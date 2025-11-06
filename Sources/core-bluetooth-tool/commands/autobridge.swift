//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import ArgumentParser
import CoreBluetooth
import CornucopiaStreams
import Foundation
import os.log
import Darwin

fileprivate var alog = OSLog(subsystem: "core-bluetooth-tool", category: "autobridge")

struct Autobridge: ParsableCommand {

    public static let configuration = CommandConfiguration(abstract: "Like 'bridge', but also connects your terminal to the created PTY for immediate I/O")

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
                print("Argument error: '\(device)' is not a valid BLE device UUID. Please use the scan subcommand to find device UUIDs.")
                Foundation.exit(-1)
            }
        }

        // Create the BLE<->PTY bridge using the existing implementation
        streamBridge = self.createBridge()
        self.connectBLE()

        // Attach our terminal stdin/stdout directly to the slave PTY for immediate interaction
        let terminal = TerminalSession(slave: streamBridge.slaveHandle)
        terminal.start()

        // We handle Ctrl-C (0x03) inside TerminalSession by detecting the byte on stdin

        let loop = RunLoop.current
        while loop.run(mode: .default, before: Date.distantFuture) {
            loop.run()
        }
    }
}

private extension Autobridge {

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
        FileHandle.standardError.write(Data("Created \(pty). Autobridge attaches your terminal now.\n".utf8))
        guard let path = self.fileName else { return }
        let url = URL(fileURLWithPath: path)
        let data = pty.data(using: .utf8)!
        do {
            try data.write(to: url)
            FileHandle.standardError.write(Data("Wrote \(pty) to \(url.absoluteString)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Can't pty path write to \(url.absoluteString): \(error.localizedDescription)\n".utf8))
        }
    }

    func connectBLE() {
        let uuid = CBUUID(string: self.uuid)
        let url: URL
        if self.device.isEmpty {
            FileHandle.standardError.write(Data("Scanning for devices with service UUID \(uuid.uuidString)…\n".utf8))
            url = URL(string: "ble://\(uuid.uuidString)")!
        } else {
            let peer = UUID(uuidString: self.device)!
            FileHandle.standardError.write(Data("Scanning for device \(peer.uuidString) providing service \(uuid.uuidString)…\n".utf8))
            url = URL(string: "ble://\(uuid.uuidString)/\(peer.uuidString)")!
        }

        Task {
            do {
                let streams = try await Cornucopia.Streams.connect(url: url)
                FileHandle.standardError.write(Data("Connected to BLE device via \(url.absoluteString).\n".utf8))
                streamBridge.bleInputStream = streams.0
                streamBridge.bleOutputStream = streams.1
            } catch {
                FileHandle.standardError.write(Data("Error: Can't connect to \(url.absoluteString): \(error.localizedDescription)\n".utf8))
                Foundation.exit(-1)
            }
        }
    }
}

final class TerminalSession {
    private let slaveHandle: FileHandle
    private var stdinSource: DispatchSourceRead?
    private var slaveSource: DispatchSourceRead?

    private var originalTerm: termios = termios()
    private var rawModeApplied = false
    private var originalSlaveTerm: termios = termios()
    private var slaveRawApplied = false

    init(slave: FileHandle) {
        self.slaveHandle = slave
    }

    func start() {
        self.applyRawMode(fd: STDIN_FILENO, saveTo: &originalTerm, setISIG: false)
        self.applySlaveRawNoEcho()
        // Drop any pending "Enter" from shell that would otherwise be consumed by the PTY
        _ = tcflush(STDIN_FILENO, TCIFLUSH)
        // Ensure our terminal cursor moves to a fresh line
        let crlf: [UInt8] = [0x0D, 0x0A]
        _ = crlf.withUnsafeBufferPointer { ptr in
            write(STDOUT_FILENO, ptr.baseAddress!, ptr.count)
        }
        self.setupIO()
        FileHandle.standardError.write(Data("Autobridge ready. Type to interact. Press Ctrl-C to exit.\r\n\r\n".utf8))
    }

    func stop() {
        self.teardownIO()
        self.restore(fd: STDIN_FILENO, term: originalTerm, applied: &rawModeApplied)
        self.restoreSlave()
        FileHandle.standardError.write(Data("Autobridge stopped.\n".utf8))
    }

    private func setupIO() {
        let stdinFD = STDIN_FILENO
        let slaveFD = self.slaveHandle.fileDescriptor

        // stdin -> slave
        let inSource = DispatchSource.makeReadSource(fileDescriptor: stdinFD, queue: .main)
        inSource.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let n = read(stdinFD, &buffer, buffer.count)
            if n > 0 {
                // Handle Ctrl-C (ETX 0x03) manually, restore terminal and exit
                if buffer[0] == 0x03 { // ETX
                    self.stop()
                    Foundation.exit(0)
                }
                _ = buffer.withUnsafeBufferPointer { ptr in
                    write(slaveFD, ptr.baseAddress!, n)
                }
            }
        }
        inSource.resume()
        self.stdinSource = inSource

        // slave -> stdout
        let outSource = DispatchSource.makeReadSource(fileDescriptor: slaveFD, queue: .main)
        outSource.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 1024)
            let n = read(slaveFD, &buffer, buffer.count)
            if n > 0 {
                _ = buffer.withUnsafeBufferPointer { ptr in
                    write(STDOUT_FILENO, ptr.baseAddress!, n)
                }
            }
        }
        outSource.resume()
        self.slaveSource = outSource
    }

    private func teardownIO() {
        self.stdinSource?.cancel()
        self.slaveSource?.cancel()
        self.stdinSource = nil
        self.slaveSource = nil
    }

    private func applyRawMode(fd: Int32, saveTo: inout termios, setISIG: Bool) {
        var t = termios()
        if tcgetattr(fd, &t) == 0 {
            saveTo = t
            cfmakeraw(&t)
            if setISIG {
                t.c_lflag |= tcflag_t(ISIG) // allow signals like Ctrl-C
            }
            if tcsetattr(fd, TCSANOW, &t) == 0 {
                if fd == STDIN_FILENO { self.rawModeApplied = true }
            }
        }
    }

    private func applySlaveRawNoEcho() {
        let fd = self.slaveHandle.fileDescriptor
        var t = termios()
        if tcgetattr(fd, &t) == 0 {
            self.originalSlaveTerm = t
            cfmakeraw(&t)
            t.c_lflag &= ~tcflag_t(ECHO) // no local echo on slave
            _ = tcsetattr(fd, TCSANOW, &t)
            self.slaveRawApplied = true
        }
    }

    private func restore(fd: Int32, term: termios, applied: inout Bool) {
        guard applied else { return }
        var t = term
        _ = tcsetattr(fd, TCSANOW, &t)
        applied = false
    }

    private func restoreSlave() {
        guard slaveRawApplied else { return }
        var t = originalSlaveTerm
        _ = tcsetattr(self.slaveHandle.fileDescriptor, TCSANOW, &t)
        slaveRawApplied = false
    }

}
