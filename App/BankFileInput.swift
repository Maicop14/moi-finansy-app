import Foundation
import Darwin

/// Read only regular local files. Check the opened descriptor so a provider cannot
/// change the file type between validation and reading.
enum BankFileInput {
    static let perFileLimit = 24_000_000
    static let batchLimit = 64_000_000
    static let fileCount = 20

    static func bytes(at url: URL, limit: Int = perFileLimit) throws -> Data {
        guard url.isFileURL, limit >= 0, limit <= perFileLimit else { throw CocoaError(.fileReadUnsupportedScheme) }
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard info.st_size >= 0, info.st_size <= limit else { throw CocoaError(.fileReadTooLarge) }
        var data = Data()
        while let chunk = try file.read(upToCount: min(64 * 1024, limit - data.count + 1)), !chunk.isEmpty {
            guard chunk.count <= limit - data.count else { throw CocoaError(.fileReadTooLarge) }
            data.append(chunk)
        }
        return data
    }
}
