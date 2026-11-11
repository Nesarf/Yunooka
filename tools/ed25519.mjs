// Ed25519 的参考实现：一份可被别处 import 的纯函数版本。
//
// 这个文件的存在理由是 build.mjs 要给第三环签一次名，而签名需要一个「主机这边也
// 信得过」的实现。tools/refed25519.mjs 是它的命令行外壳（跑 RFC 向量、自造向量），
// 两个文件共用这里的代码 —— 也就是判据与被测物之外，只留一份主机实现。
//
// 依赖只有 node:crypto 的 sha512。那一条固件侧已经证明对了（六行长度全中），所以
// 在这里借它不是偷懒：它是这条链上唯一一处「两边都用同一个东西」的地方，而那正是
// 我们想要的 —— 哈希本身不该再被怀疑。
//
// 慢是不要紧的：它只跑几条向量与一次签名，用途是对照，不是生产。

import { createHash } from 'node:crypto';

export const P = (1n << 255n) - 19n;
export const L = (1n << 252n) + 27742317777372353535851937790883648493n;

export const mod = (a) => {
  const r = a % P;
  return r < 0n ? r + P : r;
};

function powm(b, e) {
  let r = 1n;
  b = mod(b);
  while (e > 0n) {
    if (e & 1n) r = mod(r * b);
    b = mod(b * b);
    e >>= 1n;
  }
  return r;
}

export const inv = (a) => powm(a, P - 2n);

export const D = mod(-121665n * inv(121666n));
const D2 = mod(2n * D);
const SQRT_M1 = powm(2n, (P - 1n) / 4n);

// ---- 字节序：Ed25519 一律小端 ---------------------------------------------

export function fromLE(bytes) {
  let v = 0n;
  for (let i = bytes.length - 1; i >= 0; i--) v = (v << 8n) | BigInt(bytes[i]);
  return v;
}

export function toLE(v, n) {
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    out[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return out;
}

export const hex = (bytes) => Buffer.from(bytes).toString('hex');
export const unhex = (s) => new Uint8Array(Buffer.from(s, 'hex'));

export const sha512 = (...parts) => {
  const h = createHash('sha512');
  for (const p of parts) h.update(p);
  return new Uint8Array(h.digest());
};

// ---- 域上的开方与点的编码 ------------------------------------------------

function recoverX(y, sign) {
  const y2 = mod(y * y);
  const num = mod(y2 - 1n);
  const den = mod(D * y2 + 1n);
  const x2 = mod(num * inv(den));
  let x = powm(x2, (P + 3n) / 8n);
  if (mod(x * x - x2) !== 0n) x = mod(x * SQRT_M1);
  if (mod(x * x - x2) !== 0n) return null;
  if (Number(x & 1n) !== sign) x = mod(-x);
  return x;
}

export function decodePoint(bytes) {
  if (bytes.length !== 32) return null;
  const v = fromLE(bytes);
  const sign = Number(v >> 255n);
  const y = v & ((1n << 255n) - 1n);
  if (y >= P) return null;
  const x = recoverX(y, sign);
  if (x === null) return null;
  return { X: x, Y: y, Z: 1n, T: mod(x * y) };
}

export function encodePoint(p) {
  const zi = inv(p.Z);
  const x = mod(p.X * zi);
  const y = mod(p.Y * zi);
  const out = toLE(y, 32);
  out[31] |= Number(x & 1n) << 7;
  return out;
}

// ---- 点运算（扩展扭曲爱德华兹坐标） --------------------------------------

const IDENT = { X: 0n, Y: 1n, Z: 1n, T: 0n };

export function pointAdd(p, q) {
  const A = mod(mod(p.Y - p.X) * mod(q.Y - q.X));
  const B = mod(mod(p.Y + p.X) * mod(q.Y + q.X));
  const C = mod(p.T * D2 * q.T);
  const Dd = mod(2n * p.Z * q.Z);
  const E = mod(B - A);
  const F = mod(Dd - C);
  const G = mod(Dd + C);
  const H = mod(B + A);
  return { X: mod(E * F), Y: mod(G * H), T: mod(E * H), Z: mod(F * G) };
}

export function pointDouble(p) {
  const A = mod(p.X * p.X);
  const B = mod(p.Y * p.Y);
  const C = mod(2n * p.Z * p.Z);
  const Dd = mod(-A);
  const E = mod(mod(p.X + p.Y) ** 2n - A - B);
  const G = mod(Dd + B);
  const F = mod(G - C);
  const H = mod(Dd - B);
  return { X: mod(E * F), Y: mod(G * H), T: mod(E * H), Z: mod(F * G) };
}

export function scalarMult(p, e) {
  let q = IDENT;
  let acc = p;
  let k = e;
  while (k > 0n) {
    if (k & 1n) q = pointAdd(q, acc);
    acc = pointDouble(acc);
    k >>= 1n;
  }
  return q;
}

export function samePoint(p, q) {
  if (p.Z === 0n || q.Z === 0n) return false;
  return mod(p.X * q.Z) === mod(q.X * p.Z) && mod(p.Y * q.Z) === mod(q.Y * p.Z);
}

// ---- 基点 -----------------------------------------------------------------

export const B = (() => {
  const y = mod(4n * inv(5n));
  const x = recoverX(y, 0);
  return { X: x, Y: y, Z: 1n, T: mod(x * y) };
})();

// ---- 签名与验签 -----------------------------------------------------------

function clampScalar(h) {
  const a = h.slice(0, 32);
  a[0] &= 248;
  a[31] &= 127;
  a[31] |= 64;
  return fromLE(a);
}

export function sign(secret, message) {
  if (secret.length !== 32) throw new Error('secret must be 32 bytes');
  const h = sha512(secret);
  const a = clampScalar(h);
  const prefix = h.slice(32, 64);
  const A = encodePoint(scalarMult(B, a));
  const r = mod(fromLE(sha512(prefix, message)) % L);
  const R = encodePoint(scalarMult(B, r));
  const k = mod(fromLE(sha512(R, A, message)) % L);
  const S = (r + k * a) % L;
  return { publicKey: A, signature: new Uint8Array([...R, ...toLE(S, 32)]) };
}

export function verify(publicKey, message, signature, trace = null) {
  if (publicKey.length !== 32 || signature.length !== 64) return false;
  const Rbytes = signature.slice(0, 32);
  const S = fromLE(signature.slice(32, 64));
  if (S >= L) return false;

  const A = decodePoint(publicKey);
  if (A === null) return false;
  const R = decodePoint(Rbytes);
  if (R === null) return false;

  // k 是「把摘要当作小端整数」—— 第一个字节就是最低位，所以 sha512 的输出原样读，
  // 不反序。这一条在固件那边曾经错成反序，而对照脚本也一起错了；两处现在都按这一句。
  const k = mod(fromLE(sha512(Rbytes, publicKey, message)) % L);

  const left = scalarMult(B, S);
  const right = pointAdd(R, scalarMult(A, k));

  if (trace) {
    trace.A = encodePoint(A);
    trace.R = Rbytes;
    trace.k = k;
    trace.SB = encodePoint(left);
    trace.RkA = encodePoint(right);
  }

  return samePoint(left, right);
}
