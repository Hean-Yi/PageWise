import Darwin
import Foundation

/// The directory lock follows its inode when the staging directory is renamed. Another window
/// opening the same library can distinguish an active import from a crashed writer.
final class ImportDirectoryLock: Sendable {
    private let descriptor: Int32

    init?(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

public struct PendingPDFImport: Sendable {
    public let paper: Paper
    let directory: URL
    let lock: ImportDirectoryLock

    static func marker(in directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent(".pending-import-" + id.uuidString)
    }

    /// On a cleanup failure the next launch checks the committed paper ID before clearing the marker.
    public func commit() {
        withExtendedLifetime(lock) { try? FileManager.default.removeItem(at: Self.marker(in: directory, id: paper.id)) }
    }

    public func discard() {
        withExtendedLifetime(lock) { try? FileManager.default.removeItem(at: directory) }
    }
}
