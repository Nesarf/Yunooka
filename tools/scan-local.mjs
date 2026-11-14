// 扫一遍被跟踪的文件，看里面有没有只在这台机器上成立的东西。
//
// 为什么要有这一支：脱敏这件事一共做过三次（一次清路径、一次清盘符、一次清安装位置），
// 每次都是手工扫的，而每次都要重新想「扫什么」。判断没有判据，就等于每次都要再判断一遍。
// 所以这一支把「扫什么」写成数据，跑一次零命中才算过。
//
// 一个教训写在前面：第一版把「盘」字当成线索，扫出三十九处假阳性 —— IDE 盘、AHCI 盘、
// NVMe盘、盘像、盘大小，全是工程术语。只会报假阳性的检查比没有检查更费人，因为它每响
// 一次都要有人去看，看的人最后学会的是忽略它。所以这里的模式全部收紧到「只报形状明确的
// 东西」：一个盘符紧跟着分隔符、一个四段的点分数字、一个明确的品牌词。

import { execFileSync } from "node:child_process";
import fs from "node:fs";

const 根 = process.argv[2] || process.cwd();
const 跑 = (参数) => execFileSync("git", ["-C", 根, ...参数], { encoding: "utf8" });
const 文件 = 跑(["ls-files"]).trim().split(/\r?\n/).filter(Boolean);

// 四条形状。每一条都只认会被读者直接当成「这台机器」的那种写法。
const 模式 = [
  // 盘符加分隔符。负向后顾排除 UUID:\s 与 Location:\s 里的那两个冒号 —— 那是正则字面量。
  ["绝对路径", /(?<![A-Za-z])[A-Za-z]:[\\/]/],
  // 中文里的盘符说法。限定在本机存在的几个盘符，并且要求前面不是字母数字，
  // 于是「IDE 盘」「AHCI 盘」这类整体词不会命中。
  ["盘符词", /(?<![A-Za-z0-9])[CDEFG] ?盘/],
  ["本机地址", /localhost|127\.0\.0\.1/i],
  ["家目录", /[\\/]Users[\\/]|[\\/]AppData[\\/]/i],
];

// 商业软件品牌名。白名单里那几个是用户批准点名的（见 design/PUBLISH.txt 第二节）：
// 它们出现的地方都声明了「照着能力做自己的实现，不改二进制」。
const 白名单 = ["SAI", "PS", "AI", "RhinoCeros", "Keil"];
const 品牌 = [
  "rhinoceros", "rhino", "3ds\\s*max", "autocad", "solidworks", "catia", "ansys",
  "comsol", "matlab", "simulink", "labview", "multisim", "proteus", "altium",
  "quartus", "vivado", "mplab", "zbrush", "houdini", "cinema\\s*4d", "sketchup",
  "archicad", "revit", "navisworks", "coreldraw", "photoshop", "illustrator",
  "premiere", "after\\s*effects", "indesign", "lightroom", "figma", "axure",
  "mathematica", "blender", "unreal", "abaqus", "hypermesh", "metashape",
];
const 品牌式 = new RegExp("(?<![a-z])(" + 品牌.join("|") + ")(?![a-z])", "gi");
const 是白名单 = (词) => 白名单.some((w) => w.toLowerCase() === 词.toLowerCase());

const 自己 = new Set(["tools/scan-local.mjs"]);
let 命中 = 0;

for (const f of 文件) {
  if (自己.has(f)) continue;                     // 这一支自己当然写着那些词
  let 内容;
  try { 内容 = fs.readFileSync(`${根}/${f}`, "utf8"); } catch { continue; }

  内容.split("\n").forEach((行, i) => {
    for (const [名, re] of 模式) {
      if (re.test(行)) { console.log(`${名}\t${f}:${i + 1}\t${行.trim().slice(0, 100)}`); 命中 += 1; }
    }
    for (const m of 行.matchAll(品牌式)) {
      if (!是白名单(m[1])) { console.log(`品牌\t${f}:${i + 1}\t${行.trim().slice(0, 100)}`); 命中 += 1; }
    }
  });
}

const 可疑名 = 文件.filter((f) => /keys\/|\.seed$|\.vdi$|\.raw$|\.log$/.test(f));

console.log("");
console.log("被跟踪文件  " + 文件.length + " 个");
console.log("可疑文件名  " + (可疑名.length ? 可疑名.join("、") : "无"));
console.log("命中        " + 命中 + " 处");

if (命中 || 可疑名.length) {
  console.log("");
  console.log("这一趟没过：上面每一处都要有人看一眼，而判断的依据写在 design/PUBLISH.txt。");
  process.exit(1);
}
console.log("");
console.log("过了：被跟踪的文件里没有只在这台机器上成立的写法，也没有密钥与产物。");
