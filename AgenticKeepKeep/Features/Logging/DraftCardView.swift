import SwiftUI

/// 确认卡片：解析结果的每个字段都可点按修改
struct DraftCardView: View {

    @Binding var draft: LogDraft
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: Theme.Spacing.m) {
                RecordIcon(kind: draft.kind.recordKind)
                Text(draft.kind.headerTitle)
                    .font(Theme.Font.headline)
                Spacer()
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.tertiaryLabel)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除这条\(draft.kind.headerTitle)")
            }

            switch draft.kind {
            case .workout:
                WorkoutDraftFields(draft: $draft.workout)
            case .meal:
                MealDraftFields(draft: $draft.meal)
            case .metric:
                MetricDraftFields(draft: $draft.metric)
            case .note:
                NoteDraftFields(draft: $draft.note)
            }
        }
        .card()
    }
}

/// 表单行：标签 + **可直接编辑**的值。
/// 标签 12pt 次级色 + 固定宽度，这样上下几行的数值左边缘是对齐的。
struct DraftFieldRow: View {

    let label: String
    @Binding var text: String
    var placeholder: String = "—"
    var keyboard: UIKeyboardType = .default

    private static let labelWidth: CGFloat = 36

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.secondaryLabel)
                .frame(width: Self.labelWidth, alignment: .leading)

            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textFieldStyle(.plain)
                .font(Theme.Font.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, 10)
        .background(
            Theme.cardNested,
            in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous)
        )
    }
}

/// 合计高亮行：把这一组字段加起来的结果单独提出来，不让用户自己心算。
/// 用中性底 + 彩色图标，不是淡色底 —— 见设计系统 §2。
struct DraftTotalRow: View {

    let text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 12))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(Theme.Font.footnote.weight(.semibold))
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, 11)
        .background(
            Theme.cardNested,
            in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous)
        )
    }
}

// MARK: - 各类草稿的编辑界面

struct WorkoutDraftFields: View {

    @Binding var draft: WorkoutDraft

    var body: some View {
        VStack(spacing: 8) {
            DraftFieldRow(label: "标题", text: $draft.title, placeholder: "如「胸 + 三头」")

            ForEach($draft.exercises) { $exercise in
                VStack(spacing: 6) {
                    DraftFieldRow(label: "动作", text: $exercise.name, placeholder: "动作名")
                    HStack(spacing: 6) {
                        DraftFieldRow(label: "重量", text: $exercise.weightText, placeholder: "kg", keyboard: .decimalPad)
                        DraftFieldRow(label: "次数", text: $exercise.repsText, placeholder: "次", keyboard: .numberPad)
                        DraftFieldRow(label: "组数", text: $exercise.setsText, placeholder: "组", keyboard: .numberPad)
                    }
                }
                .padding(.bottom, 4)
                .overlay(alignment: .topTrailing) {
                    if draft.exercises.count > 1 {
                        Button {
                            draft.exercises.removeAll { $0.id == exercise.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -6)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    draft.exercises.append(ExerciseDraft())
                } label: {
                    Label("添加动作", systemImage: "plus.circle")
                }
                .buttonStyle(PlainActionButtonStyle(font: Theme.Font.subheadline))

                Spacer()

                DraftFieldRow(label: "RPE", text: $draft.rpeText, placeholder: "1-10", keyboard: .decimalPad)
                    .frame(width: 130)
            }

            DraftFieldRow(label: "备注", text: $draft.note, placeholder: "可选")
        }
    }
}

struct MealDraftFields: View {

    @Binding var draft: MealDraft

    var body: some View {
        VStack(spacing: 8) {
            Picker("餐次", selection: $draft.mealType) {
                ForEach(MealType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            ForEach($draft.items) { $item in
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        DraftFieldRow(label: "食物", text: $item.name, placeholder: "食物名")
                        DraftFieldRow(label: "分量", text: $item.amountText, placeholder: "如 1 碗")
                    }
                    HStack(spacing: 6) {
                        DraftFieldRow(label: "热量", text: $item.caloriesText, placeholder: "kcal", keyboard: .decimalPad)
                        DraftFieldRow(label: "蛋白", text: $item.proteinText, placeholder: "g", keyboard: .decimalPad)
                    }
                    HStack(spacing: 6) {
                        DraftFieldRow(label: "碳水", text: $item.carbsText, placeholder: "g", keyboard: .decimalPad)
                        DraftFieldRow(label: "脂肪", text: $item.fatText, placeholder: "g", keyboard: .decimalPad)
                    }
                }
                .padding(.bottom, 4)
                .overlay(alignment: .topTrailing) {
                    if draft.items.count > 1 {
                        Button {
                            draft.items.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -6)
                    }
                }
            }

            Button {
                draft.items.append(FoodDraft())
            } label: {
                Label("添加食物", systemImage: "plus.circle")
                    .font(Theme.Font.subheadline)
            }
            .buttonStyle(PlainActionButtonStyle(font: Theme.Font.subheadline))

            if draft.totalCalories > 0 {
                DraftTotalRow(
                    text: "合计 ~\(Format.number(draft.totalCalories)) kcal · 蛋白 \(Format.number(draft.totalProtein))g"
                )
            }

            Text("热量与营养素均为 AI 估算值，可手动修正")
                .font(Theme.Font.badge)
                .fontWeight(.regular)
                .foregroundStyle(Theme.tertiaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MetricDraftFields: View {

    @Binding var draft: MetricDraft

    var body: some View {
        VStack(spacing: 8) {
            Picker("类型", selection: $draft.kind) {
                ForEach(MetricKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            DraftFieldRow(
                label: "数值",
                text: $draft.valueText,
                placeholder: draft.kind.unit,
                keyboard: .decimalPad
            )

            DraftFieldRow(label: "备注", text: $draft.note, placeholder: "可选")
        }
    }
}

struct NoteDraftFields: View {

    @Binding var draft: NoteDraft

    var body: some View {
        VStack(spacing: 8) {
            TextField("写点什么", text: $draft.text, axis: .vertical)
                .lineLimit(2...5)
                .font(Theme.Font.body)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, 10)
                .background(Theme.cardNested, in: RoundedRectangle(cornerRadius: Theme.Radius.inner, style: .continuous))

            Text("无法归类的记录会保存为「待归类」笔记，之后可以再解析。")
                .font(Theme.Font.badge)
                .fontWeight(.regular)
                .foregroundStyle(Theme.tertiaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
