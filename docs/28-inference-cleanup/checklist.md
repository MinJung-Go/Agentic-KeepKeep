# 第 28 轮 · 清理清单

- [x] 按用户要求在 main 明确清理范围，见 [需求](requirements.md)。
- [x] 删除旧桥接、构建与验证脚本、旧运行时许可。
- [x] 清理工程配置并更新当前开发文档，标注历史工具退役。
- [x] 验证引用、配置、依赖测试与资源检查，记录结果。

用户已追加授权提交并推送 main；推送后的 CI 结果以对应提交的 GitHub Actions 为准，不沿用历史单测数量作为本轮结果。

## 验证结果

- 删除 9 个旧运行时文件（含依赖旧 C 接口的 `evaluate_corpus.py`）；保留通用数据准备、结果汇总及历史验证产物。
- 3 项依赖配置单测通过：`python3 -m unittest discover -s scripts/local-milo -p test_dependency.py`。
- `python3 scripts/verify_no_exercise_dataset.py AgenticKeepKeep` 通过。
- 使用现有 `/tmp/milo-yaml-check` 的 PyYAML 解析 project.yml 和 GitHub Actions YAML 通过；固定依赖 revision、包产品与当前许可证检查通过。系统 Python 默认未安装 PyYAML，未修改项目依赖。
- 活动源码、测试、脚本、CI、project.yml 与 README 中无已删除文件名或旧 C 推理入口引用；历史 docs 引用按需求保留。
- `git diff --check` 通过。
- 未运行 Xcode/iOS 构建或真机测试；本记录写入时尚无本轮 CI 结果。
