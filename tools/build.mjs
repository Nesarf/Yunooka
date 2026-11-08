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
// 它占的那些扇区 —— 两个，因为要装得下一个十进制打印。哪一条不成立，后面跑起来的东西
// 就不是我们以为的那个。
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
const 二段 = 编一段("第二段", 源二, 像二, 4096, 清单);
// 第二段自带签名（它也是一段可引导的代码，只是不经过 BIOS），所以这里只查长度上限。
console.log("引导扇区  " + 引导.length + " 字节，签名 55 AA 对");
console.log("第二段    " + 二段.length + " 字节（上限 4096，占八个扇区）");

// ---- 二、种子 ----
// 给不给种子都建得出来，这很重要：Yunooka 不欠 HMYR 仓库任何东西，所以没有种子时
// 它应当照样能建、能跑，只是判据变成第三种结果（读到扇区，但里面没有种子）。
// 给了就把整份写进去 —— 第二段现在读的是整份（到 0x1A400），不是开头一扇区。
const 种子参 = (() => {
  const i = process.argv.indexOf("--seed");
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : null;
})();
let 种子内容 = Buffer.alloc(0);
let 种子说明 = "（没给 --seed，第 3 个扇区往后是空的）";
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
//   第 1 个扇区（偏移 0）       引导扇区
//   第 2 到 9 个扇区（偏移 512）第二段，八个扇区（4 KB）
//   第 10 个扇区起（偏移 4608） 种子的第一个字节
// stage2.asm 里写的是 dap_lba = 9，也就是第 10 个扇区；引导扇区写的是 al = 8，也就是
// 读八个扇区。三处数字对得上才建得对，所以它们写在同一段注释里。
//
// 盘的大小由 --size 给（单位 MB），默认 64。现在只用了开头四兆出头，所以其余是空的；
// 那是有意的 —— 装文件系统、放工具链、塞基本库都要空间，而一块盘的尺寸定得早，
// 后面就不必为了扩大它去搬分区。这块机器 D 盘够用，1 G 到 4 G 都装得下。
const 盘大小MB = (() => {
  const i = process.argv.indexOf("--size");
  const v = i >= 0 && i + 1 < process.argv.length ? Number(process.argv[i + 1]) : 64;
  return Number.isInteger(v) && v >= 1 ? v : 64;
})();
const 种子偏移 = 4608;
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
  if (段内 < 0 || 段内 + 4 > 4096) 失败("seed_bytes 落在第二段外面：偏移 " + 段内);
  二段.writeUInt32LE(种子内容.length, 段内);
  console.log("字节数    " + 种子内容.length + " 写进第二段偏移 " + 段内);
}

// 盘用稀疏文件建，不在内存里放一份整盘副本 —— Node 的 Buffer 上限是 2 GB，而这块盘
// 将来会要 4 GB。ftruncate 造出来的空洞不占磁盘也不占内存，三段各自写在它该在的
// 偏移上就够了。VDI 那一层同样对全零区域稀疏，所以两处都不必为「名义尺寸」付账。
const fd = fs.openSync(盘像, "w");
try {
  fs.ftruncateSync(fd, 盘字节数);
  fs.writeSync(fd, 引导, 0, 引导.length, 0);
  fs.writeSync(fd, 二段, 0, 二段.length, 512);
  fs.writeSync(fd, 种子内容, 0, 种子内容.length, 种子偏移);
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
spawnSync(VBox, ["storageattach", "Yunooka", "--storagectl", "SATA", "--port", "0", "--device", "0", "--medium", "none"], { encoding: "utf8" });
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
