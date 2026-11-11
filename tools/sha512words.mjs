// 第二份独立的 SHA-512：每个 64 位字拆成两个 32 位字，进位手动处理。
//
// 为什么要写第二份：BigInt 那一份在「单块」上与 crypto 全对，「两块」上全错，而五种
// 补齐写法都不中。那种时候最该怀疑的不是标准，而是「两份东西其实都是同一份」——
// 我先前用来对照的 node 参考、汇编探针、串口输出，全都建立在我对补齐的那一个念头
// 之上。换一种字宽、换一套进位，就把那个念头从公式里拿掉了。
//
// 它对不上 crypto 就说明标准不是我以为的那样；它对得上，就说明 BigInt 那一份在
// 多块时确实有 bug，两份一对照，bug 自己会显形。

const t = Buffer.alloc(1024);
for (let i = 0; i < 1024; i++) t[i] = i & 0xff;

// K 用 32 位对（hi, lo）表示，与 sha512_k 里那 80 个 64 位数一一对应。
const K64 = [
  [0x428a2f98, 0xd728ae22], [0x71374491, 0x23ef65cd], [0xb5c0fbcf, 0xec4d3b2f], [0xe9b5dba5, 0x8189dbbc],
  [0x3956c25b, 0xf348b538], [0x59f111f1, 0xb605d019], [0x923f82a4, 0xaf194f9b], [0xab1c5ed5, 0xda6d8118],
  [0xd807aa98, 0xa3030242], [0x12835b01, 0x45706fbe], [0x243185be, 0x4ee4b28c], [0x550c7dc3, 0xd5ffb4e2],
  [0x72be5d74, 0xf27b896f], [0x80deb1fe, 0x3b1696b1], [0x9bdc06a7, 0x25c71235], [0xc19bf174, 0xcf692694],
  [0xe49b69c1, 0x9ef14ad2], [0xefbe4786, 0x384f25e3], [0x0fc19dc6, 0x8b8cd5b5], [0x240ca1cc, 0x77ac9c65],
  [0x2de92c6f, 0x592b0275], [0x4a7484aa, 0x6ea6e483], [0x5cb0a9dc, 0xbd41fbd4], [0x76f988da, 0x831153b5],
  [0x983e5152, 0xee66dfab], [0xa831c66d, 0x2db43210], [0xb00327c8, 0x98fb213f], [0xbf597fc7, 0xbeef0ee4],
  [0xc6e00bf3, 0x3da88fc2], [0xd5a79147, 0x930aa725], [0x06ca6351, 0xe003826f], [0x14292967, 0x0a0e6e70],
  [0x27b70a85, 0x46d22ffc], [0x2e1b2138, 0x5c26c926], [0x4d2c6dfc, 0x5ac42aed], [0x53380d13, 0x9d95b3df],
  [0x650a7354, 0x8baf63de], [0x766a0abb, 0x3c77b2a8], [0x81c2c92e, 0x47edaee6], [0x92722c85, 0x1482353b],
  [0xa2bfe8a1, 0x4cf10364], [0xa81a664b, 0xbc423001], [0xc24b8b70, 0xd0f89791], [0xc76c51a3, 0x0654be30],
  [0xd192e819, 0xd6ef5218], [0xd6990624, 0x5565a910], [0xf40e3585, 0x5771202a], [0x106aa070, 0x32bbd1b8],
  [0x19a4c116, 0xb8d2d0c8], [0x1e376c08, 0x5141ab53], [0x2748774c, 0xdf8eeb99], [0x34b0bcb5, 0xe19b48a8],
  [0x391c0cb3, 0xc5c95a63], [0x4ed8aa4a, 0xe3418acb], [0x5b9cca4f, 0x7763e373], [0x682e6ff3, 0xd6b2b8a3],
  [0x748f82ee, 0x5defb2fc], [0x78a5636f, 0x43172f60], [0x84c87814, 0xa1f0ab72], [0x8cc70208, 0x1a6439ec],
  [0x90befffa, 0x23631e28], [0xa4506ceb, 0xde82bde9], [0xbef9a3f7, 0xb2c67915], [0xc67178f2, 0xe372532b],
  [0xca273ece, 0xea26619c], [0xd186b8c7, 0x21c0c207], [0xeada7dd6, 0xcde0eb1e], [0xf57d4f7f, 0xee6ed178],
  [0x06f067aa, 0x72176fba], [0x0a637dc5, 0xa2c898a6], [0x113f9804, 0xbef90dae], [0x1b710b35, 0x131c471b],
  [0x28db77f5, 0x23047d84], [0x32caab7b, 0x40c72493], [0x3c9ebe0a, 0x15c9bebc], [0x431d67c4, 0x9c100d4c],
  [0x4cc5d4be, 0xcb3e42b6], [0x597f299c, 0xfc657e2a], [0x5fcb6fab, 0x3ad6faec], [0x6c44198c, 0x4a475817],
];
const IV64 = [
  [0x6a09e667, 0xf3bcc908], [0xbb67ae85, 0x84caa73b], [0x3c6ef372, 0xfe94f82b], [0xa54ff53a, 0x5f1d36f1],
  [0x510e527f, 0xade682d1], [0x9b05688c, 0x2b3e6c1f], [0x1f83d9ab, 0xfb41bd6b], [0x5be0cd19, 0x137e2179],
];

// 双字运算。每个值是 [hi, lo]，都是 Uint32 范围。
const add64 = (a, b) => {
  const lo = (a[1] + b[1]) >>> 0;
  const carry = lo < a[1] ? 1 : 0;
  return [(a[0] + b[0] + carry) >>> 0, lo];
};
// 注意这两个：JS 的 & 与 ^ 返回**有符号** 32 位，最高位为 1 时是个负数。
// 这个负数一旦进了 add64 的进位加法，整个轮函数就歪了 —— 而症状是「连 len=0 都不对」，
// 看起来像常量表错。两份实现里先错的是这份，错在看不见的符号位上。
const xor64 = (a, b) => [(a[0] ^ b[0]) >>> 0, (a[1] ^ b[1]) >>> 0];
const and64 = (a, b) => [(a[0] & b[0]) >>> 0, (a[1] & b[1]) >>> 0];
const not64 = (a) => [(~a[0]) >>> 0, (~a[1]) >>> 0];
// 循环右移 n（0 < n < 64）
function ror64(a, n) {
  const hi = a[0], lo = a[1];
  if (n === 32) return [lo, hi];
  if (n < 32) {
    const k = 32 - n;
    return [((hi >>> n) | (lo << k)) >>> 0, ((lo >>> n) | (hi << k)) >>> 0];
  }
  const m = n - 32, k = 32 - m;
  return [((lo >>> m) | (hi << k)) >>> 0, ((hi >>> m) | (lo << k)) >>> 0];
}
// 逻辑右移 n
function shr64(a, n) {
  const hi = a[0], lo = a[1];
  if (n === 0) return [hi, lo];
  if (n < 32) return [(hi >>> n) >>> 0, ((lo >>> n) | (hi << (32 - n))) >>> 0];
  if (n === 32) return [0, hi];
  return [0, (hi >>> (n - 32)) >>> 0];
}

function compress(h, blk) {
  const W = new Array(80);
  for (let i = 0; i < 16; i++) {
    W[i] = [
      ((blk[i * 8] << 24) | (blk[i * 8 + 1] << 16) | (blk[i * 8 + 2] << 8) | blk[i * 8 + 3]) >>> 0,
      ((blk[i * 8 + 4] << 24) | (blk[i * 8 + 5] << 16) | (blk[i * 8 + 6] << 8) | blk[i * 8 + 7]) >>> 0,
    ];
  }
  for (let i = 16; i < 80; i++) {
    const s1 = xor64(xor64(ror64(W[i - 2], 19), ror64(W[i - 2], 61)), shr64(W[i - 2], 6));
    const s0 = xor64(xor64(ror64(W[i - 15], 1), ror64(W[i - 15], 8)), shr64(W[i - 15], 7));
    W[i] = add64(add64(add64(W[i - 16], s0), W[i - 7]), s1);
  }
  let [a, b, c, d, e, f, g, hh] = h.map((x) => [x[0], x[1]]);
  for (let i = 0; i < 80; i++) {
    const S1 = xor64(xor64(ror64(e, 14), ror64(e, 18)), ror64(e, 41));
    const ch = xor64(and64(e, f), and64(not64(e), g));
    const t1 = add64(add64(add64(add64(hh, S1), ch), K64[i]), W[i]);
    const S0 = xor64(xor64(ror64(a, 28), ror64(a, 34)), ror64(a, 39));
    const maj = xor64(xor64(and64(a, b), and64(a, c)), and64(b, c));
    const t2 = add64(S0, maj);
    hh = g; g = f; f = e; e = add64(d, t1);
    d = c; c = b; b = a; a = add64(t1, t2);
  }
  return [a, b, c, d, e, f, g, hh];
}

function digest(msg) {
  const total = msg.length;
  let h = IV64.map((x) => [x[0], x[1]]);
  let off = 0;
  while (total - off >= 128) {
    h = compress(h, msg.subarray(off, off + 128));
    off += 128;
  }
  const rest = total - off;
  const pad = Buffer.alloc(rest >= 112 ? 256 : 128);
  msg.copy(pad, 0, off);
  pad[rest] = 0x80;
  // 128 位长度字段：高 8 字节为零，低 8 字节大端
  const bits = BigInt(total) * 8n;
  for (let i = 0; i < 8; i++) pad[pad.length - 1 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  for (let i = 0; i < pad.length; i += 128) h = compress(h, pad.subarray(i, i + 128));
  const out = Buffer.alloc(64);
  for (let i = 0; i < 8; i++) {
    const v = add64(h[i], IV64[i]);
    out.writeUInt32BE(v[0], i * 8);
    out.writeUInt32BE(v[1], i * 8 + 4);
  }
  return out.toString("hex");
}

import crypto from "node:crypto";
console.log("双字实现与 crypto 对拍：");
let 坏 = 0;
for (const L of [0, 1, 3, 111, 112, 128, 200, 239, 256, 300, 511]) {
  const want = crypto.createHash("sha512").update(t.subarray(0, L)).digest("hex");
  const got = digest(t.subarray(0, L));
  if (want === got) {
    console.log("  len=" + String(L).padStart(3) + "  相同");
  } else {
    坏++;
    console.log("  len=" + String(L).padStart(3) + "  不同");
    console.log("    双字 " + got.slice(0, 32).toUpperCase());
    console.log("    标准 " + want.slice(0, 32).toUpperCase());
  }
}
console.log("");
console.log(坏 === 0 ? "双字实现在这些长度上全部与标准相同" : "双字实现有 " + 坏 + " 个长度不符");

// 最简输入：全零与单一字节。块的内容越简单，错在哪一步越容易看出来。
console.log("");
console.log("简单输入：");
for (const [label, msg] of [
  ["128 个零", Buffer.alloc(128)],
  ["256 个零", Buffer.alloc(256)],
  ["128 个 0x41", Buffer.alloc(128, 0x41)],
  ["111 个零", Buffer.alloc(111)],
  ["112 个零", Buffer.alloc(112)],
]) {
  const want = crypto.createHash("sha512").update(msg).digest("hex");
  const got = digest(msg);
  console.log("  " + label + "  " + (want === got ? "相同" : "不同"));
}
