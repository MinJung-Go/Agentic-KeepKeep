# 第 26 轮 · checklist

- [x] 需求文档：[requirements.md](requirements.md)。
- [x] 改 `LocalMLXPolicy.maximumOutput`：1024 → 2048，唯一事实源。
- [x] 更新预算边界测试：14336／14337 输入、输出 2049 拒绝、`outputLimit` 期望值。
- [x] 更新教练派生值测试：`outputReserve` 2048、`inputLimit()` 13824、`maxTokens` 2048。
- [x] 检查全仓无其他 1024 落点：UI 文案、README、推理包均无硬编码；历史评测脚本（第 19 轮 llama.cpp 时代）不属于现路径，不改。
- [x] 更新 [docs/README.md](../README.md) 轮次索引。
- [ ] 本地 portable 测试：本环境无 Swift 工具链，未执行；以 iOS CI 结果为准（如实记录）。
- [ ] iOS 单测与编译：push 后 GitHub Actions（记录提交号与单测数量）。
- [ ] 真机验证：2048 长回复的内存、首字等待与截断体验（需用户设备，另行反馈）。
