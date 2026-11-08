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
// 两段各有各的硬约束：引导扇区必须正好 512 字节（BIOS 只读这一扇区），第二段必须在
// 512 以内（它占一个扇区）。哪一条不成立，后面跑起来的东西就不是我们以为的那个。
const 编一段 = (名字, 源路, 出) => {
  const r = spawnSync("nasm", ["-f", "bin", 源路, "-o", 出], { encoding: "utf8" });
  if (r.status !== 0) 失败(名字 + " 编不过：" + String(r.stderr || "").slice(0, 400));
  const 字节 = fs.readFileSync(出);
  if (字节.length > 512) 失败(名字 + " 超过一个扇区：" + 字节.length + " 字节");
  return 字节;
};

const 引导 = 编一段("引导扇区", 源, 像);
if (引导.length !== 512) 失败("引导扇区应当正好 512 字节，实际 " + 引导.length);
if (引导[510] !== 0x55 || 引导[511] !== 0xaa) {
  失败("末两字节应当是 55 AA，实际 " + 引导[510].toString(16) + " " + 引导[511].toString(16));
}
const 二段 = 编一段("第二段", 源二, 像二);
// 第二段自带签名（它也是一段可引导的代码，只是不经过 BIOS），所以这里只查长度上限。
console.log("引导扇区  " + 引导.length + " 字节，签名 55 AA 对");
console.log("第二段    " + 二段.length + " 字节（上限 512）");

// ---- 二、拼成一块盘 ----
// 第一扇区是引导扇区，第二扇区是第二段，其余全是零。补零不是装饰 —— 它让这块盘有确定
// 的长度，于是「挂上去的是不是我们建的那一块」也成了一个可以比对的数。
const 总扇区 = 2048;
const 盘内容 = Buffer.alloc(总扇区 * 512);
引导.copy(盘内容, 0);
二段.copy(盘内容, 512);
fs.writeFileSync(盘像, 盘内容);
console.log("盘映像    " + 盘内容.length + " 字节（" + 总扇区 + " 个扇区）");

// ---- 四、转成 vdi ----
const VBox = 找VBox();
if (!VBox) 失败("没有 VirtualBox（VBoxManage 不在注册表、也不在 PATH），盘建好了但没有 vdi");
for (const 旧 of [盘, 盘 + ".vbox"]) if (fs.existsSync(旧)) fs.unlinkSync(旧);
const 转 = spawnSync(VBox, ["convertfromraw", 盘像, 盘, "--format", "VDI"], { encoding: "utf8" });
if (转.status !== 0) 失败("convertfromraw 失败：" + String(转.stderr || "").slice(0, 300));
console.log("vdi      " + 盘 + "（" + Math.round(fs.statSync(盘).size / 1024) + " KiB）");
console.log("");
console.log("下一步：node tools/run.mjs");
