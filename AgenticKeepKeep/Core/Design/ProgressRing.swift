import SwiftUI

/// 进度环：轨道用 `chip` 中性色，进度用语义色**实色**。
///
/// 选它而不是折线或柱状，是因为这里表达的是「今天记了没」这种**单值达标率** ——
/// 见设计系统 §9 的形态选择表。环心放「当前 / 目标」，数字等宽。
struct ProgressRing: View {

    /// 0...1，超出会被夹住
    let value: Double
    var tint: Color = Theme.accent
    var current: Int
    var total: Int
    var caption: String
    var size: CGFloat = 64

    private var clamped: Double { max(0, min(1, value)) }

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            ZStack {
                Circle()
                    .stroke(Theme.chip, lineWidth: 5)

                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.snappy(duration: 0.3), value: clamped)

                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(current)")
                        .font(Theme.Font.metricSmall)
                        .foregroundStyle(.primary)
                    Text("/\(total)")
                        .font(Theme.Font.badge)
                        .foregroundStyle(Theme.tertiaryLabel)
                }
                .monospacedDigit()
            }
            .frame(width: size, height: size)

            Text(caption)
                .font(Theme.Font.badge)
                .fontWeight(.regular)
                .foregroundStyle(Theme.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption) \(current) / \(total)")
        .accessibilityValue(clamped >= 1 ? "已完成" : "进行中")
    }
}

/// 百分比环：环心直接显示百分比。用于「一个比率」的场景（计划完成度），
/// 与 `ProgressRing` 的区别是它不表达「几之几」。
struct PercentRing: View {

    let value: Double
    var tint: Color = Theme.accent
    var size: CGFloat = 56

    private var clamped: Double { max(0, min(1, value)) }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.chip, lineWidth: 5)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(Int((clamped * 100).rounded()))")
                    .font(.system(size: 14, weight: .bold))
                Text("%")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryLabel)
            }
            .monospacedDigit()
        }
        .frame(width: size, height: size)
        .animation(.snappy(duration: 0.3), value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("完成度")
        .accessibilityValue("\(Int(clamped * 100))%")
    }
}

/// 细进度条：轨道 `chip`，进度语义色实色。用于计划完成度这类**连续**进度。
struct ProgressBar: View {

    let value: Double
    var tint: Color = Theme.accent

    private var clamped: Double { max(0, min(1, value)) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chip)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: 6)
        .animation(.snappy(duration: 0.3), value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("完成度")
        .accessibilityValue("\(Int(clamped * 100))%")
    }
}

/// 迷你柱状图：只让**最高的那根**用实色，其余用中性灰 ——
/// 「哪个是峰值」靠颜色而不是靠标注（设计系统 §9）。
struct MiniBarChart: View {

    let values: [Double]
    var tint: Color = Theme.accent
    var height: CGFloat = 44

    private var peak: Double { values.max() ?? 0 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(isPeak(value) ? tint : Theme.chip)
                    .frame(maxWidth: .infinity)
                    .frame(height: barHeight(value))
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("近 \(values.count) 天趋势")
    }

    /// 全是 0 时不点亮任何一根，否则「峰值」会是一排空柱
    private func isPeak(_ value: Double) -> Bool {
        peak > 0 && value >= peak
    }

    private func barHeight(_ value: Double) -> CGFloat {
        guard peak > 0 else { return 3 }
        return max(3, height * CGFloat(value / peak))
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.xl) {
        HStack(spacing: Theme.Spacing.s) {
            ProgressRing(value: 1, tint: Theme.accent, current: 1, total: 1, caption: "训练")
            ProgressRing(value: 2.0 / 3, tint: Theme.positive, current: 2, total: 3, caption: "饮食")
            ProgressRing(value: 0, tint: Theme.info, current: 0, total: 1, caption: "身体")
        }
        ProgressBar(value: 0.6).padding(.horizontal, 40)
        MiniBarChart(values: [1200, 0, 3400, 2800, 0, 4200, 900])
    }
    .padding()
}
