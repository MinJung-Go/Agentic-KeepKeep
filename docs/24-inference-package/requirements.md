# 第 24 轮 · 推理核心独立 Swift Package

## 目标
本地推理已独立到私有仓库 `MinJung-Go/MiloInference`；App 使用固定提交的 Swift Package，已移除原 `Packages/MiloInference` 副本。保留上一轮尚未提交的正式 App 16K 适配。本轮不提交或打包 App。

## 边界
- 包：固定 MLX 依赖、模型加载、文字／单图生成、tokenizer 与预算校验、串行调度、取消、资源释放、内存采样、模型校验与派生运行目录。
- App：模型来源和安装状态、下载任务／蜂窝授权／后台接入、SwiftData、角色提示词、历史摘要、业务工具及写入确认、错误文案和 UI。
- 正式 App 使用独立推理包，保留 0.8B／16K／1024 输出。用户追加确认删除独立 Milo Lab，后续以包单测与正式 App 真实场景验收。历史 Lab 验收不代表当前正式 App 已通过。
- 包不得依赖 App 模块、UIKit、SwiftData、LLMRequest 或 Coach 类型；不内置角色、API Key、用户记录或模型权重，不自行联网。
- 调用者取消必须等待底层计算和 GPU 清理；取消排队任务不允许跳过前一任务清理；保持停止首因。
- 对外输入输出仅为通用文本／消息／图片／预算／计数及元数据；工具标签解析仍在 App 完成，未经验证不得执行工具。
- 无 UI 布局或交互变动，无新增设计确认。

## 验收与迁移
纯逻辑包测试覆盖预算、串行与取消边界、诊断；App 原有工具/安装测试保留。正式 App XcodeGen 工程使用远端固定提交依赖；CI 分别覆盖包测试和正式 App 构建／单测。Linux 验证不可替代 Apple SDK 和真机验收。私有迁移时只改本地 path 为固定版本 URL，CI 用只读凭据；公开 App 的独立编译需另提供可访问的包或公开替代实现。

## 追加：退役独立验证 App
删除 `MiloMLXValidation/`、对应测试、`project.mlx.yml`、Lab 专属 workflow 与脚本；移除共享包 CI 的 Lab 步骤和路径过滤。保留推理包测试、正式 App 回归与历史验证文档，并同步当前 README／迁移说明。仅删除本地仓库源码与配置，不删除 GitHub 历史运行或产物。

## 追加：建立独立私有仓库
用户授权在 MinJung-Go 下创建 MiloInference 私有仓库，上传包源码、测试、许可和独立 CI。App 暂时保留本地包依赖，待完成私有依赖凭据和 Apple 验证后再迁移；不上传构建缓存或模型权重。

## 追加：App 使用私有远端包
用户授权适配 App，锁定 MiloInference 提交 `5c94a02bf00d68a1bb3f5a7b2a104bbedd977888`，删除 App 内引擎源码副本。CI 使用专属只读 deploy key 检出同一提交，并用本地 Git 镜像提供 SwiftPM 访问，凭据不写入源码或依赖 URL。正式 App、IPA 和引擎测试读取同一 pin。开发机使用已有 GitHub 私有仓库权限；缺少权限时明确失败，不回退旧副本。
