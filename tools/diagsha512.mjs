// 扫描：把 L=0..200 逐个算一遍，报出第一个与 crypto 不符的长度。
//
// 为什么扫而不是继续读代码：单块（0 到 111）已经被三个长度证明对，两块（112 起）错。
// 可「两块错」也可能是补零块的字节错、也可能是链条传错、也可能是长度字段落在错误的
// 偏移上 —— 而这三种在最终摘要上长得一样。扫描把分界点钉死，分界点本身就是答案：
// 若从 112 开始错，就是补零分支；若从 128 开始错，就是分块循环。
import crypto from "node:crypto";

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
    W[i] = add(W[i - 16],
      ror(W[i - 15], 1) ^ ror(W[i - 15], 8) ^ shr(W[i - 15], 7),
      W[i - 7],
      ror(W[i - 2], 19) ^ ror(W[i - 2], 61) ^ shr(W[i - 2], 6));
  }
  let [a, b, c, d, e, f, g, hh] = h;
  for (let i = 0; i < 80; i++) {
    const t1 = add(hh, ror(e, 14) ^ ror(e, 18) ^ ror(e, 41),
      (e & f) ^ (M64(~e) & g), K[i], W[i]);
    const t2 = add(ror(a, 28) ^ ror(a, 34) ^ ror(a, 39), (a & b) ^ (a & c) ^ (b & c));
    hh = g; g = f; f = e; e = add(d, t1);
    d = c; c = b; b = a; a = add(t1, t2);
  }
  return [a, b, c, d, e, f, g, hh];
}

function digest(msg) {
  const total = msg.length;
  let h = IV.slice();
  let off = 0;
  while (total - off >= 128) {
    h = compress(h, msg.subarray(off, off + 128));
    off += 128;
  }
  const rest = total - off;
  const pad = Buffer.alloc(rest >= 112 ? 256 : 128);
  msg.copy(pad, 0, off);
  pad[rest] = 0x80;
  const bits = BigInt(total) * 8n;
  for (let i = 0; i < 8; i++) pad[pad.length - 1 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  for (let i = 0; i < pad.length; i += 128) h = compress(h, pad.subarray(i, i + 128));
  const out = Buffer.alloc(64);
  for (let i = 0; i < 8; i++) out.writeBigUInt64BE(M64(h[i] + IV[i]), i * 8);
  return out.toString("hex");
}

const t = Buffer.alloc(256);
for (let i = 0; i < 256; i++) t[i] = i & 0xff;

let 第一个 = -1;
const 全错 = [];
for (let L = 0; L <= 400; L++) {
  const want = crypto.createHash("sha512").update(t.subarray(0, L)).digest("hex");
  const got = digest(t.subarray(0, L));
  if (want !== got) {
    if (第一个 < 0) 第一个 = L;
    全错.push(L);
  }
}
console.log("不符的长度个数 " + 全错.length + "，范围 " + 全错[0] + " 到 " + 全错[全错.length - 1]);
console.log("相符的长度个数 " + (401 - 全错.length));
console.log("");
console.log(第一个 < 0 ? "0 到 400 全部与 crypto 相同" : "第一个不符的长度是 " + 第一个);

// 把那一个长度的两块打出来，直接看字节。
if (第一个 >= 0) {
  const L = 第一个;
  const rest = L;
  const pad = Buffer.alloc(rest >= 112 ? 256 : 128);
  t.subarray(0, L).copy(pad, 0);
  pad[rest] = 0x80;
  const bits = BigInt(L) * 8n;
  for (let i = 0; i < 8; i++) pad[pad.length - 1 - i] = Number((bits >> BigInt(8 * i)) & 0xffn);
  console.log("len=" + L + " 的 pad 共 " + pad.length + " 字节：");
  for (let i = 0; i < pad.length; i += 128) {
    console.log("  blk" + (i / 128 + 1) + " " + pad.subarray(i, i + 128).toString("hex"));
  }
}
