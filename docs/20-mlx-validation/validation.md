# MLX 独立验证：实施与证据

## 已实现，尚待 Apple 编译与真机验收

- 分支：`feat/mlx-runtime-validation`。独立 `project.mlx.yml`、`MiloMLXValidation/`、包名 `com.minjung.milolab`。
- 用户已确认独立 App 与三屏设计；原生页面分为准备、测试、报告，使用系统浅深色和 Milo 素材。
- MLX Swift **0.31.3**，MLX Swift LM **2.31.3**，iOS 17+，Xcode 16.4 / Swift 6.1。仅链接 `MLXLLM` 和 `MLXLMCommon`，不链接 `MLXVLM` 或 llama.cpp。
- ModelScope：`mlx-community/Qwen3.5-2B-4bit`，revision `ffa48c63955c56e22d76c1b2acd9b89e26310618`；实际下载清单见 `MiloMLXValidation/Resources/model-manifest.json`。
- 固定版本的 config、tokenizer_config、chat_template 已从 ModelScope 下载并与清单 SHA-256 核对；未在 Linux 下载整个权重并执行 MLX。
- 上游 `LLMModelFactory` 注册 `qwen3_5`；`Qwen35Model.sanitize` 过滤视觉权重。**loader 会先读取 safetensors 再过滤，不能据此承诺加载峰值不包含视觉权重或比 llama.cpp 更省内存。**
- 源 tokenizer_config 无内嵌模板，运行目录单独嵌入经过校验的 `chat_template.jinja`，原文件不修改。目录模式加载 tokenizer，不使用 Hugging Face 模型 ID。
- 模板 `enable_thinking=false` 分支输出闭合的空 think 块；Swift tokenizer 的实际模板渲染仍需 Apple 测试。
- 每轮独立加载、生成、卸载；2K 包含 256 输出预留；使用实际 tokenizer 计数。MLX 缓存限制 16 MiB、prefill step 64，不修改系统内存保护。
- 使用固定版本中仍可用的同步生成接口，确保回调循环返回后才释放容器。该接口有 deprecated 警告；升级依赖时需重新验证取消语义。
- 取消不是抢占式：加载、prefill 正在执行时，要等库返回检查点；界面显示“正在停止”。系统强杀无法保证生成最终报告。
- 下载为前台 URLSession 流式落盘，逐文件校验；Wi-Fi 默认、蜂窝需显式打开。完成文件保留，未完成文件重新下载；此验证版不承诺后台／分片续传。
- 进程内存每 200ms 采样，最多 1800 个周期点，额外保留阶段点；MLX 峰值独立记录。报告不含提示词／回复，保留错误 domain/code，不导出可能含路径或正文的错误描述。

## 本地证据

2026-09-18，Linux Swift 6.0.3：8 项纯逻辑 XCTest 通过（预算边界、首个停止原因、并发停止、清单路径／重复文件／大小／哈希格式、固定下载地址、报告隐私、进程峰值）。完整 Swift 源码语法解析通过。

这不等于 iOS SDK 类型检查、下载／哈希实现单测或 MLX 真机推理通过。CI 提交号：暂无，本轮尚未提交／推送。

## 构建

```sh
xcodegen generate --spec project.mlx.yml
xcodebuild -project MiloMLXValidation.xcodeproj -scheme MiloMLXValidation \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
scripts/mlx-validation/test-portable.sh
```

`.github/workflows/mlx-validation.yml` 为独立手动 workflow，编译设备版后产出未签名 Milo Lab IPA。不会触发原 Moveliq 发布链路。本轮尚未触发。

## iPhone 验收步骤

1. 安装 Milo Lab，与 Moveliq 并存；确认没有请求健康／照片权限，也没有读取其数据。
2. Wi-Fi 下载，尝试取消／切后台／断网，再继续；已完成文件应复用。文件缺失或篡改需重新下载，不能开始推理。
3. 飞行模式下冷启动，点击校验（已有完整文件时不需网络），依次测试三条短文本。
4. 每条先单次，再连续 5 轮。导出 JSON，检查首字、加载、采样峰值、unloaded 活跃内存是否回落。
5. 生成中停止、切后台；诊断原因不得被 cancelled 覆盖。内存警告测试需 Xcode 注入或真实系统通知，不能把关闭其他 App 当作充分测试。
6. 与旧引擎同一台手机、相同提示词／输出上限对比；没有这组数据前不做“MLX 已解决 L14”的结论。

## 上游依据

- [MLX Swift 0.31.3](https://github.com/ml-explore/mlx-swift/tree/0.31.3)
- [MLX Swift LM 2.31.3](https://github.com/ml-explore/mlx-swift-lm/tree/2.31.3)
- [Qwen3.5 ModelScope 转换仓库](https://modelscope.cn/models/mlx-community/Qwen3.5-2B-4bit)
