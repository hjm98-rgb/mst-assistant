import Foundation
import UIKit

/// 系统级截屏：先试 SpringBoard 私有截屏，再退回自身窗口快照
enum ScreenCapture {

    private static var sbsHandle: UnsafeMutableRawPointer? {
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW)
    }

    static func systemImage() -> UIImage? {
        if let h = sbsHandle {
            for name in ["SBScreenShot", "SBScreenShotImage", "SBSCaptureScreen"] {
                guard let sym = dlsym(h, name) else { continue }
                typealias Fn = @convention(c) (Int32) -> Unmanaged<AnyObject>?
                let fn = unsafeBitCast(sym, to: Fn.self)
                if let obj = fn(0)?.takeUnretainedValue() as? UIImage { return obj }
                if let obj = fn(0)?.takeUnretainedValue(), CFGetTypeID(obj as CFTypeRef) == CGImage.typeID {
                    return UIImage(cgImage: obj as! CGImage)
                }
            }
        }
        return windowSnapshot()
    }

    static func windowSnapshot() -> UIImage? {
        guard let win = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first else { return nil }
        let size = win.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        UIGraphicsBeginImageContextWithOptions(size, false, 0.5)
        defer { UIGraphicsEndImageContext() }
        win.drawHierarchy(in: win.bounds, afterScreenUpdates: false)
        return UIGraphicsGetImageFromCurrentImageContext()
    }

    static func jpegBase64(_ img: UIImage, quality: CGFloat = 0.45, maxSide: CGFloat = 900) -> String? {
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        defer { UIGraphicsEndImageContext() }
        img.draw(in: CGRect(origin: .zero, size: size))
        guard let small = UIGraphicsGetImageFromCurrentImageContext(),
              let data = small.jpegData(compressionQuality: quality) else { return nil }
        return data.base64EncodedString()
    }
}

/// 屏幕坐标换算（模型按 0-1000 归一化坐标输出）
enum ScreenGeometry {
    static var bounds: CGRect {
        UIScreen.main.bounds
    }
    static func point(nx: Double, ny: Double) -> CGPoint {
        CGPoint(x: bounds.width * CGFloat(nx) / 1000.0, y: bounds.height * CGFloat(ny) / 1000.0)
    }
}
