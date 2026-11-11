// 逐位实现的 SHA-512：把消息当一条位串来补，完全不做字节对齐的假设。
//
// 为什么值得再写一份：字节版的两份实现（BigInt 与双字）在 0..111 上全部与标准相同、
// 在 112 起全部错成同一个值。两份都错成一样，说明错在它们共享的那个假设里，而那个
// 假设只可能是「补齐是字节层面的事」。这一份从位上做：1 位「1」、若干位「0」、
// 128 位长度，每 1024 位一块。字节层面对不对，它给出了另一个答案。
import crypto from "node:crypto";

const MASK = (1n << 64n) - 1n;
const M64 = (x) => x & MASK;
const ror = (x, n) => M64((x >> BigInt(n)) | (x << BigInt(64 - n)));
const shr = (x, n) => x >> BigInt(n);
const add = (...xs) => { let s = 0n; for (const x of xs) s = M64(s + x); return s; };

function isPrime(n) { if (n < 2) return false; for (let d = 2; d * d <= n; d++) if (n % d === 0) return false; return true; }
const primes = [];
for (let n = 2; primes.length < 80; n++) if (isPrime(n)) primes.push(n);
function icbrt(N) {
  if (N < 2n) return N;
  let x = 1n << BigInt(Math.ceil(N.toString(2).length / 3) + 2);
  for (;;) { const nx = (2n * x + N / (x * x)) / 3n; if (nx >= x) break; x = nx; }
  while (x * x * x > N) x--;
  while ((x + 1n) ** 3n <= N) x++;
  return x;
}
const K = primes.map((p) => M64(icbrt(BigInt(p) << 192n)));
const IV = [
  0x6a09e667f3bcc908n, 0xbb67ae8584caa73bn, 0x3c6ef372fe94f82bn, 0xa54ff53a5f1d36f1n,
  0x510e527fade682d1n, 0x9b05688c2b3e6c1fn, 0x1f83d9abfb41bd6bn, 0x5be0cd19137e2179n,
];

function compress(h, blk) {
  const W = new Array(80);
  for (let i = 0; i < 16; i++) { let v = 0n; for (let j = 0; j < 8; j++) v = (v << 8n) | BigInt(blk[i * 8 + j]); W[i] = v; }
  for (let i = 16; i < 80; i++) {
    W[i] = add(W[i - 16], ror(W[i - 15], 1) ^ ror(W[i - 15], 8) ^ shr(W[i - 15], 7), W[i - 7],
      ror(W[i - 2], 19) ^ ror(W[i - 2], 61) ^ shr(W[i - 2], 6));
  }
  let [a, b, c, d, e, f, g, hh] = h;
  for (let i = 0; i < 80; i++) {
    const t1 = add(hh, ror(e, 14) ^ ror(e, 18) ^ ror(e, 41), (e & f) ^ (M64(~e) & g), K[i], W[i]);
    const t2 = add(ror(a, 28) ^ ror(a, 34) ^ ror(a, 39), (a & b) ^ (a & c) ^ (b & c));
    hh = g; g = f; f = e; e = add(d, t1); d = c; c = b; b = a; a = add(t1, t2);
  }
  return [a, b, c, d, e, f, g, hh];
}

// 逐位补齐：消息 -> 位数组 -> 末尾补 1 位 1、补 0 到位数 ≡ 896 mod 1024、再补 128 位长度。
function digestBits(msg) {
  const bitLen = msg.length * 8;
  const bits = [];
  for (const byte of msg) for (let k = 7; k >= 0; k--) bits.push((byte >> k) & 1);
  bits.push(1);
  while (bits.length % 1024 !== 896) bits.push(0);
  for (let i = 127; i >= 0; i--) bits.push(Number((BigInt(bitLen) >> BigInt(i)) & 1n));

  let h = IV.slice();
  for (let base = 0; base < bits.length; base += 1024) {
    const blk = Buffer.alloc(128);
    for (let i = 0; i < 128; i++) {
      let v = 0;
      for (let k = 0; k < 8; k++) v = (v << 1) | bits[base + i * 8 + k];
      blk[i] = v;
    }
    h = compress(h, blk);
  }
  const out = Buffer.alloc(64);
  for (let i = 0; i < 8; i++) out.writeBigUInt64BE(M64(h[i] + IV[i]), i * 8);
  return out.toString("hex");
}

const t = Buffer.alloc(256);
for (let i = 0; i < 256; i++) t[i] = i & 0xff;

console.log("逐位实现与 crypto 对拍：");
let 坏 = 0;
for (const [label, msg] of [
  ["0 字节", Buffer.alloc(0)],
  ["1 字节", t.subarray(0, 1)],
  ["111 字节", t.subarray(0, 111)],
  ["112 字节", t.subarray(0, 112)],
  ["128 字节", t.subarray(0, 128)],
  ["128 个零", Buffer.alloc(128)],
  ["256 个零", Buffer.alloc(256)],
  ["239 字节", t.subarray(0, 239)],
]) {
  const want = crypto.createHash("sha512").update(msg).digest("hex");
  const got = digestBits(msg);
  const ok = want === got;
  if (!ok) 坏++;
  console.log("  " + label.padEnd(10) + (ok ? "相同" : "不同  " + got.slice(0, 24) + " / " + want.slice(0, 24)));
}
console.log("");
console.log(坏 === 0 ? "逐位实现全部与标准相同" : "逐位实现有 " + 坏 + " 个不符");
