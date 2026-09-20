# 第 27 轮 · checklist

- [x] 需求文档：[requirements.md](requirements.md)，范围已确认：默认开、文字先行、温度过渡。
- [x] `LocalMiloError.thinkingUnconverged`：新错误码与文案，仅在降级重试也失败时对用户可见。
- [x] `LocalMLXPolicy` 新增 `thinkingTemperature = 0.6` 与 `thinkingBudget = 1024`（字符近似 tokens）。
- [x] `LocalPrompt.render` 读取 `request.thinkingEnabled`：开块 `</think>` 由模型闭合；历史回合保持空闭合块。
- [x] `LocalPrompt.parse` 剥离首个 `</think>` 前的思考段；未闭合仍拒绝；工具解析逻辑不变。
- [x] `LocalOutput` 重写为纯字符串状态机：思考/正文分相流式、`</think>` 尾部防截断、标签防截断沿用、子预算溢出回调、`thinking: false` 时按纯正文流式。纯逻辑无 MLX，便携测试可覆盖。
- [x] `generate()`：思考请求用 `thinkingTemperature`；溢出取消与未闭合判定统一为 `thinkingUnconverged`；含 `<think>` 才判未收敛（模型无视开块直接作答不算失败）；空回答也算未收敛。
- [x] 降级重试：同请求 `thinkingEnabled=false` 重发一次，换新取消旗标并登记，防止 unload 期间误重试与已终止消费者的无效生成；首因保留。
- [x] 测试：`LocalMiloTests` 更新思考剥离期望并新增开块渲染／工具前思考剥离；新增 `LocalThinkingStreamTests`（7 项：分相流式、尾部防截断、溢出一次性、标签防截断、answerText、flush、非思考纯流式）。
- [x] 更新 [docs/README.md](../README.md) 轮次索引。
- [x] 本地 portable 测试：本环境无 Swift 工具链，未执行；以 iOS CI 结果为准（如实记录）。
- [x] iOS 单测与编译：CI [35508236676](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/35508236676)，提交 `cc45429`，**420 项 XCTest，0 失败**（较 411 新增 9 项：思考流式 7 项 + 渲染／剥离 2 项）。
- [ ] 真机验证：首字等待、思考循环发生率、格式正确率（开关开 vs 关）；官方警告 0.8B 易循环，未验证前不宣称稳定。

## 已知简化（记录在案）

- 历史回合思考内容不随请求回传（`preserve_thinking` 未启用；0.8B 支持列表未明确包含）。
- 图文（VLM）路径思考未做，需改私有包传 `enable_thinking`，列为后续。
- 采样仅 temperature 0.6 过渡；官方防循环参数（top_p/presence_penalty）需包侧暴露后配置。
- 子预算按字符数近似 tokens，中文 1 字 ≈ 1 token；纯英文思考会提前触发（偏保守）。
