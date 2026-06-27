import Foundation

// Simple crash-breadcrumb logger. Survives app crashes because it flushes to disk
// at each write. Read on next launch from SplashVC to find the last step before crash.
struct StoatDebug {

    private static var logPath: String {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        return docs + "/stoatdebug.txt"
    }

    static func log(_ msg: String) {
        let line = "\(Date()) | \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath),
               let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath), options: .atomic)
            }
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: logPath)
    }

    static func read() -> String {
        return (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "(no log)"
    }
}
