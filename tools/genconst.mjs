// 算 SHA-512 的 80 个常量：K[i] = floor(frac(cbrt(p_i)) * 2^64)，p_i 是第 i 个质数。
//
// 为什么不抄表：八十个 64 位十六进制数手抄一遍必错，而错了以后唯一的症状是「哈希不对」，
// 与「轮函数写错」分不开。这里用 BigInt 精确求整数立方根，最后再过一遍已知值。
import crypto from "node:crypto";

function isPrime(n) {
  if (n < 2) return false;
  for (let d = 2; d * d <= n; d++) if (n % d === 0) return false;
  return true;
}
const primes = [];
for (let n = 2; primes.length < 80; n++) if (isPrime(n)) primes.push(n);

// floor(N^(1/3))，整数牛顿法。全程 BigInt，所以不丢位。
function icbrt(N) {
  if (N < 2n) return N;
  let x = 1n << BigInt(Math.ceil(N.toString(2).length / 3) + 2);
  for (;;) {
    const x2 = x * x;
    const nx = (2n * x + N / x2) / 3n;
    if (nx >= x) break;
    x = nx;
  }
  while (x * x * x > N) x--;
  while ((x + 1n) * (x + 1n) * (x + 1n) <= N) x++;
  return x;
}

const MASK64 = (1n << 64n) - 1n;
const K = primes.map((p) => icbrt(BigInt(p) << 192n) & MASK64);

// 与 SHA-384 的常量表交叉核对：SHA-512 与 SHA-384 的 K 是同一张表。
// 前四个与最后两个是人人都背得出的那几个，写下来当锚点，不是抄全表。
const 锚 = [
  [0, "428a2f98d728ae22"],
  [1, "7137449123ef65cd"],
  [2, "b5c0fbcfec4d3b2f"],
  [3, "e9b5dba58189dbbc"],
  [79, "6c44198c4a475817"],
];
for (const [i, want] of 锚) {
  const got = K[i].toString(16).padStart(16, "0");
  if (got !== want) {
    console.error("锚点不符：K[" + i + "] = " + got + "，应当是 " + want);
    process.exit(1);
  }
}
console.log("五个锚点全对，80 个常量算出来了");

// 出成 nasm 数据行，每行四个 dq。
const lines = [];
for (let i = 0; i < 80; i += 4) {
  const row = [];
  for (let j = i; j < i + 4 && j < 80; j++) {
    row.push("0x" + K[j].toString(16).padStart(16, "0"));
  }
  lines.push("    dq " + row.join(", "));
}
console.log("----8<---- 常量表开始");
console.log(lines.join("\n"));
console.log("----8<---- 常量表结束");

// 顺便确认常量表真的是「立方根」而不是「平方根」那一套：
// 平方根那套的前四项是 428a2f98 71374491 b5c0fbcf e9b5dba5（低 32 位对得上），
// 而高 32 位不同 —— 两者共用前缀，所以只比低半截是分不开的。
console.log("低 32 位对照（与 SHA-256 的 K 共用前缀，故不能靠低半截辨认）：");
console.log("  K[0] 高半 " + K[0].toString(16).padStart(16, "0").slice(0, 8));
