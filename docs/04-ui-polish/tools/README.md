# 设计稿自检

`design.html` 是 HTML 高保真稿，**改完必须渲染出来看**，不要靠推演 —— 这一轮踩过的坑（`.body` 与 `.ico.body` 类名冲突、内容被浮层裁掉、字体在非 Mac 上兜底成雅黑）都是渲染出来才发现的。

```bash
cd docs/04-ui-polish/tools
npm i playwright && npx playwright install chromium

node render.mjs          # 全部 17 屏
node render.mjs 1 4 6    # 只渲染指定屏（1 起算）
```

输出在 `out/`，2 倍图。`out/` 已在 `.gitignore` 里，不进库。

## 顺手可查的几何

渲染之外，量一下关键元素的实际尺寸比读 CSS 靠谱。例如确认手机框没有把内容裁掉：

```js
const r = document.querySelector('.scroll');
console.log(r.scrollHeight, r.clientHeight);   // 前者大于后者 = 有内容被裁
```
