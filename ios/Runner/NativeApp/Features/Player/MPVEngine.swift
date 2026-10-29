//
//  MPVEngine.swift
//  Kazumi
//
//  mpv 内核（LP 3671–3673：放弃 KSPlayer，换 MPVKit + Anime4K）。
//
//  MPVKit 只给 libmpv 的 C 接口，这一层是给它套的 Swift 壳：
//   * 建 mpv 句柄、设选项、按集 loadfile；
//   * 建 OpenGL ES 渲染上下文（GLSL 着色器只认这条渲染路径，Metal 那条不认，
//     而且 mpv 的 Metal 是补丁版）；
//   * 把 time-pos / duration / pause / eof 这些属性推给上层；
//   * 命令封装：seek、倍速、挂/摘 Anime4K 着色器、截图。
//
//  参考实现：MPVKit 自带 demo 的 MPVViewController，以及 Kazumi 现在 iOS 上
//  真在跑的那份 media_kit_video（TextureHW.swift，同样是 OPENGL + EAGLContext）。
//

import Foundation
import GLKit
import Libmpv
import OpenGLES
import UIKit

/// 上层的播放时钟接口：弹幕层只关心「现在播到哪」「在不在播」。
@MainActor
protocol PlayerClockProvider: AnyObject {
    var currentPlaybackTime: Double { get }
    var isPlayingNow: Bool { get }
}

/// 当前文件的编码规格，给「播放信息」半屏页用。
/// 每一项都是「拿得到才有值」，页面拿不到的补「—」。
struct PlaybackInfo: Sendable, Equatable {
    var videoCodec: String? = nil
    var resolution: String? = nil
    var frameRate: String? = nil
    var videoBitrate: String? = nil
    var audioCodec: String? = nil
    var audioChannels: String? = nil
    var sampleRate: String? = nil
    var container: String? = nil
}

/// 一次属性快照，从 mpv 的事件线程递回主线程。
struct MPVSnapshot: Sendable {
    var time: Double
    var duration: Double
    var isPaused: Bool
    var isIdle: Bool
    var hasVideo: Bool
    var ended: Bool
    /// 这一集加载失败时的原因（源挂了、404、403 之类）；成功时是 nil。
    var loadError: String?
    /// 视频的显示尺寸（已算过像素宽高比，mpv 的 dwidth/dheight）。
    /// 弹幕层与控制层要用它算出画面在容器里的真实矩形。
    var videoWidth: Double = 0
    var videoHeight: Double = 0
}

@MainActor
final class MPVEngine {
    private(set) var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    /// 画面和渲染上下文必须共用这一个：两个上下文各画各的，屏幕上什么都出不来。
    let glContext: EAGLContext
    private var pump: MPVEventPump?

    /// 渲染视图（GL 那一层），由容器在 makeUIView 里塞进来。
    weak var glView: MPVGLView?

    var onSnapshot: ((MPVSnapshot) -> Void)?
    /// 这一集**第一帧真的画上屏了**（不是「拿到 video-params」）。
    /// 加载符号要靠它才能一直转到画面出来为止（LP 2026-10-28 第 4 条）。
    var onFirstFrame: (() -> Void)?
    /// 本次加载是否已经报过首帧。
    private var reportedFirstFrame = false
    var onLog: ((String) -> Void)?

    /// 内联画面刚画完时同步回调（主线程、GL 上下文 current）。
    /// 画中画拿这一帧去 `glBlitFramebuffer` 到 CVPixelBuffer，不需要第二个 mpv 上下文。
    var onFrameRendered: (@MainActor (GLint, Int, Int) -> Void)?

    private var lastSnapshot = MPVSnapshot(
        time: 0, duration: 0, isPaused: true, isIdle: true, hasVideo: false, ended: false
    )

    /// 上一次记过的画面几何，变了才写日志（每帧写会把日志冲爆）。
    private var lastGeometry = ""

    init() {
        glContext = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2)!
    }

    // MARK: - 生命周期

    /// 建 mpv 与渲染上下文。只做一次，换集走 `load(url:)`。
    func start() {
        guard handle == nil else { return }
        EAGLContext.setCurrent(glContext)
        defer { EAGLContext.setCurrent(nil) }

        guard let mpv = mpv_create() else {
            onLog?("mpv_create 失败")
            return
        }
        handle = mpv

        // 只留我们自己的控件：mpv 自带的 OSC、输入绑定、终端输出全关掉。
        setOption("vo", "libmpv")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("terminal", "no")
        setOption("osd-level", "0")
        setOption("keep-open", "yes")
        setOption("idle", "yes")
        setOption("audio-display", "no")
        // 独占音频：mpv 的 audiounit 输出每次初始化音频都会自己重设一次会话类别，
        // 而它默认加的是 `mixWithOthers`——混音的会话不会被 iOS 当成「正在播放」，
        // 控制中心 / 锁屏那张卡就永远不出来。开了这个，它不再加 mixWithOthers。
        setOption("audio-exclusive", "yes")
        // 模拟器没有硬解，强行开 videotoolbox 会黑屏（MPVKit demo 同样的判断）。
        // 真机用 auto-safe，跟 main 的 `hardwareDecoder` 默认值一致：它是「只在
        // 确认安全时才开零拷贝互操作」的那一档，比硬写 videotoolbox 稳——
        // 互操作一旦对不上（10bit、双平面这些），出来的就是花屏和发绿发紫。
        #if targetEnvironment(simulator)
        setOption("hwdec", "no")
        #else
        // 用 copy-back 这一档，不走零拷贝互操作：互操作一旦和硬解出来的
        // 帧格式对不上（10bit、双平面），屏幕上的表现就是花屏、发绿发紫、
        // 或者只剩红绿两色（LP 2026-10-28 第 1 条）。copy-back 多一次拷贝，
        // 1080p 这点开销换来画面颜色一定是对的。
        setOption("hwdec", "videotoolbox-copy")
        #endif
        // 逐帧交给我们的 GL 视图，不走独立窗口。渲染 API 在
        // `mpv_render_context_create` 里指定，不用再设 gpu-api（设了会被拒）。
        // 不用 gpu-hq：它的 ewa_lanczos + 去色带很吃 GPU，会掉帧；
        // 真要画质靠 Anime4K 着色器，基础缩放用双线性就够。
        // spline36：动漫放大到 2x 时比双线性明显清楚，1080p 在手机上开销扛得住
        // （Colo 3701；真机还卡再退回双线性）。
        setOption("scale", "spline36")
        setOption("cscale", "spline36")
        setOption("deband", "no")
        setOption("dither-depth", "no")

        let initStatus = mpv_initialize(mpv)
        guard initStatus >= 0 else {
            onLog?("mpv_initialize 失败：\(String(cString: mpv_error_string(initStatus)))")
            return
        }

        // 把 mpv 自己的日志接过来：着色器编译失败、色彩空间、帧格式这些
        // 只有它会说，不订阅就是纯瞎子。
        mpv_request_log_messages(mpv, "warn")

        setupRenderContext(mpv)
        setupEvents(mpv)
    }

    private func setupRenderContext(_ mpv: OpaquePointer) {
        let api = UnsafeMutableRawPointer(
            mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String
        )
        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in MPVEngine.procAddress(name) },
            get_proc_address_ctx: nil
        )
        let created: Int32 = withUnsafeMutablePointer(to: &initParams) { paramsPtr in
            var params = [
                mpv_render_param(
                    type: MPV_RENDER_PARAM_API_TYPE,
                    data: api
                ),
                mpv_render_param(
                    type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                    data: UnsafeMutableRawPointer(paramsPtr)
                ),
                mpv_render_param()
            ]
            return mpv_render_context_create(&renderContext, mpv, &params)
        }
        guard created >= 0, let renderContext else {
            onLog?("mpv 渲染上下文建不起来：\(String(cString: mpv_error_string(created)))")
            return
        }
        onLog?("GL \(glString(GL_RENDERER)) / \(glString(GL_VERSION))")
        self.renderContext = renderContext
        mpv_render_context_set_update_callback(
            renderContext,
            kazumiMPVRenderUpdate,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func setupEvents(_ mpv: OpaquePointer) {
        let pump = MPVEventPump(mpv: mpv) { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        } log: { [weak self] message in
            Task { @MainActor in self?.onLog?(message) }
        }
        self.pump = pump
        pump.start()
    }

    private func apply(_ snapshot: MPVSnapshot) {
        lastSnapshot = snapshot
        onSnapshot?(snapshot)
    }

    // MARK: - 播放

    /// 换集 / 首次起播。UA 与 Referer 规则站点校验，缺一不可。
    func load(url: URL, referer: String?, userAgent: String?) {
        guard handle != nil else { return }
        var headers: [String] = []
        if let userAgent, !userAgent.isEmpty { headers.append("User-Agent: \(userAgent)") }
        if let referer, !referer.isEmpty { headers.append("Referer: \(referer)") }
        // init 之后只能用属性接口改，`mpv_set_option_string` 这时候会被拒。
        setOptionForPlayback("http-header-fields", headers.joined(separator: "\n"))
        // 换集 / 重试都按「接着看」处理：内核里 pause 可能还是上一集留下的 true，
        // 不显式放开，加载完了就停在那儿黑着（LP 2026-10-28 第 4 条「不会自动播放」）。
        reportedFirstFrame = false
        setFlag("pause", false)
        command("loadfile", [url.absoluteString, "replace"])
    }

    func play() {
        setFlag("pause", false)
    }

    func pause() {
        setFlag("pause", true)
    }

    /// 后台播放时把画面通道关掉、回前台再打开。
    ///
    /// 进后台 iOS 不再给画面算渲染周期（GLKView 的 draw 不会发生），但音频时钟
    /// 因为有 `UIBackgroundModes: audio` 会一直走——画面就停在被冻结的那一帧，
    /// 声音已经跑远了，回前台就是音画不同步。关掉 `vid` 让 mpv 只走声音；
    /// 回来打开 `vid` 时，mpv 会在当前音频位置重新选视频轨，画面自己追上声音，
    /// 不需要 seek，也就不会有一声破音。
    func setVideoTrackEnabled(_ enabled: Bool) {
        setOptionForPlayback("vid", enabled ? "auto" : "no")
        if enabled {
            glView?.setNeedsDisplay()
        }
    }

    /// 让 GLKView 立刻重画当前帧（回前台接回内联画面时用）。
    func requestRender() {
        glView?.setNeedsDisplay()
    }

    /// 画中画需要自己驱动出帧时调（后台 UIKit 不会自动给 GLKView 发 draw）。
    /// 直接绑 GLKView 的 drawable 走正常渲染 + 首帧钩子；不 present，
    /// 因为这一帧的消费者是 PiP 的 sample buffer，不是屏幕。
    func renderFrameForPictureInPicture() {
        guard let glView, renderContext != nil else { return }
        let width = glView.drawableWidth
        let height = glView.drawableHeight
        guard width > 0, height > 0 else { return }
        EAGLContext.setCurrent(glContext)
        glView.bindDrawable()
        glViewport(0, 0, GLsizei(width), GLsizei(height))
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        render(in: glView)
    }

    func setSpeed(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        var value = Double(rate)
        mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &value)
    }

    func seek(to time: Double) {
        guard time.isFinite, time >= 0 else { return }
        command("seek", [String(format: "%.3f", time), "absolute"])
    }

    /// 已缓冲到的位置（进度条的缓冲段）。读不到就返回 0。
    var playableTime: Double {
        var value = Double(0)
        guard mpv_get_property(handle, "demuxer-cache-time", MPV_FORMAT_DOUBLE, &value) >= 0 else {
            return 0
        }
        return value.isFinite ? value : 0
    }

    // MARK: - 视频信息

    /// 这一集文件的编码规格。
    ///
    /// 一律按字符串读：mpv 会把数值属性转成文本，省得每种类型各写一遍解析。
    /// 取不到的属性留 nil，由页面补「—」。
    func playbackInfo() -> PlaybackInfo {
        guard handle != nil else { return PlaybackInfo() }
        var info = PlaybackInfo()
        info.videoCodec = stringProperty("video-codec")
        if let width = stringProperty("width").flatMap({ Int($0) }),
           let height = stringProperty("height").flatMap({ Int($0) }) {
            info.resolution = "\(width)×\(height)"
        }
        info.frameRate = stringProperty("container-fps").flatMap(Self.formatFrameRate)
        info.videoBitrate = stringProperty("video-bitrate").flatMap(Self.formatBitrate)
        info.audioCodec = stringProperty("audio-codec-name")
        info.audioChannels = stringProperty("audio-params/channel-count")
        info.sampleRate = stringProperty("audio-params/samplerate").flatMap(Self.formatSampleRate)
        info.container = stringProperty("file-format")
        return info
    }

    /// mpv 现在真正挂着的着色器个数（读 `glsl-shaders` 属性本身，不是我们打算挂几个）。
    /// 「播放信息」里那一行用它，才能分清「没挂上」和「挂了但看不出」。
    func appliedShaderCount() -> Int {
        guard let text = stringProperty("glsl-shaders") else { return 0 }
        return text.split(separator: ",").filter { !$0.isEmpty }.count
    }

    /// 读一个字符串属性。mpv 分配的那块内存必须还回去，否则每开一次信息页漏一点。
    private func stringProperty(_ name: String) -> String? {
        var raw: UnsafeMutablePointer<CChar>?
        guard mpv_get_property(handle, name, MPV_FORMAT_STRING, &raw) >= 0, let raw else {
            return nil
        }
        defer { mpv_free(raw) }
        let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 24.000000 → "24 fps"，23.976 → "23.976 fps"：去掉小数末尾的零，最多留三位。
    private static func formatFrameRate(_ text: String) -> String? {
        guard let fps = Double(text), fps > 0 else { return nil }
        var value = String(format: "%.3f", fps)
        if value.contains(".") {
            while value.hasSuffix("0") { value.removeLast() }
            if value.hasSuffix(".") { value.removeLast() }
        }
        return "\(value) fps"
    }

    /// mpv 给的是 bps，按 kbps 取整显示（不写小数）。
    private static func formatBitrate(_ text: String) -> String? {
        guard let bps = Double(text), bps > 0 else { return nil }
        return String(format: "%.0f kbps", bps / 1000)
    }

    /// 48000 → "48 kHz"，44100 → "44.1 kHz"。
    private static func formatSampleRate(_ text: String) -> String? {
        guard let rate = Double(text), rate > 0 else { return nil }
        let khz = rate / 1000
        let value = rate.truncatingRemainder(dividingBy: 1000) == 0
            ? String(format: "%.0f", khz)
            : String(format: "%.1f", khz)
        return "\(value) kHz"
    }

    // MARK: - 超分着色器

    /// 挂上一整串 Anime4K 着色器，顺序就是数组顺序（照 main 的管线）。
    func setShaders(_ paths: [String]) {
        if paths.isEmpty {
            command("change-list", ["glsl-shaders", "clr", ""])
        } else {
            command("change-list", ["glsl-shaders", "set", paths.joined(separator: ",")])
        }
    }

    // MARK: - 截图

    /// 抓当前这一帧（视频画面，不含 OSD）。mpv 自己出 PNG，写临时文件再读回来。
    func captureFrame() async -> UIImage? {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        command("screenshot-to-file", [path.path, "video"])
        // 截图是异步落盘的，给 mpv 一点时间。
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(40))
            if let data = try? Data(contentsOf: path), let image = UIImage(data: data) {
                try? FileManager.default.removeItem(at: path)
                return image
            }
        }
        return nil
    }

    // MARK: - 收尾

    func stop() {
        pump?.stop()
        pump = nil
        if let renderContext {
            mpv_render_context_free(renderContext)
        }
        renderContext = nil
        if let handle {
            mpv_terminate_destroy(handle)
        }
        handle = nil
    }

    // MARK: - 小工具

    /// 播放中改的选项（画面填充方式这类）：走属性，当场生效。
    func setOptionForPlayback(_ name: String, _ value: String) {
        guard let handle else { return }
        let status = mpv_set_property_string(handle, name, value)
        if status < 0 {
            onLog?("设属性 \(name) 失败：\(String(cString: mpv_error_string(status)))")
        }
    }

    private func setOption(_ name: String, _ value: String) {
        let status = mpv_set_option_string(handle, name, value)
        if status < 0 {
            onLog?("设选项 \(name) 失败：\(String(cString: mpv_error_string(status)))")
        }
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        var value: Int32 = flag ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &value)
    }

    private func command(_ name: String, _ args: [String?] = []) {
        guard let handle else { return }
        var strings: [String?] = [name]
        strings.append(contentsOf: args)
        strings.append(nil)
        var cargs = strings.map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }
        let status = mpv_command(handle, &cargs)
        if status < 0 {
            onLog?("命令 \(name) 失败：\(String(cString: mpv_error_string(status)))")
        }
    }

    /// 渲染时把画面画进当前 FBO。
    func render(in view: GLKView) {
        guard let renderContext else { return }
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        // 0×0 的 FBO 交给 mpv，缩放算出来是 NaN，画面就是一坨。
        guard viewport[2] > 0, viewport[3] > 0 else { return }
        logGeometryOnce(view: view, viewport: viewport)
        var data = mpv_opengl_fbo(
            fbo: Int32(fbo),
            w: Int32(viewport[2]),
            h: Int32(viewport[3]),
            // 这里要的是 internal format 常量，不是 sized enum。
            // 传错会让 mpv 按错误格式写 FBO，画中画 blit 也会跟着错。
            internal_format: GLint(GL_RGBA)
        )
        var flip: CInt = 1
        withUnsafeMutablePointer(to: &flip) { flipPtr in
            withUnsafeMutablePointer(to: &data) { dataPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: dataPtr),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                    mpv_render_param()
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
        // 告诉 mpv 这一帧确实上屏了：不报的话它按「还没显示」算，帧会被丢。
        mpv_render_context_report_swap(renderContext)
        // 画面还在当前 FBO 里，趁没被下一帧覆盖交给画中画拷走。
        onFrameRendered?(fbo, Int(viewport[2]), Int(viewport[3]))
        if !reportedFirstFrame {
            reportedFirstFrame = true
            let callback = onFirstFrame
            Task { @MainActor in callback?() }
        }
    }

    /// 花屏、错位、色偏时先对这四个数：报给 mpv 的 FBO 尺寸必须等于真实的
    /// 可绘制尺寸。差一半是缩放错，宽高互换就是整块画面被当竖的贴上去，
    /// 色度跟着错位还会发绿发紫。
    private func logGeometryOnce(view: GLKView, viewport: [GLint]) {
        let geometry = "fbo \(viewport[2])×\(viewport[3]) drawable \(view.drawableWidth)×\(view.drawableHeight) bounds \(Int(view.bounds.width))×\(Int(view.bounds.height))@\(view.contentScaleFactor)"
        guard geometry != lastGeometry else { return }
        lastGeometry = geometry
        onLog?("画面尺寸 \(geometry)")
    }

    private func glString(_ name: Int32) -> String {
        guard let raw = glGetString(GLenum(name)) else { return "?" }
        return String(cString: UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self))
    }

    static func procAddress(_ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
        let symbol = CFStringCreateWithCString(
            kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue
        )
        let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengles" as CFString)
        return CFBundleGetFunctionPointerForName(bundle, symbol)
    }
}

/// 在 mpv 自己的线程上收事件，攒成快照再递回主线程。
final class MPVEventPump: @unchecked Sendable {
    private let mpv: OpaquePointer
    private let queue = DispatchQueue(label: "kazumi.mpv.events", qos: .userInteractive)
    private let onSnapshot: @Sendable (MPVSnapshot) -> Void
    private let onLog: @Sendable (String) -> Void
    private var running = false
    private var ticker: DispatchSourceTimer?
    /// 最近一次加载失败的原因；成功起播后清掉。
    private var lastError: String?
    /// 这一集的格式参数只记一次。
    private var loggedVideoInfo = false

    init(
        mpv: OpaquePointer,
        onSnapshot: @escaping @Sendable (MPVSnapshot) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.mpv = mpv
        self.onSnapshot = onSnapshot
        onLog = log
    }

    func start() {
        // 这些属性一变就唤醒，醒来统一读一遍值，比逐个解析事件结构省事。
        for name in ["time-pos", "duration", "pause", "eof-reached", "core-idle", "video-params"] {
            let status = mpv_observe_property(mpv, 0, name, MPV_FORMAT_NONE)
            if status < 0 {
                onLog("observe \(name) 失败：\(String(cString: mpv_error_string(status)))")
            }
        }
        mpv_set_wakeup_callback(
            mpv,
            { ctx in
                guard let ctx else { return }
                let pump = Unmanaged<MPVEventPump>.fromOpaque(ctx).takeUnretainedValue()
                pump.signal()
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        running = true
        // 不依赖 mpv 的唤醒回调：实测这条回调在这套静态库里一次都不来，
        // 改用固定节拍读属性。250ms 对进度条和暂停状态足够，也不费电。
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.drain()
        }
        timer.resume()
        ticker = timer
        Task { @MainActor in
            KazumiLogBuffer.shared.append("事件泵已启动（定时读属性）", category: .player)
        }
    }

    func stop() {
        running = false
        ticker?.cancel()
        ticker = nil
        mpv_set_wakeup_callback(mpv, nil, nil)
    }

    fileprivate func signal() {
        guard running else { return }
        MPVEventPump.debugLog("wakeup")
        queue.async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        while true {
            guard let event = mpv_wait_event(mpv, 0) else { return }
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE { break }
            if id == MPV_EVENT_SHUTDOWN { return }
            if id == MPV_EVENT_END_FILE, let raw = event.pointee.data {
                let endFile = UnsafeMutablePointer<mpv_event_end_file>(OpaquePointer(raw))
                if endFile.pointee.reason == MPV_END_FILE_REASON_ERROR {
                    let message = String(cString: mpv_error_string(endFile.pointee.error))
                    lastError = "播放失败：\(message)"
                    onLog("end-file 错误：\(message)")
                }
            }
            if id == MPV_EVENT_LOG_MESSAGE, let raw = event.pointee.data {
                let message = UnsafeMutablePointer<mpv_event_log_message>(
                    OpaquePointer(raw)
                )
                let text = String(cString: message.pointee.text)
                let prefix = String(cString: message.pointee.prefix)
                onLog("[\(prefix)] \(text)")
            }
        }
        var snap = snapshot()
        if snap.hasVideo { lastError = nil }
        // 第一帧出来的时候把源的真实格式记下来：位深、矩阵、范围这三样
        // 直接决定颜色对不对，pixelformat 里带 10 就是 10bit 片源。
        if snap.hasVideo, !loggedVideoInfo {
            loggedVideoInfo = true
            onLog("片源 \(videoInfoLine())")
        }
        snap.loadError = lastError
        MPVEventPump.debugLog("snap t=\(snap.time) d=\(snap.duration) paused=\(snap.isPaused) idle=\(snap.isIdle) video=\(snap.hasVideo) err=\(lastError ?? "-")")
        onSnapshot(snap)
    }

    /// 临时排查用：把快照值写进运行日志。
    nonisolated(unsafe) private static var debugCount = 0
    private static func debugLog(_ message: String) {
        debugCount += 1
        guard debugCount % 20 == 1 else { return }
        Task { @MainActor in
            KazumiLogBuffer.shared.append(message, category: .player)
        }
    }

    private func videoInfoLine() -> String {
        func text(_ name: String) -> String {
            guard let raw = mpv_get_property_string(mpv, name) else { return "?" }
            defer { mpv_free(raw) }
            return String(cString: raw)
        }
        return "fmt=\(text("video-format")) px=\(text("video-params/pixelformat")) 矩阵=\(text("video-params/colormatrix")) 原色=\(text("video-params/primaries")) 伽马=\(text("video-params/gamma")) 位深=\(text("video-params/plane-depth")) hwdec=\(text("hwdec-current"))"
    }

    private func snapshot() -> MPVSnapshot {
        var time = Double(0)
        mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &time)
        var duration = Double(0)
        mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &duration)
        var paused: Int32 = 1
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused)
        var idle: Int32 = 0
        mpv_get_property(mpv, "core-idle", MPV_FORMAT_FLAG, &idle)
        var ended: Int32 = 0
        mpv_get_property(mpv, "eof-reached", MPV_FORMAT_FLAG, &ended)
        var params = mpv_node()
        let hasVideo = mpv_get_property(mpv, "video-params", MPV_FORMAT_NODE, &params) >= 0
        mpv_free_node_contents(&params)
        // 画面尺寸：dwidth/dheight 是「实际显示」的尺寸（anamorphic 也算过），
        // 拿不到就退回 width/height。全 0 表示还没有画面，上层回落到整块容器。
        var videoWidth: Int64 = 0
        var videoHeight: Int64 = 0
        mpv_get_property(mpv, "dwidth", MPV_FORMAT_INT64, &videoWidth)
        mpv_get_property(mpv, "dheight", MPV_FORMAT_INT64, &videoHeight)
        if videoWidth <= 0 || videoHeight <= 0 {
            mpv_get_property(mpv, "width", MPV_FORMAT_INT64, &videoWidth)
            mpv_get_property(mpv, "height", MPV_FORMAT_INT64, &videoHeight)
        }
        return MPVSnapshot(
            time: time.isFinite ? time : 0,
            duration: duration.isFinite ? duration : 0,
            isPaused: paused > 0,
            isIdle: idle > 0,
            hasVideo: hasVideo,
            ended: ended > 0,
            videoWidth: videoWidth > 0 ? Double(videoWidth) : 0,
            videoHeight: videoHeight > 0 ? Double(videoHeight) : 0
        )
    }
}

/// mpv 有新帧时的回调。必须是文件级函数：`@convention(c)` 的函数指针不能捕获上下文。
private func kazumiMPVRenderUpdate(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let engine = Unmanaged<MPVEngine>.fromOpaque(ctx).takeUnretainedValue()
    Task { @MainActor in
        engine.glView?.setNeedsDisplay()
    }
}
