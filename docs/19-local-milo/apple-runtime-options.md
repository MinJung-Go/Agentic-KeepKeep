# 苹果端 Qwen 候选核验 · 2026-09-18

用户要求默认 ModelScope，并提出苹果端专用推理路线。当前交付先使用已通过 iOS 编译的 llama.cpp／Metal；MLX 属于已找到的候选，尚未迁移或在 iPhone 验证。

| 路线 | 当前证据 | 尚缺验证 |
|---|---|---|
| GGUF + llama.cpp／Metal | iOS 构建通过，包内框架约 8.14 MB；ModelScope 两文件与已测版本 SHA-256 一致 | 真机速度、内存、模型任务质量 |
| MLX Swift LM + Qwen 图文 | 官方发布记录含 Qwen3.5 Vision；ModelScope MLX 4bit 仓库包含视觉配置 | 固定 Swift 包版本、iOS 最低版本、加载、图片和工具整条链路 |
| Core ML 转换模型 | 苹果提供通用设备端推理与模型转换工具 | 未核验可直接满足本项目 Qwen3.5 图文与工具需求的完整模型包 |

## ModelScope 上的 MLX 候选

[mlx-community/Qwen3.5-2B-4bit](https://modelscope.cn/models/mlx-community/Qwen3.5-2B-4bit)

- revision：`ffa48c63955c56e22d76c1b2acd9b89e26310618`。
- 主权重 `model.safetensors`：1,722,271,785 字节；还需要 tokenizer、config、processor 等文件，不能把主权重大小当完整下载量。
- SHA-256：`713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5`（仓库元数据，尚未在本机下载校验）。
- 配置：`Qwen3_5ForConditionalGeneration`，有 `vision_config`；4bit affine、group_size 64。
- 模型卡注明通过 mlx-vlm 0.3.12 从 Qwen3.5-2B 转换。Python 示例不等于 iPhone 适配已通过。
- 也搜到 OptiQ 4bit 版本，但其额外视觉／MTP 文件和运行时要求需另核验，不能只比较语言权重大小。

## 官方资料

- [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)：LLM／VLM 的 Swift 实现。
- [发布记录](https://github.com/ml-explore/mlx-swift-lm/releases)：含 Qwen3.5 Vision 支持和后续修复。
- [Foundation Models](https://developer.apple.com/documentation/FoundationModels/)：苹果模型和新版本自定义模型接口；系统模型受设备／地区可用性限制。当前 MLXFoundationModels 桥接要求 iOS 27 SDK，不能据此宣称覆盖本 App 的 iOS 17 用户。
- [Core ML](https://developer.apple.com/documentation/coreml)：苹果设备端机器学习框架；需要适配其模型格式与执行路径，不能直接把 GGUF 下载地址换成 safetensors 就使用。

下载站点与推理引擎是两个独立选择。ModelScope 可以提供 GGUF 或 MLX 文件；两条路线都可使用国内下载源。暂不承诺 MLX 更快、更省内存或解决事实幻觉，须用同一用例和目标手机比较。
