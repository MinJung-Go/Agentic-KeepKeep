# 第 26 轮 · checklist

- [x] 需求文档：[requirements.md](requirements.md)。
- [x] 改 `LocalMLXPolicy.maximumOutput`：1024 → 2048，唯一事实源。
- [x] 更新预算边界测试：14336／14337 输入、输出 2049 拒绝、`outputLimit` 期望值。
- [x] 更新教练派生值测试：`outputReserve` 2048、`inputLimit()` 13824、`maxTokens` 2048。
- [x] 检查全仓无其他 1024 落点：UI 文案、README、推理包均无硬编码；历史评测脚本（第 19 轮 llama.cpp 时代）不属于现路径，不改。
- [x] 更新 [docs/README.md](../README.md) 轮次索引。
- [x] 本地 portable 测试：本环境无 Swift 工具链，未执行；以 iOS CI 结果为准（如实记录）。
- [x] iOS 单测与编译：CI [35506107114](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/35506107114)，提交 `fdee3e6`，**411 项 XCTest，0 失败**，测试与 IPA 双 job 成功。
- [x] `verify_ipa.py` 迁移到 MLX 时代：检查 bundle id／版本／metallib／三份许可／Widget，替换失效的 llama.framework 断言。
- [x] 版本号提升 0.5.3 (24)：de827bc 记录的 0.5.2 IPA 早于第 25 轮解析修复提交，同名不同内容，必须区分。
- [ ] 重建 0.5.3 (24) IPA 并核验产物（待 CI）。
- [ ] 真机验证：2048 长回复的内存、首字等待与截断体验（需用户设备，另行反馈）。

## 首轮产物（0.5.2/23，仅作过程记录）

- IPA 8,754,158 字节，SHA-256 `8045a1699099247d798a8ddbf53a2db621aba873cc4d07d32ebd547773f63c0d`；bundle `com.minjung.keepkeep`，iOS 17.0+；含 MLX Metal 库（3,814,924 字节）与 Widget；无权重文件。因版本与第 25 轮已公告的 0.5.2 冲突，不对外交付。
