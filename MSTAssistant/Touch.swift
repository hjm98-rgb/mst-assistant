import Foundation
import UIKit

/// IOHIDEvent 触摸注入（私有 API，需 platform-application / no-sandbox / hid.client.event-dispatch）
enum TouchInjector {

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    struct Probe {
        var createFinger = false
        var createDigitizer = false
        var appendEvent = false
        var clientCreate = false
        var dispatch = false
        var describe: String {
            "finger=\(createFinger) digitizer=\(createDigitizer) append=\(appendEvent) client=\(clientCreate) dispatch=\(dispatch)"
        }
    }

    static func probe() -> Probe {
        var p = Probe()
        guard let h = iokit else { return p }
        p.createFinger = dlsym(h, "IOHIDEventCreateDigitizerFingerEventWithQuality") != nil
        p.createDigitizer = dlsym(h, "IOHIDEventCreateDigitizerEvent") != nil
        p.appendEvent = dlsym(h, "IOHIDEventAppendEvent") != nil
        p.clientCreate = dlsym(h, "IOHIDEventSystemClientCreateSimpleClient") != nil
        p.dispatch = dlsym(h, "IOHIDEventSystemClientDispatchEvent") != nil
        return p
    }

    /// 在屏幕坐标点做一次点击（began → ended）
    static func tap(_ point: CGPoint) -> Bool {
        guard let h = iokit,
              let fingerSym = dlsym(h, "IOHIDEventCreateDigitizerFingerEventWithQuality")
        else { return false }

        typealias CreateFinger = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, Double, Double, Double, Double, Double, Double, Double, Double, Double, Bool, UInt32) -> UnsafeMutableRawPointer?
        let create = unsafeBitCast(fingerSym, to: CreateFinger.self)

        // eventMask: 1=TouchDown(begin), 2=TouchUp(end); 4=range? 用 3 表示 began+ended 由两次事件分开
        let down = create(kCFAllocatorDefault, 0, 1, 1, 1, Double(point.x), Double(point.y), 0, 0, 0, 1, 1, 0, 0, true, 0)
        let up = create(kCFAllocatorDefault, 0, 1, 1, 2, Double(point.x), Double(point.y), 0, 0, 0, 1, 1, 0, 0, true, 0)

        guard let d = down, let u = up else { return false }
        let client = makeClient()
        guard let c = client else { return false }

        typealias Dispatch = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Void
        guard let dispSym = dlsym(h, "IOHIDEventSystemClientDispatchEvent") else { return false }
        let dispatch = unsafeBitCast(dispSym, to: Dispatch.self)

        dispatch(c, d)
        usleep(60_000)
        dispatch(c, u)
        return true
    }

    private static func makeClient() -> UnsafeMutableRawPointer? {
        guard let h = iokit,
              let sym = dlsym(h, "IOHIDEventSystemClientCreateSimpleClient") else { return nil }
        typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        return unsafeBitCast(sym, to: Create.self)(kCFAllocatorDefault)
    }
}
