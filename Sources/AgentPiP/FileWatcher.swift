import Foundation

final class DirectoryWatcher: @unchecked Sendable {
    private let path: String
    private let queue: DispatchQueue
    private let callback: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    init(path: String, queue: DispatchQueue, callback: @escaping @Sendable () -> Void) {
        self.path = path
        self.queue = queue
        self.callback = callback
    }

    func start() throws {
        descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: queue
        )
        source.setEventHandler(handler: callback)
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source
    }

    func cancel() { source?.cancel(); source = nil }
    deinit { cancel() }
}
