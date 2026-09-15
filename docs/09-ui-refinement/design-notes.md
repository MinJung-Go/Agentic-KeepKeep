# 首批 UI 设计提案

入口：[design.html](design.html)。HTML 提案包括首页、图文记录确认、教练计划确认，各有深浅两种模式。其余原稿界面没有在本次全部重做；Figma 暂保留原稿基线。

## 视觉取舍

- 今日课程进入首屏，健康状态收为可展开摘要；概览使用一行计数，降低对主操作的干扰。
- 页面背景、内容卡、可编辑字段三层；聊天气泡改为中性色。
- 亮橙 `#FF9F0A` 搭配深色 `#241600` 按钮文字；浅色选中导航用深橙，保证白底可辨。
- 辅助文字：深色 `#B5B5BF`，浅色 `#595961`；更弱的元信息仍采用可辨认的灰色。
- 主要卡片圆角 22px，主按钮 15px；这里是本轮设计候选值，不自动修改旧设计规范或 App Theme。
- 记录确认和计划确认使用独立底部操作区，内容滚动不遮盖操作；普通记录输入仍在首页。
- 图标复用旧稿的 Ionicons SVG，将写死黑色描边改为 currentColor；品牌沿用已有壶铃/勾号图标。

## 可交互范围

- 展开健康数据、计划依据与其余训练安排。
- 修改餐次、食物、分量与营养字段，确认后保留卡片并锁定字段。
- 确认计划后保留回执，禁止同一个演示状态重复确认。
- 首页可以输入文字、选择本地图片并演示发送；以纯文本展示输入，没有远程上传、AI 调用或持久化。
- 顶部可筛选深浅模式、放大字号、重置演示。
- 训练执行、语音、继续调整和新增记录入口以提示说明后续行为，不冒充完整 App 流程。

## 验证

Chromium / Linux，1440px 展示页、393px 手机画板，以及 375px 浏览器视口。

- 六屏普通/1.2 倍字号：主要按钮均在手机可见区域，手机内部无横向溢出。
- 375px 浏览器视口：页面宽度 375px，六个手机容器宽 349px，无横向溢出。
- 展开教练长计划并滚到底部，确认区仍可见。
- 保存饮食及确认计划的回执可见；首页文字演示发送成功。
- 用截图复核深浅色和放大字号，修正蛋白质标签窄宽导致的换行。
- `node --check design.js` 与 `git diff --check` 通过。

[深色预览](previews/normal-dark.jpg) · [浅色预览](previews/normal-light.jpg) · [大字号深色](previews/large-dark.jpg) · [大字号浅色](previews/large-light.jpg)

这里没有验证 iOS 真机键盘、VoiceOver 或全部 Dynamic Type 档位，不运行 App 构建、不打 IPA。

## 独立预览修复

`design.html` 现在内嵌样式、脚本与 Logo，并预先生成六屏 HTML，单独打开即可查看；禁用 JavaScript 仍可显示设计，交互演示需要启用脚本。远程字体不可用时使用系统字体。Figma 仍为设计主稿，此文件仅为辅助预览。

维护源文件：`design.template.html`、`design.css`、`design.js`；修改后运行 `python3 docs/09-ui-refinement/build-preview.py` 生成独立文件（需要 Node.js）。

浏览器验证：将 HTML 单独复制到 `/tmp`，禁用脚本后仍显示 6 屏、手机宽度 393px、Logo 加载成功；启用脚本后保存回执正常显示。

## 全量UI版本

当前独立HTML包含16类界面×深浅两套，共32屏，对应Figma全量主稿33:2。新增页面是视觉设计稿：字段可输入、折叠可展开，主要按钮提示操作意图；搜索、筛选、导航及业务保存未实现。首批六屏的记录与确认演示保留。

## SwiftUI 落地规则

系统字体继续跟随 Dynamic Type，不将 Figma 中文替代字体嵌入App。主按钮使用 #FF9F0A 与深色文字；次级按钮及用户气泡采用中性色。原生表单、导航、键盘和健康授权保留系统行为。API密钥在引导页使用SecureField。设计稿内的目标、日期、动作及训练次数均由实际模型替代。

### 设计覆盖与代码映射

| 设计界面（各含深浅两套） | SwiftUI落地 |
|---|---|
| 今日 | TodayView：课程、折叠健康、紧凑概览、输入栏 |
| 记录确认 | QuickLogSheet / DraftCardView：固定确认、只读草稿回执 |
| 教练计划确认 / 生成中 | CoachChatView / PlanDraftCard / ThinkingBlock：确认栏、动作行、折叠思考 |
| 记录列表 | RecordsView / RecordRow：搜索、无结果、两行摘要 |
| 课程表 / 训练日编辑 | PlanView / PlanDayDetailView：简化计划头部，保留原生编辑和执行 |
| 洞察 / 训练报告 | InsightsView / ReportDetailView：共享样式与系统字体，保留真实KPI与依据 |
| 设置 / 隐私 | SettingsView / PrivacyInfoView：品牌、共享样式，保留权限和数据说明 |
| 训练详情 | RecordDetailView：保留原生可编辑表单，亮色标签深字 |
| 力量趋势 | TrendsView：单动作曲线、最新数值与单点 |
| 饮食分析 | NutritionAnalysisView：保留实际算法，辅助文字对比增强 |
| 首次启动 | OnboardingView：品牌、可滚动欢迎、密钥遮挡 |
| 小组件 | KeepKeepWidget：小/中尺寸与锁屏矩形 |

原生详情和设置继续采用系统表单，未硬编码设计稿的固定行数、示例值或目标。颜色、字体、按钮等共享调整覆盖这些页面。
