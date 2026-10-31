import Foundation

/// A small rolling log of playback events (shown in Settings → Diagnostics) so
/// problems on the phone, like stopping when locked, can be traced afterwards.
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    private let queue = DispatchQueue(label: "wolf.diagnostics")
    private let maxBytes = 200_000
    let fileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("diagnostics.log")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String) {
        let line = "\(Self.stamp.string(from: Date()))  \(message)\n"
        queue.async { [fileURL, maxBytes] in
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                let size = handle.offsetInFile
                try? handle.close()
                if size > UInt64(maxBytes), let all = try? Data(contentsOf: fileURL) {
                    try? all.suffix(maxBytes / 2).write(to: fileURL)
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    func recentText(lines: Int = 150) -> String {
        queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
            return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
        }
    }

    func clear() {
        queue.async { [fileURL] in try? FileManager.default.removeItem(at: fileURL) }
    }
}
