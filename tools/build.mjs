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
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const 建 = path.join(ROOT, "build");
fs.mkdirSync(建, { recursive: true });

const 源 = path.join(ROOT, "boot/boot.asm");
const 源二 = path.join(ROOT, "boot/stage2.asm");
const 像 = path.join(建, "boot.img");
const 像二 = path.join(建, "stage2.bin");
const 盘像 = path.join(建, "disk.img");
const 盘 = path.join(建, "disk.vdi");

const 失败 = (为什么) => {
  console.error("建不起来：" + 为什么);
  process.exit(1);
};

// 从 nasm 的清单里按符号名找它的地址。清单的每一行形如：
//   123 00007E1F 0000         seed_bytes: dw 0
// 第二列是地址，含 org 声明的那一段基址（这里是 0x7e00）。
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

// ---- 一、编两段，各查各的形状 ----
// 两段各有各的硬约束：引导扇区必须正好 512 字节（BIOS 只读这一扇区），第二段不能超过
// 它占的那些扇区 —— 三十二个，16 KB。哪一条不成立，后面跑起来的东西就不是我们以为的
// 那个。
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
const 二段 = 编一段("第二段", 源二, 像二, 16384, 清单);
// 第二段自带签名（它也是一段可引导的代码，只是不经过 BIOS），所以这里只查长度上限。
console.log("引导扇区  " + 引导.length + " 字节，签名 55 AA 对");
console.log("第二段    " + 二段.length + " 字节（上限 16384，占三十二个扇区）");

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
let 种子说明 = "（没给 --seed，第 34 个扇区往后是空的）";
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
//   第 1 个扇区（偏移 0）         引导扇区
//   第 2 到 33 个扇区（偏移 512） 第二段，三十二个扇区（16 KB）
//   第 34 个扇区起（偏移 16896）  种子的第一个字节
// stage2.asm 里写的是 dap_lba = 33，也就是第 34 个扇区；引导扇区写的是 al = 32，也就是
// 读三十二个扇区。三处数字对得上才建得对，所以它们写在同一段注释里。
//
// 第二段从 8 KB 长到 16 KB，长出来的是解释器：块长、letters、is_digit 那一套进来之后
// 只剩一千多字节，再塞一块砖就会撞上 times 8192。所以要动的就这几处 —— 上面的 al、
// 下面的 dap_lba 与种子偏移、以及 stage2 末尾的 times 上限。
//
// 盘的大小由 --size 给（单位 MB），默认 64。现在只用了开头几十兆，所以其余是空的；
// 那是有意的 —— 装文件系统、放工具链、塞基本库都要空间，而一块盘的尺寸定得早，
// 后面就不必为了扩大它去搬分区。这块机器 D 盘够用，1 G 到 4 G 都装得下。
const 盘大小MB = (() => {
  const i = process.argv.indexOf("--size");
  const v = i >= 0 && i + 1 < process.argv.length ? Number(process.argv[i + 1]) : 64;
  return Number.isInteger(v) && v >= 1 ? v : 64;
})();
const 种子偏移 = 16896;
const 盘字节数 = 盘大小MB * 1024 * 1024;
if (种子偏移 + 种子内容.length > 盘字节数) 失败("种子比盘还大，装不下");

// 把种子的真实字节数写进第二段里那一格。第二段自己只知道读了多少扇区，而扇区是向上
// 取整的 —— 74594 与 74752 差的那 158 字节正是末尾的补零。这个数只有这一侧见过，
// 所以由这一侧写进去；写的位置从 nasm 的清单里按符号名找，不靠人记偏移。
// 这一步必须在写盘之前 —— 它改的是内存里的那份第二段，改完才跟着一起落盘。
if (种子内容.length) {
  const 格 = 找符号(清单, "seed_bytes");
  if (格 === null) 失败("清单里没有 seed_bytes 这个符号 —— 第二段里那一格改名了吗");
  // nasm 的清单给的是段内偏移（-f bin 的输出与 org 无关），所以这里直接用；
  // 万一哪天它改成给绝对地址，减去 org 之后才对，所以两种都认。
  const 段内 = 格 >= 0x7e00 ? 格 - 0x7e00 : 格;
  if (段内 < 0 || 段内 + 4 > 16384) 失败("seed_bytes 落在第二段外面：偏移 " + 段内);
  二段.writeUInt32LE(种子内容.length, 段内);
  console.log("字节数    " + 种子内容.length + " 写进第二段偏移 " + 段内);
  // seed_bytes 是 times 之前的最后一项，所以它之后就是「这一段实际用到哪」。
  // 不报这个数的话，16384 那个数字总像是用满了，而下一块砖就会在没人预料的时候撞上去。
  console.log("实到      " + (段内 + 4) + " 字节，余 " + (16384 - 段内 - 4));
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
const 示例文件 = Buffer.from("Yunooka filesystem ok\n", "utf8");
const 子文件 = Buffer.from("Yunooka subdirectory ok\n", "utf8");
// 盘上的第一条命令。shell 的「解释」那一半从它读起 —— 交互那一半要串口能收字节，
// 而那条路还没通，所以命令先写在盘上，等能读行了再换成真的键盘。
const 命令文件 = Buffer.from("files\n", "utf8");
// repl 的第一行输入：一个函数名，UTF-16 码元，没有换行 —— 这样读的人不必再切。
// 名字要与种子里真有的一致：块长 在种子中出现两次，读程序 折进 Map 时留最后那个
// （返回 512），而按名字找也留最后一个，所以两边对得上。
const 求值输入 = Buffer.from("块长", "utf16le");
const 示例扇区数 = Math.ceil(示例文件.length / 512) + Math.ceil(子文件.length / 512)
  + Math.ceil(命令文件.length / 512) + Math.ceil(求值输入.length / 512);

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

const 超级块 = Buffer.alloc(512);
超级块.write("YUNOFS", 0, "latin1");
超级块.writeUInt16LE(1, 6);                        // 版本
超级块.writeUInt32LE(盘字节数 / 512, 8);             // 盘上扇区总数
超级块.writeUInt32LE(根目录号, 12);
超级块.writeUInt32LE(1, 16);                       // 根目录占一个扇区
超级块.writeUInt32LE(数据起, 20);
超级块.writeUInt32LE(盘字节数 / 512 - 数据起 - 示例扇区数, 24);

const 根目录 = Buffer.alloc(512);
let 根位 = 写条目(根目录, 0, "hello.txt", 0, 数据起, 示例文件.length);
根位 = 写条目(根目录, 根位, "docs", 1, 子目录号, 0);       // 目录的字节长度没有意义，写 0
根位 = 写条目(根目录, 根位, "cmd.txt", 0, 数据起 + 2, 命令文件.length);
写条目(根目录, 根位, "repl.txt", 0, 数据起 + 3, 求值输入.length);

const 子目录 = Buffer.alloc(512);
写条目(子目录, 0, "note.txt", 0, 数据起 + 1, 子文件.length);

console.log("文件系统  超级块第 " + 文件系统起 + " 号扇区，根目录第 " + 根目录号
  + " 号扇区，docs 目录第 " + 子目录号 + " 号扇区；hello.txt（" + 示例文件.length
  + " 字节）、docs/note.txt（" + 子文件.length + " 字节）、cmd.txt（"
  + 命令文件.length + " 字节）、repl.txt（" + 求值输入.length + " 字节，UTF-16）");

// 盘用稀疏文件建，不在内存里放一份整盘副本 —— Node 的 Buffer 上限是 2 GB，而这块盘
// 将来会要 4 GB。ftruncate 造出来的空洞不占磁盘也不占内存，各段各自写在它该在的
// 偏移上就够了。VDI 那一层同样对全零区域稀疏，所以两处都不必为「名义尺寸」付账。
const fd = fs.openSync(盘像, "w");
try {
  fs.ftruncateSync(fd, 盘字节数);
  fs.writeSync(fd, 引导, 0, 引导.length, 0);
  fs.writeSync(fd, 二段, 0, 二段.length, 512);
  fs.writeSync(fd, 种子内容, 0, 种子内容.length, 种子偏移);
  fs.writeSync(fd, 超级块, 0, 512, 文件系统起 * 512);
  fs.writeSync(fd, 根目录, 0, 512, 根目录号 * 512);
  fs.writeSync(fd, 子目录, 0, 512, 子目录号 * 512);
  fs.writeSync(fd, 示例文件, 0, 示例文件.length, 数据起 * 512);
  fs.writeSync(fd, 子文件, 0, 子文件.length, (数据起 + 1) * 512);
  fs.writeSync(fd, 命令文件, 0, 命令文件.length, (数据起 + 2) * 512);
  fs.writeSync(fd, 求值输入, 0, 求值输入.length, (数据起 + 3) * 512);
} finally {
  fs.closeSync(fd);
}
console.log("盘映像    " + 盘大小MB + " MB（" + 盘字节数 / 512 + " 个扇区）");

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
