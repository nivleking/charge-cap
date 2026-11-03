import Foundation

/// Appends one line per event to the log file. Keeps it small: when it passes 1 MB the old half is dropped.
public final class FileLog {
    public static let defaultPath = "/var/log/chargecap.log"
    public let path: String
    private let maxBytes = 1_000_000
    private let lock = NSLock()

    public init(path: String? = nil) {
        self.path = path ?? ProcessInfo.processInfo.environment["CHARGECAP_LOG"] ?? Self.defaultPath
    }

    public func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        if let size = try? handle.seekToEnd(), size > UInt64(maxBytes) { trim() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func trim() {
        guard let old = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let kept = old.suffix(maxBytes / 2)
        // Start at a line boundary.
        let start = kept.firstIndex(of: 0x0a).map { kept.index(after: $0) } ?? kept.startIndex
        try? Data(kept[start...]).write(to: URL(fileURLWithPath: path))
    }

    public func tail(_ lines: Int) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}
