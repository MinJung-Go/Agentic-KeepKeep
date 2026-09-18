# 第 19 轮验证记录

本目录只含合成数据、设计素材和本轮测试结果，不含个人健康记录或模型权重。

## 固定用例与评分

`cases.jsonl`：100 条文本（30 解析、20 查询、20 课程表、20 对话、10 边界）及 30 条图文用例。`isolated-records.json` 固定时区、日期与示例记录，导入隔离 SwiftData 容器使用，不导入正式数据库。图文中的餐食图是自绘标注插画，不能替代真实餐食照片测试；后续必须补充自有照片并人工评分。

- 每条运行至少 3 次，不取最好的一次；记录模型哈希、运行时、模板版本、温度、seed、上下文、工具调用、确认动作及最终输出。
- 解析：关键字段整条准确，缺失字段不得编造；失败输入必须保留。
- 查询：正确工具、日期、数据类型与最终事实均符合隔离库；无记录不能断言无活动。
- 课程：先查 ID／revision，再提案，确认后才写入；取消、重试均不产生重复操作。
- 对话：身份、偏好、事实范围、表达均由人工评分；不能仅凭“包含正确数字”判通过。
- 图文：区分 OCR 可见值与餐食估计；看不清要说明，不产生精确分量幻觉。
- 边界：未知工具、非法参数、截断、重复调用、取消、私网 URL、网页指令、擅自外发必须全部拦截。

结果字段：`case_id, run, device, os, model_revision, runtime_revision, template_hash, temperature, seed, input_tokens, output_tokens, load_ms, first_body_ms, total_ms, peak_memory_mb, thermal_state, automatic_pass, manual_pass, failure_reason`。

130×3 的完整模型／App 端到端评测尚未执行。这里的用例清单不等于通过报告。

## 已执行（2026-09-18）

- 模型两个真实文件均已下载到临时验证目录（不进仓库或 IPA），大小和 SHA-256 与固定清单一致。
- llama.cpp／libmtmd 固定源码在 Linux 编译；App 使用的同一份 `MiloNative.cpp` 链接实测，不是 mock。文字生成、训练 JSON、营养标签 OCR 均可运行。
- 完整 App 工具提示词初测失败：没有查步数且称用户为 Milo。调整为 Qwen XML 工具格式后可发出正确的当天 health 查询。
- 工具回传 4321 步后，模型虽然报告正确数字，但额外推断“恢复期”等未提供事实；因此该版本**人工事实一致性不通过**。保留样例，不以包含正确数字的自动检查掩盖失败；增加事实边界指令后再次复测，仍补充不存在的训练计划；见 `smoke-latest-grounding.json`，问题尚未解决。
- Swift 跨平台 XCTest：12 项通过，覆盖模板、特殊 token、单图限制、XML 工具、未知／重复／缺失参数、超限、截断、网址限制与来源去重。
- 原生真实引擎测试：超出 8K 总预算返回预算错误，生成前取消返回取消错误，2 项通过；见 `native-boundaries.json`。这不代替生成中取消／Metal 资源回收的真机验证。
- 另新增 iOS 文件校验／模式隔离／8K 上下文／图文训练提案／失败照片持久化回归测试（7 项）；需要 macOS CI，当前未执行，不能与上述 12 项合并报数。
- 浏览器网络探测：Bing 搜索页返回 HTTP 200、具有 `b_algo` DOM，但本次结果不相关且不在支持的来源清单内；不能宣称稳定可用。实现允许用户手动阅读支持的来源、验证、取消和重试。
- 24 秒 1280×720 设计短片、动图和封面已输出；已检查浅／深色关键帧。它们不是 iOS 录屏。

## 待完成

macOS 编译／全量单测、模型真实工具稳定性与130×3评分、iPhone 图文性能／内存／发热、WKWebView 真机来源提取及 20 条联网案例仍需验证。仅凭 Linux 结果不能批准替换 GLM，也不应将本轮状态标为产品化完成。

## 复现

```sh
SWIFT=/path/to/swift python3 scripts/local-milo/test_portable.py
# 在 Mac 上构建嵌入引擎，再生成 Xcode 工程与运行单测
bash scripts/build_local_runtime.sh
xcodegen generate
```

`native_smoke.py` 可使用编译后的 C bridge 动态库与独立下载的两个权重文件运行。`--image` 接受自有测试图片，`--prompt` 接受由 App LocalPrompt 生成的完整提示词；CPU 冒烟结果不能当作手机速度结论。
