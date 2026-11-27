import Foundation

/// 崩溃面包屑：每次危险动作前落盘，闪退后能看最后一步卡在哪
enum Breadcrumb {
    private static var url: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("mst", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("last-step.txt")
    }
    static func mark(_ s: String) {
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    static func read() -> String { (try? String(contentsOf: url)) ?? "" }
}
