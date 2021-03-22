//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import Foundation

class FileHandleOutputStream: OutputStream {

    private let fileHandle: FileHandle

    private var _streamStatus: Stream.Status
    private var _streamError: Error?
    private var _delegate: StreamDelegate?

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        self._streamStatus = .notOpen
        self._streamError = nil
        super.init(toMemory: ())
    }

    override var streamStatus: Stream.Status {
        return _streamStatus
    }

    override var streamError: Error? {
        return _streamError
    }

    override var delegate: StreamDelegate? {
        get {
            return _delegate
        }
        set {
            _delegate = newValue
        }
    }

    override func open() {
        guard self._streamStatus != .open else { return }
        self._streamStatus = .open
    }

    override var hasSpaceAvailable: Bool { true }

    override func write(_ buffer: UnsafePointer<UInt8>, maxLength len: Int) -> Int {

        let data = Data(bytes: buffer, count: len)
        self.fileHandle.write(data)
        return len
    }

    override func close() {
        self._streamStatus = .closed
    }

    override func property(forKey key: Stream.PropertyKey) -> Any? { nil }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { false }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) { }
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) { }
}
