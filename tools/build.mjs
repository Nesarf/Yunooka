// 把 boot/boot.asm 变成一块 VirtualBox 认得的硬盘。
//
// 三步，每一步都留一个可核对的形状：nasm 出的必须是整整 512 字节，末两字节必须是
// 0x55 0xAA（BIOS 认引导扇区的唯一凭据），补成盘之后长度必须是整数个扇区。
// 这三条任何一条不成立，后面跑起来的东西就不是我们以为的那个。
//
// 用法：node tools/build.mjs
// 产出：build/boot.img（512 字节，引导扇区原文）、build/disk.vdi（可挂的盘）
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { sign as edSign, hex as edHex } from "./ed25519.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const 建 = path.join(ROOT, "build");
fs.mkdirSync(建, { recursive: true });

const 源 = path.join(ROOT, "boot/boot.asm");
const 源二 = path.join(ROOT, "boot/stage2.asm");
const 像 = path.join(建, "boot.img");
const 像装 = path.join(建, "loader.bin");
const 像二 = path.join(建, "stage2.bin");
const 盘像 = path.join(建, "disk.img");
const 盘 = path.join(建, "disk.vdi");

const 失败 = (为什么) => {
  console.error("建不起来：" + 为什么);
  process.exit(1);
};

// 从 nasm 的清单里按符号名找它的地址。清单的每一行形如：
//   123 00007E1F 0000         seed_bytes: dw 0
// 第二列是**段内偏移**，不含 org —— 验过：org 是 0x7e00 的时候，清单第一行 cli 的
// 地址是 00000000。所以取出来直接用，不要减 org。
const 找符号 = (清单路, 名字) => {
  if (!fs.existsSync(清单路)) return null;
  const m = new RegExp("^\\s*\\d+\\s+([0-9A-Fa-f]{8})\\s+.*\\b" + 名字 + ":", "m").exec(fs.readFileSync(清单路, "utf8"));
  return m ? parseInt(m[1], 16) : null;
};

// ---- 找 VBoxManage（与 hmyr 仓库里那个重验脚本同一个办法：注册表、再 PATH）----
const 找VBox = () => {
  if (process.env.VBOX_MANAGE && fs.existsSync(process.env.VBOX_MANAGE)) return process.env.VBOX_MANAGE;
  if (process.platform === "win32") {
    const r = spawnSync("reg", ["query", "HKLM\\SOFTWARE\\Oracle\\VirtualBox", "/v", "InstallDir"], { encoding: "utf8" });
    const m = /InstallDir\s+REG_SZ\s+(.+)/.exec(String(r.stdout || ""));
    if (m) {
      const 猜 = path.join(m[1].trim(), "VBoxManage.exe");
      if (fs.existsSync(猜)) return 猜;
    }
  }
  const 哪 = spawnSync("VBoxManage", ["--version"], { encoding: "utf8" });
  return 哪.status === 0 ? "VBoxManage" : null;
};

// ---- 一、编三段，各查各的形状 ----
// 三段各有各的硬约束：引导扇区必须正好 512 字节（BIOS 只读这一扇区）；加载器不能超过
// 它占的那 8 个扇区；主体不能超过 128 个扇区（64 KB）。哪一条不成立，后面跑起来的东西
// 就不是我们以为的那个。
//
// 为什么有三段：BIOS 那一次 int 0x13 不能跨 64 KB DMA 边界，而主体原先从 0x7E00 起 ——
// 于是它最多 64 个扇区（0xFE00 就到界）。主体长到 32768 字节的那一天那条界顶住了，
// 而症状是「引导读了、内容却不对」，看起来像主体自己崩了。加一层加载器之后主体住到
// 0x30000，上限变成 0x40000（预读区起点），也就是 128 个扇区。
//
// 「主体多大」只有这一个数，后面全从它推：上限、种子起始扇区、种子偏移，以及那几行
// 打印出来的字。
const 加载器扇区 = 8;
const 第二段上限扇区 = 128;
const 第二段上限 = 第二段上限扇区 * 512;
const 编一段 = (名字, 源路, 出, 上限 = 512, 清单 = null) => {
  const 参 = ["-f", "bin", 源路, "-o", 出];
  if (清单) 参.push("-l", 清单);
  const r = spawnSync("nasm", 参, { encoding: "utf8" });
  if (r.status !== 0) 失败(名字 + " 编不过：" + String(r.stderr || "").slice(0, 400));
  const 字节 = fs.readFileSync(出);
  if (字节.length > 上限) 失败(名字 + " 超过上限：" + 字节.length + " > " + 上限);
  return 字节;
};

const 引导 = 编一段("引导扇区", 源, 像);
if (引导.length !== 512) 失败("引导扇区应当正好 512 字节，实际 " + 引导.length);
if (引导[510] !== 0x55 || 引导[511] !== 0xaa) {
  失败("末两字节应当是 55 AA，实际 " + 引导[510].toString(16) + " " + 引导[511].toString(16));
}
const 清单 = path.join(建, "stage2.lst");
const 装载器 = 编一段("加载器", path.join("boot", "loader.asm"), 像装, 加载器扇区 * 512);
// 它必须**正好**占 8 个扇区，不是「不超过 8」。因为引导扇区按 8 个扇区读它，而主体
// 的位置从「1 + 8」算起 —— 加载器少占的扇区会让主体整体错位，而错位的症状是
// 「loader failed」或者更糟：读进来一截别的代码。第一版就少占了七个。
if (装载器.length !== 加载器扇区 * 512)
  失败("加载器是 " + 装载器.length + " 字节，而它必须正好 " + (加载器扇区 * 512)
    + " 字节（" + 加载器扇区 + " 个扇区）—— loader.asm 末尾那句 times 是按 4096 对齐的吗");
const 二段 = 编一段("第二段", 源二, 像二, Infinity, 清单);
// 上限检查从 编一段 里挪到这里，为的是错误信息能说出该改哪两处、改成多少。
// 「超过上限：27136 > 26624」这种话不告诉人下一步，而这一组数返工过六次了。
const 二段扇区数 = Math.ceil(二段.length / 512);
if (二段扇区数 > 第二段上限扇区)
  失败("第二段长到 " + 二段.length + " 字节，占 " + 二段扇区数 + " 个扇区，而声明的是 "
    + 第二段上限扇区 + " 个。把 stage2.asm 的 stage2_sectors"
    + " 一起改成 " + 二段扇区数 + "。");
// 第二段自带签名（它也是一段可引导的代码，只是不经过 BIOS），所以这里只查长度上限。
console.log("引导扇区  " + 引导.length + " 字节，签名 55 AA 对");
console.log("加载器    " + 装载器.length + " 字节（上限 " + (加载器扇区 * 512)
  + "，占 " + 加载器扇区 + " 个扇区）");
console.log("第二段    " + 二段.length + " 字节（上限 " + 第二段上限 + "，占 "
  + 二段扇区数 + " 个扇区，住 0x10000）");

// ---- 二、种子 ----
// 给不给种子都建得出来，这很重要：Yunooka 不欠 HMYR 仓库任何东西，所以没有种子时
// 它应当照样能建、能跑，只是判据变成第三种结果（读到扇区，但里面没有种子）。
// 给了就把整份写进去 —— 第二段现在读的是整份（0x20000 起，74594 字节铺到 0x32400），
// 不是开头一扇区。
const 种子参 = (() => {
  const i = process.argv.indexOf("--seed");
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : null;
})();
let 种子内容 = Buffer.alloc(0);
let 种子说明 = "（没给 --seed，第 " + (1 + 加载器扇区 + 二段扇区数) + " 个扇区往后是空的）";
if (种子参) {
  if (!fs.existsSync(种子参)) 失败("给的种子不在：" + 种子参);
  种子内容 = fs.readFileSync(种子参);
  const 魔数 = 种子内容.subarray(0, 5).toString("latin1");
  if (魔数 !== "HMYRB") 失败("给的种子魔数不是 HMYRB，是 " + JSON.stringify(魔数));
  const 扇区数 = Math.ceil(种子内容.length / 512);
  种子说明 = 种子参 + "（" + 种子内容.length + " 字节，" + 扇区数 + " 个扇区，魔数 HMYRB）";
}
console.log("种子      " + 种子说明);

// ---- 三、拼成一块盘 ----
// 布局（BIOS 从 1 数扇区，数组从 0 数偏移）：
//   第 1 个扇区（偏移 0）                       引导扇区
//   第 2 到 1+加载器扇区 个扇区（偏移 512）      加载器
//   第 2+加载器扇区 个扇区起                     主体（第二段）
//   主体之后                                    种子的第一个字节
//
// 引导扇区里写的是 `mov al, 加载器扇区`（带 loader-sectors 标记），加载器里写的是
// 「主体从第 9 号扇区起」，stage2 里写的是 `seed_lba = 1 + 加载器 + 主体`。
// 这几处加下面推出来的种子偏移，由后面那段检查一次核完。
//
// 盘的大小由 --size 给（单位 MB），默认 64。现在只用了开头几十兆，所以其余是空的；
// 那是有意的 —— 装文件系统、放工具链、塞基本库都要空间，而一块盘的尺寸定得早，
// 后面就不必为了扩大它去搬分区。这块机器 D 盘够用，1 G 到 4 G 都装得下。
const 盘大小MB = (() => {
  const i = process.argv.indexOf("--size");
  const v = i >= 0 && i + 1 < process.argv.length ? Number(process.argv[i + 1]) : 64;
  return Number.isInteger(v) && v >= 1 ? v : 64;
})();
// 种子从 1 + 第二段扇区 起。它与上面那个数是一组，而下面那段检查会把它们一次核完。
const 种子偏移 = (1 + 加载器扇区 + 二段扇区数) * 512;
// 「第二段多大」现在只在 stage2.asm 里写一次（stage2_sectors equ）。这里做的是核对，
// 不是复述 —— 三方各说一遍自己的数，对不上就建不起来：
//   一、真的占了多少：ceil(二段.length / 512)，由 nasm 的输出量出来；
//   二、汇编自己声明多少：stage2_sectors equ N；
//   三、这份脚本预留多少：第二段扇区（它的两倍就是编一段的上限）。
// 另外还查两件容易分家的事：boot.asm 那句 mov al、以及 dap_lba 有没有被写成字面数。
//
// 为一个数字返工过六次，每次的症状都不同（编不过、盘建不起来、种子魔数不对、ata differ），
// 所以这里一次核完 —— 上游的算术错误不该等到第六次 build 才被人看见。
{
  const 扇区数 = Math.ceil(二段.length / 512);
  const 引导源 = fs.readFileSync(path.join("boot", "boot.asm"), "utf8");
  const 读扇区 = /mov al,\s*(\d+)\s*;\s*loader-sectors/.exec(引导源);
  const 装源 = fs.readFileSync(path.join("boot", "loader.asm"), "utf8");
  // 加载器的第一批读用 LBA 模式，所以核的是 dap_lba 那个数（从 0 数）。
  const 装与 = /mov dword \[dap_lba\],\s*(\d+)/.exec(装源);
  const 段源 = fs.readFileSync(path.join("boot", "stage2.asm"), "utf8");
  const 段声明 = /^stage2_sectors\s+equ\s+(\d+)/m.exec(段源);
  const 装声明 = /^loader_sectors\s+equ\s+(\d+)/m.exec(段源);
  const 问题 = [];
  if (!读扇区) 问题.push("boot.asm 里找不到带 loader-sectors 标记的 mov al");
  else if (Number(读扇区[1]) !== 加载器扇区)
    问题.push("boot.asm 读 " + 读扇区[1] + " 个扇区，而加载器占 " + 加载器扇区
      + " 个 —— 把它改成 " + 加载器扇区);
  if (!装与) 问题.push("loader.asm 里找不到 mov dword [dap_lba], N —— 主体从哪读的");
  else if (Number(装与[1]) !== 1 + 加载器扇区)
    问题.push("加载器从第 " + 装与[1] + " 号扇区读主体，而它应当在第 "
      + (1 + 加载器扇区) + "（从 0 数：引导 1 + 加载器 " + 加载器扇区 + "）");
  if (!装声明) 问题.push("stage2.asm 里找不到 loader_sectors equ");
  else if (Number(装声明[1]) !== 加载器扇区)
    问题.push("stage2.asm 的 loader_sectors 是 " + 装声明[1] + "，而这份脚本用的是 "
      + 加载器扇区 + " —— 两边得是同一个数");
  if (!段声明) 问题.push("stage2.asm 里找不到 stage2_sectors equ");
  else {
    const 声明 = Number(段声明[1]);
    if (声明 !== 扇区数)
      问题.push("stage2_sectors 写的是 " + 声明 + "，而第二段真的占了 " + 扇区数 + " 个 —— 把它改成 " + 扇区数);
    // 「预留多少」与「真的占多少」现在是两个数，不再核。理由：主体后面紧跟的是种子，
    // 所以 stage2_sectors 必须等于真实占用（向上圆整）；而这里那个 128 是它能长到多大
    // 的上限。三段的时代它们碰巧相等，而那是巧合，不是规矩。
  }
  // 三批种子读都要用 seed_lba 这个符号。写成字面数就会与那几个声明分家 ——
  // 这一回 ata differ 就是这么来的：种子挪了一个扇区，而那一处还写着旧数。
  // 只数这一种形状：dap_lba 还有别的用处（读超级块是 1024、别处是 0），那些不该管。
  const 种子批读 = (段源.match(/mov dword \[dap_lba\],\s*seed_lba\s*(\+\s*\d+)?\s*$/gm) || []).length;
  if (种子批读 !== 3)
    问题.push("stage2.asm 里应当有三处 mov dword [dap_lba], seed_lba，实际 " + 种子批读 + " 处");
  if (种子偏移 !== (1 + 加载器扇区 + 扇区数) * 512)
    问题.push("种子偏移应当是 " + ((1 + 加载器扇区 + 扇区数) * 512) + "，而这里写的是 " + 种子偏移);
  if (问题.length) 失败("三段的那几个数对不上：\n  " + 问题.join("\n  "));
  console.log("三段      引导 1 + 加载器 " + 加载器扇区 + " + 主体 " + 扇区数
    + " ⇒ 种子从第 " + (1 + 加载器扇区 + 扇区数) + " 个扇区起 —— 几处声明一致");
}
const 盘字节数 = 盘大小MB * 1024 * 1024;
if (种子偏移 + 种子内容.length > 盘字节数) 失败("种子比盘还大，装不下");

// 把种子的真实字节数写进第二段里那一格。第二段自己只知道读了多少扇区，而扇区是向上
// 取整的 —— 74594 与 74752 差的那 158 字节正是末尾的补零。这个数只有这一侧见过，
// 所以由这一侧写进去；写的位置从 nasm 的清单里按符号名找，不靠人记偏移。
// 这一步必须在写盘之前 —— 它改的是内存里的那份第二段，改完才跟着一起落盘。
if (种子内容.length) {
  const 格 = 找符号(清单, "seed_bytes");
  if (格 === null) 失败("清单里没有 seed_bytes 这个符号 —— 第二段里那一格改名了吗");
  // nasm 的 -f bin 清单给的是**段内偏移**，不是绝对地址。实测的证据：这个文件里
  // org 是 0x7e00，而清单第一行 cli 的地址是 00000000。
  //
  // 这里原先有一句「万一哪天它改成给绝对地址」的兼容处理：值 ≥ 0x7e00 就减 0x7e00。
  // 它一直是错的，只是很久没有踩到 —— 直到第二段长过 32256 字节（0x7e00）的那一天，
  // seed_bytes 的偏移变成 32504，于是被减成 232：种子字节数被写进了**代码区**第 232 个
  // 字节，把程序自己写坏了。症状是 seed ok 0，然后连保护模式那一行都不出来 ——
  // 而「种子没读到」与「种子读到了但代码被写坏」在串口上长得一样，所以这一处
  // 白查了好几轮。
  //
  // 教训：兼容处理本身要有证据。这一句的证据现在有了（清单第一行是 0），所以去掉。
  const 段内 = 格;
  if (段内 < 0 || 段内 + 4 > 第二段上限) 失败("seed_bytes 落在第二段外面：偏移 " + 段内);
  二段.writeUInt32LE(种子内容.length, 段内);
  console.log("字节数    " + 种子内容.length + " 写进第二段偏移 " + 段内);
  // seed_bytes 是 times 之前的最后一项，所以它之后就是「这一段实际用到哪」。
  // 不报这个数的话，第二段上限那个数字总像是用满了，而下一块砖就会在没人预料的时候撞上去。
  console.log("实到      " + (段内 + 4) + " 字节，余 " + (第二段上限 - 段内 - 4));
}

// ---- 三·五、文件系统 ----
// 设计在 design/FS.txt，这里做两件事：把布局摆出来，再放一份两层的样本。
// 位置照文档里写的固定在第 1024 号扇区 —— 前面一千个扇区留给引导链，它不参与分配。
//
// 两层的意思是：根目录里有 hello.txt 与一个叫 docs 的目录，docs 里再有 note.txt。
// 多级路径这条路，判据必须真的走过一次「先拿到目录的扇区、再在它里面找下一个名字」，
// 否则一层与两层在代码上看起来是一样的。
const 文件系统起 = 1024;
const 根目录号 = 文件系统起 + 1;
const 子目录号 = 文件系统起 + 2;
const 数据起 = 文件系统起 + 3;
// 三层那一层：docs 里再嵌一个 sub，sub 里放 deep.txt。
// 两个扇区按顺序排在数据区之后 —— 数据区现在是 1027 到 1032 六个文件，所以 sub 在 1033、
// deep.txt 在 1034。stage2 的预读要盖到 1034，所以那一边的扇区数也跟着加了。
const 子目录2号 = 文件系统起 + 9;
const 深层文件起 = 文件系统起 + 10;
// 签名匹配的两个样本排在深层文件之后：1035 与 1036。
// 它们一进盘，stage2 的预读就要跟着多两个扇区 —— 那个数与这里是一组。
// EICAR：一段公开的、专为测杀毒软件而造的字符串，不是恶意代码。
// 它先定义，因为样本与规则两边都要用它 —— 而这两个东西必须来自同一个串，
// 否则「规则命中样本」就只是巧合。
const EICAR串 = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*";
const 毒样本起 = 文件系统起 + 11;
const 干净样本起 = 文件系统起 + 12;
// 规则也是盘上的数据，不是写死在代码里的常量。
//
// 这一行是 ClamAV 的 .ndb 形状的简化版：名字、冒号、十六进制串。真的 .ndb 还有「目标类型」
// 与「偏移」两栏（偏移可以写 * 表示任意位置），而那两样这一版还没解析 —— 但形状先按它来，
// 因为「规则是数据」这句话的证明方式就是：换掉这个文件、不改一行代码，行为跟着变。
const 规则起 = 文件系统起 + 13;
// 三行 —— 一条真的、两条假的。假的不是凑数：一个「见到什么都报」的实现会连着报出
// never 与 also，而只有第一行那一条能对上。名字也因此有用：报「命中」不够，
// 还要报「是哪一条命中」。
const 规则文件 = Buffer.from([
  "eicar:" + Buffer.from(EICAR串, "latin1").toString("hex").toUpperCase(),
  "never:00112233445566778899AABBCCDDEEFF",
  "also:DEADBEEFCAFEBABE",
].join("\n") + "\n", "latin1");
// 要画的那条曲线。UTF-16，因为它要被 calc_expr 读，而那个求值器读的是码元。
//
// 为什么是 x*x/1000：x 从 0 到 319 时它从 0 长到约 101.8，整条落在上半屏 ——
// 值域进得了 -100 到 100 这个范围，所以一个点都不会被裁掉。换成 x*x 就会飞出去，
// 而那时「曲线没画出来」与「坐标变换错了」在截图上长得一样。
const 绘图文件 = Buffer.from("x*x/1000", "utf16le");
const 绘图起 = 文件系统起 + 14;
const 假样本起 = 文件系统起 + 15;
const 示例文件 = Buffer.from("Yunooka filesystem ok\n", "utf8");
const 子文件 = Buffer.from("Yunooka subdirectory ok\n", "utf8");
const 深层文件 = Buffer.from("Yunooka three levels ok\n", "utf8");
// 签名匹配的两个样本。EICAR 是一段公开的、专为测杀毒软件而造的字符串 —— 它不是恶意代码，
// 而是一段打印得出来、命不命中当场看得见的测试串。用它当第一批素材，理由不是它简单，
// 是它合法且可核对：不需要从任何一个病毒库里搬真东西进这台机器。
const 含毒样本 = Buffer.from("Yunooka scan me\n" + EICAR串 + "\n", "latin1");
const 干净样本 = Buffer.from("Yunooka clean file, nothing to find here\n", "latin1");
// 盘上的第一条命令。shell 的「解释」那一半从它读起 —— 交互那一半要串口能收字节，
// 而那条路还没通，所以命令先写在盘上，等能读行了再换成真的键盘。
const 命令文件 = Buffer.from("files\n", "utf8");
// repl 的第一行输入：一个函数名，UTF-16 码元，没有换行 —— 这样读的人不必再切。
// 名字要与种子里真有的一致：块长 在种子中出现两次，读程序 折进 Map 时留最后那个
// （返回 512），而按名字找也留最后一个，所以两边对得上。
const 求值输入 = Buffer.from("块长", "utf16le");
// 数学控制台的四行输入，UTF-16 码元。设计在 design/MATH.txt。
//
// 四行放在一个文件里不是图省事：三节说的是「一行的两种形状」—— 冒号前是已知运算名
// 就是具名运算，否则按表达式读。所以分派发生在行上，而四行正好压住四种写法：
// 第一行是具名运算（average），后三行是同一个左边的三种写法（y、f(x)、f x）。
// 括号与空格都是给人看的，对读的人没有影响 —— 三行认出来应当一模一样。
//
// average 那一串选它是因为五件事压在一条读数里：十进制小数（30.4）、π 与 e 两个常量
// （6π、24e）、逗号分隔、以及平均本身。少一样，六位小数就对不上。
// 九个数、六个整数、一个小数、两个常量，和是 262.48831980370736。
const 数学输入 = Buffer.from(
  "average: 1,4,19,40,55,29,30.4,6π,24e\ny=1/x\nf(x)=1/x\nf x=1/x", "utf16le");
// 盘上的第一个「程序」：与种子同一种格式的一个包，里面只有一个函数 main，它返回 7。
//
// 为什么是这种形状：userland 那一件要回答的是「一个程序从盘上的哪一份字节开始跑」。
// 最小能成立的答案，就是一个包住在盘上、格式与种子相同、由同一段查找代码找入口 ——
// 于是「程序」与「种子」分开了：种子是启动时就在的那个包，这个是从盘上取的另一个。
//
// 七个字节的头之后是函数表：名字（u16 长度 + 码元）、参数量、槽数、效果数、指令数、
// 指令流。两个函数：main 返 7、echo 把一段字交给宿主去打。
//
// main 返 7 而不是别处能查到的数，是因为那一行要证明「值来自这个包」，而 7 在别处
// 没有出现过。
//
// echo 是 LAYERS 第六节第二条判据的第一步：一个包把一段字交给宿主去打，而它不必知道
// 串口在哪个端口。它走内置 write —— 三条指令，压串、调内置、返回。
//
// 为什么两个函数放一个包而不是两个包：根目录那一个扇区已经满了（一条 29 字节的条目
// 放不下，症状是构建抛 RangeError）。而多函数本来就是包格式支持的东西，所以这不是
// 妥协，是把已有的形状用起来。
const 回声串 = "myon here";
const 程序包 = Buffer.alloc(192);
程序包.write("HMYRB", 0, "latin1");
程序包.writeUInt16LE(1, 5);       // 版本
程序包.writeUInt16LE(2, 7);       // 两个函数
let 位 = 9;
程序包.writeUInt16LE(4, 位); 位 += 2;                      // 名字长度
for (const 字 of "main") { 程序包.writeUInt16LE(字.charCodeAt(0), 位); 位 += 2; }
程序包.writeUInt16LE(0, 位); 位 += 2;                      // 参数量
程序包.writeUInt16LE(0, 位); 位 += 2;                      // 槽数
程序包.writeUInt16LE(0, 位); 位 += 2;                      // 效果数
程序包.writeUInt32LE(2, 位); 位 += 4;                      // 指令数
程序包[位++] = 5;                                           // 常量
程序包[位++] = 1;                                           // 种类：数
程序包.writeDoubleLE(7.0, 位); 位 += 8;
程序包[位++] = 28;                                          // 返回

程序包.writeUInt16LE(4, 位); 位 += 2;                      // 第二个函数：echo
for (const 字 of "echo") { 程序包.writeUInt16LE(字.charCodeAt(0), 位); 位 += 2; }
程序包.writeUInt16LE(0, 位); 位 += 2;                      // 参数量
程序包.writeUInt16LE(0, 位); 位 += 2;                      // 槽数
程序包.writeUInt16LE(0, 位); 位 += 2;                      // 效果数
程序包.writeUInt32LE(6, 位); 位 += 4;                      // 六条指令
程序包[位++] = 5;                                           // 常量
程序包[位++] = 2;                                           // 种类：串
程序包.writeUInt16LE(回声串.length, 位); 位 += 2;
for (const 字 of 回声串) { 程序包.writeUInt16LE(字.charCodeAt(0), 位); 位 += 2; }
程序包[位++] = 3;                                           // 调内置 write
程序包.writeUInt16LE(5, 位); 位 += 2;
for (const 字 of "write") { 程序包.writeUInt16LE(字.charCodeAt(0), 位); 位 += 2; }
程序包.writeUInt16LE(1, 位); 位 += 2;                      // 一参
程序包[位++] = 3;                                           // 调内置 readline（无参）
程序包.writeUInt16LE(8, 位); 位 += 2;
for (const 字 of "readline") { 程序包.writeUInt16LE(字.charCodeAt(0), 位); 位 += 2; }
程序包.writeUInt16LE(0, 位); 位 += 2;                      // 零参
程序包[位++] = 3;                                           // 再把那一行写出去
程序包.writeUInt16LE(5, 位); 位 += 2;
for (const 字 of "write") { 程序包.writeUInt16LE(字.charCodeAt(0), 位); 位 += 2; }
程序包.writeUInt16LE(1, 位); 位 += 2;
程序包[位++] = 3;                                           // 让宿主画一个窗口的框
程序包.writeUInt16LE(6, 位); 位 += 2;
for (const 字 of "border") { 程序包.writeUInt16LE(字.charCodeAt(0), 位); 位 += 2; }
程序包.writeUInt16LE(0, 位); 位 += 2;                      // 零参
程序包[位++] = 28;                                          // 返回
const 程序字节 = 程序包.subarray(0, 位);

// ---- 三·二·二、Myon 的回声函数 ----
//
// 上面那个块里已经把它写进去了（"echo"，三条指令）。它原来是一个独立的包，后来并进
// prog.hmtn —— 根目录那一个扇区放不下第四条 29 字节的条目，而多函数本来就是包格式
// 支持的东西。并进去之后它不占新扇区、不占新条目，也就没有新的布局要照顾。

// 一个改名成 hello.txt 的包。它的存在只为了一条判据：认一个文件是什么，要看内容，
// 不看名字。没有它，「按魔数分析」与「按扩展名猜」在判据上分不开 —— 而分不开的那一对，
// 恰恰是 Kohane 第六层唯一值得做的东西。
const 假样本 = 程序字节;

// ---- 三·三、核心清单与校验和 ----
//
// 系统文件保护的第二层，设计在 design/GUARD.txt 第二节。第一层是目录条目的只读位 ——
// 它在盘上、跟着文件走；这一层在系统里：换一块盘插过来，清单还在。
//
// 校验和用 FNV-1a：一条异或、一条乘法，两条指令的量，不需要表。它不防碰撞，而这一层
// 要防的不是碰撞，是「文件被改过而没人知道」。
//
// 清单是二进制而不是文本：stage2 要逐项读它，而解析十六进制 ASCII 是白多做一步。
const fnv1a = (buf) => {
  let h = 0x811c9dc5;
  for (const b of buf) {
    h ^= b;
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
};
// --break 改的是**盘上那份字节**，而清单仍按原内容算 —— 于是启动时校验会红。
// 这是这一层唯一的验红手段，而它必须改盘、不能改内存里的变量：
// 判据要能看出「内容与清单不符」，而不是「清单跟着内容一起变了」。
const 破 = process.argv.includes("--break");
// --forge：盘上那份改了，而 core.bin 里那一条的 FNV-1a **也跟着重算对**。
//
// 这是「有人故意改了并把校验和也重算了」那个场景 —— GUARD.txt 说过，只有校验和的时候
// 那场景是零防护。它也是 sign.bin 存在的唯一理由：--break 验的是第一环（文件与清单是否
// 一致），--forge 让第一环是绿的，于是只有第二环（清单自己有没有被动过）能看出来。
// 两个开关各自对应一个层次，没有一个是多余的。
const 伪造 = process.argv.includes("--forge");
const 盘上示例 = Buffer.from(示例文件);
if (破 || 伪造) 盘上示例[0] ^= 0xFF;
const 核心项 = [
  ["hello.txt", 示例文件],
  ["prog.hmtn", 程序字节],
  ["cmd.txt", 命令文件],
  // 这一项是**唯一长过 64 字节的一项**，加它的理由只有一条：在此之前，清单里三个文件
  // 都短于 64 字节，于是第二环的 SHA-256 只走过「一块」的路径，多块从来没被验过。
  // 一份只在小输入上对得上的哈希，在小输入上看着是绿的 —— 那正是这一层最怕的绿。
  ["math.txt", 数学输入],
];
// 核心项的长度分布要打出来，而且**必须有一项长过一块**。
//
// 这条检查是为了记住一件事：第二环的判据只对清单里的文件算摘要，而 SHA-256 的块是
// 64 字节。清单里三个文件（22、40、6 字节）曾经全都短于一块 —— 于是那一条判据从落地
// 起就只走过「一次压缩」的路径，而它的绿没有覆盖多块。一条只在小输入上成立的分支，
// 在短输入上看着是通的，那正是这一层最怕的那种通。
//
// 所以这里不是一个提示，是一条建不起来的理由：判据的覆盖范围与判据本身一样重要，
// 而覆盖这件事只能靠清单里真的有一份长文件来保证。
{
  const 长度 = 核心项.map(([名, 内容]) => [名, 内容.length]);
  const 最长 = Math.max(...长度.map(([, n]) => n));
  console.log("核心项   " + 长度.map(([n, l]) => n + " " + l).join("、")
    + "（最长 " + 最长 + " 字节）");
  if (最长 < 64)
    失败("核心项里没有一项长过 64 字节，而 SHA-256 的块就是 64 字节 —— 多块路径于是"
      + "没有被覆盖，那一条判据只会在短输入上通过。往核心项里加一个长于 64 字节的文件。");
}
// 清单按什么算：--forge 时按**盘上那份**算，于是 FNV-1a 那一层是绿的。
const 清单项 = 伪造
  ? 核心项.map(([名, 内容]) => [名, 名 === "hello.txt" ? 盘上示例 : 内容])
  : 核心项;
// SHA-256 清单永远按**原始内容**算。它记的是「该有什么」，不跟着盘上的变化走 ——
// 一旦它也跟着写坏的那一份算，第二环就退化成了第一环的复制品。
const 核心清单 = Buffer.alloc(512);
核心清单.writeUInt32LE(清单项.length, 0);
let 清位 = 4;
for (const [名, 内容] of 清单项) {
  核心清单.writeUInt8(名.length, 清位); 清位 += 1;
  核心清单.write(名, 清位, "latin1"); 清位 += 名.length;
  核心清单.writeUInt32LE(fnv1a(内容), 清位); 清位 += 4;
}
const 核心清单起 = 假样本起 + 1;

// ---- 三·三·二、SHA-256 清单：OnlySign 的第二环 ----
//
// 设计在 design/SIGN.txt。它与 core.bin 同形，换掉哈希长度、加一个算法字节 ——
// 那个字节是为「将来换算法不必改魔数」留的，而现在只有 1 这一个取值。
//
// 它回答的问题与 core.bin 不同：core.bin 说「文件与清单是否一致」，这一份说
// 「清单自己有没有被动过」。所以它按原始内容算，即使 --forge 让 core.bin 跟着变。
const 签名清单 = Buffer.alloc(512);
签名清单.write("YUNOSIG\0", 0, "latin1");
签名清单.writeUInt16LE(1, 8);        // 版本
签名清单.writeUInt8(1, 10);          // 算法：1 = SHA-256
签名清单.writeUInt8(0, 11);          // 留白
签名清单.writeUInt32LE(核心项.length, 12);
let 签位 = 16;
for (const [名, 内容] of 核心项) {
  const 摘 = crypto.createHash("sha256").update(内容).digest();
  签名清单.writeUInt8(名.length, 签位); 签位 += 1;
  签名清单.write(名, 签位, "latin1"); 签位 += 名.length;
  摘.copy(签名清单, 签位); 签位 += 32;
}
const 签名起 = 核心清单起 + 1;

// ---- 三·三·三、第三环：对 SHA-256 清单本身签一次 ----
//
// 前两环都在「盘上有一份清单」这个层面：core.bin 说文件与清单是否一致，sign.bin 说
// 清单自己有没有被动过。而 sign.bin 本身也会被一起重算 —— 下决心的人可以把两份一起
// 改对。第三环挡的是这一手：对 sign.bin 的内容签一次名，公钥内嵌在第二段里。
//
// 用的是 RFC 8032 第 7.1 节第一条向量给的种子。它是公开的，所以这里的签名只能证明
// 「这条链接得通」，不能证明「谁签的」—— 生产上要换成一对没人贴过网的密钥，而那只是
// 换两个常量，不是改设计。
//
// 签名覆盖的是 签位 个字节，不是整个 512 字节的缓冲区：盘上那条目的长度就是 签位，
// 而固件读到的也正是那么多。多签四十九个零是小事，但它会让「文件内容」与「被签的
// 内容」从此有两个定义，而这两个定义总有一天会分家。
const 第三环种子 = Buffer.from(
  "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "hex");
const 第三环期望公钥 = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
const 第三环签 = edSign(new Uint8Array(第三环种子), 签名清单.subarray(0, 签位));
if (edHex(第三环签.publicKey) !== 第三环期望公钥) {
  失败("第三环的公钥与第二段里那个常量对不上：" + edHex(第三环签.publicKey)
    + " —— 换种子就要同时换 stage2.asm 里那三十二个字节");
}
const 第三环签名 = Buffer.from(第三环签.signature);

// --authbreak：把签名的第一个字节翻一位。
//
// 它是第三环唯一的验红手段，而这一环需要两条判据：正常那一趟必须绿（否则这一环只是
// 把一切判死），破签那一趟必须红（否则一个「永远通过」的实现也是绿的，而它与真正的
// 验签在正常那一趟上完全一样）。
if (process.argv.includes("--authbreak")) 第三环签名[0] ^= 0x01;

// ---- 三·四、别的系统的五个样本 ----
//
// 每一个只有几十个字节，而判据只看头 —— 所以造的是「头对、身体短」的假件，
// 不是真的可执行文件。这一点要写清，因为一个 128 字节的「PE」什么也跑不了，
// 而它在这台机器上的作用只是「让 identify 有机会答对」。
//
// PE 那一个是唯一需要两处的：MZ 两个字节太容易撞上（一个以 MZ 开头的文本文件就是），
// 所以真 PE 的定义是「MZ，而 offset 0x3C 那个 u32 指着 PE\0\0」。样本照那个定义造，
// 判据才是对的定义而不是它的缩写。
const 造PE = () => {
  const b = Buffer.alloc(128);
  b.write("MZ", 0, "latin1");
  b.writeUInt32LE(0x40, 0x3C);       // e_lfanew：PE 头在 0x40
  b.write("PE\0\0", 0x40, "latin1");
  return b;
};
const 造ELF = () => {
  const b = Buffer.alloc(64);
  b.write("\x7fELF", 0, "latin1");
  b[4] = 2;                          // 64 位
  b[5] = 1;                          // 小端
  b[6] = 1;                          // 版本
  return b;
};
const 造MachO = () => {
  const b = Buffer.alloc(64);
  b.writeUInt32LE(0xFEEDFACF, 0);    // 64 位小端那一族
  return b;
};
const 造ZIP = () => {
  const b = Buffer.alloc(64);
  b.write("PK\x03\x04", 0, "latin1");
  return b;
};
const 造DEX = () => {
  const b = Buffer.alloc(64);
  b.write("dex\n035\0", 0, "latin1");
  return b;
};
// 另外七种。每一个只造头 —— 判据看的是头，而一个 64 字节的「PNG」本来也打不开。
//
// 为什么要七个而不是十几个：判据那一行每加一格，盘上就多一个文件、预读多一个扇区、
// 索引多一条，而这三样都由 build 核对。七个让那一行从八格变成十五格，仍然读得下来。
const 造GZIP = () => { const b = Buffer.alloc(64); b[0] = 0x1F; b[1] = 0x8B; b[2] = 0x08; return b; };
const 造7Z = () => { const b = Buffer.alloc(64); b.write("7z\xBC\xAF\x27\x1C", 0, "latin1"); return b; };
const 造RAR = () => { const b = Buffer.alloc(64); b.write("Rar!\x1A\x07", 0, "latin1"); return b; };
const 造PDF = () => { const b = Buffer.alloc(64); b.write("%PDF-1.7\n", 0, "latin1"); return b; };
const 造PNG = () => { const b = Buffer.alloc(64); b.write("\x89PNG\r\n\x1A\n", 0, "latin1"); return b; };
const 造JPEG = () => { const b = Buffer.alloc(64); b[0] = 0xFF; b[1] = 0xD8; b[2] = 0xFF; b[3] = 0xE0; return b; };
const 造SQLite = () => { const b = Buffer.alloc(64); b.write("SQLite format 3\0", 0, "latin1"); return b; };
const 外五起 = 签名起 + 1;
const 外五件 = [
  ["pe.bin", 造PE()],
  ["elf.bin", 造ELF()],
  ["macho.bin", 造MachO()],
  ["zip.bin", 造ZIP()],
  ["dex.bin", 造DEX()],
];
// 最后一个占用的扇区号 —— 预读那条检查要拿它当上界，而那一条不该自己再算一遍。
// auth.bin 排在五个样本之后，所以它不必把前面任何一份文件往后挪 —— 插入在中间的代价
// 是那一段布局的每一个偏移都要重新对一遍，而它们各自都有一条判据指着。
const auth起 = 外五起 + 外五件.length;
const 最后一份扇区 = auth起;

const 示例扇区数 = Math.ceil(示例文件.length / 512) + Math.ceil(子文件.length / 512)
  + Math.ceil(命令文件.length / 512) + Math.ceil(求值输入.length / 512)
  + Math.ceil(数学输入.length / 512) + Math.ceil(程序字节.length / 512)
  + 1 + Math.ceil(深层文件.length / 512)   // sub 目录自己占一个扇区，再加 deep.txt
  + Math.ceil(含毒样本.length / 512) + Math.ceil(干净样本.length / 512)
  + Math.ceil(规则文件.length / 512)
  + Math.ceil(绘图文件.length / 512)
  + Math.ceil(假样本.length / 512)
  + 1                                     // 核心清单自己占一个扇区
  + 1                                     // SHA-256 清单（sign.bin）也占一个
  + 1                                     // 第三环的签名（auth.bin）
  + 外五件.length;                        // 五个头部样本，每个一个扇区

const 码元 = (s) => {
  const 列 = [];
  for (let i = 0; i < s.length; i++) 列.push(s.charCodeAt(i));
  return 列;
};

// 一个目录条目：u16 名字长度、若干码元、u8 类型、u32 起始扇区、u32 字节长度。
// 变长、顺序摆、遇到名字长度为 0 就结束。
const 写条目 = (buf, at, 名字, 类型, 起始, 长度) => {
  const 列 = 码元(名字);
  buf.writeUInt16LE(列.length, at); at += 2;
  for (const c of 列) { buf.writeUInt16LE(c, at); at += 2; }
  buf.writeUInt8(类型, at); at += 1;
  buf.writeUInt32LE(起始, at); at += 4;
  buf.writeUInt32LE(长度, at); at += 4;
  return at;
};

// --drop <名字>：那个名字不进根目录，于是盘上「缺一份」。
//
// 这是补完界面唯一的验红手段，而它必须是「盘上真的少了一条」，不是「标记一下」——
// 补完界面要回答的问题是「该有的东西现在不在」，而那正是这一条造的处境。
// 数据照原样写下去：留一块没人指着的字节，比留一个洞清楚。
const 落名 = (() => {
  const i = process.argv.indexOf("--drop");
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : null;
})();
const 条目 = (buf, at, 名字, 类型, 起始, 长度) => {
  if (落名 === 名字) {
    console.log("缺一份    " + 名字 + "（--drop，补完界面应当点出它）");
    return at;
  }
  return 写条目(buf, at, 名字, 类型, 起始, 长度);
};

// ---- 三·三·一、补丁包：被落下的那一份，装成客人机能读的形状 ----
//
// 补完界面要能真的修，就必须有「该修成什么样」的那一份字节。这一份不能由客人机自己造
// （它正是缺的那一侧），也不该由 run.mjs 另抄一遍（两份内容会分家，而分家的那一天
// 「补丁对不上清单」与「补丁抄错了」会看起来一模一样）。所以它从 build 这一侧出，
// 来源就是上面那份 核心项 —— 与清单里算哈希用的是同一份字节。
//
// 格式 YUNOPAT：魔数八字节、u32 项数；然后每项 u16 名字长、名字 UTF-16 码元、
// u32 字节数、内容。魔数与 stage2.asm 的 pat_magic 同源，改一处就要改两处。
//
// 没有 --drop 时不留这个文件。上一趟留下的那份会让「没有补丁」那一条判据假绿 ——
// 而那一趟验的恰恰是「没有补丁时进补完界面」。
const 补丁路径 = path.join(建, "patch-drop.bin");
if (落名) {
  const 补丁项 = 核心项.filter(([名]) => 名 === 落名);
  if (补丁项.length === 0)
    失败("--drop " + 落名 + " 不在核心清单里（清单是 " + 核心项.map(([n]) => n).join(" ") + "）");
  const 头 = Buffer.alloc(12);
  头.write("YUNOPAT\0", 0, "latin1");
  头.writeUInt32LE(补丁项.length, 8);
  const 块 = [头];
  for (const [名, 内容] of 补丁项) {
    const 列 = Buffer.alloc(2 + 名.length * 2 + 4);
    列.writeUInt16LE(名.length, 0);
    for (let i = 0; i < 名.length; i++) 列.writeUInt16LE(名.charCodeAt(i), 2 + i * 2);
    列.writeUInt32LE(内容.length, 2 + 名.length * 2);
    块.push(列, Buffer.from(内容));
  }
  const 补丁 = Buffer.concat(块);
  if (补丁.length > 1536)
    失败("补丁包 " + 补丁.length + " 字节，超过信箱给补丁的那三个扇区（1536）");
  fs.writeFileSync(补丁路径, 补丁);
  console.log("补丁包    " + 补丁路径 + "（" + 补丁.length + " 字节，" + 补丁项.length
    + " 项；run.mjs 会把它写进信箱第 1 个扇区，补完界面拿它来修）");
} else if (fs.existsSync(补丁路径)) {
  fs.unlinkSync(补丁路径);
  console.log("补丁包    没有 --drop，上一趟那份删掉了（留着会让「没有补丁」那一条假绿）");
}

const 超级块 = Buffer.alloc(512);
超级块.write("YUNOFS", 0, "latin1");
超级块.writeUInt16LE(1, 6);                        // 版本
超级块.writeUInt32LE(盘字节数 / 512, 8);             // 盘上扇区总数
超级块.writeUInt32LE(根目录号, 12);
超级块.writeUInt32LE(1, 16);                       // 根目录占一个扇区
超级块.writeUInt32LE(数据起, 20);
超级块.writeUInt32LE(盘字节数 / 512 - 数据起 - 示例扇区数, 24);
// 偏移 28：家庭组的「家」。同一个数的两块盘是一家，不同就不是。
// 主盘用 YKNR 的 ASCII，β 盘在 run.mjs 里故意写另一个数 —— 判据要能看出比较发生过，
// 而两块盘的家一样时，「比较过」与「没比较」看起来一样。
超级块.writeUInt32LE(0x594B4E52, 28);

const 根目录 = Buffer.alloc(512);
let 根位 = 条目(根目录, 0, "hello.txt", 0, 数据起, 示例文件.length);
根位 = 条目(根目录, 根位, "docs", 1, 子目录号, 0);       // 目录的字节长度没有意义，写 0
根位 = 条目(根目录, 根位, "cmd.txt", 0, 数据起 + 2, 命令文件.length);
根位 = 条目(根目录, 根位, "repl.txt", 0, 数据起 + 3, 求值输入.length);
根位 = 条目(根目录, 根位, "math.txt", 0, 数据起 + 4, 数学输入.length);
// 每一行都要把根位接过去。漏一次，下一个条目就会写在同一个位置、把那一条覆盖掉 ——
// 而症状是「某个文件凭空消失」，不是「布局错了」。这一处漏过一次：prog.hmtn 被 eicar.txt 吃掉。
根位 = 条目(根目录, 根位, "prog.hmtn", 0, 数据起 + 5, 程序字节.length);
根位 = 条目(根目录, 根位, "eicar.txt", 0, 毒样本起, 含毒样本.length);
根位 = 条目(根目录, 根位, "clean.txt", 0, 干净样本起, 干净样本.length);
根位 = 条目(根目录, 根位, "rules.txt", 0, 规则起, 规则文件.length);
根位 = 条目(根目录, 根位, "plot.txt", 0, 绘图起, 绘图文件.length);
根位 = 条目(根目录, 根位, "fake.txt", 0, 假样本起, 假样本.length);
根位 = 条目(根目录, 根位, "core.bin", 0, 核心清单起, 清位);
根位 = 条目(根目录, 根位, "sign.bin", 0, 签名起, 签位);
根位 = 条目(根目录, 根位, "auth.bin", 0, auth起, 第三环签名.length);
for (let i = 0; i < 外五件.length; i++) {
  根位 = 条目(根目录, 根位, 外五件[i][0], 0, 外五起 + i, 外五件[i][1].length);
}

const 子目录 = Buffer.alloc(512);
let 子位 = 写条目(子目录, 0, "note.txt", 0, 数据起 + 1, 子文件.length);
子位 = 写条目(子目录, 子位, "sub", 1, 子目录2号, 0);

const 子目录2 = Buffer.alloc(512);
写条目(子目录2, 0, "deep.txt", 0, 深层文件起, 深层文件.length);

console.log("文件系统  超级块第 " + 文件系统起 + " 号扇区，根目录第 " + 根目录号
  + " 号扇区，docs 目录第 " + 子目录号 + " 号扇区；hello.txt（" + 示例文件.length
  + " 字节）、docs/note.txt（" + 子文件.length + " 字节）、cmd.txt（"
  + 命令文件.length   + " 字节）、repl.txt（" + 求值输入.length + " 字节，UTF-16）、math.txt（"
  + 数学输入.length + " 字节，UTF-16）、prog.hmtn（" + 程序字节.length + " 字节，程序包）、"
  + "docs/sub/deep.txt（" + 深层文件.length + " 字节，三层路径）");

// 盘用稀疏文件建，不在内存里放一份整盘副本 —— Node 的 Buffer 上限是 2 GB，而这块盘
// 将来会要 4 GB。ftruncate 造出来的空洞不占磁盘也不占内存，各段各自写在它该在的
// 偏移上就够了。VDI 那一层同样对全零区域稀疏，所以两处都不必为「名义尺寸」付账。
const fd = fs.openSync(盘像, "w");
try {
  fs.ftruncateSync(fd, 盘字节数);
  fs.writeSync(fd, 引导, 0, 引导.length, 0);
  fs.writeSync(fd, 装载器, 0, 装载器.length, 512);
  fs.writeSync(fd, 二段, 0, 二段.length, (1 + 加载器扇区) * 512);
  fs.writeSync(fd, 种子内容, 0, 种子内容.length, 种子偏移);
  fs.writeSync(fd, 超级块, 0, 512, 文件系统起 * 512);
  fs.writeSync(fd, 根目录, 0, 512, 根目录号 * 512);
  fs.writeSync(fd, 子目录, 0, 512, 子目录号 * 512);
  fs.writeSync(fd, 盘上示例, 0, 盘上示例.length, 数据起 * 512);
  fs.writeSync(fd, 子文件, 0, 子文件.length, (数据起 + 1) * 512);
  fs.writeSync(fd, 命令文件, 0, 命令文件.length, (数据起 + 2) * 512);
  fs.writeSync(fd, 求值输入, 0, 求值输入.length, (数据起 + 3) * 512);
  fs.writeSync(fd, 数学输入, 0, 数学输入.length, (数据起 + 4) * 512);
  fs.writeSync(fd, 程序字节, 0, 程序字节.length, (数据起 + 5) * 512);
  fs.writeSync(fd, 子目录2, 0, 512, 子目录2号 * 512);
  fs.writeSync(fd, 深层文件, 0, 深层文件.length, 深层文件起 * 512);
  fs.writeSync(fd, 含毒样本, 0, 含毒样本.length, 毒样本起 * 512);
  fs.writeSync(fd, 干净样本, 0, 干净样本.length, 干净样本起 * 512);
  fs.writeSync(fd, 规则文件, 0, 规则文件.length, 规则起 * 512);
  fs.writeSync(fd, 绘图文件, 0, 绘图文件.length, 绘图起 * 512);
  fs.writeSync(fd, 假样本, 0, 假样本.length, 假样本起 * 512);
  fs.writeSync(fd, 核心清单, 0, 512, 核心清单起 * 512);
  fs.writeSync(fd, 签名清单, 0, 512, 签名起 * 512);
  fs.writeSync(fd, 第三环签名, 0, 第三环签名.length, auth起 * 512);
  for (let i = 0; i < 外五件.length; i++) {
    fs.writeSync(fd, 外五件[i][1], 0, 外五件[i][1].length, (外五起 + i) * 512);
  }
} finally {
  fs.closeSync(fd);
}
console.log("盘映像    " + 盘大小MB + " MB（" + 盘字节数 / 512 + " 个扇区）"
  + (破 ? "；核心清单的第 1 个字节被改过（--break），启动时校验应当红" : ""));

// ---- 三·九、预读区要盖住盘上最后一份文件 ----
//
// 这是同一个坑的第三次，而三次的症状都长得像别的东西 —— 因为 fs_load 照样算得出一个
// 地址，只是那个地址上没有这个文件：
//   一、fake.txt 落在第 1039 号而预读只盖到 1038 —— 症状是 identify 把它认成 unknown，
//       看起来像识别逻辑错了。
//   二、扩 ADT 那次，同一类。
//   三、core.bin 落在第 1040 号而预读只盖到 1039 —— 症状是「清单读到了，项数是零」，
//       看起来像清单格式错了。
//
// 靠人记得不算判据。这个数在 stage2.asm 里带 preread-sectors 标记，这里拿它与
// 「盘上最后一份能打开的东西在第几个扇区」比。
//
// 预读从第 1024 号扇区起、盖 N 个，所以末尾是 1024 + N - 1。而盘上最后一份要能打开的
// 东西是核心清单 —— 它自己也在根目录里，所以它必须落在覆盖范围之内。
{
  const 段源2 = fs.readFileSync(path.join("boot", "stage2.asm"), "utf8");
  const 预读 = /mov word \[dap_count\],\s*(\d+)\s*; preread-sectors/.exec(段源2);
  if (!预读) 失败("stage2.asm 里找不到带 preread-sectors 标记的 dap_count");
  const 需要 = 最后一份扇区 - 1024 + 1;
  if (Number(预读[1]) < 需要)
    失败("预读只盖 " + 预读[1] + " 个扇区（1024 到 " + (1024 + Number(预读[1]) - 1)
      + "），而盘上最后一份文件在第 " + 最后一份扇区 + " 号扇区 —— 它读不到，而症状会是"
      + "「读到了、内容是零」那一类。把 stage2.asm 里那个 dap_count 改成 " + 需要 + "。");
  console.log("预读区    1024 起盖 " + 预读[1] + " 个扇区（到第 "
    + (1024 + Number(预读[1]) - 1) + "），最后一份在第 " + 最后一份扇区 + " 号 —— 盖得住");
}

// ---- 三·九、索引表要装得下盘上的名字 ----
//
// 这与上面那条预读检查是同一种东西，只是对象不同：一个管「读进来几个扇区」，
// 一个管「这张表能放几条」。两者都随盘上的文件增长，而两者的症状都长得像别的东西 ——
// 预读不够时是「读到了、内容是零」，索引不够时是「甲盘条目数与索引不一致」，
// 而后者读起来像层三或层二算错了，实际是这张表自己截断的。
//
// 这一处与 index_buf 的大小、cmp r9 那一句同源（都从 index_cap 那一行来），
// 所以只核一次就够。
{
  // 数根目录里的名字：变长、顺序摆、遇到名字长度为 0 就停。
  let 名字数 = 0;
  {
    let 位 = 0;
    while (位 + 2 <= 512) {
      const 名长 = 根目录.readUInt16LE(位);
      if (名长 === 0) break;
      名字数++;
      位 += 11 + 名长 * 2;
    }
  }
  const 段源3 = fs.readFileSync(path.join("boot", "stage2.asm"), "utf8");
  const 容量 = /^index_cap\s+equ\s+(\d+)/m.exec(段源3);
  if (!容量) 失败("stage2.asm 里找不到 index_cap equ");
  if (Number(容量[1]) < 名字数)
    失败("索引表只能装 " + 容量[1] + " 条，而根目录里有 " + 名字数 + " 个名字 —— "
      + "层三会列出全部而索引会少几条，判据报的是「甲盘条目数与索引不一致」。"
      + "把 stage2.asm 的 index_cap 改成 " + 名字数 + "。");
  // 注意这个数只数静态那一份：运行时的 fs_write 与 guard 还会新建几个，而构建这一侧
  // 不知道它们。那一半由判据管 —— run.mjs 里有「层三的条目数与索引相等」这一条，
  // 两处各管一半：静态的增长在构建时挡住，运行时的截断在每次跑的时候挡住。
  console.log("索引表    能装 " + 容量[1] + " 条，静态的名字有 " + 名字数
    + " 个 —— 装得下（运行时还会新建几个，那一半归判据）");
}

// ---- 四、转成 vdi ----
const VBox = 找VBox();
if (!VBox) 失败("没有 VirtualBox（VBoxManage 不在注册表、也不在 PATH），盘建好了但没有 vdi");
// 上一趟的盘要先从虚拟机上卸下来。挂着的盘既不能从登记里关掉，也不能删文件 ——
// VirtualBox 会报「still attached to 1 virtual machine(s)」。而 build 跑在 run 之前，
// 那时上一趟的盘还挂着，所以这一步必须在这里做，不能指望 run 那一侧。
// 虚拟机里没有这块盘时这条什么也不做（返回非零，忽略即可）。
// 控制器名要与 tools/run.mjs 一致：那边建的是 IDE（PIIX4），因为长模式下的 ATA PIO
// 要走 0x1F0 那组 legacy 端口，而 AHCI 不映射它们。这里写错只会让这一步静悄悄失败，
// 然后把「盘还挂着」留到 closemedium 那一步去报 —— 那时读起来像盘坏了。
spawnSync(VBox, ["storageattach", "Yunooka", "--storagectl", "IDE", "--port", "0", "--device", "0", "--medium", "none"], { encoding: "utf8" });
// 然后再按**它自己的 UUID** 从登记里注销。不能按路径：旧条目多半已经 inaccessible
// （文件被删或重建过），用路径匹配不到它，于是它一直挂着，下一次 startvm 报
// 「UUID 与登记里那份不匹配」，而真正的错在这里。
const 清登记 = () => {
  const r = spawnSync(VBox, ["list", "hdds"], { encoding: "utf8" });
  for (const 段 of String(r.stdout || "").split(/\n\s*\n/)) {
    const u = /^UUID:\s+(.+)$/m.exec(段);
    const l = /^Location:\s+(.+)$/m.exec(段);
    if (u && l && l[1].trim().toLowerCase() === 盘.toLowerCase()) {
      spawnSync(VBox, ["closemedium", "disk", u[1].trim(), "--delete"], { encoding: "utf8" });
    }
  }
};
清登记();
for (const 旧 of [盘, 盘 + ".vbox"]) if (fs.existsSync(旧)) fs.unlinkSync(旧);
// 固定的盘 UUID。每趟重建都换一个 UUID 会让虚拟机配置里记着的那个过期，startvm 就会
// 抱怨「UUID 与登记里那份不匹配」—— 那不是盘坏了。给它一个固定的，这件事就不存在了；
// 而且「这块盘永远是这一块」也让判据少一个会漂的东西。
const 盘UUID = "1b4e28ba-2fa1-11d2-883f-0016d3cca427";
const 转 = spawnSync(VBox, ["convertfromraw", 盘像, 盘, "--format", "VDI", "--uuid", 盘UUID], { encoding: "utf8" });
if (转.status !== 0) 失败("convertfromraw 失败：" + String(转.stderr || "").slice(0, 300));
console.log("vdi      " + 盘 + "（" + Math.round(fs.statSync(盘).size / 1024) + " KiB）");
console.log("");
console.log("下一步：node tools/run.mjs");
