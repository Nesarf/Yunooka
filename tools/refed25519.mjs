// Ed25519 的参考实现：主机侧的尺子，固件那边照着它量。
//
// 为什么需要它：固件里要写域算术、点运算、标量乘，每一层都可能错，而串口上
// 「验签不通过」与「签名本来就是假的」分不开。这里用 BigInt 把 RFC 8032 的
// 测试向量跑通，再给出每一层的中间量（公钥点的坐标、标量乘的结果、k 的值），
// 固件打出来的每个中间量都能在这里找到对照。
//
// 它还负责自造向量：签名也实现了，所以「篡改一个字节必须验不过」这种反面判据
// 可以在主机上先立起来，再交给固件。
//
// 依赖只有 node:crypto 的 sha512 —— 那一条固件侧已经证明对了（六行长度全中）。
// 慢是不要紧的：它只跑几条向量，用途是对照，不是生产。

import { createHash } from 'node:crypto';

const P = (1n << 255n) - 19n;
const L = (1n << 252n) + 27742317777372353535851937790883648493n;

const mod = (a) => {
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

const inv = (a) => powm(a, P - 2n);

// d = -121665/121666
const D = mod(-121665n * inv(121666n));
const D2 = mod(2n * D);
// sqrt(-1) = 2^((p-1)/4)
const SQRT_M1 = powm(2n, (P - 1n) / 4n);

// ---- 字节序：Ed25519 一律小端 ---------------------------------------------

function fromLE(bytes) {
  let v = 0n;
  for (let i = bytes.length - 1; i >= 0; i--) v = (v << 8n) | BigInt(bytes[i]);
  return v;
}

function toLE(v, n) {
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    out[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return out;
}

const hex = (bytes) => Buffer.from(bytes).toString('hex');
const unhex = (s) => new Uint8Array(Buffer.from(s, 'hex'));

const sha512 = (...parts) => {
  const h = createHash('sha512');
  for (const p of parts) h.update(p);
  return new Uint8Array(h.digest());
};

// ---- 域上的开方与点的编码 ------------------------------------------------

// 由 y 与 x 的符号位还原 x。不是二次剩余就返回 null。
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

// 32 字节压缩点 → 扩展坐标 (X, Y, Z=1, T)
function decodePoint(bytes) {
  if (bytes.length !== 32) return null;
  const v = fromLE(bytes);
  const sign = Number(v >> 255n);
  const y = v & ((1n << 255n) - 1n);
  if (y >= P) return null;
  const x = recoverX(y, sign);
  if (x === null) return null;
  return { X: x, Y: y, Z: 1n, T: mod(x * y) };
}

function encodePoint(p) {
  const zi = inv(p.Z);
  const x = mod(p.X * zi);
  const y = mod(p.Y * zi);
  const out = toLE(y, 32);
  out[31] |= Number(x & 1n) << 7;
  return out;
}

// ---- 点运算（扩展扭曲爱德华兹坐标） --------------------------------------

const IDENT = { X: 0n, Y: 1n, Z: 1n, T: 0n };

function pointAdd(p, q) {
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

function pointDouble(p) {
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

function scalarMult(p, e) {
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

// 两个点是否同一个点：比较投影坐标
function samePoint(p, q) {
  return mod(p.X * q.Z) === mod(q.X * p.Z) && mod(p.Y * q.Z) === mod(q.Y * p.Z);
}

// ---- 基点 -----------------------------------------------------------------

// y = 4/5，x 取偶数那一个（RFC 8032 规定的正方向）
const B = (() => {
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

function sign(secret, message) {
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

function verify(publicKey, message, signature, trace = null) {
  if (publicKey.length !== 32 || signature.length !== 64) return false;
  const Rbytes = signature.slice(0, 32);
  const S = fromLE(signature.slice(32, 64));
  if (S >= L) return false;

  const A = decodePoint(publicKey);
  if (A === null) return false;
  const R = decodePoint(Rbytes);
  if (R === null) return false;

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

// ---- RFC 8032 §7.1 的测试向量 --------------------------------------------

const VECTORS = [
  {
    name: 'rfc8032-1',
    secret: '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
    publicKey: 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
    message: '',
    signature:
      'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155' +
      '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
  },
  {
    name: 'rfc8032-2',
    secret: '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
    publicKey: '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
    message: '72',
    signature:
      '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da' +
      '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
  },
  {
    name: 'rfc8032-3',
    secret: 'c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7',
    publicKey: 'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025',
    message: 'af82',
    signature:
      '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac' +
      '18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a',
  },
];

// ---- 命令行 ---------------------------------------------------------------

function main() {
  const args = process.argv.slice(2);
  const wantSelfMade = args.includes('--self');
  let allPass = true;

  console.log(`# field p = 2^255-19`);
  console.log(`d      = ${D.toString(16)}`);
  console.log(`base x = ${B.X.toString(16)}`);
  console.log(`base y = ${B.Y.toString(16)}`);
  console.log(`baseenc= ${hex(encodePoint(B))}`);
  console.log('');

  for (const v of VECTORS) {
    const pk = unhex(v.publicKey);
    const msg = unhex(v.message);
    const sig = unhex(v.signature);
    const trace = {};
    const ok = verify(pk, msg, sig, trace);
    if (!ok) allPass = false;
    console.log(`vector ${v.name} msglen=${msg.length} verify=${ok ? 'pass' : 'fail'}`);
    console.log(`  k      = ${trace.k !== undefined ? trace.k.toString(16) : '-'}`);
    console.log(`  S*B    = ${trace.SB ? hex(trace.SB) : '-'}`);
    console.log(`  R+[k]A = ${trace.RkA ? hex(trace.RkA) : '-'}`);

    // 反面：同一个签名，消息改一个字节必须验不过
    const tampered = new Uint8Array(msg.length + 1);
    tampered.set(msg);
    tampered[msg.length] = 0x01;
    const bad = verify(pk, tampered, sig);
    if (bad) allPass = false;
    console.log(`  tampered-message verify=${bad ? 'pass (wrong)' : 'fail (right)'}`);
    console.log('');
  }

  // 自造向量：长消息、跨 SHA-512 多块，正是固件那条多块路径
  if (wantSelfMade) {
    const secret = unhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60');
    for (const n of [0, 1, 63, 64, 111, 112, 200, 500]) {
      const message = new Uint8Array(n);
      for (let i = 0; i < n; i++) message[i] = (i * 37 + 11) & 0xff;
      const { publicKey, signature } = sign(secret, message);
      const trace = {};
      const ok = verify(publicKey, message, signature, trace);
      if (!ok) allPass = false;
      // 自签必须能过，改过的必须过不了
      const broken = signature.slice();
      broken[0] ^= 0x01;
      const mustFail = verify(publicKey, message, broken);
      if (mustFail) allPass = false;
      console.log(
        `self len=${n} pk=${hex(publicKey)} sig=${hex(signature)} verify=${
          ok ? 'pass' : 'fail'
        } flipped=${mustFail ? 'pass (wrong)' : 'fail (right)'}`,
      );
    }
  }

  console.log('');
  console.log(allPass ? 'result: all pass' : 'result: something failed');
  process.exit(allPass ? 0 : 1);
}

main();
