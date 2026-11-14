// 把 Unifont 的 .hex 转成盘上的字库格式。
//
// 为什么自己写一个而不是直接用 Unifont 的 .bin：那两种格式解决不同的问题。Unifont 的
// 文本格式便于人读与比较；盘上那份要能被一个九万字节的第二段按偏移读出来。中间这一步
// 不写下来，每一次「这个字怎么是空的」都要回到几十兆的文本里翻。
//
// 盘上格式：
//
//   0   魔数 YUNOFONT（八字节）
//   8   u16 版本
//   10  u16 留白
//   12  u32 条目数
//   16  条目：每 20 字节 —— u32 码点，然后十六字节位图（八行，每行两字节）
//
// 没有按码点排序的要求，但写出来的顺序照 .hex 的读入顺序 —— 排序是查找层的事，不是
// 存储层的事。

import fs from "node:fs";

export function 解析(text) {
  const 条 = [];
  for (const 行 of text.split(/\r?\n/)) {
    const s = 行.trim();
    if (!s) continue;
    const 冒 = s.indexOf(":");
    if (冒 < 0) throw new Error("这一行没有冒号，不是 .hex：" + s);
    const 码点 = parseInt(s.slice(0, 冒), 16);
    if (!Number.isFinite(码点) || 码点 < 0 || 码点 > 0x10ffff) {
      throw new Error("码点不合法：" + s);
    }
    const 位 = s.slice(冒 + 1).replace(/\s+/g, "");
    if (位.length !== 32) {
      throw new Error("位图应当是十六字节（三十二个十六进制字符），这一行是 " + 位.length / 2 + " 字节：" + s);
    }
    条.push([码点, Buffer.from(位, "hex")]);
  }
  return 条;
}

export function 打包(条) {
  const 头 = Buffer.alloc(16);
  头.write("YUNOFONT", 0, "ascii");
  头.writeUInt16LE(1, 8);
  头.writeUInt32LE(条.length, 12);
  const 体 = Buffer.alloc(条.length * 20);
  条.forEach(([码点, 图], i) => {
    体.writeUInt32LE(码点, i * 20);
    图.copy(体, i * 20 + 4);
  });
  return Buffer.concat([头, 体]);
}

export function 解包(包) {
  if (包.length < 16 || 包.toString("ascii", 0, 8) !== "YUNOFONT") {
    throw new Error("不是字库：魔数不对");
  }
  const 版本 = 包.readUInt16LE(8);
  const 数 = 包.readUInt32LE(12);
  if (包.length < 16 + 数 * 20) throw new Error("字库被截断：条目数 " + 数 + "，实际字节 " + 包.length);
  const 条 = [];
  for (let i = 0; i < 数; i++) {
    条.push([包.readUInt32LE(16 + i * 20), 包.subarray(20 + i * 20, 36 + i * 20)]);
  }
  return { 版本, 条 };
}

// 自测：两条样本走一遍「解析、打包、解包」，再逐字节比。
//
// 比的是位图本身而不是长度 —— 一个把字节顺序写反的实现长度完全正确，而它画出来的字
// 上下颠倒，那种错在屏幕上看最像「字体不对」。
if (process.argv[1] && process.argv[1].endsWith("hexfont.mjs")) {
  const 样本 = [
    "0041:0008 0808 0808 FFFF 0808 0808 0808 0808",
    "0042:0000 7E81 8181 81FF 8181 8181 8181 0000",
  ].join("\n");
  const 条 = 解析(样本);
  if (条.length !== 2) throw new Error("解析出 " + 条.length + " 条，应当是两条");
  const 包 = 打包(条);
  const 回 = 解包(包);
  if (回.版本 !== 1) throw new Error("版本读回来是 " + 回.版本);
  if (回.条.length !== 2) throw new Error("解包出 " + 回.条.length + " 条");
  for (let i = 0; i < 2; i++) {
    if (回.条[i][0] !== 条[i][0]) throw new Error("第 " + i + " 条码点不同");
    if (!回.条[i][1].equals(条[i][1])) throw new Error("第 " + i + " 条位图不同");
  }
  // 反向：一个被改掉一个字节的包必须认得出来。
  const 坏 = Buffer.from(包);
  坏[20] ^= 0xFF;
  const 坏回 = 解包(坏);
  if (坏回.条[0][1].equals(条[0][1])) throw new Error("改了一个字节却仍与原文相同 —— 比较是空的");
  console.log("通过  两条字形走完解析、打包、解包，位图逐字节相同（" + 包.length + " 字节）");
  console.log("通过  改掉一个字节之后比较能看出来 —— 否则上面那条什么也没验");
}
