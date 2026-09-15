# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目状态

**已实现并可装机运行**：P0/P1/P2 全部完成，另经两轮真机反馈修复（当前 186 个单元测试）。
最新可安装版本由 `v*` tag 触发 GitHub Actions 产出，见 Actions Artifacts。

> 04 轮（界面与交互优化）进行中，分支 `feat/ui-polish`。

需求基线按轮次放在 [docs/](docs/)，索引与约定见 [docs/README.md](docs/README.md)。**改需求或砍范围前，先读对应轮次的需求文档。**

## 文档约定（docs/）

按「轮次」组织：一轮一个文件夹，文件夹内自带该轮的需求、清单与设计稿。

| 轮次 | 主题 | 文档 |
|------|------|------|
| 01-foundation | 项目基线（P0/P1/P2 全量实现） | requirements.md · checklist.md · design.html |
| 02-device-feedback | 真机反馈修复（bug 修复轮） | checklist.md |
| 03-coach-streaming | 教练综合个人数据 + 流式回复 + 图片与文字同发 | requirements.md · checklist.md |
| 04-ui-polish | 界面与交互优化（设计系统 v2、动作示意图） | requirements.md · design-system.md · design.html · checklist.md |

- 新轮次建 `docs/NN-<slug>/`，**先写 `requirements.md` 并确认，再动手**
- **除纯 bug 修复轮外，每轮都必须有需求文档**；bug 修复轮只写 `checklist.md`（现象 / 根因 / 修复 / 验证）
- `checklist.md` 记录实施项与验证结果，包含 CI 提交号与单测数量
- 设计稿（高保真 HTML、线框、真机截图）放同一文件夹，命名 `design.*`

## 构建与测试（无 Mac 开发链路）

Xcode 工程不进库，由 **XcodeGen** 从 `project.yml` 生成；**GitHub Actions**（macos runner）负责构建/测试/出 IPA。

- 生成工程：`xcodegen generate`
- 单测（本地有 Mac 时）：`xcodebuild test -scheme AgenticKeepKeep -destination 'platform=iOS Simulator,name=iPhone 15 Pro'`
- 出 IPA：打 `v*` tag → archive + Payload 打包 → 未签名 IPA 上传 Artifacts → AltStore/Sideloadly 自签装机
- CI 触发条件：push 到 `main`、`v*` tag、PR。**功能分支需手动触发**：`gh workflow run ios.yml --ref <branch>`

## 架构（已与用户确认的决策）

分层单向依赖，Agent 层为纯逻辑层（输入数据摘要 + prompt → Codable JSON），不碰 UI/数据库，可独立单测：

```
Features/ (SwiftUI UI)  →  Core/Agents/  →  Core/LLM/ (BYOK 协议抽象)  →  Core/Data/
```

- **SwiftData 是唯一数据源**；HealthKit 只读（睡眠/HRV/心率/步数/运动记录），**不回写**
- 四个 Agent：`ParserAgent`（自然语言→结构化记录）、`CoachAgent`（对话式创建/调整课程表，function call）、`AnalystAgent`（周月报）、`VisionAgent`（食物照片→热量）
- **BYOK**：主模型为 OpenAI 兼容端点（用户自填 API Key，Keychain 存储），另支持 Anthropic 原生协议；无自建服务器
- LLM 层同时支持**一次性**（`complete`）与**流式**（`stream`，含 `reasoning_content` / `thinking_delta` 思考内容）；两种协议的流式拼接共用 `LLMStreamAccumulator`
- 发给 LLM 的只能是**聚合摘要**（`AnalysisDigest` / `CoachContextBuilder` 产出），原始记录不出设备
- 解析失败必须降级为 `RawNote` 留存原文，不丢用户数据
- 记录弹窗是**对话流**：`LoggingViewModel` 用 turns 承载「用户输入 / 解析卡片 / 失败说明」；照片是附件，与文字一起发送

## 目录约定（Xcode 标准布局）

- `AgenticKeepKeep/App` — @main 入口与 App 级状态
- `Core/Agents` — 四个 Agent 与 DTO；`Core/LLM` — 协议抽象与两个客户端；`Core/Data` — SwiftData 模型、聚合器、导入器、HealthKit 桥接；`Core/Design` — 主题与通用视图；`Core/Support` — 图片压缩、语音识别
- `Features/` — Today / Records / Logging / Plan / Insights / Settings
- `AgenticKeepKeepTests/` — 按 `AgentTests` / `DataTests` 组织

## 工作流约定

- 一轮工作 = 建分支 → 写需求文档与清单 → 分批实现（每批 push 后等 CI 绿）→ 开 PR → 合并回 main → 打 tag 出 IPA
- 敏感配置（API Key 等）不进库；`.claude/` 已 gitignore
- commit / push 需用户明确要求
- 真机才能验证的改动（相机、健康数据、通知、签名相关）要在报告里明确标注，不要声称已验证
- 改动完成后如实报告改了什么、没改什么，不夸大
