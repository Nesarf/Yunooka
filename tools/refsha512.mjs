// SHA-512 的参考实现：能算「每一次压缩之后的 h」，而不只是最终摘要。
//
// 为什么需要它：汇编那边打出来的是中间状态（dbg blk h0=...），而最终摘要对不上时，
// 「第一块就错了」与「链条接错了」是两个不同的结论，只看最终值分不开。这里用 BigInt
// 逐块算，把每次压缩后的 h0 打出来，与串口那些行一一对照。
//
// 慢是不要紧的：它只跑几个块，用途是对照，不是生产。

const MASK = (1n << 64n) - 1n;
const M64 = (x) => x & MASK;
const ror = (x, n) => M64((x >> BigInt(n)) | (x << BigInt(64 - n)));
const shr = (x, n) => x >> BigInt(n);
const add = (...xs) => {
  let s = 0n;
  for (const x of xs) s = M64(s + x);
  return s;
};

function isPrime(n) {
  if (n < 2) return false;
  for (let d = 2; d * d <= n; d++) if (n % d === 0) return false;
  return true;
}
const primes = [];
for (let n = 2; primes.length < 80; n++) if (isPrime(n)) primes.push(n);
function icbrt(N) {
  if (N < 2n) return N;
  let x = 1n << BigInt(Math.ceil(N.toString(2).length / 3) + 2);
  for (;;) {
    const nx = (2n * x + N / (x * x)) / 3n;
    if (nx >= x) break;
    x = nx;
  }
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
  for (let i = 0; i < 16; i++) {
    let v = 0n;
    for (let j = 0; j < 8; j++) v = (v << 8n) | BigInt(blk[i * 8 + j]);
    W[i] = v;
  }
  for (let i = 16; i < 80; i++) {
    const s1 = ror(W[i - 2], 19) ^ ror(W[i - 2], 61) ^ shr(W[i - 2], 6);
    const s0 = ror(W[i - 15], 1) ^ ror(W[i - 15], 8) ^ shr(W[i - 15], 7);
    W[i] = add(W[i - 16], s0, W[i - 7], s1);
  }
  let [a, b, c, d, e, f, g, hh] = h;
  for (let i = 0; i < 80; i++) {
    const S1 = ror(e, 14) ^ ror(e, 18) ^ ror(e, 41);
    const ch = (e & f) ^ (M64(~e) & g);
    const t1 = add(hh, S1, ch, K[i], W[i]);
    const S0 = ror(a, 28) ^ ror(a, 34) ^ ror(a, 39);
    const maj = (a & b) ^ (a & c) ^ (b & c);
    const t2 = add(S0, maj);
    hh = g; g = f; f = e; e = add(d, t1);
    d = c; c = b; b = a; a = add(t1, t2);
  }
  return [a, b, c, d, e, f, g, hh];
}

const hex = (x) => x.toString(16).padStart(16, "0").toUpperCase();

// 逐块跑，把每次压缩后的 h0 报出来。
function trace(msg) {
  const out = [];
  const total = msg.length;
  let h = IV.slice();
  let off = 0;
  while (total - off >= 128) {
    h = compress(h, msg.subarray(off, off + 128));
    out.push(hex(h[0]));
    off += 128;
  }
  // 补齐，与汇编同一套判断
  const rest = total - off;
  const pad = Buffer.alloc(rest >= 112 ? 256 : 128);
  msg.copy(pad, 0, off);
  pad[rest] = 0x80;
  const bits = BigInt(total) * 8n;
  for (let i = 0; i < 8; i++) pad[pad.length - 1 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  for (let i = 0; i < pad.length; i += 128) {
    h = compress(h, pad.subarray(i, i + 128));
    out.push(hex(h[0]));
  }
  return out;
}

// 与汇编的探针同一种编码：整个 h 的 64 字节按内存顺序（每个字小端）打出来。
// 这样串口那一行与这里的行可以逐字符比，不必在脑子里换字节序。
function hbytes(h) {
  const b = Buffer.alloc(64);
  for (let i = 0; i < 8; i++) b.writeBigUInt64LE(h[i], i * 8);
  return b.toString("hex").toUpperCase();
}
function traceFull(msg) {
  const out = [];
  const total = msg.length;
  let h = IV.slice();
  let off = 0;
  while (total - off >= 128) {
    h = compress(h, msg.subarray(off, off + 128));
    out.push(hbytes(h));
    off += 128;
  }
  const rest = total - off;
  const pad = Buffer.alloc(rest >= 112 ? 256 : 128);
  msg.copy(pad, 0, off);
  pad[rest] = 0x80;
  const bits = BigInt(total) * 8n;
  for (let i = 0; i < 8; i++) pad[pad.length - 1 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  for (let i = 0; i < pad.length; i += 128) {
    h = compress(h, pad.subarray(i, i + 128));
    out.push(hbytes(h));
  }
  return out;
}

const t = Buffer.alloc(256);
for (let i = 0; i < 256; i++) t[i] = i & 0xff;

console.log("每次压缩之后的 h0（未加回初值）：");
for (const L of [0, 1, 111, 112, 128, 239]) {
  const tr = trace(t.subarray(0, L));
  console.log("  len=" + String(L).padStart(3) + "  " + tr.join(" "));
}

console.log("");
console.log("每次压缩之后的整个 h（64 字节，按内存顺序；探针打的就是这个）：");
for (const L of [0, 1, 111, 112, 128, 239]) {
  for (const v of traceFull(t.subarray(0, L))) {
    console.log("  len=" + String(L).padStart(3) + "  " + v);
  }
}

// 诊断：把 len=112 的两块补齐与最终摘要原样摊开。
// 这一步存在的理由是「参考实现与汇编对得上」并不等于「对得上标准」—— 两者都写错时
// 它们照样一致，而只有 node 的 crypto 是不动的那个锚。
{
  const msg = t.subarray(0, 112);
  const pad = Buffer.alloc(256);
  msg.copy(pad, 0);
  pad[112] = 0x80;
  const bits = 112n * 8n;
  for (let i = 0; i < 8; i++) pad[255 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  console.log("");
  console.log("len=112 的补齐两块：");
  console.log("  blk1 " + pad.subarray(0, 128).toString("hex"));
  console.log("  blk2 " + pad.subarray(128, 256).toString("hex"));
  let h = IV.slice();
  h = compress(h, pad.subarray(0, 128));
  h = compress(h, pad.subarray(128, 256));
  const outBuf = Buffer.alloc(64);
  for (let i = 0; i < 8; i++) outBuf.writeBigUInt64BE(M64(h[i] + IV[i]), i * 8);
  console.log("  参考算出的 len=112 摘要 " + outBuf.toString("hex").toUpperCase());
  console.log("  标准（crypto）             C5FBD731D19D2AE1180F001BE72C2C1AABA1D7B094B3748880E24593B8E117A750E11C1BD867CC2F96DACE8C8B74ABD2D5C4F236BE444E77D30D1916174070B9");
}
