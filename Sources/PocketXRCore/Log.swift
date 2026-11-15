import Foundation

/// Pocket XR's log: ~/Library/Logs/Pocket XR/pocket-xr.log, kept under 4 MB (the old half moves to pocket-xr.1.log).
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    public let folder: URL
    public let file: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private let maxBytes: UInt64 = 4 << 20
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    /// Also print each line (the --imu-test run and debugging from Terminal).
    public var echo = false

    init() {
        folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pocket XR", isDirectory: true)
        file = folder.appendingPathComponent("pocket-xr.log")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        open()
    }

    private func open() {
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
    }

    public func callAsFunction(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        lock.lock(); defer { lock.unlock() }
        if echo { FileHandle.standardError.write(Data(text.utf8)) }
        handle?.write(Data(text.utf8))
        if let size = try? handle?.offset(), size > maxBytes { rotate() }
    }

    private func rotate() {
        try? handle?.close()
        let old = folder.appendingPathComponent("pocket-xr.1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: file, to: old)
        open()
    }
}

/// Shortcut used everywhere: plog("..."). (Not "log", which is the maths function.)
public func plog(_ line: String) { Log.shared(line) }
