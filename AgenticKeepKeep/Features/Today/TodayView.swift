import PhotosUI
import UIKit
import SwiftUI
import SwiftData

/// 今日：概览三环 + 健康快照 + 今日课程 + 今日已记录 + 底部常驻输入条
struct TodayView: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var health = HealthKitService.shared

    @Query private var workouts: [WorkoutSession]
    @Query private var meals: [MealEntry]
    @Query private var metrics: [BodyMetric]
    @Query private var notes: [RawNote]
    @Query private var healthWorkouts: [HealthWorkout]
    @Query private var snapshots: [HealthSnapshot]
    @Query private var planDays: [PlanDay]
    @Query private var plans: [Plan]
    @Query private var trainingDrafts: [WorkoutSessionDraft]
    @AppStorage(MiloPersona.nameKey) private var miloName = "Milo"
    private var displayName: String { MiloPersona(name: miloName).name }
    private struct ChatEntry: Identifiable {
        let id = UUID()
        let text: String
    }
    @State private var chatEntry: ChatEntry?
    @State private var choosesIntent = false
    @AppStorage("localMilo.invitationShown") private var invitationShown = false
    @State private var showsLocalInvitation = false
    @ObservedObject private var localStore = LocalModelStore.shared

    /// 今日页输入条里敲的内容（还没提交，所以不进 ViewModel）
    @State private var showsHealthDetails = false
    @State private var draftText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var draftPhoto: Data?
    @FocusState private var isInputFocused: Bool

    init() {
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!

        _workouts = Query(
            filter: #Predicate<WorkoutSession> { $0.date >= start && $0.date < end },
            sort: [SortDescriptor(\WorkoutSession.date, order: .reverse)]
        )
        _meals = Query(
            filter: #Predicate<MealEntry> { $0.date >= start && $0.date < end },
            sort: [SortDescriptor(\MealEntry.date, order: .reverse)]
        )
        _metrics = Query(
            filter: #Predicate<BodyMetric> { $0.date >= start && $0.date < end },
            sort: [SortDescriptor(\BodyMetric.date, order: .reverse)]
        )
        _notes = Query(
            filter: #Predicate<RawNote> { $0.date >= start && $0.date < end },
            sort: [SortDescriptor(\RawNote.date, order: .reverse)]
        )
        _healthWorkouts = Query(
            filter: #Predicate<HealthWorkout> { $0.date >= start && $0.date < end },
            sort: [SortDescriptor(\HealthWorkout.date, order: .reverse)]
        )
        _snapshots = Query(filter: #Predicate<HealthSnapshot> { $0.day == start })
        _planDays = Query(filter: #Predicate<PlanDay> { $0.date >= start && $0.date < end })
    }

    private var items: [RecordItem] {
        RecordItemBuilder.build(
            workouts: workouts,
            meals: meals,
            metrics: metrics,
            notes: notes,
            healthWorkouts: healthWorkouts
        )
    }

    private var todayPlanDay: PlanDay? {
        let days = planDays.filter { $0.plan?.isActive == true }.sorted { $0.order < $1.order }
        return days.first(where: { $0.status == .pending }) ?? days.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    greeting.staggeredAppear(0)
                    if localStore.phase != .absent {
                        NavigationLink { LocalModelView() } label: {
                            LocalDownloadStatus().frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                .background(RoundedRectangle(cornerRadius: 18).stroke(Theme.secondaryLabel.opacity(0.2)))
                        }.buttonStyle(.plain)
                    }
                    planSection.staggeredAppear(1)
                    recordsSection.staggeredAppear(2)
                    if !snapshots.isEmpty { healthSection }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.top, Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.l)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { isInputFocused = false })
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.conversationCanvas)
            .toolbarBackground(Theme.conversationCanvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("Moveliq")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { BrandMark(size: 28) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { chatEntry = ChatEntry(text: "") } label: {
                        Image(systemName: "bubble.left.and.bubble.right").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("与 \(displayName) 的对话")
                }
            }
            .sheet(isPresented: $showsLocalInvitation) { LocalModelInvitation() }
            .task {
                if !invitationShown {
                    invitationShown = true
                    showsLocalInvitation = true
                }
            }
            .sheet(item: $chatEntry) { entry in
                CoachChatView(initialMessage: entry.text, onMessageSubmitted: {
                    if draftText == entry.text { draftText = "" }
                })
            }
            .confirmationDialog("这句话要怎么处理？", isPresented: $choosesIntent, titleVisibility: .visible) {
                Button("整理为记录") { openLogSheet() }
                Button("继续对话") { openChat() }
                Button("返回修改", role: .cancel) { isInputFocused = true }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
            .refreshable { await syncHealth(force: true) }
            .task { await syncHealth(force: false) }
            .task(id: photoItem) { await attachPhotoFromHome() }
        }
    }

    // MARK: - 问候

    private var greeting: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack(spacing: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text("\(Format.greeting())，今天感觉怎么样？")
                        .font(.title2.weight(.semibold))
                    Text("我是 \(displayName)，陪你慢慢找到自己的节奏。")
                        .font(Theme.Font.subheadline).foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                MiloAvatar(size: 78)
            }
            Text(Format.day(.now)).font(Theme.Font.caption).foregroundStyle(Theme.secondaryLabel)
            ViewThatFits(in: .horizontal) {
                HStack { quickChat("我有点累"); quickChat(plans.contains { $0.isActive } ? "看看今天怎么练" : "一起制定训练计划") }
                VStack(alignment: .leading) { quickChat("我有点累"); quickChat(plans.contains { $0.isActive } ? "看看今天怎么练" : "一起制定训练计划") }
            }
        }
        .padding(.vertical, Theme.Spacing.m)
    }

    private func quickChat(_ text: String) -> some View {
        Button { chatEntry = ChatEntry(text: text) } label: {
            Text(text).font(Theme.Font.footnote)
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(Theme.chip, in: Capsule())
        }.buttonStyle(.plain)
    }

    // MARK: - 健康快照

    @ViewBuilder
    private var healthSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let snapshot = snapshots.first {
                DisclosureGroup(isExpanded: $showsHealthDetails) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.s),
                                   count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                    spacing: Theme.Spacing.s
                ) {
                    StatTile(
                        symbol: "moon.fill",
                        tint: Theme.info,
                        title: "睡眠",
                        value: Format.number(snapshot.sleepHours, decimals: 1),
                        unit: "小时",
                        delta: snapshot.sleepHours > 0 && snapshot.sleepHours < 6.5 ? "偏低 · 目标 7.5h" : "目标 7.5h",
                        deltaTint: snapshot.sleepHours > 0 && snapshot.sleepHours < 6.5 ? Theme.warning : Theme.secondaryLabel
                    )
                    StatTile(
                        symbol: "waveform.path.ecg",
                        tint: Theme.accent,
                        title: "HRV",
                        value: Format.number(snapshot.hrvMs),
                        unit: "ms",
                        delta: snapshot.hrvMs > 0 && snapshot.hrvMs < 35 ? "偏低" : "正常",
                        deltaTint: snapshot.hrvMs > 0 && snapshot.hrvMs < 35 ? Theme.warning : Theme.secondaryLabel
                    )
                    StatTile(
                        symbol: "figure.walk",
                        tint: Theme.positive,
                        title: "活动量",
                        value: "\(snapshot.steps)",
                        unit: "步",
                        delta: "今天",
                        deltaTint: Theme.secondaryLabel
                    )
                    StatTile(
                        symbol: "heart.fill",
                        tint: Theme.danger,
                        title: "静息心率",
                        value: Format.number(snapshot.restingHeartRate),
                        unit: "bpm",
                        delta: "正常",
                        deltaTint: Theme.secondaryLabel
                    )
                }
                .padding(.top, Theme.Spacing.m)
                } label: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Label(snapshot.sleepHours > 0 ? "昨晚睡眠 \(Format.number(snapshot.sleepHours, decimals: 1)) 小时" : "今日身体状态", systemImage: "moon.fill")
                            .font(Theme.Font.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("查看睡眠、HRV、步数与静息心率")
                            .font(Theme.Font.footnote)
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }
                .card()
            } else {
                SectionHeader(text: "身体状态")
                unauthorizedHealthCard
            }
        }
    }

    /// FR15.4：先说明读什么、存在哪，再给授权按钮 —— 不直接弹系统授权框
    private var unauthorizedHealthCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Image(systemName: healthIcon)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(healthIconColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(healthTitle)
                        .font(Theme.Font.subheadline.weight(.semibold))
                    Text(healthDetail)
                        .font(Theme.Font.footnote)
                        .foregroundStyle(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if health.authorizationState != .unavailable {
                Button {
                    Task {
                        await health.authorizeAndSync(into: context)
                    }
                } label: {
                    Text(health.authorizationActionTitle)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(health.isAuthorizing || health.isSyncing)
            }
        }
        .card()
    }

    private var healthIcon: String {
        switch health.authorizationState {
        case .unsupportedSigning, .failed: return "exclamationmark.triangle.fill"
        case .unavailable: return "iphone.slash"
        default: return "heart.text.square"
        }
    }

    private var healthIconColor: Color {
        switch health.authorizationState {
        case .unsupportedSigning, .failed: return Theme.warning
        case .unavailable: return Theme.secondaryLabel
        default: return Theme.accent
        }
    }

    private var healthTitle: String {
        switch health.authorizationState {
        case .unsupportedSigning: return "健康数据需要重新授权"
        case .unavailable: return "此设备不支持健康数据"
        case .failed: return "健康数据授权失败"
        default: return "还没接入健康数据"
        }
    }

    private var healthDetail: String {
        switch health.authorizationState {
        case .unsupportedSigning:
            return HealthKitService.signingHelp
        case .unavailable:
            return "该设备不提供 HealthKit。"
        case .failed:
            return health.lastError ?? "可以稍后重试。"
        default:
            return "只读读取睡眠、HRV、静息心率与步数，仅保存在本机。"
        }
    }

    // MARK: - 今日课程

    @ViewBuilder
    private var planSection: some View {
        if let day = todayPlanDay {
            let plan = day.plan
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionHeader(text: "今日课程", trailing: weekLabel(plan))
                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    // 状态色条：今天该练什么，一眼能看出状态
                    Capsule()
                        .fill(day.status == .done ? Theme.positive : Theme.accent)
                        .frame(width: 3)

                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        HStack(alignment: .center, spacing: Theme.Spacing.m) {
                            SymbolChip("dumbbell.fill", tint: Theme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(day.title)
                                    .font(Theme.Font.headline)
                                Text(day.exerciseSummary)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.secondaryLabel)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }

                        if let plan, !plan.days.isEmpty {
                            ProgressBar(
                                value: Double(plan.completedCount) / Double(plan.days.count),
                                tint: day.status == .done ? Theme.positive : Theme.accent
                            )
                            HStack(spacing: Theme.Spacing.s) {
                                Text("已完成 \(plan.completedCount) / \(plan.days.count) 次")
                                Spacer(minLength: 0)
                                Text("\(day.exercises.count) 个动作")
                            }
                            .font(Theme.Font.badge)
                            .foregroundStyle(Theme.secondaryLabel)
                            .monospacedDigit()
                        }

                        // 两个 ButtonStyle 是不同类型，不能走三元表达式，只能分支
                        if day.status == .done {
                            Button("标记为未完成") { toggleDay(day) }
                                .buttonStyle(SecondaryButtonStyle())
                        } else {
                            // 主按钮从「标记完成」改成「开始训练」——
                            // 直接勾完成是旧做法，现在跟着计划练一遍就自动完成
                            NavigationLink {
                                WorkoutSessionView(planDay: day)
                            } label: {
                                Text(trainingDrafts.contains { $0.planDayUUID == day.uuid } ? "继续训练" : "开始训练")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                }
                .card()
            }
        } else {
            // 还没有课程表：给一个显眼的入口，而不是让人去翻底部 Tab
            SectionHeader(text: "今日课程")
            Button {
                appState.selectedTab = .plan
            } label: {
                HStack(spacing: Theme.Spacing.m) {
                    SymbolChip("calendar", tint: Theme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plans.contains { $0.isActive } ? "今天没有安排训练" : "还没有训练计划")
                            .font(Theme.Font.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(plans.contains { $0.isActive } ? "查看课程表，按自己的节奏来" : "和 \(displayName) 一起安排第一份计划")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(Theme.Font.footnote.weight(.semibold))
                        .foregroundStyle(Theme.tertiaryLabel)
                }
                .card()
            }
            .buttonStyle(.plain)
        }
    }

    private func toggleDay(_ day: PlanDay) {
        withAnimation(.snappy) {
            day.status = day.status == .done ? .pending : .done
        }
        try? context.save()
        Haptics.tap()
    }

    /// 「第 2 / 4 周」
    private func weekLabel(_ plan: Plan?) -> String? {
        guard let plan else { return nil }
        let week = Format.currentWeek(since: plan.startDate, total: plan.weeks)
        return "第 \(week) / \(plan.weeks) 周"
    }

    // MARK: - 今日已记录

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                SectionHeader(text: "今日记录", trailing: items.isEmpty ? nil : "\(items.count) 条")
                Button("查看全部") { appState.selectedTab = .records }
                    .font(Theme.Font.caption).frame(minHeight: 44)
            }

            if items.isEmpty {
                EmptyStateView(
                    symbol: "square.and.pencil",
                    title: "今天还没有记录",
                    message: "在下面说一句「深蹲100kg 5×5」试试"
                )
                .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                        NavigationLink {
                            RecordDetailView(item: item)
                        } label: {
                            RecordRow(item: item)
                        }
                        .buttonStyle(.plain)

                        if index < min(items.count, 3) - 1 {
                            RowDivider()
                        }
                    }
                }
                .card()
            }
        }
    }

    // MARK: - 输入条

    /// FR13.2：胶囊输入条，位于 Tab 栏之上，用 chip 底。
    /// 首页准备文字与照片，发送一次即可开始解析。
    private var inputBar: some View {
        VStack(spacing: Theme.Spacing.s) {
            if let draftPhoto, let image = UIImage(data: draftPhoto) {
                HStack(spacing: Theme.Spacing.s) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inner))
                    Text("已附加照片，可补充说明后发送")
                        .font(Theme.Font.footnote)
                        .foregroundStyle(Theme.secondaryLabel)
                    Spacer(minLength: 0)
                    Button("移除") { self.draftPhoto = nil }
                        .font(Theme.Font.footnote)
                }
                .padding(.horizontal, Theme.Spacing.s)
            }
            inputComposer
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .frame(maxWidth: .infinity)
        .background(Theme.conversationCanvas.ignoresSafeArea(edges: .bottom))

    }

    private var inputComposer: some View {
        HStack(spacing: Theme.Spacing.s) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Group {
                    if photoItem != nil {
                        ProgressView()
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 19))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(photoItem != nil)
            .accessibilityLabel("添加记录照片")

            TextField("和 \(displayName) 说说…", text: $draftText, axis: .vertical)
                .lineLimit(1...3)
                .font(Theme.Font.subheadline)
                .focused($isInputFocused)
                .submitLabel(.send)
                .onSubmit(routeInput)

            if isInputFocused {
                Button {
                    isInputFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryLabel)
                .accessibilityLabel("收起键盘")
                .accessibilityHint("保留文字和已附加照片")
                .accessibilityIdentifier("today.dismissKeyboard")
            }

            if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftPhoto == nil {
                Button {
                    isInputFocused = false
                    appState.isQuickLogPresented = true
                } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.secondaryLabel)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .accessibilityLabel("语音记录")
            } else {
                Button(action: routeInput) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 44, height: 44)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(photoItem != nil)
                .accessibilityLabel("发送")
            }
        }
        .padding(.leading, Theme.Spacing.l)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 28))
    }

    /// 照片先附在首页，用户可以补充说明、移除或替换，再统一发送。
    private func attachPhotoFromHome() async {
        guard let item = photoItem else { return }
        do {
            let data = try await item.loadTransferable(type: Data.self)
            try Task.checkCancellation()
            guard let data, !data.isEmpty else {
                photoItem = nil
                appState.showToast("无法读取这张照片，请换一张")
                return
            }
            draftPhoto = data
            photoItem = nil
        } catch {
            guard !Task.isCancelled else { return }
            photoItem = nil
            appState.showToast("读取照片失败，请重试")
        }
    }

    private func routeInput() {
        guard photoItem == nil else { return }
        isInputFocused = false
        switch HomeInputRouter.destination(text: draftText, hasPhoto: draftPhoto != nil) {
        case .empty: break
        case .chat: openChat()
        case .record: openLogSheet()
        case .choose: choosesIntent = true
        }
    }

    private func openChat() {
        guard draftPhoto == nil else { openLogSheet(); return }
        chatEntry = ChatEntry(text: draftText)
        isInputFocused = false
    }

    private func openLogSheet() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard photoItem == nil, !text.isEmpty || draftPhoto != nil else { return }
        isInputFocused = false
        appState.pendingLogText = text
        appState.pendingLogPhoto = draftPhoto
        draftText = ""
        draftPhoto = nil
        Haptics.tap()
        appState.isQuickLogPresented = true
    }

    // MARK: - 健康同步

    private func syncHealth(force: Bool) async {
        guard health.isAvailable else { return }
        if !force, let last = health.lastSyncDate, Date().timeIntervalSince(last) < 3_600 {
            return
        }
        guard health.hasRequestedAuthorization || force else { return }
        await health.sync(days: 30, into: context)
    }
}

/// 健康指标小方块。
///
/// 图标是**彩色符号直接放在中性底上**（不是实色容器）—— 小尺寸下容器会喧宾夺主，
/// 而这里的重点是指标数字。见设计系统 §2「语义色的用法只有一种」。
struct StatTile: View {

    let symbol: String
    let tint: Color
    let title: String
    let value: String
    let unit: String
    let delta: String
    var deltaTint: Color = Theme.secondaryLabel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                Text(title)
                    .font(Theme.Font.badge)
                    .fontWeight(.regular)
                    .foregroundStyle(Theme.secondaryLabel)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Theme.Font.metric)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .padding(.top, 7)

            Text(delta)
                .font(Theme.Font.badge)
                .fontWeight(.regular)
                .foregroundStyle(deltaTint)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, 11)
        .background(Theme.cardNested, in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))
    }
}

/// 记录行（今日与记录页共用）。
/// 时间放在右侧而不是标题下面 —— 扫一列时间就能定位，不用逐行读。
struct RecordRow: View {

    let item: RecordItem

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            RecordIcon(kind: item.kind)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(Theme.Font.headline)
                        .lineLimit(2)
                    if item.hasPhoto {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryLabel)
                    }
                    if let badge = item.badge {
                        Badge(badge.text, tone: badge.tone)
                    }
                }
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(Theme.Font.footnote)
                        .foregroundStyle(item.isPendingNote ? Theme.warning : Theme.secondaryLabel)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: Theme.Spacing.xs)

            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                Text(Format.time(item.date))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.tertiaryLabel)
                    .monospacedDigit()
                if !item.isEditable {
                    // HealthKit 同步来的记录只读，源数据在「健康」App
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryLabel)
                        .accessibilityLabel("只读")
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

#Preview {
    TodayView()
        .environmentObject(AppState())
        .modelContainer(try! AppModelContainer.inMemory())
}
