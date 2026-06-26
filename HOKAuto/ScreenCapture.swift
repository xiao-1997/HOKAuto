import UIKit
import Accelerate
import Photos

/// IOSurface + 私有API 全屏截图 + 图像优化
struct ScreenCapture {

    /// 调试模式：每张截图保存到相册（调试完成后关闭）
    static var debugSaveToPhotos = false

    static func capture(maxWidth: CGFloat = 600, quality: CGFloat = 0.5) -> UIImage? {
        var attempts = 0
        while attempts < 3 {
            if let raw = captureRaw() {
                let opt = optimize(raw, maxWidth: maxWidth, quality: quality)
                Logger.log("截图成功 \(Int(opt.size.width))x\(Int(opt.size.height))")

                // 调试：保存原始截图到相册
                if debugSaveToPhotos {
                    saveToAlbum(raw)
                }
                return opt
            }
            attempts += 1
            Logger.log("截图失败 重试\(attempts)/3")
            usleep(500000)
        }
        Logger.log("截图彻底失败(3次)")
        return nil
    }

    /// 保存图片到系统相册（调试用）
    static func saveToAlbum(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized else {
                Logger.log("相册权限未授权")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                if success {
                    Logger.log("截图已保存到相册")
                } else {
                    Logger.log("保存相册失败: \(error?.localizedDescription ?? "")")
                }
            }
        }
    }

    // MARK: - IOSurface 截图（解决游戏 GPU 渲染白屏问题）

    /// IOSurface 函数指针类型
    private typealias IOSurfaceLookupFunc = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private typealias IOSurfaceGetWidthFunc = @convention(c) (CFTypeRef) -> Int
    private typealias IOSurfaceGetHeightFunc = @convention(c) (CFTypeRef) -> Int
    private typealias IOSurfaceGetBytesPerRowFunc = @convention(c) (CFTypeRef) -> Int
    private typealias IOSurfaceGetBaseAddressFunc = @convention(c) (CFTypeRef) -> UnsafeMutableRawPointer?
    private typealias IOSurfaceGetPixelFormatFunc = @convention(c) (CFTypeRef) -> UInt32

    private static func captureRaw() -> UIImage? {
        // ── ① IOMobileFramebuffer 帧缓冲（模拟Home+关机键截图）──
        if let img = captureFramebuffer() {
            Logger.log("IOMobileFramebuffer截图成功")
            return img
        }
        // ── ② IOSurface 直接读帧缓冲 ──
        if let img = captureIOSurface() {
            return img
        }
        Logger.log("帧缓冲截图失败，尝试UIGetScreenImage...")

        // ── ② UIGetScreenImage（私有API）──
        if let handle = dlopen(nil, RTLD_NOW) {
            if let fn = dlsym(handle, "UIGetScreenImage") {
                typealias GetScreenFn = @convention(c) () -> Unmanaged<UIImage>?
                let getScreen = unsafeBitCast(fn, to: GetScreenFn.self)
                if let img = getScreen()?.takeUnretainedValue() { dlclose(handle); return img }
                dlclose(handle)
            }
        }
        // ── ③ 降级：本app截图 ──
        guard let w = UIApplication.shared.windows.first else { return nil }
        let r = UIGraphicsImageRenderer(bounds: w.bounds)
        return r.image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: false) }
    }

    // MARK: - IOMobileFramebuffer 截图（模拟Home+关机键）

    /// 通过 IOMobileFramebuffer 获取显示层帧缓冲（等同于系统截图）
    private static func captureFramebuffer() -> UIImage? {
        guard let cgImage = ve_capture_screen() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// 通过 IOSurface 直接读取屏幕帧缓冲，解决 GPU/Metal 渲染游戏白屏问题
    private static func captureIOSurface() -> UIImage? {
        guard let handle = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW) else {
            Logger.log("IOSurface.framework 加载失败")
            return nil
        }
        defer { dlclose(handle) }

        guard let lookupFn = dlsym(handle, "IOSurfaceLookup"),
              let getW = dlsym(handle, "IOSurfaceGetWidth"),
              let getH = dlsym(handle, "IOSurfaceGetHeight"),
              let getBytesPerRow = dlsym(handle, "IOSurfaceGetBytesPerRow"),
              let getBaseAddr = dlsym(handle, "IOSurfaceGetBaseAddress"),
              let getPixelFmt = dlsym(handle, "IOSurfaceGetPixelFormat")
        else {
            Logger.log("IOSurface 函数解析失败")
            return nil
        }

        let lookup = unsafeBitCast(lookupFn, to: IOSurfaceLookupFunc.self)
        let surfW = unsafeBitCast(getW, to: IOSurfaceGetWidthFunc.self)
        let surfH = unsafeBitCast(getH, to: IOSurfaceGetHeightFunc.self)
        let surfBPR = unsafeBitCast(getBytesPerRow, to: IOSurfaceGetBytesPerRowFunc.self)
        let surfBase = unsafeBitCast(getBaseAddr, to: IOSurfaceGetBaseAddressFunc.self)
        let surfFmt = unsafeBitCast(getPixelFmt, to: IOSurfaceGetPixelFormatFunc.self)

        let screenW = Int(UIScreen.main.bounds.width * UIScreen.main.scale)
        let screenH = Int(UIScreen.main.bounds.height * UIScreen.main.scale)

        // 遍历可能的 Surface ID（屏幕通常在小范围内）
        for id in Int32(0)..<Int32(20) {
            guard let surface = lookup(id)?.takeUnretainedValue() else { continue }

            let w = surfW(surface)
            let h = surfH(surface)
            let bpr = surfBPR(surface)
            let fmt = surfFmt(surface)

            // 匹配屏幕尺寸的 BGRA 表面 (kCVPixelFormatType_32BGRA = 'BGRA' = 0x42475241)
            guard w == screenW, h == screenH, bpr >= w * 4, fmt == 0x42475241 else { continue }

            guard let baseAddr = surfBase(surface) else { continue }
            let data = Data(bytes: baseAddr, count: h * bpr)

            guard let provider = CGDataProvider(data: data as CFData) else { continue }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let cgImage = CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            ) else { continue }

            Logger.log("IOSurface ID\(id) 截图成功 \(w)x\(h)")
            return UIImage(cgImage: cgImage)
        }

        return nil
    }

    /// 缩放 + 灰度 + JPEG压缩
    static func optimize(_ image: UIImage, maxWidth: CGFloat, quality: CGFloat) -> UIImage {
        let scale = min(maxWidth / image.size.width, 1.0)
        let newW = Int(image.size.width * scale)
        let newH = Int(image.size.height * scale)
        let rect = CGRect(x: 0, y: 0, width: newW, height: newH)

        // 缩放渲染
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let scaled = UIGraphicsImageRenderer(size: rect.size, format: fmt)
            .image { _ in image.draw(in: rect) }

        // JPEG 压缩
        guard let data = scaled.jpegData(compressionQuality: quality),
              let compressed = UIImage(data: data) else { return scaled }
        return compressed
    }
}

@_silgen_name("UIGetScreenImage")
func UIGetScreenImage() -> Unmanaged<UIImage>?

@_silgen_name("ve_capture_screen")
func ve_capture_screen() -> CGImage?
