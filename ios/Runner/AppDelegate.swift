import UIKit
import Flutter
import AVKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

        let channel = FlutterMethodChannel(
            name: "com.predidit.kazumi/intent",
            binaryMessenger: engineBridge.applicationRegistrar.messenger()
        )
        channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            if call.method == "openWithReferer" {
                guard let args = call.arguments else { return }
                if let myArgs = args as? [String: Any],
                   let url = myArgs["url"] as? String,
                   let referer = myArgs["referer"] as? String {
                    self?.openVideoWithReferer(url: url, referer: referer)
                }
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        let storageChannel = FlutterMethodChannel(
            name: "com.predidit.kazumi/storage",
            binaryMessenger: engineBridge.applicationRegistrar.messenger()
        )
        storageChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "getAvailableStorage":
                do {
                    let attrs = try FileManager.default.attributesOfFileSystem(
                        forPath: NSHomeDirectory()
                    )
                    if let freeSize = attrs[.systemFreeSize] as? Int64 {
                        result(freeSize)
                    } else {
                        result(-1)
                    }
                } catch {
                    result(-1)
                }
            case "pickDirectory":
                self?.pickDownloadDirectory(result: result)
            case "resolveBookmark":
                guard let args = call.arguments as? [String: Any],
                      let bookmark = args["bookmark"] as? String else {
                    result(nil)
                    return
                }
                self?.resolveBookmark(bookmark, result: result)
            case "releaseDirectory":
                self?.releaseAccessedDirectories()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    // MARK: - Download directory access

    /// Directories the user granted through the folder picker. The URL objects
    /// must stay alive for the security-scoped access to remain valid.
    private var accessedDirectories: [String: URL] = [:]
    private var pendingPickResult: FlutterResult?

    private func pickDownloadDirectory(result: @escaping FlutterResult) {
        guard pendingPickResult == nil else {
            result(FlutterError(code: "picker_busy",
                                message: "目录选择已在进行中",
                                details: nil))
            return
        }
        guard let presenter = topViewController() else {
            result(FlutterError(code: "no_presenter",
                                message: "无法打开系统文件选择器",
                                details: nil))
            return
        }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        pendingPickResult = result
        presenter.present(picker, animated: true)
    }

    /// Resolves a stored bookmark and starts accessing the folder.
    /// Returns the folder path, or nil when the bookmark is stale/broken.
    private func resolveBookmark(_ bookmark: String, result: @escaping FlutterResult) {
        guard let data = Data(base64Encoded: bookmark) else {
            result(nil)
            return
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                result(nil)
                return
            }
            accessedDirectories[url.path] = url
            result(url.path)
        } catch {
            result(nil)
        }
    }

    private func releaseAccessedDirectories() {
        for url in accessedDirectories.values {
            url.stopAccessingSecurityScopedResource()
        }
        accessedDirectories.removeAll()
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first,
              var controller = window.rootViewController else {
            return nil
        }
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let result = pendingPickResult else { return }
        pendingPickResult = nil
        guard let url = urls.first else {
            result(nil)
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            result(FlutterError(code: "access_denied",
                                message: "无法获得该目录的访问权限",
                                details: nil))
            return
        }
        accessedDirectories[url.path] = url
        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            result([
                "path": url.path,
                "bookmark": bookmark.base64EncodedString(),
            ])
        } catch {
            result(FlutterError(code: "bookmark_failed",
                                message: error.localizedDescription,
                                details: nil))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingPickResult?(nil)
        pendingPickResult = nil
    }
    
    // TODO: ADD VLC SUPPORT
    // VLC can be downloaded from iOS App Store, but don't know how to build selectable app lists, while checking if it is installled.
    // VLC supports more video formats than AVPlayer but does not support referer while AVPlayer does
    private func openVideoWithReferer(url: String, referer: String) {
        guard let videoUrl = URL(string: url) else { return }

        let headers: [String: String] = [
            "Referer": referer,
        ]
        let asset = AVURLAsset(url: videoUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        let playerViewController = AVPlayerViewController()
        playerViewController.player = player
        playerViewController.videoGravity = AVLayerVideoGravity.resizeAspect

        // Use UIScene API instead of deprecated keyWindow
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            return
        }

        rootViewController.present(playerViewController, animated: true) {
            playerViewController.player?.play()
        }

//        guard let appURL = URL(string: "vlc-x-callback://x-callback-url/stream?url=" + url) else {
//            return
//        }
//        if UIApplication.shared.canOpenURL(appURL) && referer.isEmpty {
//            UIApplication.shared.open(appURL, options: [:], completionHandler: nil)
//        }
    }
}
