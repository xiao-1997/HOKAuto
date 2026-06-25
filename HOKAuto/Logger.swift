import Foundation

/// 调试日志，写入 /var/mobile/Documents/hok_auto.log
struct Logger {
    static let path = "/var/mobile/Documents/hok_auto.log"

    static func log(_ msg: String) {
        let ts = DateFormatter()
        ts.dateFormat = "MM-dd HH:mm:ss"
        let line = "[\(ts.string(from: Date()))] \(msg)\n"
        print(line, terminator: "")

        if let f = FileHandle(forWritingAtPath: path) {
            f.seekToEndOfFile()
            f.write(line.data(using: .utf8)!)
            f.closeFile()
        } else {
            try? line.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }
}
