#!/usr/bin/env node
// 仓库自检：三件与「机器做得对不对」无关、但会让判据本身失效的事。
//
// 一、判据定义了却没被引用 —— 那种判据永远不跑，也永远不红。这一份检查存在的理由就是
//     它：一个写得对但没挂上去的判据，比一个写错的判据更安静。
// 二、PLAN 的 after 引用指向不存在的目标 —— 那样的依赖图不是图。
// 三、design/*.txt 里出现 markdown 记号 —— 那些文件是纯文本；混进 markdown 之后，读的
//     人会以为它在渲染，而它不会。
//
// 它不进 run.mjs 的那条链：那条链验的是这台机器，这一份验的是我们写下来的东西有没有
// 自相矛盾。两者都会红，但红的含义不同 —— 混在一起会让「机器坏了」与「文档写歪了」
// 长得一样。

import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const 结果 = [];

const 判 = (名字, 通过, 说明) => {
  结果.push({ 名字, 通过, 说明 });
};

// ---- 一、判据有没有挂上去 ----
//
// 「判据」在这里指 run.mjs 里以 成 结尾的那些变量。它们全都在一条（或几条）&& 链上，
// 所以判断的办法是「定义行之外还有没有出现」。
const 跑 = fs.readFileSync(path.join(ROOT, "tools", "run.mjs"), "utf8");
const 定义 = new Map();
for (const m of 跑.matchAll(/^const\s+([A-Za-z_\u4e00-\u9fa5][\w\u4e00-\u9fa5]*)\s*=/gm)) {
  定义.set(m[1], m.index);
}
const 全部判据 = [...定义.keys()].filter((n) => /成$/.test(n));
const 死判据 = [];
for (const n of 全部判据) {
  const 次 = (跑.match(new RegExp("(?<![A-Za-z_\\u4e00-\\u9fa5])" + n + "(?![A-Za-z_\\u4e00-\\u9fa5])", "g")) || []).length;
  if (次 <= 1) 死判据.push(n);
}
判(
  "判据都挂了",
  死判据.length === 0,
  全部判据.length + " 个判据，" + (死判据.length ? "没有引用的：" + 死判据.join("、") : "每一个都在某条链上"),
);

// ---- 二、PLAN 的 after 指着存在的目标吗 ----
const 计划 = JSON.parse(fs.readFileSync(path.join(ROOT, "design", "PLAN.json"), "utf8"));
const 名字集 = new Set(计划.goals.map((g) => g.id));
const 断链 = [];
for (const g of 计划.goals) {
  for (const a of g.after || []) {
    if (!名字集.has(a)) 断链.push(g.id + " -> " + a);
  }
}
判(
  "PLAN 的依赖能解析",
  断链.length === 0,
  计划.goals.length + " 个目标，" + (断链.length ? "断的：" + 断链.join("、") : "after 全部指向存在的目标"),
);

// ---- 三、design 里没有 markdown ----
//
// 只查明显的记号：行首的 #、表格的 |---、加粗、以及 ``` 代码围栏。那几种混进纯文本
// 之后最容易被误读成「它该渲染」。
//
// 加粗用全文匹配而不是逐行：这个检查的头一版是逐行的，而 LAYERS 里有一对星号跨了两行，
// 于是那一处留了下来，而检查报了「十七个文件都没有」。全文匹配才看得见跨行的。
const 设计目录 = path.join(ROOT, "design");
const 带毒 = [];
for (const 名 of fs.readdirSync(设计目录).filter((f) => f.endsWith(".txt"))) {
  const 文 = fs.readFileSync(path.join(设计目录, 名), "utf8");
  const 行 = 文.split(/\r?\n/);
  for (let i = 0; i < 行.length; i++) {
    const s = 行[i];
    if (/^#{1,6}\s/.test(s) || /^\|?[\s-]*\|[\s:|-]+\|?\s*$/.test(s) || /^```/.test(s)) {
      带毒.push(名 + ":" + (i + 1));
      break;
    }
  }
  // 加粗可能跨行，所以单独全文找一次。
  if (!带毒.some((x) => x.startsWith(名 + ":")) && /\*\*[^*]+\*\*/.test(文)) {
    const 处 = (文.match(/\*\*[^*]+\*\*/g) || []).length;
    带毒.push(名 + "（" + 处 + " 处加粗）");
  }
}
判("design 是纯文本", 带毒.length === 0, 带毒.length ? "有 markdown 记号：" + 带毒.join("、") : "十七个文件都没有");

// ---- 四、每个 event= 行都有人读 ----
//
// 这一条与第一条方向相反。第一条问「判据有没有挂上去」，这一条问「这一行有没有人看」。
// 两者是同一个病的两面：一条打了没人读的 event 行，与一条挂了但永不触发的判据一样，
// 都会在出事的时候保持沉默。
//
// 只查 event= 开头的行，不查所有串口输出：诊断行（比如 myon2 dbg）是给人看的、不是给
// 判据看的，而把诊断也纳入要求会把这条检查逼成一个负担。
const 二段源 = fs.readFileSync(path.join(ROOT, "boot", "stage2.asm"), "utf8");
const 事件名 = [...new Set(
  [...二段源.matchAll(/db "Yunooka: event=([A-Za-z0-9._-]+)/g)].map((m) => m[1]),
)];
const 无人读 = 事件名.filter((e) => !跑.includes(e));
判(
  "每个 event 都有人读",
  无人读.length === 0,
  事件名.length + " 个事件，" + (无人读.length ? "没人读的：" + 无人读.join("、") : "每一个都在 run.mjs 里被查过"),
);

// ---- 报告 ----
let 坏 = 0;
for (const r of 结果) {
  if (!r.通过) 坏++;
  console.log((r.通过 ? "通过  " : "不通过") + "  " + r.名字 + " —— " + r.说明);
}
if (坏) {
  console.log("");
  console.log(坏 + " 项不通过。它们说的是「写下来的东西自相矛盾」，不是「机器有问题」。");
  process.exit(1);
}
