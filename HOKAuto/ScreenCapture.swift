import UIKit
import Accelerate
import Photos

/// 截图工具
struct ScreenCapture {

    /// 调试模式：每张截图保存到相册（调试完成后关闭）
    static var debugSaveToPhotos = false

    static func capture(maxWidth: CGFloat = 600, quality: CGFloat = 0.5) -> UIImage? {
        var attempts = 0
        while attempts < 3 {
            if let raw = captureRaw() {
                let opt = optimize(raw, maxWidth: maxWidth, quality: quality)
                Logger.log("截图成功 \(Int(opt.size.width))x\(Int(opt.size.height))")

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

    /// 保存到系统相册
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

    private static func captureRaw() -> UIImage? {
        // ① IOMobileFramebuffer + IOSurface（底层帧缓冲，支持Metal游戏）
        if let cg = ve_capture_screen() {
            Logger.log("IOMobileFramebuffer 截图成功")
            return UIImage(cgImage: cg)
        }
        // ② UIGetScreenImage（私有API）
        if let handle = dlopen(nil, RTLD_NOW) {
            if let fn = dlsym(handle, "UIGetScreenImage") {
                typealias GetScreenFn = @convention(c) () -> Unmanaged<UIImage>?
                let getScreen = unsafeBitCast(fn, to: GetScreenFn.self)
                if let img = getScreen()?.takeUnretainedValue() { dlclose(handle); return img }
                dlclose(handle)
            }
        }
        // ③ 降级：本app截图
        guard let w = UIApplication.shared.windows.first else { return nil }
        let r = UIGraphicsImageRenderer(bounds: w.bounds)
        return r.image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: false) }
    }

    /// 缩放 + JPEG压缩
    static func optimize(_ image: UIImage, maxWidth: CGFloat, quality: CGFloat) -> UIImage {
        let scale = min(maxWidth / image.size.width, 1.0)
        let newW = Int(image.size.width * scale)
        let newH = Int(image.size.height * scale)
        let rect = CGRect(x: 0, y: 0, width: newW, height: newH)

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let scaled = UIGraphicsImageRenderer(size: rect.size, format: fmt)
            .image { _ in image.draw(in: rect) }

        guard let data = scaled.jpegData(compressionQuality: quality),
              let compressed = UIImage(data: data) else { return scaled }
        return compressed
    }
}

@_silgen_name("UIGetScreenImage")
func UIGetScreenImage() -> Unmanaged<UIImage>?

@_silgen_name("ve_capture_screen")
func ve_capture_screen() -> CGImage?
