import Foundation

/// Lightweight append-only file logger at ~/.config/spaceboot/spaceboot.log.
enum SpaceBootLogger {
    static let logFilePath = "\(NSHomeDirectory())/.config/spaceboot/spaceboot.log"
    private static let maxLogBytes: UInt64 = 512 * 1024
    private static let queue = DispatchQueue(label: "com.spaceboot.logger")

    static func log(_ message: String) {
        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            let url = URL(fileURLWithPath: logFilePath)

            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            rotateIfNeeded(url: url)

            if FileManager.default.fileExists(atPath: logFilePath),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func rotateIfNeeded(url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogBytes else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
