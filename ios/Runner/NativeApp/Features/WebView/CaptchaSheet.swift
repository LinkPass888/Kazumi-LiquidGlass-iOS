//
//  CaptchaSheet.swift
//  Kazumi
//
//  验证面板 UI（对应 source_captcha_flow.dart 里的 _CaptchaDialog /
//  _AutomatedVerifyDialog / _VerificationCompleteDialog）。
//

import SwiftUI

struct CaptchaSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let flow: CaptchaFlow

    @State private var code = ""
    @State private var didStart = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    switch flow.phase {
                    case .completed:
                        Label("验证完成，正在获取结果…", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("重试") {
                            code = ""
                            Task { await flow.reload() }
                        }
                        .buttonStyle(.borderedProminent)
                    case .cancelled:
                        Text("已取消验证")
                            .foregroundStyle(.secondary)
                    case .preparing, .awaitingInput, .verifying:
                        content
                    }
                }
                .padding(20)
            }
            .background(KazumiPalette.heroBackground(for: colorScheme).ignoresSafeArea())
            .navigationTitle("需要验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        Task {
                            await flow.cancel()
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            guard !didStart else { return }
            didStart = true
            await flow.start()
        }
        .onDisappear { flow.dispose() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(KazumiPalette.accent(for: colorScheme))
            Text(flow.plugin.name)
                .font(.headline)
            Text(flow.requiresUserInput ? "请输入页面上的验证码" : "正在自动完成站点验证，请勿关闭…")
                .font(.footnote)
                .foregroundStyle(KazumiPalette.secondaryText(for: colorScheme))
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var content: some View {
        if flow.requiresUserInput {
            if let image = flow.captchaImage, let uiImage = UIImage(data: image) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture {
                        Task { await flow.reload() }
                    }
            } else {
                ProgressView("正在加载验证码…")
            }
            TextField("验证码", text: $code)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .multilineTextAlignment(.center)
            Button {
                Task { await flow.submit(code) }
            } label: {
                if flow.phase == .verifying {
                    ProgressView()
                } else {
                    Text("提交")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || flow.phase == .verifying)
            Button("换一张") {
                Task { await flow.reload() }
            }
            .font(.footnote)
        } else {
            ProgressView()
                .padding(.vertical, 24)
        }
    }
}
