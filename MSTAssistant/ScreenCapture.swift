import Foundation
import UIKit

/// 截屏：只用稳定路径。私有 SBScreenShot 系列符号签名不确定，盲调会直接崩，先不碰。
enum ScreenCapture {

    static func systemImage() -> UIImage? {
        // 自身窗口快照（稳定），跨 App 截屏需要 SpringBoard 侧实现，留到注入验证通过后再上
        return windowSnapshot()
    }

    static func windowSnapshot() -> UIImage? {
        let wins = UIApplication.shared.windows
        guard let win = wins.first(where: { $0.isKeyWindow }) ?? wins.first else { return nil }
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

enum ScreenGeometry {
    static var bounds: CGRect { UIScreen.main.bounds }
    static func point(nx: Double, ny: Double) -> CGPoint {
        CGPoint(x: bounds.width * CGFloat(nx) / 1000.0, y: bounds.height * CGFloat(ny) / 1000.0)
    }
}
