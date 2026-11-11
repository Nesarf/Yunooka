// Ed25519 的命令行外壳：跑 RFC 8032 的三条向量、自造长消息向量、逐层吐出中间量。
//
// 实现在 tools/ed25519.mjs。这一份只管「跑与打印」，因为 build.mjs 也要用同一份
// 实现去签第三环 —— 判据与被测物之外，主机这边只该有一份代码。

import { P, L, D, B, hex, unhex, sign, verify, encodePoint } from './ed25519.mjs';

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

    const tampered = new Uint8Array(msg.length + 1);
    tampered.set(msg);
    tampered[msg.length] = 0x01;
    const bad = verify(pk, tampered, sig);
    if (bad) allPass = false;
    console.log(`  tampered-message verify=${bad ? 'pass (wrong)' : 'fail (right)'}`);
    console.log('');
  }

  if (wantSelfMade) {
    const secret = unhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60');
    for (const n of [0, 1, 63, 64, 111, 112, 200, 500]) {
      const message = new Uint8Array(n);
      for (let i = 0; i < n; i++) message[i] = (i * 37 + 11) & 0xff;
      const { publicKey, signature } = sign(secret, message);
      const trace = {};
      const ok = verify(publicKey, message, signature, trace);
      if (!ok) allPass = false;
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
