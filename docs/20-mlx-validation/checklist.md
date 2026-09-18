# MLX Swift 验证 checklist

## 需求与路线
- [x] 新建独立分支 `feat/mlx-runtime-validation`，明确不替换现有生产引擎。
- [x] 编写需求、验收与不支持范围。
- [x] 锁定可用的 MLX Swift LM／MLX 版本，核对 iOS 最低版本和 Qwen3.5 纯文字加载路径。
- [x] 核验 ModelScope 固定版本文件清单、大小／哈希与模板。
- [x] 确认验证入口；新增 UI 出设计稿并经用户确认。

## 开发
- [x] 独立依赖与构建目标，避免与 llama.cpp 同时加载。
- [x] 模型下载／校验／独立存储；失败不可标记就绪。
- [x] 2K 预算、256 输出、实际 tokenizer 限制与非思考文本生成。
- [x] 串行加载与运行、取消、后台／内存保护、卸载和缓存清理。
- [x] 分阶段进程与 MLX 内存、加载／首字／速度报告；不保存原始文本。
- [x] 设计确认后开发验证 UI。

## 验证
- [x] 纯逻辑单测与文件／预算／报告隐私边界。
- [x] Apple SDK 编译，独立 IPA 生成并检查 MLX Metal 资源。
- [ ] iPhone 上 MLX 实际加载与完整短回复。
- [ ] iPhone 冷启动、连续 5 轮、取消、后台、内存警告；与旧引擎同条件比较。
- [ ] 根据证据决定是否进入图文／工具阶段。

## 本轮证据与待验收边界

- 用户已确认独立 App 和三屏设计。
- Linux：8 项纯逻辑测试通过，Swift 语法解析通过；下载／SHA-256／MLX 实际执行尚待 Apple 环境验证。
- 已提交并推送。IPA 源码 `0f7fc20`；[CI 35373796349](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/35373796349) 成功，macOS 纯逻辑单测 8 项通过。尚无真机通过结论。
- Milo Lab 0.1.0 (1)，iOS 17+，未签名 IPA；已核对独立 bundle ID、34.28 MB 主程序及 3.81 MB `default.metallib`，未内置模型权重。
- [实现说明、构建与真机步骤](validation.md)。
