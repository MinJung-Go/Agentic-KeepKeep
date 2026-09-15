import SwiftUI
import UIKit

/// 对话气泡。教练页与记录弹窗共用同一套形状 —— 两处气泡不一样会显得像两个 App。
///
/// - 用户在右：中性底 + 主色字
/// - AI / 系统在左：`card` 底 + 主色字
/// - 圆角 20，靠说话人那一侧的底角收成 8，形成指向说话人的「尾巴」
struct ChatBubble<Content: View>: View {

    enum Speaker {
        case user
        case assistant
    }

    let speaker: Speaker
    /// 附在气泡里的缩略图（记录时选的照片）
    let thumbnail: UIImage?
    /// 只有缩略图、没有文字时传 `false` —— 否则文字那圈内边距会留下一片空白
    let showsContent: Bool
    private let content: Content

    init(
        speaker: Speaker = .assistant,
        thumbnail: UIImage? = nil,
        showsContent: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.speaker = speaker
        self.thumbnail = thumbnail
        self.showsContent = showsContent
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            if speaker == .user { Spacer(minLength: 48) }

            VStack(alignment: speaker == .user ? .trailing : .leading, spacing: 0) {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 150, height: 150)
                        .clipShape(
                            RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous)
                        )
                        .padding(5)
                }

                if showsContent {
                    content
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                }
            }
            .foregroundStyle(Color.primary)
            .background(background, in: shape)

            if speaker == .assistant { Spacer(minLength: 48) }
        }
    }

    private var background: Color {
        speaker == .user ? Theme.userBubble : Theme.card
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Theme.Radius.card,
            bottomLeadingRadius: speaker == .assistant ? Theme.Radius.compact : Theme.Radius.card,
            bottomTrailingRadius: speaker == .user ? Theme.Radius.compact : Theme.Radius.card,
            topTrailingRadius: Theme.Radius.card,
            style: .continuous
        )
    }
}

/// 发送 / 停止：同一个圆钮，生成中变成停止。
/// 教练页与记录弹窗共用 —— 两处按钮不一样会显得像两个 App。
struct ChatSendButton: View {

    let isBusy: Bool
    let canSend: Bool
    var onSend: () -> Void
    var onStop: () -> Void

    var body: some View {
        Button {
            if isBusy { onStop() } else { onSend() }
        } label: {
            Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isBusy || !canSend ? Color.primary : Theme.onAccent)
                .frame(width: 44, height: 44)
                .background(background, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isBusy && !canSend)
        .accessibilityLabel(isBusy ? "停止生成" : "发送")
    }

    private var background: Color {
        if isBusy { return Theme.chip }
        // 不可用时用中性灰，而不是把强调色调淡 —— 见设计系统 §2
        return canSend ? Theme.accent : Color(uiColor: .tertiaryLabel)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
        ChatBubble(speaker: .assistant) {
            Text("只有一对哑铃、每周 4 天，我按上下肢分化排 4 周。")
                .font(Theme.Font.body)
        }
        ChatBubble(speaker: .user) {
            Text("中午吃了牛肉面，大概一碗半").font(Theme.Font.body)
        }
        ChatSendButton(isBusy: false, canSend: true, onSend: {}, onStop: {})
        ChatSendButton(isBusy: true, canSend: false, onSend: {}, onStop: {})
    }
    .padding()
    .background(Theme.canvas)
}
