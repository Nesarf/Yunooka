// 从宿主侧看盘：给一个名字，说出它在哪个扇区、以及那个扇区里前八个字节是什么。
//
// 为什么要有它：客人机那一趟要五分钟，而「条目指对了没有」这件事在盘上就能看出来。
// 上一格就是靠手写的一段 node -e 才发现条目指向的扇区里躺着另一个文件的魔数 —— 而那段
// 代码值得留下，不该每次重写一遍。
//
// 用法：
//   node tools/peekdisk.mjs              列出根目录的条目
//   node tools/peekdisk.mjs font.hmft    只看那一条，并读它指向的扇区

import fs from "node:fs";

const 盘 = fs.readFileSync(new URL("../build/disk.img", import.meta.url));
const 根扇区 = Number(process.env.PEEK_ROOT || 1025);
const 根页数 = 2;

// 条目：u16 名字长、名字（UTF-16LE）、u8 类型、u32 扇区、u32 字节数。
// 一条的长度是 11 + 名字长 * 2 —— 与 stage2 里那一句 lea r9, [r9 + 11 + rax * 2] 同源。
function 读条目(基址) {
  const 条 = [];
  let 位 = 基址;
  const 止 = 基址 + 根页数 * 512;
  while (位 + 11 <= 止) {
    const 名长 = 盘.readUInt16LE(位);
    if (名长 === 0) break;
    if (名长 > 64) break;
    let 名 = "";
    for (let i = 0; i < 名长; i++) 名 += String.fromCharCode(盘.readUInt16LE(位 + 2 + i * 2));
    const 头 = 位 + 2 + 名长 * 2;
    条.push({
      名,
      类: 盘[头],
      扇区: 盘.readUInt32LE(头 + 1),
      字节: 盘.readUInt32LE(头 + 5),
      位,
    });
    位 = 头 + 9;
  }
  return 条;
}

const 条 = 读条目(根扇区 * 512);
const 要的 = process.argv[2];

if (!要的) {
  console.log("根目录第 " + 根扇区 + " 号扇区，共 " + 条.length + " 条：");
  for (const t of 条) console.log("  " + t.名.padEnd(12) + " 类 " + t.类 + "  扇区 " + t.扇区 + "  " + t.字节 + " 字节");
  process.exit(0);
}

const 中 = 条.find((t) => t.名 === 要的);
if (!中) {
  console.log("根目录里没有：" + 要的);
  process.exit(1);
}
const 起 = 中.扇区 * 512;
const 头 = 盘.subarray(起, 起 + 16);
const 可见 = [...头].map((b) => (b >= 0x20 && b < 0x7f ? String.fromCharCode(b) : ".")).join("");
console.log(中.名 + "  扇区 " + 中.扇区 + "  " + 中.字节 + " 字节");
console.log("  前十六字节  " + 头.toString("hex"));
console.log("  当作文本    " + 可见);
