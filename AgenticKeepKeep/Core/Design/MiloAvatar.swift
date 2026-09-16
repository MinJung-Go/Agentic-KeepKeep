import SwiftUI

/// 共享同一角色轮廓；深色调色对应已确认 HTML 的 saturate(.88) / brightness(.82)。
struct MiloAvatar: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 64

    var body: some View {
        Image("Milo")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .saturation(colorScheme == .dark ? 0.88 : 1)
            // CSS brightness 是 RGB 乘法；SwiftUI brightness 是加法，不能直接互换。
            .colorMultiply(colorScheme == .dark
                ? Color(red: 0.82, green: 0.82, blue: 0.82)
                : .white)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
