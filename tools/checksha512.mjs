// 把串口里那六行 event=sha512 与主机算的逐字符比对。
//
// 判据就这一条：字符串相等。不解释、不近似 —— 一个 512 位哈希里错一位与错一半，
// 在「相等」这件事上是同一件事，而道歉式的比较（比如只看前 8 字节）会让一个错到
// 离谱的实现也报绿。
import fs from "node:fs";
import crypto from "node:crypto";

const log = fs.readFileSync("build/serial.log", "utf8");
const lines = log.split(/\r?\n/).filter((l) => l.includes("event=sha512"));
if (lines.length === 0) {
  console.error("串口里没有 event=sha512 行 —— 那一段没跑到");
  process.exit(1);
}

const t = Buffer.alloc(256);
for (let i = 0; i < 256; i++) t[i] = i & 0xff;

let 坏 = 0;
for (const line of lines) {
  const m = /event=sha512 len=(\d+) hex=([0-9A-Fa-f]+)/.exec(line);
  if (!m) {
    console.log("看不懂的一行：" + line);
    坏++;
    continue;
  }
  const L = Number(m[1]);
  const got = m[2].toUpperCase();
  const want = crypto.createHash("sha512").update(t.subarray(0, L)).digest("hex").toUpperCase();
  if (got.length !== 128) {
    console.log("len=" + L + " 长度不对：" + got.length + " 个十六进制字符（应当是 128）");
    坏++;
    continue;
  }
  if (got === want) {
    console.log("len=" + String(L).padStart(3) + "  与主机相同");
  } else {
    坏++;
    // 逐字节指出从第几字节开始不同 —— 「全错」与「错一个字节」要分得开，
    // 前者像算法错，后者像搬运错。
    let first = -1, n = 0;
    for (let i = 0; i < 64; i++) {
      if (got.slice(i * 2, i * 2 + 2) !== want.slice(i * 2, i * 2 + 2)) {
        if (first < 0) first = i;
        n++;
      }
    }
    console.log("len=" + String(L).padStart(3) + "  不同：从第 " + first + " 字节起，64 个字节里 " + n + " 个不同");
    console.log("     机器 " + got.slice(0, 32) + "...");
    console.log("     主机 " + want.slice(0, 32) + "...");
  }
}
console.log("");
console.log(坏 === 0 ? "六行全部与主机相同" : "有 " + 坏 + " 行不同 —— SHA-512 还没对");
process.exit(坏 === 0 ? 0 : 1);
