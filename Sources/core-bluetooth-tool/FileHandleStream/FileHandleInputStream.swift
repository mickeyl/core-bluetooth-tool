//
//  (C) Copyright Dr. Michael 'Mickey' Lauer <mickey@vanille-media.de>
//
import Foundation

class FileHandleInputStream: InputStream {

    private let fileHandle: FileHandle

    private var _streamStatus: Stream.Status
    private var _streamError: Error?
    private var _delegate: StreamDelegate?
    private var hasReadabilityHandler = false

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

        self.fileHandle.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            self.delegate?.stream?(self, handle: .hasBytesAvailable)
        }
        self.hasReadabilityHandler = true
        self._streamStatus = .open
        self.delegate?.stream?(self, handle: .openCompleted)
    }

    override var hasBytesAvailable: Bool { self._streamStatus == .open }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard _streamStatus == .open else { return 0 }
        // Note: readabilityHandler has already signaled data.
        // We must be careful not to block here if readabilityHandler was triggered but data was already read.
        // However, FileHandle.read(upToCount:) usually behaves well if there is data.
        let data = self.fileHandle.availableData
        if data.isEmpty {
            // This can happen if EOF
            self._streamStatus = .atEnd
            self.delegate?.stream?(self, handle: .endEncountered)
            return 0
        }
        let count = min(data.count, len)
        data.copyBytes(to: buffer, count: count)
        return count
    }

    override func close() {
        if hasReadabilityHandler {
            self.fileHandle.readabilityHandler = nil
            hasReadabilityHandler = false
        }
        self._streamStatus = .closed
    }

    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool { false }
    override func property(forKey key: Stream.PropertyKey) -> Any? { nil }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { false }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) { }
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) { }

    deinit {
        if hasReadabilityHandler {
            self.fileHandle.readabilityHandler = nil
        }
    }
}
