# 实施与验证

- [x] 删除教练输入栏重复停止控件，正文停止生成仍保留。
- [x] 确认计划保留 JSON，持久化确认时间，展示回执，防止重复导入。
- [x] 构建下载固定版本 180×180 GIF，校验完整性；App 只读取 Bundle，保留署名。
- [x] 首页输入栏通栏不透明底色、分隔线和安全区间距。
- [x] 1024×1024 App 图标与主 App/Widget 版本 0.4.1 (2)。
- [x] GitHub macOS 构建及单测：代码提交 `c10b70d486aa5bf3e383abf223d7c801eb283d70`，245 个测试全部通过。
  - PR CI：https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/34798495162
- [x] `v0.4.1` 归档及图片资源校验通过，161 个 GIF，15.1 MiB。
  - 发布 CI：https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/34799288871
  - IPA：https://github.com/MinJung-Go/Agentic-KeepKeep/actions/runs/34799288871/artifacts/10331435225

新增回归测试：工具调用无正文的计划确认后重新读取仍有完整回执；重复确认只生成一份；新计划替换激活状态但保留旧回执；所有目录内 GIF 可从 Bundle 读取解码。

真机待复验：浅色/深色首页滚动和键盘、计划确认后关闭重进、飞行模式查看姿势图、桌面图标和自签安装。旧版已经清除的聊天计划 JSON 无法凭空恢复，已有课程表不受影响。

最终 IPA 本地核验：ZIP 完整性通过；161 个原始 GIF 完整且尺寸正确；AppIcon 元数据存在；主 App 与 Widget 均为 0.4.1 (2)。产物在 `build/v0.4.1/KeepKeep-unsigned.ipa`（不入库）。
