// 把 design.html 渲染成 PNG，用来核对设计稿 —— 不要靠想象改视觉。
//
//   cd docs/04-ui-polish/tools && npm i playwright && npx playwright install chromium
//   node render.mjs            # 全部 17 屏 + 两条规范带
//   node render.mjs 1 4 6      # 只渲染第 1、4、6 屏（1 起算）
//
// 输出在 ./out/。手机屏按 deviceScaleFactor 2 出图，够看清 1px 描边与图标细节。
import { chromium } from 'playwright';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';

const here = path.dirname(fileURLToPath(import.meta.url));
const target = path.resolve(here, '..', 'design.html');
const outDir = path.join(here, 'out');
fs.mkdirSync(outDir, { recursive: true });

const only = process.argv.slice(2).map(Number).filter(n => n > 0);

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1400, height: 1000 }, deviceScaleFactor: 2 });
await page.goto(`file://${target.replace(/\/g, '/')}`, { waitUntil: 'networkidle', timeout: 60000 });
await page.evaluate(() => document.fonts.ready);
await page.waitForTimeout(1500);   // 等 webfont 落地，否则截到兜底字体

const total = await page.$$eval('.scene', els => els.length);
console.log(`共 ${total} 屏`);

for (let i = 0; i < total; i++) {
  if (only.length && !only.includes(i + 1)) continue;
  await page.evaluate((idx) => {
    document.querySelectorAll('.scene').forEach((el, i) => { el.style.display = i === idx ? '' : 'none'; });
    document.querySelectorAll('.band, .notes, header').forEach(el => { el.style.display = 'none'; });
    const g = document.querySelector('.gallery');
    g.style.display = 'flex'; g.style.padding = '0';
  }, i);
  await page.waitForTimeout(250);
  const el = (await page.$$('.scene'))[i];
  const name = `screen-${String(i + 1).padStart(2, '0')}.png`;
  await el.screenshot({ path: path.join(outDir, name) });
  console.log('  ' + name);
}

await browser.close();
