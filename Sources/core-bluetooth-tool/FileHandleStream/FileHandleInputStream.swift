//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import Foundation

class FileHandleInputStream: InputStream {

    private let fileHandle: FileHandle

    private var _streamStatus: Stream.Status
    private var _streamError: Error?
    private var _delegate: StreamDelegate?
    private var observingAvailability = false

    init(fileHandle: FileHandle, offset: UInt64 = 0) {
        self.fileHandle = fileHandle
        if offset > 0 {
            self.fileHandle.seek(toFileOffset: offset)
        }
        self._streamStatus = .notOpen
        self._streamError = nil
        super.init(data: Data())
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

        NotificationCenter.default.addObserver(self, selector: #selector(onFileHandleDataAvailable), name: Notification.Name.NSFileHandleDataAvailable, object: self.fileHandle)
        self.fileHandle.waitForDataInBackgroundAndNotify()
        self.observingAvailability = true
        self._streamStatus = .open
        self.delegate?.stream?(self, handle: .openCompleted)
    }

    override var hasBytesAvailable: Bool { self._streamStatus == .open }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard _streamStatus == .open else { return 0 }
        do {
            guard let data = try self.fileHandle.read(upToCount: len) else {
                self._streamStatus = .atEnd
                self.delegate?.stream?(self, handle: .endEncountered)
                return 0
            }
            if data.isEmpty {
                self._streamStatus = .atEnd
                self.delegate?.stream?(self, handle: .endEncountered)
                return 0
            }
            data.copyBytes(to: buffer, count: data.count)
            self.fileHandle.waitForDataInBackgroundAndNotify()
            return data.count
        } catch {
            self._streamError = error
            self._streamStatus = .error
            self.delegate?.stream?(self, handle: .errorOccurred)
            return -1
        }
    }

    override func close() {
        if observingAvailability {
            NotificationCenter.default.removeObserver(self, name: Notification.Name.NSFileHandleDataAvailable, object: self.fileHandle)
            observingAvailability = false
        }
        self._streamStatus = .closed
    }

    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool { false }
    override func property(forKey key: Stream.PropertyKey) -> Any? { nil }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { false }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) { }
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) { }

    deinit {
        if observingAvailability {
            NotificationCenter.default.removeObserver(self, name: Notification.Name.NSFileHandleDataAvailable, object: self.fileHandle)
        }
    }
}

extension FileHandleInputStream {

    @objc func onFileHandleDataAvailable() {
        self.delegate?.stream?(self, handle: .hasBytesAvailable)
    }
}
