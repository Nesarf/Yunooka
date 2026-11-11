// 把 112 字节补齐的每一种「我可能想错的地方」都试一遍。
//
// 三种实现（BigInt、双字、汇编）在单块上全部与标准相同、在两块上全部错成同一个值，
// 这说明错误不在压缩、也不在常量表，而在它们共享的那一段补齐逻辑里。
// 与其继续读那段逻辑（读它只会读出我写它时的同一个念头），不如把「可能想错的格子」
// 一格一格填上，看哪一格能把标准值对上。
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
function final(h) {
  const out = Buffer.alloc(64);
  for (let i = 0; i < 8; i++) out.writeBigUInt64BE(M64(h[i] + IV[i]), i * 8);
  return out.toString("hex");
}

const t = Buffer.alloc(256);
for (let i = 0; i < 256; i++) t[i] = i & 0xff;
const msg = t.subarray(0, 112);
const want = crypto.createHash("sha512").update(msg).digest("hex");
console.log("标准  " + want.toUpperCase());
console.log("");

// 一个「建补齐、跑压缩、出摘要」的通用小工具。
function run(label, pad) {
  let h = IV.slice();
  for (let i = 0; i < pad.length; i += 128) h = compress(h, pad.subarray(i, i + 128));
  const got = final(h);
  const ok = got === want;
  console.log((ok ? "相符  " : "不符  ") + label + "  (" + pad.length + " 字节)  " + got.slice(0, 24).toUpperCase());
  return ok;
}

// 基准：我以为对的那一种
{
  const pad = Buffer.alloc(256);
  msg.copy(pad, 0);
  pad[112] = 0x80;
  let bits = 112n * 8n;
  for (let i = 0; i < 8; i++) pad[255 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  run("基准：两块，长度在末 8 字节", pad);
}
// 变体：0x80 后面全是零，长度写在 240..247（低 8 字节提前）
{
  const pad = Buffer.alloc(256);
  msg.copy(pad, 0);
  pad[112] = 0x80;
  let bits = 112n * 8n;
  for (let i = 0; i < 8; i++) pad[247 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  run("长度在 240..247", pad);
}
// 变体：长度写满 16 字节（大端，高 8 字节也是零）
{
  const pad = Buffer.alloc(256);
  msg.copy(pad, 0);
  pad[112] = 0x80;
  let bits = 112n * 8n;
  for (let i = 0; i < 16; i++) pad[255 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  run("长度写满 16 字节", pad);
}
// 变体：长度按字节数
{
  const pad = Buffer.alloc(256);
  msg.copy(pad, 0);
  pad[112] = 0x80;
  for (let i = 0; i < 8; i++) pad[255 - i] = Number((112n >> BigInt(8 * i)) & 0xffn);
  run("长度按字节数", pad);
}
// 变体：长度小端
{
  const pad = Buffer.alloc(256);
  msg.copy(pad, 0);
  pad[112] = 0x80;
  let bits = 112n * 8n;
  for (let i = 0; i < 8; i++) pad[248 + i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  run("长度小端放在 248..255", pad);
}
// 变体：0x80 放在 111（即把数据当成 111 字节）
{
  const pad = Buffer.alloc(128);
  msg.copy(pad, 0, 0, 111);
  pad[111] = 0x80;
  let bits = 112n * 8n;
  for (let i = 0; i < 8; i++) pad[127 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  run("0x80 放在 111", pad);
}
// 变体：补三块（多一块全零）
{
  const pad = Buffer.alloc(384);
  msg.copy(pad, 0);
  pad[112] = 0x80;
  let bits = 112n * 8n;
  for (let i = 0; i < 8; i++) pad[383 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  run("补三块", pad);
}
// 变体：两块但第二块不放长度（长度留在第一块尾部，即 112 字节就当 56 字节处理）
{
  const pad = Buffer.alloc(256);
  msg.copy(pad, 0);
  pad[112] = 0x80;
  let bits = 112n * 8n;
  for (let i = 0; i < 8; i++) pad[127 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  run("长度放在第一块尾部", pad);
}
// 变体：0x80 放在 112 但只补一块、长度写在 120..127（即 pad 128 字节）
{
  const pad = Buffer.alloc(128);
  msg.copy(pad, 0, 0, 112);
  pad[112] = 0x80;
  let bits = 112n * 8n;
  for (let i = 0; i < 8; i++) pad[127 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  run("只补一块且长度在末 8 字节", pad);
}
