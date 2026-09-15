import SwiftUI

/// 首次启动引导：欢迎 → HealthKit 授权 → API Key（均可跳过）
struct OnboardingView: View {

    var onFinish: () -> Void

    @State private var step = 0
    @State private var isRequestingHealth = false
    @ObservedObject private var settings = LLMSettings.shared
    @ObservedObject private var health = HealthKitService.shared

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                welcomePage.tag(0)
                healthPage.tag(1)
                keyPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            actions
        }
        .background(Color(uiColor: .systemBackground))
        .task { await NetworkAccessBootstrap.shared.requestOnce() }
    }

    // MARK: - 三页

    private var welcomePage: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                BrandMark(size: 88)
                Text("Moveliq").font(.title2.weight(.semibold))
                Text("记下来，\n看见自己的进步。")
                    .font(Theme.Font.largeTitle)
                    .multilineTextAlignment(.center)
                Text("随手记录训练和饮食，和 Milo 一起整理、回顾和计划。")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Label("「深蹲 100kg 5×5」→ 整理后确认保存", systemImage: "dumbbell")
                    Label("文字、照片、语音，随手记录", systemImage: "camera")
                    Label("数据本机保存，使用自己的模型服务", systemImage: "lock.shield")
                }
                .font(Theme.Font.subheadline)
                .card()
            }
            .padding(Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.xl)
        }
    }

    private var healthPage: some View {
        page(
            symbol: "heart.text.square.fill",
            tint: Theme.danger,
            title: "接入健康数据",
            lines: [
                "只读读取睡眠、HRV、静息心率、步数与运动记录",
                "原始健康记录留在本机，AI 分析按需使用汇总摘要",
                "跳过也没关系，随时可以在设置里开启"
            ]
        )
    }

    private var keyPage: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            Image(systemName: "key.fill")
                .font(.system(size: 44, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
            Text("配置你的 AI")
                .font(Theme.Font.title)
            Text("填入自己的 API Key（默认支持智谱 GLM，也可切换 OpenAI / Claude / 任意兼容端点）。\nKey 保存在系统钥匙串，只用于你自己的设备。")
                .font(Theme.Font.subheadline)
                .foregroundStyle(Theme.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xxl)

            VStack(spacing: Theme.Spacing.s) {
                SecureField("API Key", text: $settings.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(Theme.Spacing.m)
                    .background(
                        Theme.cardNested,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous)
                    )

                TextField("模型（默认 \(settings.preset.defaultModel)）", text: $settings.modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(Theme.Spacing.m)
                    .background(
                        Theme.cardNested,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous)
                    )
            }
            .padding(.horizontal, Theme.Spacing.xxl)

            Spacer()
        }
    }

    private func page(symbol: String, tint: Color, title: String, lines: [String]) -> some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            Text(title)
                .font(Theme.Font.title)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .top, spacing: Theme.Spacing.s) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 3)
                        Text(line)
                            .font(Theme.Font.subheadline)
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)

            Spacer()
        }
    }

    // MARK: - 底部按钮

    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            if step == 1 {
                Button {
                    Task {
                        isRequestingHealth = true
                        await health.requestAuthorization()
                        isRequestingHealth = false
                        step = 2
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.s) {
                        if isRequestingHealth { ProgressView() }
                        Text("允许读取健康数据")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isRequestingHealth)
            }

            Button(step == 2 ? "开始使用" : "继续") {
                if step < 2 {
                    withAnimation { step += 1 }
                } else {
                    onFinish()
                }
            }
            .buttonStyle(PrimaryButtonStyle())

            Button("跳过") { onFinish() }
                .font(Theme.Font.footnote)
                .foregroundStyle(Theme.secondaryLabel)
                .padding(.top, Theme.Spacing.xs)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.l)
    }
}
