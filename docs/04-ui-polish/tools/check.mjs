// 设计稿自检：类名碰撞 + 结构性错误。
// 手机外的「展示页」和手机内的「App 界面」共用一份 CSS，同名的类会互相污染 ——
// 已经踩过两次：.body（内容容器）撞 .ico.body，.note（说明卡）撞 .ico.note。
//
//   node tools/check.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const file = path.resolve(here, '..', 'design.html');
const src = fs.readFileSync(file, 'utf8');

const css = src.match(/<style>([\s\S]*?)<\/style>/)[1];
const noStyle = src.replace(/<style>[\s\S]*?<\/style>/g, '');
const body = noStyle.replace(/<svg style="display:none"[\s\S]*?<\/svg>/g, '');

const classesIn = (html) => {
  const out = new Set();
  for (const m of html.matchAll(/class="([^"]+)"/g)) m[1].split(/\s+/).forEach(c => c && out.add(c));
  return out;
};

// 手机内的 HTML：每个 .scene 里 .phone 的内容
const inPhone = new Set();
for (const m of body.matchAll(/<div class="phone[^"]*">([\s\S]*?)(?=<div class="scene"|<section class=|<div class="gallery"|\Z)/g)) {
  classesIn(m[1]).forEach(c => inPhone.add(c));
}
const outside = classesIn(body.replace(/<div class="scene"[\s\S]*?(?=<section class=|<div class="gallery"|\Z)/g, ''));

// 只有同时满足「两边都用」且「CSS 里有裸选择器 .X{}」才可能互相污染 ——
// 复合选择器（.ico.ai）不会误伤别处。
const hasBare = (c) => new RegExp('(?:^|\})\s*\.' + c + '\{', 'm').test(css);
const clash = [...inPhone].filter(c => outside.has(c) && hasBare(c)).sort();

console.log(`手机内 class: ${inPhone.size} · 展示页 class: ${outside.size}`);
if (clash.length) {
  console.log(`\n同名类 ${clash.length} 个（确认两边样式意图一致，否则改名）：`);
  for (const c of clash) {
    const r = css.match(new RegExp('(?:^|\})\s*\.' + c.replace(/[-]/g, '\-') + '\{([^}]*)\}'));
    console.log(`  .${c.padEnd(16)} ${r ? r[1].replace(/\s+/g, ' ').trim().slice(0, 64) : ''}`);
  }
} else {
  console.log('\n无同名类');
}

// 结构
const count = (re, s) => (s.match(re) || []).length;
const issues = [];
if (count(/<div(?=[\s>])/g, body) !== count(/<\/div>/g, body)) issues.push('div 标签不平衡');
if (count(/\{/g, css) !== count(/\}/g, css)) issues.push('CSS 括号不平衡');
const neg = count(/letter-spacing:-/g, src);
if (neg) issues.push(`负字距 ${neg} 处（中文不应有）`);
console.log(issues.length ? '\n问题: ' + issues.join(' · ') : '\n结构检查通过');
process.exit(issues.length ? 1 : 0);
