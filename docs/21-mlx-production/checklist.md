# 第 21 轮 · MLX 正式接入 checklist

## 需求与范围
- [x] 记录独立验证版的用户真机通过反馈，明确证据边界。
- [x] 新建迁移分支与正式需求。
- [x] 用户确认图文同轮；正式工具 8K 上限、1024 输出、单图最长边 384，真机另验。

## 开发
- [x] 正式目标接入锁定 MLX 依赖，移除 llama.cpp 链接及构建步骤。
- [x] MLX 固定模型清单、多文件后台下载、哈希校验、旧安装和任务隔离。
- [x] 保留模板、工具白名单、参数校验；实现 tokenizer 预算、非思考、流式输出、JSON 失败保护。
- [x] 所有 Agent 串行调度、取消、后台、内存警告首因、释放模型和缓存。
- [x] 现有 UI 的模型名称／体积／能力文案与新引擎一致。
- [x] 图文根据确认范围实施，未验证能力明确隔离。

## 验证
- [x] 自动测试覆盖预算、安装格式、任务隔离、结构化结果、流式控制标签与取消。
- [x] 运行现有可移植回归及 Swift 语法检查。
- [x] Apple SDK 正式 App 编译及全量 XCTest：`6c68ee0`，393 项、0 失败。
- [ ] 真机文字／工具／后台下载／连续请求／内存复测。
- [x] 更新证据、IPA 下载与包内检查；保留图文／8K／后台真机未验收项。

## 当前证据
- 27 项可移植 XCTest 通过，Swift 语法解析及 diff 检查通过。
- 视觉配置两个文件已按固定 revision 下载并核对 SHA-256；上游支持 Qwen3.5 与 Qwen3VLProcessor。
- 图文仅接入，不把静态配置检查视为实际模型看图通过；真机与任务质量仍待新版 IPA。

[安装说明与验证边界](validation.md)。

## IPA
- 0.5.0 (21)，源码 `6c68ee0`；[构建成功](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/35380521646)。
- [下载 IPA](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/35380521646/artifacts/10562367633)。已核对原 Bundle ID、小组件、MLX Metal 资源及不再携带 llama 框架。
