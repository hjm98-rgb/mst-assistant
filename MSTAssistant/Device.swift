import Foundation
import UIKit

enum DeviceInfo {
    static var isRoot: Bool { geteuid() == 0 }

    static var jailbreakMarkers: [String] {
        ["/var/jb", "/var/jb/usr/bin/sileo", "/var/jb/usr/bin/bash",
         "/var/jb/Library/MobileSubstrate", "/var/jb/usr/lib/libroot.dylib",
         "/Applications/Sileo.app", "/private/var/lib/dpkg",
         "/.installed_dopamine", "/var/jb/.installed_dopamine"]
    }

    static var isJailbroken: Bool {
        jailbreakMarkers.contains { FileManager.default.fileExists(atPath: $0) }
    }

    static func summary() -> String {
        let v = UIDevice.current.systemVersion
        let jb = isJailbroken ? "已越狱" : "未越狱"
        let id = isRoot ? "uid 0" : "uid \(geteuid())"
        return "iPadOS \(v) · \(jb) · \(id)"
    }
}

enum AppLauncher {
    /// SpringBoardServices 的 SBSLaunchApplicationWithIdentifier
    static func open(bundleID: String) -> Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW) else {
            return false
        }
        typealias Fn = @convention(c) (CFString, Bool) -> Int32
        guard let sym = dlsym(h, "SBSLaunchApplicationWithIdentifier") else { return false }
        let fn = unsafeBitCast(sym, to: Fn.self)
        let ret = fn(bundleID as CFString, false)
        if ret == 0 { return true }
        // 退回 LSApplicationWorkspace
        return openViaLSWorkspace(bundleID: bundleID)
    }

    private static func openViaLSWorkspace(bundleID: String) -> Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW) else { return false }
        typealias Cls = @convention(c) () -> AnyObject
        guard let clsSym = dlsym(h, "OBJC_CLASS_$_LSApplicationWorkspace") else { return false }
        let clsFn = unsafeBitCast(clsSym, to: Cls.self)
        guard let cls = clsFn() as? NSObject else { return false }
        let sel1 = NSSelectorFromString("defaultWorkspace")
        let sel2 = NSSelectorFromString("openApplicationWithBundleID:")
        guard cls.responds(to: sel1) else { return false }
        let ws = cls.perform(sel1)?.takeUnretainedValue() as AnyObject
        if let obj = ws as? NSObject, obj.responds(to: sel2) {
            _ = obj.perform(sel2, with: bundleID)
            return true
        }
        return false
    }
}

enum Cleaner {
    /// 清掉白色巨魔残留：bundle + LaunchServices/FrontBoard 注册库
    static func cleanStaleTrollStore() -> String {
        let fm = FileManager.default
        var log: [String] = []
        let targets = [
            "/var/mobile/Documents/mst-apps/TrollStore.app",
            "/var/jb/Applications/TrollStore.app",
            "/var/jb/tmp"
        ]
        for t in targets {
            if fm.fileExists(atPath: t) {
                do {
                    try fm.removeItem(atPath: t)
                    log.append("已删除 \(t)")
                } catch {
                    log.append("删除失败 \(t)：\(error.localizedDescription)")
                }
            }
        }
        let dbs = [
            "/var/mobile/Library/FrontBoard/applicationState.db",
            "/var/mobile/Library/FrontBoard/applicationState.db-wal",
            "/var/mobile/Library/FrontBoard/applicationState.db-shm",
            "/var/mobile/Library/MobileInstallation/LastLaunchServicesMap.plist",
            "/var/mobile/Library/Caches/com.apple.mobile.installation.plist"
        ]
        for db in dbs where fm.fileExists(atPath: db) {
            do { try fm.removeItem(atPath: db); log.append("已删除 \(db)") }
            catch { log.append("删除失败 \(db)：\(error.localizedDescription)") }
        }
        if fm.fileExists(atPath: "/var/mobile/Documents/mst-apps"),
           (try? fm.contentsOfDirectory(atPath: "/var/mobile/Documents/mst-apps").isEmpty) == true {
            try? fm.removeItem(atPath: "/var/mobile/Documents/mst-apps")
        }
        log.append("完成。请长按电源键关机再开机，注册表在开机时重建。")
        return log.joined(separator: "\n")
    }
}
