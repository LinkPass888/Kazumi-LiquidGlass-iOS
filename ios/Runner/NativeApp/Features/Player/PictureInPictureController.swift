//
//  PictureInPictureController.swift
//  Kazumi
//
//  后台自动画中画（设置里的 `backgroundAutoPiP`，默认开启）。
//
//  为什么不能直接把内联画面交给系统：libmpv 只把画面画进我们自己的 GL FBO，
//  系统拿不到帧，PiP 要的是 `AVSampleBufferDisplayLayer` 能吃的 `CMSampleBuffer`。
//
//  这里的做法不是再开一个 mpv 渲染上下文（mpv 每个 core 同时只允许一个），
//  而是在**同一帧画完以后**，用 `glBlitFramebuffer` 把 GLKView 当前 FBO 里的
//  画面 GPU 拷贝到一块 `CVPixelBuffer` 支持的纹理上，再包成 sample buffer。
//  画面仍然走原来的内联渲染路径：不换上下文、不关视频轨、不 seek，
//  所以前台后台都是同一份时钟，也没有交接空窗。
//
//  设置关掉时这个文件里的对象一个都不会建：没有取帧器、没有 PiP 控制器、
//  没有定时器，行为与加这个功能之前完全一样。
//

import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Libmpv
import OpenGLES
import QuartzCore
import UIKit

/// 负责「什么时候进 / 出画中画」以及和播放页对接的那一层。
///
/// 所有 UI / GL 操作都在主线程：取帧发生在 `MPVEngine.render(in:)` 的同一个
/// GL 上下文里，不能挪到别的队列。
@MainActor
final class PictureInPictureController: NSObject {
    /// 画中画显示的图层。它必须真的挂在窗口里、有非零尺寸，系统才肯让 PiP 起来。
    private let hostView = PiPHostView()
    private var pipController: AVPictureInPictureController?

    /// 把内联 GL 帧拷到 CVPixelBuffer 并喂给画中画图层。
    private var copier: PiPFrameCopier?

    /// 播放页那只画面模型与引擎（弱引用：播放页拆掉时不拖住它们）。
    private weak var surface: PlayerSurfaceModel?
    private weak var engine: MPVEngine?

    /// 后台时手动驱动 GLKView 出帧的节拍。
    private var captureTimer: DispatchSourceTimer?

    /// 等 `isPictureInPicturePossible` 变 true 的那次尝试。
    private var startTask: Task<Void, Never>?

    /// 系统已经确认画中画窗口起来了。
    private(set) var isActive = false

    /// 出问题时给播放页的日志行。
    var onLog: ((String) -> Void)?

    /// 画中画没起来（设备不支持 / 图层不在窗口 / 系统拒绝）。
    /// 页面据此退回原来的「后台播放」策略，不至于设置开着却没声音也没画面。
    var onFailed: (() -> Void)?

    /// 用户从系统画中画窗口里关掉画面、而 App 还在后台。
    /// 没开「后台继续播放音频」时页面应该把声音停掉，别让黑屏后面继续响。
    var onStoppedInBackground: (() -> Void)?

    private var didReportFailure = false

    // MARK: - 准备

    /// 提前把图层挂进窗口、把取帧钩子装到引擎上。
    ///
    /// 系统的「自动画中画」要求内联内容在切后台**之前**就存在，
    /// 等 `scenePhase == .background` 再临时创建往往来不及（也会让
    /// `isPictureInPicturePossible` 一直是 false）。所以设置开着时在起播后调一次。
    func prepare(engine: MPVEngine?, surface: PlayerSurfaceModel) {
        self.engine = engine
        self.surface = surface
        guard ensureController() else { return }
        attachHostIfNeeded()
        guard let engine else { return }

        if copier == nil {
            let copier = PiPFrameCopier(
                mpv: engine.handle,
                context: engine.glContext,
                displayLayer: hostView.displayLayer
            )
            copier.onLog = { [weak self] message in
                self?.log(message)
            }
            self.copier = copier
        }

        // 播放器一打开就开始喂画面（低频），不要等小窗要起了才喂。
        //
        // 原来是「小窗要起的时候才 beginCapture」，于是第一次退后台时图层里一帧都还没有，
        // `isPictureInPicturePossible` 一直是 false，小窗起不来；等那一轮拷过帧之后，
        // 下一次退后台才成功——正好就是「第一次不出、再退出反而出了」。
        copier?.beginCapture()

        // 钩子只装一次；`isCapturing` 由 prepare / teardown 控制。
        engine.onFrameRendered = { [weak self] fbo, width, height, videoWidth, videoHeight in
            self?.copier?.capture(
                sourceFBO: fbo,
                sourceWidth: width,
                sourceHeight: height,
                videoWidth: videoWidth,
                videoHeight: videoHeight
            )
        }
    }

    /// 切后台时调用。返回 false 表示这次没法走画中画，页面应退回原有的后台策略。
    @discardableResult
    func start(engine: MPVEngine?, surface: PlayerSurfaceModel) -> Bool {
        guard surface.isPlaying else {
            log("没有在播放，不起画中画")
            return false
        }
        guard let engine, engine.handle != nil else {
            log("mpv 句柄还没建好，起不了画中画")
            return false
        }
        guard ensureController(), attachHostIfNeeded() else { return false }

        self.engine = engine
        self.surface = surface
        didReportFailure = false
        if copier == nil {
            prepare(engine: engine, surface: surface)
        }
        guard copier != nil else {
            log("取帧器没建起来，画中画不可用")
            onFailed?()
            return false
        }

        // 后台 UIKit 不会主动给 GLKView 发 draw，这里自己按 30Hz 驱动；
        // 前台时多出来的 display 也只是重画当前帧，不改变播放状态。
        beginCapture()

        // `canStartPictureInPictureAutomaticallyFromInline` 通常会在退后台时自己起；
        // 这里显式再拉一次兜底（自动路径不触发、或系统正处在 app switcher 的过渡里）。
        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            // `isPictureInPicturePossible` 要等图层真正上屏、时序稳定后才变 true，
            // 退后台那一刻往往还是 false，所以轮询一小段时间而不是只看一次。
            for attempt in 0..<30 {
                guard !Task.isCancelled, let self, let controller = self.pipController else { return }
                if controller.isPictureInPictureActive { return }
                if controller.isPictureInPicturePossible {
                    controller.startPictureInPicture()
                    return
                }
                if attempt == 29 {
                    self.log("画中画一直不可用（isPictureInPicturePossible = false）")
                    self.finishStopping()
                    self.reportFailure()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return true
    }

    /// 回前台 / 离开播放器时调用：停掉画中画和取帧节拍。内联 GL 一直没停过，
    /// 回到前台直接继续画，不 seek、不重启。
    func stop() {
        startTask?.cancel()
        startTask = nil
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        finishStopping()
        // 内联 GL 一直在画，但回前台这一刻可能没有新帧事件；主动要一帧，
        // 让画面立刻从 PiP 接回来（位置就是 mpv 当前的同一个时钟）。
        engine?.requestRender()
    }

    /// 彻底拆掉（离开播放器、或设置被关掉）。下次需要时重新建。
    func teardown() {
        startTask?.cancel()
        startTask = nil
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        pipController?.delegate = nil
        pipController = nil
        engine?.onFrameRendered = nil
        captureTimer?.cancel()
        captureTimer = nil
        copier?.teardown()
        copier = nil
        hostView.removeFromSuperview()
        isActive = false
        surface = nil
        engine = nil
        onFailed = nil
        onStoppedInBackground = nil
    }

    /// 画中画是否真的在显示（物理按钮 / 系统关闭都算）。
    var isPictureInPictureActive: Bool {
        pipController?.isPictureInPictureActive == true
    }

    // MARK: - 组装

    private func ensureController() -> Bool {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log("这台设备 / 这个系统不支持画中画")
            return false
        }
        if pipController == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: hostView.displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            // 设置开着才有这个对象；允许系统在退后台时自动起，不用用户手点。
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            pipController = controller
        }
        return true
    }

    @discardableResult
    private func attachHostIfNeeded() -> Bool {
        guard hostView.superview == nil else { return true }
        guard let window = Self.keyWindow() else {
            log("找不到窗口，画中画图层没地方挂")
            return false
        }
        // 非零尺寸 + 在窗口里是硬要求；alpha 压到几乎透明并插到最底层，
        // 用户看不到它，但系统仍然认为这是一块可用的内联画面。
        hostView.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        hostView.autoresizingMask = [.flexibleRightMargin, .flexibleBottomMargin]
        window.insertSubview(hostView, at: 0)
        return true
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    // MARK: - 取帧节拍

    private func beginCapture() {
        copier?.beginCapture()
        guard captureTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(33),
            leeway: .milliseconds(5)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.engine?.renderFrameForPictureInPicture()
            }
        }
        timer.resume()
        captureTimer = timer
    }

    private func finishStopping() {
        startTask?.cancel()
        startTask = nil
        // 只停「自己驱动渲染」的那条节拍；喂帧本身继续留着。
        // 停了它，回前台之后图层就又没有新帧了，下一次退后台照样起不来小窗。
        captureTimer?.cancel()
        captureTimer = nil
        isActive = false
    }

    private func reportFailure() {
        guard !didReportFailure else { return }
        didReportFailure = true
        onFailed?()
    }

    private func log(_ message: String) {
        onLog?(message)
        KazumiLogBuffer.player("画中画: \(message)")
    }
}

// MARK: - AVKit 回调

// AVKit 这两个 delegate 在 SDK 里没有标 `@MainActor`，但回调都从主线程来。
// 用 `@preconcurrency` 声明这条一致性：不把整套实现改成 `nonisolated`，
// 也就不会在回调里丢掉主线程隔离（Swift 6 会按 @MainActor 检查）。
extension PictureInPictureController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        // 系统自动起 PiP 时不会先走我们的 start()，这里补上取帧节拍。
        beginCapture()
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isActive = true
        // 小窗真的在显示了才用满帧率；平时低频喂着就够。
        copier?.captureInterval = 1.0 / 30.0
        log("画中画已启动")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isActive = false
        log("画中画启动失败：\(error.localizedDescription)")
        finishStopping()
        reportFailure()
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        // 等 didStop 再收：关闭动画期间 sample buffer 还应该能继续进来。
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isActive = false
        // 收回低频：内联播放时不需要 30Hz 的额外拷贝。
        copier?.captureInterval = 1.0 / 10.0
        if UIApplication.shared.applicationState == .background {
            // 用户自己点了画中画窗口的关闭键、App 还在后台：画面没了。
            // 没开后台音频就停声；开着则继续当音频播放器用。
            onStoppedInBackground?()
        }
        finishStopping()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void
    ) {
        // 播放页一直都在（画中画是从它起来的），不需要额外恢复界面。
        completionHandler(true)
    }
}

extension PictureInPictureController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    /// 画中画那条进度条能拖的范围。时长还没拿到时给一个无限范围，
    /// 系统会按直播 / 未知时长处理，而不是画一条 0 秒的假进度。
    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        guard let surface, surface.duration.isFinite, surface.duration > 0 else {
            return CMTimeRange(start: .zero, duration: .positiveInfinity)
        }
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: surface.duration, preferredTimescale: 600)
        )
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        surface?.isPlaying != true
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // 系统窗口里的播放 / 暂停直接落到现有 surface，音频、控制中心、
        // 内联控件看到的都是同一份状态。
        guard let surface else { return }
        if playing {
            surface.play()
        } else {
            surface.pause()
        }
        // 播放 / 暂停状态变了，让系统重新向 delegate 取一次状态。
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // 画中画窗口换了大小（用户缩放 / 转屏）。帧固定按源比例送，
        // 由图层缩放，这里不需要重建缓冲。
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        guard let surface else {
            completionHandler()
            return
        }
        let seconds = CMTimeGetSeconds(skipInterval)
        guard seconds.isFinite, seconds != 0 else {
            completionHandler()
            return
        }
        // 不在这里等画面：seek 之后 mpv 出帧，下一拍自己会送过去。
        let target = max(0, surface.currentTime + seconds)
        surface.seek(to: target)
        // 完成回调返回前，时基必须已经反映目标时间；旧帧也要先扔掉，
        // 否则系统会拿旧时间点去画进度条 / 处理下一次快进。
        copier?.prepareForSeek(to: target, paused: !surface.isPlaying)
        pictureInPictureController.invalidatePlaybackState()
        completionHandler()
    }
}

// MARK: - 图层的宿主

/// 里面就是一块 `AVSampleBufferDisplayLayer`。
/// 用 `layerClass` 而不是把 layer 塞进 sublayer：PiP 要的正是这个 view 的根 layer。
private final class PiPHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // layerClass 已经定死，这里的强制转换不会失败。
        layer as! AVSampleBufferDisplayLayer
    }

    init() {
        super.init(frame: .zero)
        // 320×180 是给系统的「内联画面」，不是给用户看的：几乎全透明、放在最底层。
        // 不能 hidden，也不能做成 0×0，否则 PiP 的 content source 不成立。
        backgroundColor = .clear
        alpha = 0.01
        isUserInteractionEnabled = false
        let display = displayLayer
        display.videoGravity = .resizeAspect
        display.backgroundColor = UIColor.clear.cgColor
        display.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - GPU 取帧

/// 把 GLKView 当前 FBO 里的画面 blit 到 CVPixelBuffer 支持的纹理上，
/// 再包成 `CMSampleBuffer` 入队给画中画图层。
///
/// 所有方法都在主线程、且调用时 EAGLContext 已经 current（由 GLKView 保证）。
/// 不持有 mpv 的渲染上下文，只借它的时间戳做 PTS / seek 判断。
@MainActor
private final class PiPFrameCopier {
    private let mpv: OpaquePointer?
    private let context: EAGLContext
    private let displayLayer: AVSampleBufferDisplayLayer

    var onLog: ((String) -> Void)?
    private(set) var isCapturing = false

    /// 两次拷贝之间至少隔多久。平时（还没进小窗）低频喂着，只要图层里有内容、
    /// `isPictureInPicturePossible` 能变 true 就够；小窗真起来了才提到满帧率。
    var captureInterval: Double = 1.0 / 10.0

    private var textureCache: CVOpenGLESTextureCache?
    private var framebuffer: GLuint = 0
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var formatDescription: CMVideoFormatDescription?
    /// 画中画图层的控制时基：PTS 按视频时间轴解释。
    /// 不设的话 `AVSampleBufferDisplayLayer` 会拿 mach_absolute_time 当时间轴，
    /// 媒体时间戳全都落在「过去」，PiP 的进度条和 seek 也会按错误的时间走。
    private var controlTimebase: CMTimebase?

    private var lastPTS = Double.nan
    private var lastVideoTime = Double.nan
    private var lastCaptureHostTime = 0.0
    private var hasCapturedOnce = false
    private var didLogRenderFailure = false
    private var didLogFirstFrame = false

    init(mpv: OpaquePointer?, context: EAGLContext, displayLayer: AVSampleBufferDisplayLayer) {
        self.mpv = mpv
        self.context = context
        self.displayLayer = displayLayer
    }

    // MARK: 生命周期

    func beginCapture() {
        isCapturing = true
        // 上一次 PiP 留下的帧和 PTS 都不能接着用，否则新窗口会从旧时间轴开始。
        displayLayer.flush()
        ensureTimebase()
        // 第一帧到来前别让时基自己往前跑（此时还没有对应的画面）。
        if let controlTimebase {
            CMTimebaseSetRate(controlTimebase, rate: 0)
        }
        lastPTS = .nan
        lastVideoTime = .nan
        lastCaptureHostTime = 0
        hasCapturedOnce = false
    }

    func endCapture() {
        isCapturing = false
        if let controlTimebase {
            CMTimebaseSetRate(controlTimebase, rate: 0)
        }
    }

    /// 用户在 PiP 里拖进度条 / 点快进：先把旧帧和旧时基清掉，
    /// 再让时基直接落到目标位置，这样完成回调返回时系统看到的时间是对的。
    func prepareForSeek(to seconds: Double, paused: Bool) {
        displayLayer.flush()
        lastPTS = .nan
        lastVideoTime = .nan
        syncTimebase(to: seconds, paused: paused)
    }

    /// 把 `AVSampleBufferDisplayLayer` 的时基对齐到视频时间轴。
    /// 播放时 rate=1，暂停时 rate=0，时间点始终是 mpv 的 `time-pos`。
    func syncTimebase(to seconds: Double, paused: Bool) {
        guard seconds.isFinite else { return }
        ensureTimebase()
        guard let controlTimebase else { return }
        CMTimebaseSetTime(
            controlTimebase,
            time: CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        )
        CMTimebaseSetRate(controlTimebase, rate: paused ? 0 : 1)
    }

    private func ensureTimebase() {
        guard controlTimebase == nil else { return }
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithMasterClock(
            allocator: kCFAllocatorDefault,
            masterClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        guard status == noErr, let timebase else {
            logOnce("画中画时基创建失败：\(status)")
            return
        }
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0)
        displayLayer.controlTimebase = timebase
        controlTimebase = timebase
    }

    /// 在引擎销毁 / 播放页退出前调用。GL 资源必须在 EAGLContext current 时删。
    func teardown() {
        isCapturing = false
        let previous = EAGLContext.current()
        EAGLContext.setCurrent(context)
        if framebuffer != 0 {
            glDeleteFramebuffers(1, &framebuffer)
            framebuffer = 0
        }
        if let textureCache {
            CVOpenGLESTextureCacheFlush(textureCache, 0)
        }
        textureCache = nil
        displayLayer.controlTimebase = nil
        controlTimebase = nil
        EAGLContext.setCurrent(previous)
        pixelBufferPool = nil
        poolSize = .zero
        formatDescription = nil
    }

    // MARK: 每帧

    /// 由 `MPVEngine.render(in:)` 在 mpv 画完当前 FBO 后同步调用。
    func capture(
        sourceFBO: GLint,
        sourceWidth: Int,
        sourceHeight: Int,
        videoWidth: Double,
        videoHeight: Double
    ) {
        guard isCapturing, sourceWidth > 1, sourceHeight > 1 else { return }

        let hostNow = CACurrentMediaTime()
        guard lastCaptureHostTime == 0 || hostNow - lastCaptureHostTime >= captureInterval else {
            return
        }
        lastCaptureHostTime = hostNow

        let time = videoTime()
        let paused = isPaused()
        if paused {
            // 暂停期间没有新帧：把时基钉在最后一帧，进度条不会自己往前爬。
            freezeTimebaseAtLastFrame()
        }
        if paused, hasCapturedOnce, lastPTS.isFinite, time.isFinite,
           abs(time - lastPTS) < 0.05 {
            // 暂停且这个时间点已经成功送过：mpv 不会给新帧，重复入队只会糊满图层。
            return
        }

        // 只拷画面那一块：容器里画面之外是黑边（16:9 的番放在更宽的屏幕里、
        // 或者用户选了别的画面比例），整块容器拷过去会把黑边一起送进小窗，
        // 小窗就变成「比例不对、两边有黑边」。拿不到画面尺寸时退回整块。
        let rect = videoRect(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            videoWidth: videoWidth,
            videoHeight: videoHeight
        )
        let size = targetSize(sourceWidth: Int(rect.width), sourceHeight: Int(rect.height))
        guard let pixelBuffer = makePixelBuffer(width: size.width, height: size.height) else {
            logOnce("CVPixelBuffer 分配失败")
            return
        }

        // 往回 seek：旧 PTS 还在图层队列里，先清掉；新时间轴重新起。
        if time.isFinite, lastVideoTime.isFinite, time + 0.5 < lastVideoTime {
            displayLayer.flush()
            lastPTS = .nan
        }

        guard blit(sourceFBO: sourceFBO, rect: rect, pixelBuffer: pixelBuffer) else {
            return
        }

        let pts = time.isFinite ? max(0, time) : (lastPTS.isFinite ? lastPTS + 1.0 / 30.0 : 0)
        if lastPTS.isFinite, pts <= lastPTS {
            // 同一个时间点已经送过：再送只会让 PiP 的 PTS 越走越快。
            return
        }

        guard let sampleBuffer = makeSampleBuffer(pixelBuffer: pixelBuffer, presentationTime: pts) else {
            logOnce("CMSampleBuffer 创建失败")
            return
        }

        // 先对时基再入队：这一帧的 PTS 正好是时基当前时间，系统会立即显示，
        // 后面的进度条 / 快进也都在媒体时间轴上。
        syncTimebase(to: pts, paused: paused)
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        guard displayLayer.isReadyForMoreMediaData else { return }
        displayLayer.enqueue(sampleBuffer)
        // 只有真正进了图层队列才更新去重状态：被丢弃的一帧下一拍还要再试。
        lastPTS = pts
        lastVideoTime = time
        hasCapturedOnce = true
        if !didLogFirstFrame {
            didLogFirstFrame = true
            onLog?("取到第一帧 \(size.width)x\(size.height)")
        }
    }

    // MARK: GPU blit

    private func blit(
        sourceFBO: GLint,
        rect: CGRect,
        pixelBuffer: CVPixelBuffer
    ) -> Bool {
        guard let cache = ensureTextureCache() else { return false }

        var texture: CVOpenGLESTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            GLenum(GL_TEXTURE_2D),
            GLint(GL_RGBA),
            GLsizei(width),
            GLsizei(height),
            GLenum(GL_BGRA_EXT),
            GLenum(GL_UNSIGNED_BYTE),
            0,
            &texture
        )
        guard status == kCVReturnSuccess, let texture else {
            logOnce("CVPixelBuffer 纹理创建失败：\(status)")
            return false
        }

        var previousFBO: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &previousFBO)
        var previousViewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &previousViewport)

        if framebuffer == 0 {
            glGenFramebuffers(1, &framebuffer)
        }
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), framebuffer)
        glFramebufferTexture2D(
            GLenum(GL_DRAW_FRAMEBUFFER),
            GLenum(GL_COLOR_ATTACHMENT0),
            GLenum(GL_TEXTURE_2D),
            CVOpenGLESTextureGetName(texture),
            0
        )
        let framebufferStatus = glCheckFramebufferStatus(GLenum(GL_DRAW_FRAMEBUFFER))
        guard framebufferStatus == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(previousFBO))
            restoreViewport(previousViewport)
            logOnce("画中画 FBO 不完整：0x\(String(framebufferStatus, radix: 16))")
            return false
        }

        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(sourceFBO))
        // 先清掉之前残留的 GL 错误，否则这里会把别人的错误算到 blit 头上。
        while glGetError() != GLenum(GL_NO_ERROR) {}
        // 源 FBO 是给屏幕看的（mpv 用 FLIP_Y=1 画的），所以 GL 的 y=0 是画面底部。
        // CVPixelBuffer 反过来：内存第 0 行被 AVFoundation 当成画面顶部。
        // 目标 y 反向写，正好让源底部落到 PixelBuffer 的最后一行（画面底部）。
        glBlitFramebuffer(
            GLint(rect.minX), GLint(rect.minY),
            GLint(rect.maxX), GLint(rect.maxY),
            0, GLsizei(height), GLsizei(width), 0,
            GLbitfield(GL_COLOR_BUFFER_BIT),
            GLenum(GL_LINEAR)
        )
        let blitError = glGetError()

        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(previousFBO))
        restoreViewport(previousViewport)

        guard blitError == GLenum(GL_NO_ERROR) else {
            logOnce("画中画 blit 失败：0x\(String(blitError, radix: 16))")
            return false
        }

        // 这块 CVPixelBuffer 接下来要给 AVFoundation 读，必须等 GPU 真写完。
        glFinish()
        CVOpenGLESTextureCacheFlush(cache, 0)
        return true
    }

    private func ensureTextureCache() -> CVOpenGLESTextureCache? {
        if let textureCache { return textureCache }
        var cache: CVOpenGLESTextureCache?
        let status = CVOpenGLESTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            context,
            nil,
            &cache
        )
        guard status == kCVReturnSuccess, let cache else {
            logOnce("CVOpenGLESTextureCache 创建失败：\(status)")
            return nil
        }
        textureCache = cache
        return cache
    }

    private func restoreViewport(_ viewport: [GLint]) {
        guard viewport.count == 4 else { return }
        glViewport(viewport[0], viewport[1], viewport[2], viewport[3])
    }

    // MARK: 像素缓冲与 sample buffer

    /// 画面在容器里的矩形（GL 坐标，y 从底往上）。
    ///
    /// mpv 按 `keepaspect` 把画面居中放进 FBO，画面之外是黑边。画中画只该拷这个矩形：
    /// 拷贝整块容器会把黑边一起带进小窗，看起来就是「比例不对、两边有黑边」。
    /// 拿不到画面尺寸（还没出第一帧）时退回整块容器。
    private func videoRect(
        sourceWidth: Int,
        sourceHeight: Int,
        videoWidth: Double,
        videoHeight: Double
    ) -> CGRect {
        guard videoWidth > 1, videoHeight > 1 else {
            return CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        }
        let scale = min(Double(sourceWidth) / videoWidth, Double(sourceHeight) / videoHeight)
        let width = (videoWidth * scale).rounded()
        let height = (videoHeight * scale).rounded()
        // 宽高取偶数：CVPixelBuffer 的 4:2:0 兼容性、以及奇数列在缩放时容易出锯齿。
        let evenWidth = max(2, min(Double(sourceWidth), width - width.truncatingRemainder(dividingBy: 2)))
        let evenHeight = max(2, min(Double(sourceHeight), height - height.truncatingRemainder(dividingBy: 2)))
        let x = ((Double(sourceWidth) - evenWidth) / 2).rounded()
        let y = ((Double(sourceHeight) - evenHeight) / 2).rounded()
        return CGRect(x: x, y: y, width: evenWidth, height: evenHeight)
    }

    /// 输出宽度不超过 1280，保持源画面比例，宽高取偶数。
    /// 小窗本身不大，但 640 那一档放大到平板 / 大屏画中画时会糊（LP 抓到画质被压）。
    private func targetSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let scale = min(1.0, 1280.0 / Double(sourceWidth))
        let width = max(2, Int((Double(sourceWidth) * scale).rounded()) & ~1)
        let height = max(2, Int((Double(sourceHeight) * scale).rounded()) & ~1)
        return (width, height)
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        ensurePool(width: width, height: height)
        var buffer: CVPixelBuffer?
        if let pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &buffer)
        }
        // 池子偶尔会一时拿不到（系统内存紧）：直接建一块兜底。
        if buffer == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                Self.bufferAttributes(width: width, height: height) as CFDictionary,
                &buffer
            )
        }
        return buffer
    }

    private func ensurePool(width: Int, height: Int) {
        let size = CGSize(width: width, height: height)
        guard pixelBufferPool == nil || poolSize != size else { return }
        poolSize = size
        formatDescription = nil

        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            Self.bufferAttributes(width: width, height: height) as CFDictionary,
            &pool
        )
        pixelBufferPool = pool
    }

    private static func bufferAttributes(width: Int, height: Int) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // IOSurface 支撑：GPU 能写，系统 PiP 那边也能直接拿。
            // FBO/Texture 两个 compatibility 显式打开，确保这张 IOSurface 不仅能
            // 变成 GL 纹理，还能直接当 FBO 的颜色附件被 blit 写入。
            kCVPixelBufferIOSurfacePropertiesKey as String: [
                kCVPixelBufferIOSurfaceOpenGLESFBOCompatibilityKey as String: true,
                kCVPixelBufferIOSurfaceOpenGLESTextureCompatibilityKey as String: true,
            ],
            // 允许这块 buffer 直接拿来做 GL 纹理。
            kCVPixelBufferOpenGLESCompatibilityKey as String: true,
        ]
    }

    private func makeSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        presentationTime: Double
    ) -> CMSampleBuffer? {
        if formatDescription == nil {
            var description: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            )
            guard status == noErr, let description else { return nil }
            formatDescription = description
        }
        guard let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(
                seconds: presentationTime,
                preferredTimescale: 600
            ),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        // 时基没建起来时只能退回「入队即显示」，否则 PTS 会被当成开机的绝对时间。
        if controlTimebase == nil, let sampleBuffer {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_DisplayImmediately,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        }
        return sampleBuffer
    }

    // MARK: 时间

    private func freezeTimebaseAtLastFrame() {
        guard lastPTS.isFinite, let controlTimebase else { return }
        CMTimebaseSetTime(
            controlTimebase,
            time: CMTime(seconds: max(0, lastPTS), preferredTimescale: 600)
        )
        CMTimebaseSetRate(controlTimebase, rate: 0)
    }

    private func videoTime() -> Double {
        guard let mpv else { return .nan }
        var value = Double(0)
        guard mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &value) >= 0,
              value.isFinite
        else { return .nan }
        return max(0, value)
    }

    private func isPaused() -> Bool {
        guard let mpv else { return false }
        var value: Int32 = 0
        guard mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &value) >= 0 else { return false }
        return value != 0
    }

    private func logOnce(_ message: String) {
        guard !didLogRenderFailure else { return }
        didLogRenderFailure = true
        onLog?(message)
    }
}
