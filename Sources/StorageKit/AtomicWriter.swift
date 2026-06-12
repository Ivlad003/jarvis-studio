import Foundation

public enum AtomicWriterError: Error {
    case writeFailed(underlying: Error)
    case fsyncFailed(errno: Int32)
    case renameFailed(underlying: Error)
    case parentDirOpenFailed(errno: Int32)
}

public enum AtomicWriter {
    /// Atomically write `data` to `url` using the tmp+fsync+rename pattern.
    ///
    /// The file is first written to `<url>.tmp.<pid>`, fsync'd, then renamed
    /// over `url`. The parent directory is also fsync'd to ensure the rename
    /// is durable across crashes / power loss.
    ///
    /// - Throws: `AtomicWriterError` on filesystem errors. The temp file is
    ///   removed on any error path (best effort; tolerates EBUSY).
    public static func write(_ data: Data, to url: URL) throws {
        let tmpURL = url.appendingPathExtension("tmp.\(ProcessInfo.processInfo.processIdentifier)")

        // Write to temp file
        do {
            try data.write(to: tmpURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw AtomicWriterError.writeFailed(underlying: error)
        }

        // fsync the temp file. Use POSIX directly so errno is captured from
        // the failing syscall rather than guessed from a Foundation throw.
        let tmpFd = Darwin.open(tmpURL.path, O_RDONLY)
        if tmpFd == -1 {
            let e = Foundation.errno
            try? FileManager.default.removeItem(at: tmpURL)
            throw AtomicWriterError.fsyncFailed(errno: e)
        }
        let tmpFsyncResult = Darwin.fsync(tmpFd)
        let tmpFsyncErrno = Foundation.errno
        Darwin.close(tmpFd)
        if tmpFsyncResult != 0 {
            try? FileManager.default.removeItem(at: tmpURL)
            throw AtomicWriterError.fsyncFailed(errno: tmpFsyncErrno)
        }

        // fsync the parent directory to durably record the future rename
        let parentPath = url.deletingLastPathComponent().path
        let dirFd = Darwin.open(parentPath, O_RDONLY)
        if dirFd == -1 {
            let e = Foundation.errno
            try? FileManager.default.removeItem(at: tmpURL)
            throw AtomicWriterError.parentDirOpenFailed(errno: e)
        }
        let fsyncResult = Darwin.fsync(dirFd)
        Darwin.close(dirFd)
        if fsyncResult != 0 {
            let e = Foundation.errno
            try? FileManager.default.removeItem(at: tmpURL)
            throw AtomicWriterError.fsyncFailed(errno: e)
        }

        // Atomic rename over destination
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw AtomicWriterError.renameFailed(underlying: error)
        }

        // Re-fsync the parent directory AFTER the rename. The pre-rename fsync
        // covers the temp-file's existence; the rename itself is a directory
        // mutation that needs its own fsync to be durable across power loss.
        // Skipping this is the previous bug — a crash between rename and the
        // next OS-driven flush could roll back to the old file (or no file at
        // all on first write), undoing what callers thought was committed.
        let dirFd2 = Darwin.open(parentPath, O_RDONLY)
        if dirFd2 == -1 {
            throw AtomicWriterError.parentDirOpenFailed(errno: Foundation.errno)
        }
        let postRenameFsyncResult = Darwin.fsync(dirFd2)
        let postRenameFsyncErrno = Foundation.errno
        Darwin.close(dirFd2)
        if postRenameFsyncResult != 0 {
            throw AtomicWriterError.fsyncFailed(errno: postRenameFsyncErrno)
        }
    }

    /// JSON-encode and atomically write a Codable value.
    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try write(data, to: url)
    }
}
