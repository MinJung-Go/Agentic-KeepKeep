import SwiftUI

/// 模型的思考过程（GLM / Kimi / DeepSeek 的 `reasoning_content`，或 Anthropic 的 thinking）。
///
/// 这里最容易做砸的地方是**把折叠态做成一个空盒子** —— 没有内容却占满整行宽度和 40+pt 高度，
/// 里面只放一行小字，第一眼像加载失败的占位。规则是：**有内容才有容器，没内容就只是一行字**。
///
/// | 状态 | 形态 |
/// |------|------|
/// | 折叠（已结束） | 无容器、无背景，宽度贴合文字 —— 像一行「查看详情」 |
/// | 展开 / 思考中 | 才有 `cardNested` 容器；表头转强调色，正文次级色 |
/// | 生成中 | 表头追加已用秒数（等宽数字）。**不做扫光/流光** —— 那是装饰，且每秒重绘 |
///
/// 判据：把折叠态截图单独拎出来看，如果它像一个「控件」而不是一句「说明」，就是做重了。
struct ThinkingBlock: View {

    let text: String
    var isStreaming: Bool = false

    @State private var isExpanded: Bool
    @State private var startedAt = Date.now
    /// 流式结束后冻结的秒数 —— 不再随时间增长
    @State private var frozenSeconds: Int?

    init(text: String, isStreaming: Bool = false, defaultExpanded: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
        _isExpanded = State(initialValue: defaultExpanded)
    }

    /// 有内容才有容器：折叠态不加内边距、不加底色
    private var showsContainer: Bool { isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                Text(text)
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineSpacing(9)                     // 12pt × 1.75 ≈ 21pt 行距
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Spacing.s)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, showsContainer ? 13 : 0)
        .padding(.vertical, showsContainer ? 11 : 0)
        .background {
            if showsContainer {
                RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous)
                    .fill(Theme.cardNested)
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            // 结束时把秒数定住，否则会一直往上走
            if !streaming, frozenSeconds == nil {
                frozenSeconds = Int(Date.now.timeIntervalSince(startedAt))
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "brain")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)

                if isStreaming {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("思考中 · \(seconds(at: context.date))s")
                    }
                    PulsingDots(tint: Theme.accent)
                } else {
                    Text("思考过程 · \(elapsed)s")
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .font(Theme.Font.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(isExpanded || isStreaming ? Theme.accent : Theme.secondaryLabel)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "收起思考过程" : "展开思考过程")
    }

    private var elapsed: Int {
        frozenSeconds ?? max(0, Int(Date.now.timeIntervalSince(startedAt)))
    }

    private func seconds(at date: Date) -> Int {
        frozenSeconds ?? max(0, Int(date.timeIntervalSince(startedAt)))
    }
}
