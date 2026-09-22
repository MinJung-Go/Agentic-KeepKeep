# App 接入独立推理包

引擎仓库：[MinJung-Go/MiloInference](https://github.com/MinJung-Go/MiloInference)，私有。

`project.yml` 是依赖版本的唯一配置来源：HTTPS URL，固定 revision `5c94a02bf00d68a1bb3f5a7b2a104bbedd977888`。App 使用 `MiloInference` 与 `MiloInferenceCore` 产品；已移除本地 `Packages/MiloInference` 副本。引擎改动应在独立仓库完成，再更新 App 的 revision 并验证。

## 开发机

先使用具有该私有仓库读取权限的 GitHub 账号配置 Git 凭据。`git ls-remote https://github.com/MinJung-Go/MiloInference.git HEAD` 应成功；不在 URL 中放 token。随后生成 Xcode 工程并构建。无权限的开发者不能独立编译当前 App。

Linux 业务回归：`python3 scripts/local-milo/test_portable.py`（需 Swift 6.0+）。脚本从 project.yml 读取同一个固定 revision，使用远端包。Apple 后端实际构建需 Swift 6.1+／iOS 17+。

## CI

App 仓库 Secret `MILO_INFERENCE_DEPLOY_KEY` 对应引擎仓库的只读 deploy key，只能拉取该库；未复用个人账号 token。

`.github/actions/inference-dependency` 读取 project.yml 的 pin，用部署密钥检出到忽略目录 `.inference/MiloInference`，校验 HEAD，建立临时 Git mirror 映射供 SwiftPM 解析。checkout 不持久化凭据。项目声明仍是远端 URL；测试、构建和 IPA 都使用该固定提交，不跟随 main。

正式 App 的 xcodebuild 使用 `-scmProvider system` 以读取 Git 映射。引擎包测试 workflow 使用同一检出。日志 artifact 不包含检出目录或私钥。fork PR 默认拿不到 Secret，会明确报缺少私有依赖权限；不要改为 pull_request_target 执行不可信 PR 代码。

## 当前验证状态

只读 SSH 访问已验证；App 31 项 portable XCTest 已使用私有远端固定提交通过。Apple 编译、4 项 Apple 包测试和完整 iOS 单测仍待提交后 CI。引擎仓库自身 Actions 曾因账号账单／额度未启动，不能视为代码测试结果；本轮未更改账单。

如需轮换密钥：为引擎库创建新的只读部署密钥，更新 App 的同名 Secret，验证构建后删除旧公钥。不要把私钥放入源码。当前 App 侧配置和拆分改动尚未提交、推送或打包。
