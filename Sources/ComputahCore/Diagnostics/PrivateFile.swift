import Foundation
import Darwin

/// Diagnostic files can contain private app content even after credential redaction.
/// Create the temporary file as 0600 before writing, then atomically replace the destination.
public enum PrivateFile {
    public static func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var template = Array(directory.appendingPathComponent(".computah-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporary = String(cString: template)
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? file.close()
            unlink(temporary)
        }
        try file.write(contentsOf: data)
        guard rename(temporary, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
