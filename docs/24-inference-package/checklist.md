# 推理包拆分 checklist

- [x] 明确包与 App 边界，保留上一轮 16K 改动，不涉及新 UI。
- [x] 创建独立 Package、通用输入输出、预算、取消及串行调度。
- [x] 移入 MLX LLM／VLM 加载生成、图像预处理、内存诊断与释放。
- [x] 共享文件校验及派生运行目录，下载留在宿主。
- [x] 正式 App 适配并保留业务错误映射、输出过滤与工具校验。
- [x] 按用户追加要求退役独立 Lab，删除 App、对应测试、工程与脚本。
- [x] 正式 App 工程及 CI 使用本地包；保留包测试与迁移说明。
- [x] 执行可用测试、结构检查与语法解析。
- [ ] Apple SDK 正式 App构建、iOS 单测与真机回归（提交后 CI／真机完成）。

## 拆分时的验证记录（退役前）
- 共享核心 XCTest：6 项通过，包含两个预算、整数边界、并发停止首因、取消排队与失败恢复、诊断未知值。
- 正式 App portable XCTest：31 项通过；Lab portable XCTest：8 项通过；合计 45 项，0 失败。
- Swift 语法解析通过；Apple 分支 Package.swift 可求值，两个产品和四个 target 配置正确；XcodeGen/Actions YAML 可解析。
- 依赖边界检查通过：两个 App 无直接 MLX imports；包无 UIKit／SwiftData／App 业务类型／URLSession 依赖。
- Apple 后端另有 4 项新增 XCTest（文件校验／派生目录／取消预检查／预算预检查），当前 Linux 未执行。
- 修正可用内存采样的平台差异：`os_proc_available_memory` 不支持 macOS，macOS 返回明确约定的不可用值；iOS 保留该采样。参考 [Apple WWDC22 内存分析](https://developer.apple.com/videos/play/wwdc2022/10106/)。
- `git diff --check` 通过。当前分支 `feat/inference-package`，保留上一轮未提交的 16K 改动。

## 待验收
源码未提交、未推送，CI 提交号与单测数量尚无。本轮未打 IPA、未创建远端私有仓库。Apple SDK 正式 App编译、包 Apple 测试、正式 App iOS 回归和真机 L14／图文／长上下文仍待执行；不沿用旧版真机结论。

## Lab 退役验证
- [x] 删除 Lab 专属源码、资源、测试、工程、workflow 与脚本。
- [x] 清理共享包 CI、当前 README 和迁移说明的有效引用。
- [x] 保留并标注历史验证文档，验证配置及剩余测试。

退役后重新验证：推理核心 6 项 + 正式 App portable 31 项，共 **37 项通过，0 失败**。CI YAML、有效路径引用、保留测试／文档检查与 `git diff --check` 均通过。Apple 平台的 4 项包测试和正式 App iOS 全量回归仍待 CI；当前未提交、推送或打包。

## 独立仓库已创建
- [x] 创建私有仓库 [MinJung-Go/MiloInference](https://github.com/MinJung-Go/MiloInference)，默认分支 main。
- [x] 以 MinJung-Go 身份推送独立初始提交 `5c94a02bf00d68a1bb3f5a7b2a104bbedd977888`；仅 15 个源码／测试／配置文件，无 App 历史、缓存或权重。
- [x] 独立目录重新运行核心测试：6 项通过，0 失败。
- [ ] Apple CI：首次 [运行 35488156416](https://github.com/MinJung-Go/MiloInference/actions/runs/35488156416) 未启动 job，GitHub 提示账号近期付款失败或需提高消费额度，应检查 Billing & plans。不是代码编译失败；未更改账单设置。
- [x] App 已改为私有远端固定提交依赖，权限已配置；Apple 验证仍待提交后 CI。

App 仓库的其他改动未提交、未推送；本次只提交并推送新引擎仓库。

## App 远端依赖适配
- [x] 固定 URL／revision，更新 portable 测试并移除本地源码副本。
- [x] 配置只读 deploy key 和 App Actions secret。
- [x] 构建、IPA、包测试共用同一检出与认证流程。
- [x] 验证私有依赖访问、锁定提交、本地测试和配置，更新说明。

### 远端适配验证结果
- MiloInference 只读 deploy key：ID `163847795`；App Actions Secret `MILO_INFERENCE_DEPLOY_KEY` 已设置，仅此仓库读取范围。专用 SSH 凭据实测可读取远端 HEAD；临时私钥已删除。
- `project.yml` 为 URL／revision 唯一来源，固定 `5c94a02bf00d68a1bb3f5a7b2a104bbedd977888`；portable 测试和各 CI job 共用该 pin。
- App portable 测试实际从私有远端解析依赖：31 项 XCTest 通过；固定提交配置校验：3 项 Python 单测通过。
- 源码删除前已逐文件对比独立仓库固定提交，Sources／Tests／Package.swift／LICENSE 一致。App 内已无引擎源码副本。
- CI 的 Git 本地镜像映射已实测解析为同一 SHA；YAML、所有 job 接入、凭据不持久化配置与 `git diff --check` 检查通过。
- 仍未提交／推送 App 改动或打包。Apple 编译与真机验证尚未完成，不能视为已通过。
