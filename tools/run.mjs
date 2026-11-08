// 把 build/disk.vdi 挂到一台虚拟机上，从它引导，读串口，比对那行字。
//
// 判据走串口而不是屏幕：VBoxManage 能把 COM1 的字节直接写进主机的一个文件，于是
// 「它说得出话吗」变成「文件里有没有那段字节」—— 这件事可以自动比对，而且不依赖
// 截图、OCR 或者人的眼睛。屏幕输出照样留着，用来看，不用来判。
//
// 退出码：0 那行字出现了；1 没出现（引导了，但没说话）；2 这一台做不了。
//
// 用法：node tools/run.mjs
//       node tools/run.mjs --keep        跑完不停机，好让人打开窗口看
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const 建 = path.join(ROOT, "build");
const 盘 = path.join(建, "disk.vdi");
const 串口 = path.join(建, "serial.log");
const 截屏 = path.join(建, "screen.png");
const 机名 = "Yunooka";
// 两行都要在。只看到第二行说明第一段没跑；只看到第一行说明读盘或跳转断了 ——
// 判据分两行写，正是为了让失败停在能分辨的位置上。
const 该有 = ["Yunooka: boot ok", "Yunooka: stage2 ok"];
const 留机 = process.argv.includes("--keep");

const 做不了 = (为什么) => {
  console.error("这一台做不了：" + 为什么);
  process.exit(2);
};

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

const VBox = 找VBox();
if (!VBox) 做不了("没有 VirtualBox");
const vbox = (参数, 超时 = 120000) => spawnSync(VBox, 参数, { encoding: "utf8", timeout: 超时 });

if (!fs.existsSync(盘)) 做不了("还没有 build/disk.vdi，先跑 node tools/build.mjs");

// ---- 一、机器：没有就建，有就复用 ----
const 册 = vbox(["list", "vms"]);
if (册.status !== 0) 做不了("VBoxManage list vms 跑不动");
const 有这台 = String(册.stdout || "").includes('"' + 机名 + '"');

const 态 = () => {
  const r = vbox(["showvminfo", 机名, "--machinereadable"]);
  const m = /^VMState="(.*)"$/m.exec(String(r.stdout || ""));
  return m ? m[1] : "";
};

if (有这台 && 态() !== "poweroff" && 态() !== "aborted") {
  vbox(["controlvm", 机名, "poweroff"]);
  // 等它真的停，不然下面的 modifyvm 会撞上锁
  for (let i = 0; i < 20 && 态() !== "poweroff"; i++) {
    spawnSync("node", ["-e", "0"], { timeout: 500 });
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 500);
  }
}

if (!有这台) {
  const 建机 = vbox(["createvm", "--name", 机名, "--ostype", "Other_64", "--register"]);
  if (建机.status !== 0) 做不了("建机器失败：" + String(建机.stderr || "").slice(0, 200));
  vbox(["storagectl", 机名, "--name", "SATA", "--add", "sata", "--controller", "IntelAhci", "--portcount", "2"]);
  vbox(["storageattach", 机名, "--storagectl", "SATA", "--port", "0", "--device", "0", "--type", "hdd", "--medium", 盘]);
} else {
  vbox(["storageattach", 机名, "--storagectl", "SATA", "--port", "0", "--device", "0", "--medium", "none"]);
  vbox(["storageattach", 机名, "--storagectl", "SATA", "--port", "0", "--device", "0", "--type", "hdd", "--medium", 盘]);
}

// ---- 二、配置：最小机器，串口写进文件 ----
// 32 MiB 是 VirtualBox 允许的最小内存。这台机器现在只需要把一条指令走完，
// 内存小反而好 —— 它逼着后面加东西时先想清楚要多少。
for (const 旧 of [串口]) if (fs.existsSync(旧)) fs.unlinkSync(旧);
vbox(["modifyvm", 机名, "--memory", "32", "--cpus", "1", "--firmware", "bios",
  "--boot1", "disk", "--boot2", "none", "--boot3", "none", "--boot4", "none",
  "--audio", "none", "--usb", "off", "--nic1", "none",
  "--uart1", "0x3F8", "4", "--uartmode1", "file", 串口]);

// ---- 三、跑 ----
const 起 = vbox(["startvm", 机名, "--type", "headless"]);
if (起.status !== 0) 做不了("起不来：" + String(起.stderr || "").slice(0, 200));

// 等串口文件里出现那行字，最多二十秒。引导扇区是同步的，正常几秒就够 ——
// 二十秒是给慢盘与冷启动留的余量。
const 睡 = (毫秒) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 毫秒);
let 读到 = "";
for (let i = 0; i < 40; i++) {
  睡(500);
  if (fs.existsSync(串口)) {
    读到 = fs.readFileSync(串口, "utf8");
    if (该有.every((s) => 读到.includes(s))) break;
  }
}

vbox(["controlvm", 机名, "screenshotpng", 截屏]);

// ---- 四、报 ----
const 缺 = 该有.filter((s) => !读到.includes(s));
const 成了 = 缺.length === 0;
console.log("");
console.log("机器      " + 机名 + "（32 MiB，BIOS 引导，串口写文件）");
console.log("串口读到  " + (读到 ? JSON.stringify(读到.replace(/\r/g, "\\r").replace(/\n/g, "\\n")) : "(空)"));
console.log("截屏      " + 截屏);
console.log("");
console.log(成了
  ? "两行都在：" + 该有.join(" / ") + " —— 链条是两段。"
  : "缺：" + 缺.join("、") + " —— 断在那一行前面。");

if (!留机) {
  vbox(["controlvm", 机名, "poweroff"]);
  console.log("机器已关（--keep 可以留着它，用 GUI 打开看）。");
}
process.exit(成了 ? 0 : 1);
