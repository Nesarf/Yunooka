// 用 SHA-384 的初值跑同一套压缩与补齐，与 crypto 的 sha384 对拍。
//
// 为什么这一刀能切开：SHA-384 与 SHA-512 的压缩函数、块大小（128 字节）、补齐规则
// （128 位长度）完全一样，只有初值与输出截断不同。所以同一个消息如果 SHA-384 对而
// SHA-512 错，错在初值或末尾；两者同样错，错在压缩或两块的处理上。
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

const IV512 = [
  0x6a09e667f3bcc908n, 0xbb67ae8584caa73bn, 0x3c6ef372fe94f82bn, 0xa54ff53a5f1d36f1n,
  0x510e527fade682d1n, 0x9b05688c2b3e6c1fn, 0x1f83d9abfb41bd6bn, 0x5be0cd19137e2179n,
];
const IV384 = [
  0xcbbb9d5dc1059ed8n, 0x629a292a367cd507n, 0x9159015a3070dd17n, 0x152fecd8f70e5939n,
  0x67332667ffc00b31n, 0x8eb44a8768581511n, 0xdb0c2e0d64f98fa7n, 0x47b5481dbefa4fa4n,
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

function digest(msg, IV, outWords) {
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
  const out = Buffer.alloc(outWords * 8);
  for (let i = 0; i < outWords; i++) out.writeBigUInt64BE(M64(h[i] + IV[i]), i * 8);
  return out.toString("hex");
}

const t = Buffer.alloc(256);
for (let i = 0; i < 256; i++) t[i] = i & 0xff;

console.log("SHA-384 对照（同一个 compress，只换初值）：");
for (const L of [0, 1, 111, 112, 128, 239]) {
  const want = crypto.createHash("sha384").update(t.subarray(0, L)).digest("hex");
  const got = digest(t.subarray(0, L), IV384, 6);
  const ok = want === got;
  console.log("  len=" + String(L).padStart(3) + "  " + (ok ? "相同" : "不同")
    + (ok ? "" : "  实现 " + got.slice(0, 24) + " / 标准 " + want.slice(0, 24)));
}

console.log("");
console.log("SHA-512 同样几个长度（应当是 0..111 相同、112 起不同）：");
for (const L of [0, 111, 112]) {
  const want = crypto.createHash("sha512").update(t.subarray(0, L)).digest("hex");
  const got = digest(t.subarray(0, L), IV512, 8);
  console.log("  len=" + String(L).padStart(3) + "  " + (want === got ? "相同" : "不同"));
}
