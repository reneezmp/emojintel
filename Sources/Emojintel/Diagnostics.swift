import Foundation

/// Appends a line per trigger to ~/Library/Logs/Emojintel.log.
///
/// Debugging this app by guessing is expensive — every wrong guess costs a rebuild, a
/// reinstall, and a round of manual testing in five apps. A log of what actually happened
/// (which app, which element, which replacement tier, whether it verified) turns that into
/// reading a file.
enum Diagnostics {

    static let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Emojintel.log")

    private static let queue = DispatchQueue(label: "dev.renee.emojintel.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var enabled = true

    static func log(_ message: String) {
        guard enabled else { return }
        queue.async {
            let line = "\(formatter.string(from: Date()))  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }

    /// Keeps the file from growing without bound across sessions.
    static func rotateIfLarge(limit: Int = 256 * 1024) {
        queue.async {
            guard let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int, size > limit else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
