//
//  ImageSearchScreen.swift
//  Kazumi
//
//  1:1 复刻 lib/pages/search/image_search_page.dart（入口在搜索页顶栏的「以图搜番」按钮）：
//  * 两种图片来源：本地截图 / 图片链接，切换后清空上一次结果；
//  * 链接输入 500ms 防抖后展示预览；
//  * 宽屏（>= 840pt，或横屏 >= 600pt 且字号未放大）左右分栏：左侧选图、右侧结果；
//  * 点选结果把番名回传给搜索页，由搜索页直接检索。
//

import SwiftUI
import UniformTypeIdentifiers

struct ImageSearchScreen: View {
    /// 搜索页拿到识别结果后的回调：把番名填进搜索框并立即搜索。
    var onPickKeyword: (String) -> Void

    @State private var controller = ImageSearchController()
    @State private var useURL = false
    @State private var urlText = ""
    @State private var previewURL = ""
    @State private var imageFile: PickedImage?
    @State private var inputError: String?
    @State private var isPicking = false
    @State private var debounceTask: Task<Void, Never>?
    @State private var isShowingHelp = false
    @State private var isShowingPicker = false
    @State private var isShowingCamera = false
    @State private var isShowingFileImporter = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var toast: String?
    @FocusState private var isURLFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 1

    private var isBusy: Bool { controller.isSearching || isPicking }
    private var hasImage: Bool {
        useURL ? ImageSearchURL.httpURL(from: urlText) != nil : imageFile != nil
    }
    private var showResults: Bool {
        controller.isSearching || !controller.results.isEmpty || !controller.errorMessage.isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if isSplitLayout(proxy.size) {
                    splitContent(proxy.size)
                } else {
                    singleColumnContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(KazumiPalette.background(for: colorScheme).ignoresSafeArea())
        .navigationTitle("以图搜番")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("搜图小贴士")
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .kazumiGlassCapsule()
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $isShowingHelp) { helpSheet }
        .photosPicker(isPresented: $isShowingPicker, selection: $photoSelection, matching: .images)
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraImagePicker { picked in
                adopt(picked)
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $isShowingFileImporter, allowedContentTypes: [.image]) { result in
            handleFileImport(result)
        }
        .onChange(of: urlText) { _, newValue in
            schedulePreview(for: newValue)
        }
        .onChange(of: photoSelection) { _, newValue in
            guard let newValue else { return }
            loadPhoto(newValue)
            // 复位选择项：同一张图再次选中时也要能触发 onChange。
            photoSelection = nil
        }
        .onDisappear {
            debounceTask?.cancel()
            controller.clear()
        }
    }

    // MARK: - 布局

    /// 与原版一致：宽屏左右分栏；横屏且字号未放大时同样分栏。
    private func isSplitLayout(_ size: CGSize) -> Bool {
        if size.width >= KazumiLayout.mediumWidth { return true }
        return size.width >= KazumiLayout.compactWidth
            && size.height < size.width
            && bodyScale < 1.5
    }

    private func padding(for width: CGFloat) -> CGFloat {
        width < KazumiLayout.compactWidth ? 16 : 24
    }

    private var singleColumnContent: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    sourceSection(compact: false)
                    if showResults {
                        resultsSection
                    }
                }
                .frame(maxWidth: showResults ? .infinity : 520, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, padding(for: proxy.size.width))
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func splitContent(_ size: CGSize) -> some View {
        let inset = padding(for: size.width)
        let sourceWidth = showResults
            ? min(max((size.width - inset * 2 - 24) * 0.36, 264), 400)
            : min(size.width - inset * 2, 520)
        return HStack(alignment: .top, spacing: 24) {
            ScrollView {
                sourceSection(compact: size.height < 440)
                    .padding(.bottom, 32)
            }
            .frame(width: sourceWidth)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.immediately)

            if showResults {
                ScrollView {
                    resultsSection
                        .padding(.trailing, inset)
                        .padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.leading, 0)
            } else {
                Spacer(minLength: 0)
                    .padding(.trailing, inset)
            }
        }
        .padding(.leading, inset)
        .padding(.top, 8)
    }

    // MARK: - 选图

    /// 对应 _buildSource。
    private func sourceSection(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headlineText(compact: compact))
                .font(showResults || compact ? .title2.weight(.bold) : .largeTitle.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !showResults && !compact {
                Text("用一张截图，找到番名与出现的集数。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }

            sourceSwitcher
                .padding(.top, compact ? 12 : 24)

            previewSection
                .padding(.top, 16)

            if useURL {
                urlField
                    .padding(.top, 12)
            }

            if let inputError {
                Text(inputError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.top, 12)
            }

            primaryAction
                .padding(.top, 16)

            Text("由 trace.moe 识别动画截图")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)

            if !showResults && !compact {
                screenshotTip
                    .padding(.top, 24)
            }
        }
    }

    private func headlineText(compact: Bool) -> String {
        if showResults { return "搜索图片" }
        return compact ? "用截图找到番名" : "这一幕，\n出自哪部番？"
    }

    /// 对应 _ImageSourceSelector：本地截图 / 图片链接。
    private var sourceSwitcher: some View {
        HStack(spacing: 4) {
            ForEach([false, true], id: \.self) { isURLSource in
                let selected = useURL == isURLSource
                Button {
                    changeSource(toURL: isURLSource)
                } label: {
                    Text(isURLSource ? "图片链接" : "本地截图")
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            Capsule(style: .continuous)
                                .fill(selected ? KazumiPalette.accent : Color.clear)
                        }
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(KazumiPalette.cardSurface(for: colorScheme))
        )
    }

    /// 对应 _buildPreview：本地图片直接显示，链接图先加载预览。
    @ViewBuilder
    private var previewSection: some View {
        if useURL {
            if let target = ImageSearchURL.httpURL(from: previewURL) {
                RemoteFrameImage(url: target, height: previewHeight)
            }
        } else if let imageFile {
            Image(uiImage: imageFile.image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: previewHeight)
                .background(KazumiPalette.cardSurface(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityLabel("待识别的完整截图")
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        pickImage()
                    } label: {
                        Label("更换截图", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .kazumiGlassCapsule()
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .padding(10)
                }
        } else {
            Button {
                pickImage()
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("选择一张动画截图")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("JPG、PNG、WebP · 最大 25 MB")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: previewHeight)
                .background(KazumiPalette.cardSurface(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
    }

    private var previewHeight: CGFloat { showResults ? 168 : 208 }

    private var urlField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("粘贴图片链接（http / https）", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($isURLFocused)
                .onSubmit { search() }

            if urlText.isEmpty {
                Button {
                    pasteLinkFromClipboard()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("从剪贴板粘贴链接")
            } else {
                Button {
                    urlText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空链接")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(KazumiPalette.cardSurface(for: colorScheme))
        )
    }

    /// 对应 _buildPrimaryAction。
    private var primaryAction: some View {
        let selecting = !useURL && imageFile == nil
        let title: String = {
            if controller.isSearching { return "正在识别" }
            if isPicking { return "正在读取图片" }
            if selecting { return "选择截图" }
            return useURL ? "开始识别" : "识别这张截图"
        }()
        return Button {
            if selecting {
                pickImage()
            } else {
                search()
            }
        } label: {
            HStack(spacing: 10) {
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: selecting ? "photo.badge.plus" : "magnifyingglass")
                }
                Text(title)
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(KazumiPalette.accent)
        .disabled(isBusy || (!selecting && !hasImage))
    }

    /// 对应 _ScreenshotTip：截图的小建议。
    private var screenshotTip: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(KazumiPalette.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("截图小建议")
                    .font(.footnote.weight(.semibold))
                Text("完整保留 16:9 画面、避开字幕遮挡与水印，命中率最高。插画、漫画和大幅裁剪的图片通常无法匹配。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(KazumiPalette.cardSurface(for: colorScheme))
        )
    }

    // MARK: - 结果

    /// 对应 _ImageSearchResults。
    @ViewBuilder
    private var resultsSection: some View {
        if controller.isSearching {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("正在寻找这一幕")
                    .font(.title3.weight(.bold))
                Text("正在比对动画画面，匹配番名、集数与时间。\n请稍等片刻。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else if controller.results.isEmpty {
            if controller.errorMessage == ImageSearchController.emptyResultMessage {
                emptyState(icon: "picture", title: "没有找到匹配画面", message: nil)
            } else {
                emptyState(
                    icon: "wifi.exclamationmark",
                    title: "这次识别未完成",
                    message: controller.errorMessage
                )
            }
        } else {
            resultsContent
        }
    }

    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("找到 \(controller.results.count) 个相似片段")
                .font(.title3.weight(.bold))
            Text("按画面相似度排序，先对照截图再确认。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            if !controller.errorMessage.isEmpty {
                Text(controller.errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .padding(.top, 12)
            }

            BestMatchCard(
                result: controller.results[0],
                onSelect: { pick(controller.results[0]) },
                onPreview: { openExternal($0) }
            )
            .padding(.top, 20)

            if controller.results.count > 1 {
                Text("其他相似片段")
                    .font(.headline)
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                VStack(spacing: 4) {
                    ForEach(controller.results.dropFirst()) { item in
                        OtherMatchRow(result: item) { pick(item) }
                    }
                }
            }
        }
    }

    private func emptyState(icon: String, title: String, message: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            if let message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if hasImage {
                Button("重新识别") { search() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - 弹窗

    /// 对应 _showHelp。
    private var helpSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("使用动画正片截图，保留原始比例。尽量避开黑边、字幕遮挡、水印与拼接画面。")
                    Text("插画、漫画和经过大幅裁剪的图片通常无法匹配。相似度仅供参考，建议对照画面或预览片段确认。")
                    Text("识别由 trace.moe 提供。开始识别后，所选图片或图片链接会发送至该服务。")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("让截图更容易被找到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let url = URL(string: "https://trace.moe") {
                        Link("访问 trace.moe", destination: url)
                            .font(.callout)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("知道了") { isShowingHelp = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - 行为

    /// 从剪贴板读出一个 http(s) 图片链接。
    private func pasteLinkFromClipboard() {
        guard let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              ImageSearchURL.httpURL(from: value) != nil
        else {
            withAnimation(.snappy) { toast = "剪贴板里没有可用的图片链接" }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.snappy) { toast = nil }
            }
            return
        }
        useURL = true
        urlText = value
    }

    /// 对应 _pickImage：相册 / 拍照 / 文件三个来源。
    private func pickImage() {
        guard !isBusy else { return }
        isURLFocused = false
        showPickerMenu()
    }

    private func showPickerMenu() {
        let sheet = UIAlertController(title: "选择截图", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "从相册选择", style: .default) { _ in
            isShowingPicker = true
        })
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            sheet.addAction(UIAlertAction(title: "拍照", style: .default) { _ in
                isShowingCamera = true
            })
        }
        sheet.addAction(UIAlertAction(title: "从文件选择", style: .default) { _ in
            isShowingFileImporter = true
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet)
    }

    private func present(_ controller: UIAlertController) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        else { return }
        var presenter = window.rootViewController
        while let presented = presenter?.presentedViewController { presenter = presented }
        guard let presenter else { return }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.maxY - 40,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    /// 相册选择结果：读到内存后按 JPEG 上传，与原版 image_picker + readAsBytes 等价。
    private func loadPhoto(_ item: PhotosPickerItem) {
        isPicking = true
        inputError = nil
        Task {
            defer { isPicking = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data)
                else {
                    inputError = "无法读取这张图片，请换一张"
                    return
                }
                adopt(PickedImage(image: image, fileName: "screenshot"))
            } catch {
                inputError = "无法读取这张图片，请换一张"
            }
        }
    }

    private func handleFileImport(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        isPicking = true
        Task {
            defer { isPicking = false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let image = UIImage(data: data) else {
                    inputError = "无法读取这张图片，请换一张"
                    return
                }
                adopt(PickedImage(image: image, fileName: url.lastPathComponent))
            } catch {
                inputError = "无法读取这张图片，请换一张"
            }
        }
    }

    /// 采用新图片：清空上一次的识别结果，回到本地截图模式。
    private func adopt(_ picked: PickedImage) {
        debounceTask?.cancel()
        useURL = false
        previewURL = ""
        inputError = nil
        imageFile = picked
        controller.clear()
    }

    /// 对应 _changeSource。
    private func changeSource(toURL: Bool) {
        guard !isBusy, useURL != toURL else { return }
        debounceTask?.cancel()
        isURLFocused = false
        useURL = toURL
        controller.clear()
        inputError = nil
        previewURL = toURL && ImageSearchURL.httpURL(from: urlText) != nil
            ? urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    /// 对应 _onUrlChanged：输入变化即作废旧结果，500ms 后再换预览。
    private func schedulePreview(for value: String) {
        guard useURL else { return }
        debounceTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.clear()
        inputError = nil
        previewURL = ""
        guard ImageSearchURL.httpURL(from: trimmed) != nil else { return }
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            previewURL = trimmed
        }
    }

    /// 对应 _search。
    private func search() {
        guard !isBusy else { return }
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceURL = ImageSearchURL.httpURL(from: trimmed)
        guard useURL ? sourceURL != nil : imageFile != nil else {
            inputError = "请输入有效的 HTTP 或 HTTPS 图片链接"
            isURLFocused = true
            return
        }
        debounceTask?.cancel()
        isURLFocused = false
        inputError = nil
        if useURL { previewURL = trimmed }

        Task {
            if useURL, let sourceURL {
                await controller.search(imageURL: sourceURL.absoluteString)
            } else if let file = imageFile {
                await controller.search(imageData: file.jpegData)
            }
        }
    }

    /// 对应 onSelect：把番名回传给搜索页。
    private func pick(_ result: TraceResultItem) {
        onPickKeyword(result.displayTitle)
        dismiss()
    }

    private func openExternal(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { success in
            guard !success else { return }
            withAnimation(.snappy) { toast = "暂时无法打开链接，请稍后再试" }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.snappy) { toast = nil }
            }
        }
    }
}
