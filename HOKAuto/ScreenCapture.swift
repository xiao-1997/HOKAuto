import UIKit
import Accelerate
import Photos

/// 截图工具
struct ScreenCapture {

    /// 调试：保存到相册
    static var debugSaveToPhotos = true

    static func capture(maxWidth: CGFloat = 600, quality: CGFloat = 0.5) -> UIImage? {
        var attempts = 0
        while attempts < 3 {
            if let raw = captureRaw() {
                // 保存原始截图到相册（调试用）
                if debugSaveToPhotos {
                    saveToAlbum(raw)
                }
                let opt = optimize(raw, maxWidth: maxWidth, quality: quality)
                Logger.log("截图成功 \(Int(opt.size.width))x\(Int(opt.size.height))")
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
            guard status == .authorized else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                if success { Logger.log("已保存到相册") }
            }
        }
    }

    // MARK: - 截图策略（5级降级，含故障排查日志）

    private static var diagSocketFail = false
    private static var diagActivatorFail = false
    private static var diagShellFileFail = false
    private static var diagUIGetWhite = false
    private static var diagDrawSelf = false

    private static func captureRaw() -> UIImage? {
        // ① SpringBoard Socket → 需要 Tweak 注入 SpringBoard + Respring
        if let img = captureViaSocket() {
            if diagSocketFail { Logger.log("✅ Socket 已恢复"); diagSocketFail = false }
            return img
        }
        if !diagSocketFail {
            Logger.log("⚠ Socket 连接失败 → Tweak 未注入，需 Respring")
            diagSocketFail = true
        }

        // ② Activator 系统截图 → 等同 Home+Lock，相册取回
        if let img = captureViaActivator() {
            if diagActivatorFail { Logger.log("✅ Activator 已恢复"); diagActivatorFail = false }
            return img
        }
        if !diagActivatorFail {
            Logger.log("⚠ Activator 相册为空 → 需授权相册权限 + 等截图写入")
            diagActivatorFail = true
        }

        // ③ Shell 截图工具 → 直接写文件，不经过相册
        if let img = captureViaShellFile() {
            if diagShellFileFail { Logger.log("✅ Shell 截图已恢复"); diagShellFileFail = false }
            return img
        }
        if !diagShellFileFail {
            Logger.log("⚠ Shell 截图工具不可用 → 需安装 screencapture/snapshot 命令")
            diagShellFileFail = true
        }

        // ④ UIGetScreenImage → 私有 API，Metal 游戏画面纯白
        if let img = captureViaUIGetScreen() {
            if isWhiteImage(img) {
                if !diagUIGetWhite {
                    Logger.log("⚠ UIGetScreenImage 纯白 → 前台是 Metal 游戏，私有 API 失效")
                    diagUIGetWhite = true
                }
            } else {
                if diagUIGetWhite { Logger.log("✅ UIGetScreenImage 已恢复"); diagUIGetWhite = false }
                return img
            }
        }

        // ⑤ drawHierarchy → 仅能截本 app 自身窗口
        if let img = captureViaDrawHierarchy() {
            if !diagDrawSelf {
                Logger.log("❌ 仅截取自身窗口 → 前四层全部故障，跨APP截图不可用")
                diagDrawSelf = true
            }
            return img
        }

        return nil
    }

    /// 检测图片是否接近纯白（Metal 游戏白屏特征）
    private static func isWhiteImage(_ img: UIImage) -> Bool {
        guard let cg = img.cgImage,
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return false }
        let w = cg.width, h = cg.height, bpr = cg.bytesPerRow
        guard w > 0, h > 0 else { return false }
        // 采样检测：取中间行和四角
        var whitePixels = 0, total = 0
        let rows = [0, h/4, h/2, h*3/4, h-1]
        for y in rows {
            for x in stride(from: 0, to: w, by: 10) {
                let off = y * bpr + x * 4
                guard off + 3 < CFDataGetLength(data) else { continue }
                let r = ptr[off], g = ptr[off+1], b = ptr[off+2]
                if r > 240, g > 240, b > 240 { whitePixels += 1 }
                total += 1
            }
        }
        return total > 20 && Float(whitePixels) / Float(total) > 0.9
    }

    // MARK: - ④ UIGetScreenImage

    private static func captureViaUIGetScreen() -> UIImage? {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        guard let fn = dlsym(handle, "UIGetScreenImage") else { dlclose(handle); return nil }
        typealias GetScreenFn = @convention(c) () -> Unmanaged<UIImage>?
        let getScreen = unsafeBitCast(fn, to: GetScreenFn.self)
        let img = getScreen()?.takeUnretainedValue()
        dlclose(handle)
        return img
    }

    // MARK: - ⑤ drawHierarchy

    private static func captureViaDrawHierarchy() -> UIImage? {
        guard let w = UIApplication.shared.windows.first else { return nil }
        let r = UIGraphicsImageRenderer(bounds: w.bounds)
        return r.image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: false) }
    }

    // MARK: - ② Activator 系统截图 → 相册取回

    private static func captureViaActivator() -> UIImage? {
        // 检查相册权限
        let semAuth = DispatchSemaphore(value: 0)
        var hasAuth = false
        PHPhotoLibrary.requestAuthorization { status in
            hasAuth = (status == .authorized || status == .limited)
            semAuth.signal()
        }
        _ = semAuth.wait(timeout: .now() + 2)

        guard hasAuth else {
            Logger.log("⚠ Activator: 相册权限未授予")
            return nil
        }

        let before = Date()

        // 触发系统截图
        shell("su mobile -c 'activator send libactivator.system.screenshot' 2>/dev/null")

        // 轮询相册（最多等8秒，游戏负载大时相册写入慢）
        for i in 0..<16 {
            usleep(500000) // 0.5s
            if let img = fetchPhoto(after: before) {
                Logger.log("  Activator 相册命中 (第\(i+1)次, \(String(format:"%.1f",Double(i+1)*0.5))s)")
                return img
            }
        }
        Logger.log("  Activator 等待8秒仍未在相册找到截图")
        return nil
    }

    private static func fetchPhoto(after date: Date) -> UIImage? {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "creationDate > %@", date as NSDate)
        opts.fetchLimit = 1
        guard let latest = PHAsset.fetchAssets(with: .image, options: opts).firstObject else { return nil }

        let sem = DispatchSemaphore(value: 0)
        var result: UIImage?
        let req = PHImageRequestOptions()
        req.isSynchronous = false
        req.deliveryMode = .highQualityFormat
        PHImageManager.default().requestImage(for: latest, targetSize: PHImageManagerMaximumSize,
                                               contentMode: .default, options: req) { img, _ in
            result = img; sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
        return result
    }

    // MARK: - ③ Shell 截图工具 → 直接写文件，不经过相册

    /// 已知的越狱截图命令行工具（按优先级）
    private static let shellScreenshotCommands: [(cmd: String, path: String)] = [
        // screencapture 来自 sbutils/chromium-ios-screenshot
        ("su mobile -c 'screencapture -x /tmp/hok_shell.jpg 2>/dev/null'", "/tmp/hok_shell.jpg"),
        // snapshot 来自某些越狱工具包
        ("su mobile -c 'snapshot /tmp/hok_shell.png 2>/dev/null'", "/tmp/hok_shell.png"),
        // activator 直接写文件（部分版本支持）
        ("su mobile -c 'activator send libactivator.system.screenshot-to-file /tmp/hok_shell.jpg 2>/dev/null'", "/tmp/hok_shell.jpg"),
        // 直接调用 screendump
        ("su mobile -c 'screendump /tmp/hok_shell.png 2>/dev/null'", "/tmp/hok_shell.png"),
    ]

    private static func captureViaShellFile() -> UIImage? {
        for (cmd, path) in shellScreenshotCommands {
            // 清理旧文件
            unlink(path)

            shell(cmd)
            usleep(800000) // 0.8s 等待截图写入

            if let img = UIImage(contentsOfFile: path),
               img.size.width > 100, img.size.height > 100,
               !isWhiteImage(img) {
                unlink(path) // 清理
                Logger.log("✅ Shell截图成功: \(cmd.prefix(30))...")
                return img
            }
            unlink(path) // 清理失败文件
        }
        return nil
    }

    private static func shell(_ cmd: String) {
        let a: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(cmd), nil]
        defer { a.forEach { if let p = $0 { free(p) } } }
        var pid: pid_t = 0
        posix_spawn(&pid, "/bin/sh", nil, nil, a, nil)
        var s: Int32 = 0; waitpid(pid, &s, 0)
    }

    // MARK: - ① SpringBoard Socket 截图

    private static let sockPath = "/var/mobile/Library/HOKAuto/cap.sock"

    private static func captureViaSocket() -> UIImage? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        strncpy(&addr.sun_path.0, sockPath, MemoryLayout.size(ofValue: addr.sun_path) - 1)

        let ret = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ret >= 0 else { close(fd); return nil }

        var len: UInt32 = 0
        guard read(fd, &len, 4) == 4, len > 0, len < 5_000_000 else {
            close(fd); return nil
        }

        var data = Data(count: Int(len))
        let bytesRead = data.withUnsafeMutableBytes { buf in
            read(fd, buf.baseAddress!, Int(len))
        }
        close(fd)

        guard bytesRead == Int(len), let img = UIImage(data: data) else { return nil }
        return img
    }

    // MARK: - 图像优化

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
