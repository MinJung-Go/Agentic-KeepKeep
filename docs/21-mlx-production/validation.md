# MLX 正式接入：验证与安装说明

## 实现边界

- 沿用已确认的下载／设置／照片交互布局，更新模型来源、格式、体积与错误说明；本轮没有新增迁移界面。
- 正式 App 保留 `com.minjung.keepkeep`，独立 Lab 保留 `com.minjung.milolab`。
- 新模型目录为 `LocalMilo/mlx-ffa48c63955c56e22d76c1b2acd9b89e26310618`，共 8 个固定版本文件；旧 GGUF 不兼容，不会自动删除。Lab 与正式 App 的沙盒隔离，无法自动共享已下载权重。
- 复用后台 URLSession 标识以重新连接并取消旧任务；新的下载意图与安装代际使用独立 defaults key，旧回调不能被新模型接收。
- 每个请求重新加载、完成后释放模型；纯文字使用 MLXLLM，照片使用 MLXVLM。首次请求校验原文件；运行目录硬链接权重并生成包含聊天模板的 tokenizer 配置，不修改原始文件。
- 文字保持既有非思考 ChatML 和工具协议；图文转换为带正确角色和图片占位的消息，再由 Qwen3VLProcessor 展开视觉 tokens。单张最长边 384，总输入加输出不得超过 8192 tokens，输出最多 1024，prefill 64，缓存 16 MiB。
- MLX 路径没有沿用 llama.cpp 的 JSON grammar。使用 JSON 提示与完整对象／数组校验，仍由各 Agent 校验结构；无效／截断输出不直接写入，原始记录保留。格式成功率必须另做真实任务评测。
- 不自动回退云端。正常取消、后台和内存警告保持首因；等待底层检查点退出后清理，不能承诺立即停止正在执行的 prefill。

## 已有证据

- 用户反馈：Milo Lab 独立短文本验证通过。没有原始性能报告，不能外推为 8K 或图文性能通过。
- Linux：27 项可移植 XCTest 通过；Swift 语法、diff 与旧版权资源检查通过。
- 固定版本的视觉配置实际下载并核对 SHA-256；源码核对 VLM 工厂支持 `qwen3_5` 和 `Qwen3VLProcessor`。这不是实际模型看图结果。

- iOS CI：`6c68ee022344820a695f0b3cfa400bc10814baaf`，正式 App 编译成功，393 项 XCTest、0 失败。运行 [35380521646](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/35380521646)。

## 安装后检查

1. 覆盖安装正式 App，确认原记录、课程表与云端配置仍在。
2. 下载新版 MLX 模型。旧 GGUF 不会复用；独立 Lab 的模型也不能跨沙盒复用。
3. 分别验证：纯文字聊天、今天步数查询、文字记餐、课程表提案；检查时间／事实、工具调用和确认操作。
4. 飞行模式下一张照片＋文字记录：先清晰单一食物，再模糊图片。检查识别、失败保留、重试、未自动联网。
5. 连续文字／图文切换 5 轮，生成时停止、切后台、锁屏，返回后重试。遇到 L14／L12／L13，记录设备、操作和错误，不能将编译成功视为已排除内存问题。
6. 下载中切后台、断网、暂停恢复与删除模型；确认已保存记录不受影响。

## 尚未取得的证据

图文真机首字与峰值内存、8K 真实工具链质量、不同设备稳定性、后台系统回收后的大文件续传。本轮 IPA 用于这些验收，不预先宣称全面通过。

## IPA 交付 · 2026-09-18

- 版本 **0.5.0 (21)**，源码 `6c68ee022344820a695f0b3cfa400bc10814baaf`。
- [CI 35380521646](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/35380521646)：编译、393 项 XCTest、归档与旧版权素材检查全部成功。
- [下载 KeepKeep-unsigned-ipa](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/35380521646/artifacts/10562367633)。ZIP 解压得到未签名 IPA，使用原签名账号／相同 App 标识覆盖安装，避免先卸载丢失本机记录。
- 实际检查：原 Bundle ID `com.minjung.keepkeep`、iOS 17+、小组件仍在；主程序 22,348,528 字节，MLX `default.metallib` 3,814,924 字节；包含 MLX／Qwen 许可，不含 llama.framework、GGUF 或 safetensors 权重。
- IPA 8,705,533 字节，SHA-256 `804f3ce1983d76ee2d53990ac51dfc0f4e4fe1933810c15c0f06ae1e0c97436a`。
- 源码使用 MinJung-Go 提交；README 与本文为后续文档提交，不改变上述 IPA 源码。
- 图文任务实际输出、8K 工具任务质量及 iPhone 内存稳定性仍按上方步骤验收，不以构建成功替代。
