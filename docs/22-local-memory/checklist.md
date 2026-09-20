# 纯文字 L14 checklist

- [x] 记录用户“你好”后 L14 的复现信息与根因证据缺口。
- [x] 明确需求，保持 8K 上限与原内存保护。
- [x] 按用户纠正撤回纯问候精简；原角色／历史／工具构建路径恢复。
- [x] 核验 0.8B MLX 图文候选的 ModelScope 文件元数据。
- [x] 切换 0.8B 固定版本完整清单、型号显示、许可及版本号。
- [x] 隔离旧模型后台任务与安装状态，增加迁移回归。
- [x] 提交、推送，完成 iOS 单测与 IPA 归档。
- [ ] 真机验证加载、工具和图文效果。
- [x] 阶段、路径、token 与内存采样诊断，错误无正文数据。
- [x] GPU 计算结束后释放资源。
- [x] 新增边界测试并运行可用回归。
- [x] iOS 编译与完整 XCTest。
- [ ] 同设备“你好”与正常工具请求复测。

## 本地验证
- 撤回问候优化及其测试，保留诊断、内存保护和 GPU 清理改动。
- 用户已授权切换 0.8B 并打包，正式 App 本轮切换；独立 Lab 保持基线。

- 本地 Swift 6.0.3 portable XCTest：29 项通过；Swift 语法解析、`git diff --check` 通过。完整 iOS 测试已通过（见下）。
- ModelScope 固定 revision 的 8 个文件共 645,303,999 字节；配置文件 SHA-256 实测匹配，qwen3_5 与现有 MLX LLM／VLM factory 兼容。权重加载仍需真机验收。

## CI 验证
- 源码提交：`ba78c6fe54b0f9f4a262b45d1eeb6f4db8c09038`。
- [GitHub Actions 35483344157](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/35483344157)：iOS 编译通过，**397 项 XCTest，0 失败**。Release 归档与 IPA 上传成功。
- 7 个非权重文件已实际下载并核对大小／SHA-256；权重文件固定元数据，App 下载后执行完整 SHA-256。

## IPA · 0.5.1（22）
- [下载未签名 IPA](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/35483344157/artifacts/10596852788)，使用原侧载方式重签安装。
- 已下载产物核验：Bundle ID `com.minjung.keepkeep`，版本 `0.5.1` / build `22`，iOS 17.0+，包含 MLX Metal library 与 Widget、0.8B 型号许可；无 GGUF／safetensors 权重或 llama.framework。
- IPA：8,732,435 字节；SHA-256：`47ca37297744e032994d6dab3c63e7589cc8d4b56f0942fa11b3efcbaa910e8a`。
- 安装后进入离线设置下载约 645 MB 新模型，原 2B 文件不作为本版就绪条件；用户记录保持原存储。
- 真机待验收：纯文字“你好”、完整历史与工具调用、单图；如仍发生 L14，反馈新错误中的阶段／路径／token／采样峰值。尚未宣称内存故障已根治。
