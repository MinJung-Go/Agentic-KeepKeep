# Agentic-KeepKeep 实施 Checklist

- 日期：2026-09-11（2026-09-12 更新状态）
- 依据：[需求文档](requirements.md) v1.1 + [界面设计稿](design.html) v1.1
- 状态：**P0 / P1 / P2 代码已完成**，CI（构建 + 单测）全绿；详见文末「验证记录」

## 前置：无 Mac 开发链路（XcodeGen + GitHub Actions）

- [x] `project.yml`（XcodeGen 工程定义：iOS 17+、HealthKit、App Group、手写 Info.plist）
- [x] `.github/workflows/ios.yml`：`macos-latest` + xcodegen + `xcodebuild build/test`
- [x] tag 触发：`xcodebuild archive` + Payload 打包出 **未签名 IPA** → Actions Artifacts
- [ ] 装到真机：Artifacts 下载 IPA → AltStore / Sideloadly 自签安装
- [ ] （可选，后期）证书进 GitHub Secrets，workflow 直接出已签名 IPA
- [x] `Secrets.xcconfig` 未进库；Key 只在 App 设置页或 Keychain 中
- [ ] （可选）有 Mac 时 `xcodegen generate` 本地开发

## P0 — MVP：记录 → 存储 → 分析 ✅

### ① 界面骨架

- [x] OnboardingFlow：欢迎 → HealthKit 授权 → API Key 引导（均可跳过）
- [x] TabBar 骨架：今日 / 记录 / 课程表 / 洞察 / 设置；强调色 systemOrange
- [x] TodayView：日期头 + 健康快照卡 + 今日课程 + 今日已记录 + 底部常驻输入条
- [x] QuickLogSheet：输入 → 解析中态 → 确认卡片（字段可点改，保存/取消）
- [x] RecordsView：按日分组时间流 + 类型图标 + 来源徽标（AI 估算 / ⌚Watch / 待归类）
- [x] RecordDetailView：编辑 / 删除
- [x] InsightsView：报告卡 + ReportDetailView（正文 + AI 依据折叠区）
- [x] SettingsView：LLM 分区 + 数据分区 + 用量分区 + 关于 + 隐私说明
- [x] 状态界面：无网/无 Key 降级 RawNote；未授权显示引导卡；空态齐备

### ② 数据层

- [x] SwiftData 模型：WorkoutSession / ExerciseSet / MealEntry / FoodItem / BodyMetric /
      RawNote / HealthSnapshot / HealthWorkout / AnalysisReport / Plan / PlanDay / PlanExercise / ChatMessage
- [x] HealthKit 只读桥接：睡眠、HRV、静息心率、步数、活动消耗 → 每日 HealthSnapshot（幂等 upsert）
- [x] HKWorkout 读取：Watch 训练 + 第三方 App 运动，按 UUID 去重，标来源，只读

### ③ LLM 层

- [x] LLMClient 协议 + OpenAI 兼容客户端（GLM / OpenAI / 自定义）
- [x] Anthropic 原生协议客户端（Claude）
- [x] Keychain 存取 API Key；连接测试；用量统计（token + 调用次数）
- [x] JSONExtractor / 宽松解码（容忍代码围栏、字符串数字、字段别名）

### ④ 记录闭环

- [x] ParserAgent：自然语言 → 训练 / 饮食 / 指标 / 笔记四类
- [x] 多条目 → 多张确认卡片（可增删条目、逐字段编辑）
- [x] 解析失败降级 RawNote；详情页可「重新解析 / 标记已处理 / 删除」
- [x] 确认卡片即快捷表单（无网/无 Key 时手动录入通道）
- [x] 今日视图数据接通

### ⑤ 分析

- [x] DataAggregator：训练趋势 / 容量 / 停滞检测 / 营养聚合 → 摘要（只发摘要）
- [x] AnalystAgent 周报：平台期、渐进超负荷、训练-睡眠-饮食关联；持久化可回看
- [x] 数据不足时的引导空态

### ⑥ P0 测试

- [x] ParserAgent 语料单测（16 例，含代码围栏 / 字符串数字 / 裸数组 / 错误路径）
- [x] 聚合器（8 例）、HealthKit 桥接结构（模型层）、RecordImporter（9 例）
- [x] LLMClient mock 测试（断网 / 超时 / 非法 JSON 降级路径）

## P1 — 私教能力 ✅

- [x] Plan / PlanDay 模型（状态：待做/完成/跳过；编辑 + 备注）
- [x] CoachChatView：气泡对话 + function call 结果计划卡片（加入课程表 / 不采用）
- [x] CoachAgent：对话澄清 → `create_plan` 工具生成计划
- [x] 课程表手动编辑：增删改动作、改日期与状态
- [x] CoachAgent 调整建议流：`propose_plan_adjustment` → 差异卡片（减载/换动作/顺延/跳过）
- [x] 饮食分析：日均热量与宏营养素、蛋白质目标缺口、每日热量柱状图
- [x] 今日视图接入「今日课程」卡片（可一键标记完成）

## P2 — 增强 ✅

- [x] VisionAgent：食物照片 → 热量估算（PhotosPicker，降采样后发送，标注 AI 估算）
- [x] 趋势图表：体重 / 动作估算 1RM（前 3 动作分色）/ 每周训练容量 / 睡眠（Swift Charts）
- [x] 桌面小组件：今日训练 + 记录数（WidgetKit + App Group 共享 SwiftData）
- [x] 语音输入：系统 Speech 框架转写，填入输入框

## 发布前

- [x] 扫描密钥：仓库内无真实密钥（唯一命中的 `.claude/settings.json` 已被 gitignore 覆盖且从未提交，`git log --all` 已确认）
- [x] README 更新：Hero/特性/安装/权限与数据/已知限制（按 readme-crafter 规范，事实经代码与 CI 核对）
- [x] 打 `v0.1.0` tag 验证 IPA 产物可下载（Artifacts: `KeepKeep-unsigned-ipa`，739 KB）
- [ ] **真机验证**（需要设备）：HealthKit 授权流、离线记录降级、GLM Key 配置与连接测试、小组件、照片与语音
- [ ] 截图替换 README 中的设计稿链接（真机截图更有说服力）

## 验证记录

| 日期 | 提交 / 标签 | 结果 |
|------|------|------|
| 2026-09-11 | `f26cf2d` | CI 绿：构建 + 79 个单测（数据层 / LLM / Agent / 导入器 / 聚合器） |
| 2026-09-11 | `90dff2d` | CI 绿：教练调整流、饮食分析、趋势图表（86 例） |
| 2026-09-11 | `3e26651` | CI 绿：照片识别 + 语音输入 |
| 2026-09-11 | `18b3edd` | 小组件 target 构建通过；测试暴露 App Group 无权限时 SwiftData fatalError |
| 2026-09-11 | `9b521d5` | CI 绿：App Group 先探测再使用，unsigned 构建与免费侧载不再崩溃 |
| 2026-09-11 | `v0.1.0` | **IPA 构建成功**：archive + Payload 打包 → Artifacts `KeepKeep-unsigned-ipa`（739 KB） |

## 已知限制（需真机/账号条件）

- **免费 Apple ID 侧载**：HealthKit 与 App Group（小组件用）能力不可用，App 会降级
  （健康卡显示引导、小组件显示空态），记录与 AI 功能不受影响。完整功能需付费开发者账号（$99/年）。
- **GLM 模型名**：默认 `glm-5.3-flash` 按需求文档填写，实际调用前请在「设置 → 模型」确认与服务商文档一致。
- **照片识别与语音输入**在模拟器上可能不可用，需真机验证。
