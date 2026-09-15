# 预览图

设计稿是 HTML（动图靠浏览器播 GIF），GitHub 不渲染 HTML。这里放导出的 PNG。

> **PNG 不在仓库里** —— 它们是含第三方素材（© Gym visual）画面的截图，已 gitignore。
> 想知道这些图长什么样，按下面重新生成，或直接开 HTML 看。

生成方式：

```bash
bash docs/04-ui-polish/vendor/fetch.sh     # 先拉素材（版权原因不入库）
node docs/04-ui-polish/tools/render.mjs    # 再导出截图
```

| 文件 | 内容 |
|------|------|
| `20-gif-catalog.png` | **素材总览**：8 个动作的 GIF（真动画截其中一帧），红色即发力肌群 |
| `25-frame-strip.png` | **抽帧条**：3 个动作各取 8 帧排开 —— 静态图也能看出动作轨迹与残影 |
| `21-gif-detail.png` | 动作详情页（深色）：GIF + 训练参数 + 发力点 + 要点 |
| `22-gif-training.png` | 训练执行页（深色）：GIF 与当前动作并排 + 逐组打勾 |
| `23-gif-light.png` | 动作详情（浅色）+ 未收录动作的兜底 |

> PNG 只能截到动图的某一帧；**要确认真的是动的，看 HTML**：
> `docs/04-ui-polish/exercise-illustrations.html`

素材版权与替换方式见 [`../vendor/NOTICE.md`](../vendor/NOTICE.md)。
