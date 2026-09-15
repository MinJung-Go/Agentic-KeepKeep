# AI 教练聊天页适配清单

分支：feat/coach-chat-polish（包含已通过 300 项测试的动作详情修复）。

- [x] 空态底部布局与三条快捷问题
- [x] 轻量消息排版与突出计划卡片
- [x] 单一圆角输入区及键盘收起入口
- [x] 顶部简化、数据说明收纳、清空确认
- [x] 本地语法与资源检查
- [x] Xcode 构建、全量单测：`6de0eee`，[Actions 34932405338](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/34932405338)，300 项通过、0 失败
- [ ] 真机：浅色/深色、大字体、小屏、键盘开关、进入历史定位与流式回复
- [ ] 真机：计划确认、清空取消/确认、无 Key 时错误提示

本地 112 个 Swift 文件语法解析、git diff --check 与旧素材检查通过。代码已合入 main，0.4.3（7）IPA 已生成。CI 不覆盖实际视觉效果，浅深模式、大字与键盘布局仍需真机检查。

## 合并与打包

- [x] 聊天页与动作详情修复合入 main；发布提交 `6e14e69`
- [x] [Actions 34933383381](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/34933383381)：构建、完整单测、归档、旧素材检查、侧载权限检查及 IPA 上传全部通过
- [x] IPA 版本 0.4.3（7），[下载产物](https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/34933383381/artifacts/10382372124)
- [ ] 真机验证新聊天页、动作详情与删除确认
