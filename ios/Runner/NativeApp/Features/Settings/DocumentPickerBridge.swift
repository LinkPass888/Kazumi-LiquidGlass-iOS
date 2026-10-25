//
//  DocumentPickerBridge.swift
//  Kazumi
//
//  文件面板只有一份实现，谁要选文件、存文件都从这里走。
//
//  为什么不用 SwiftUI 的 .fileImporter / .fileExporter：
//  侧载包上点文件、点目录都不响应（面板开着，点下去什么也不发生）。改成直接
//  呈现系统的 UIDocumentPickerViewController，并且一律 asCopy——选中的文件
//  先拷进 App 自己的临时目录再交给我们，读的时候不依赖安全作用域，也不依赖
//  文件提供器把 URL 传过来的那条路。
//
//  「等面板退干净再继续」也放在这里：delegate 回调时面板还在退场动画里，
//  上层拿到的结果由调用方延后一拍再弹窗/改状态。
//

import UIKit
import UniformTypeIdentifiers

@MainActor
final class DocumentPickerBridge: NSObject, UIDocumentPickerDelegate {
    typealias Completion = (Result<[URL], Error>) -> Void

    /// 面板期间必须有人持有 bridge，否则 delegate 当场被释放，回调不会来。
    private static var active: DocumentPickerBridge?
    private let completion: Completion

    private init(completion: @escaping Completion) {
        self.completion = completion
    }

    // MARK: - 入口

    /// 选文件（导入）。asCopy：拷进 App 沙箱，回来的是一个随时能读的 URL。
    /// 选目录必须 asCopy: false —— 拷贝模式只对文件成立，对文件夹要么直接不给选，
    /// 要么把它整个复制一份，两种都不对；这时拿到的 URL 要自己开安全作用域
    /// （见 DownloadDirectoryStore）。
    static func open(
        types: [UTType],
        asCopy: Bool = true,
        from host: UIViewController? = nil,
        completion: @escaping Completion
    ) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        present(picker, from: host, completion: completion)
    }

    /// 存文件（导出）。调用方先把内容写成临时文件，这里只负责让用户挑位置。
    static func export(
        url: URL,
        from host: UIViewController? = nil,
        completion: @escaping Completion
    ) {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        present(picker, from: host, completion: completion)
    }

    // MARK: - 呈现

    private static func present(
        _ picker: UIDocumentPickerViewController,
        from host: UIViewController?,
        completion: @escaping Completion
    ) {
        guard let host = host ?? topViewController() else {
            completion(.failure(PickerError.noHost))
            return
        }
        let bridge = DocumentPickerBridge(completion: completion)
        active = bridge
        picker.delegate = bridge
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        host.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
        guard var top = windows.first(where: \.isKeyWindow)?.rootViewController
            ?? windows.first?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(.success(urls))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.failure(PickerError.cancelled))
    }

    private func finish(_ result: Result<[URL], Error>) {
        // 面板正在退场：这一拍只放行 bridge，等它退干净再由上层动作。
        Self.active = nil
        completion(result)
    }

    enum PickerError: LocalizedError {
        case cancelled
        case noHost

        var errorDescription: String? {
            switch self {
            case .cancelled: return "已取消"
            case .noHost: return "打不开文件面板"
            }
        }
    }
}
