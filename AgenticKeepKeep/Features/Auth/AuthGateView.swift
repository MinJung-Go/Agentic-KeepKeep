import SwiftUI
import SwiftData

struct AuthGateView: View {
    @ObservedObject private var auth = AuthStore.shared
    var body: some View {
        Group {
            switch auth.phase {
            case .signedOut: LoginView()
            case .restoring: ProgressView("正在恢复登录…")
            case .failed:
                VStack(spacing: 20) {
                    Text("暂时无法连接").font(.title2)
                    Text(auth.message ?? "请检查网络后重试。").foregroundStyle(.secondary)
                    Button("重试") { Task { await auth.restore() } }.buttonStyle(PrimaryButtonStyle())
                    Button("使用其他账号") { Task { await auth.logout() } }
                }.padding(24)
            case .signedIn:
                if let user = auth.user {
                    AccountContentView(user: user).id(user.id)
                }
            }
        }
        .task { if auth.phase == .restoring { await auth.restore() } }
    }
}

private struct AccountContentView: View {
    let user: ServiceUser
    @State private var container: ModelContainer?
    @State private var needsClaim = false
    @State private var error: String?
    @State private var confirmsClaim = false
    private var account: String { AppModelContainer.accountKey(userID: user.id, server: ServiceEndpoint.baseURL) }
    var body: some View {
        Group {
            if let container {
                RootView(accountKey: account).modelContainer(container)
            } else if needsClaim {
                VStack(alignment: .leading, spacing: 24) {
                    Text("把原来的记录，\n留在这个账号？").font(.largeTitle.bold())
                    Text("发现尚未关联账号的本机记录。当前账号：\(user.username)").foregroundStyle(.secondary)
                    Text("关联不会上传或删除记录。其他账号使用独立的本机数据库。")
                    Button("关联并继续") { confirmsClaim = true }.buttonStyle(PrimaryButtonStyle())
                    Button("换一个账号") { Task { await AuthStore.shared.logout() } }
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(24)
                .confirmationDialog("确认将本机旧记录关联到 \(user.username)？", isPresented: $confirmsClaim, titleVisibility: .visible) {
                    Button("确认关联") { open(claim: true) }
                    Button("取消", role: .cancel) { }
                }
            } else if let error {
                VStack(spacing: 20) {
                    Text("无法打开本机记录").font(.title2)
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { open(claim: false) }
                    Button("退出登录") { Task { await AuthStore.shared.logout() } }
                }.padding(24)
            } else { ProgressView("正在打开记录…") }
        }
        .task {
            guard container == nil else { return }
            needsClaim = AppModelContainer.needsLegacyClaim(account: account)
            if !needsClaim { open(claim: false) }
        }
    }
    private func open(claim: Bool) {
        do {
            let result = try AppModelContainer.open(account: account, claimLegacy: claim)
            AccountPreferences().activate(account, adoptingLegacy: claim)
            LLMSettings.shared.reloadAccountUsage()
            HealthKitService.shared.reloadAccountMetadata()
            if let session = ServiceCredentials.session { AppModelContainer.unlockWidget(expiresAt: session.expiresAt) }
            container = result; error = nil; needsClaim = false
        } catch { self.error = "记录未被修改或删除。\(error.localizedDescription)" }
    }
}
