// 试一次 tcpserver，并且这次带上了 uart_init。
//
// 两次失败都在 uart_init 之前：那时 MCR 是上电默认的 0，DTR 与 RTS 都没拉起来。
// 而在串口这一层，「DTR 没起来」对端可以理解成「设备没准备好」，于是它一个字节都不发 ——
// 主机那一侧看到的正是「连得上、收不到」。这不是通道的问题，是设备状态的问题。
//
// 所以这一趟只改一个变量：把 uart_init 加进去。通道照旧用 tcpserver。
//
// 用法：node tools/try-tcp.mjs
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const 机名 = "Yunooka";
const 串口 = path.join(ROOT, "build", "serial.log");
const 口 = 47111;

const 找VBox = () => {
  const 册 = spawnSync("reg", ["query", "HKLM\\SOFTWARE\\Oracle\\VirtualBox", "/v", "InstallDir"], { encoding: "utf8" });
  const m = /InstallDir\s+REG_SZ\s+(.+)/.exec(String(册.stdout || ""));
  if (m) {
    const 猜 = path.join(m[1].trim(), "VBoxManage.exe");
    if (fs.existsSync(猜)) return 猜;
  }
  return null;
};
const VBox = 找VBox();
if (!VBox) { console.log("没有 VirtualBox"); process.exit(2); }
const vbox = (参数) => spawnSync(VBox, 参数, { encoding: "utf8", timeout: 60000 });
const 睡 = (毫秒) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 毫秒);

vbox(["controlvm", 机名, "poweroff"]);
睡(1500);
for (const 旧 of [串口]) if (fs.existsSync(旧)) fs.unlinkSync(旧);

const 设 = vbox(["modifyvm", 机名, "--uart1", "0x3F8", "4", "--uartmode1", "tcpserver", String(口)]);
console.log("modifyvm 退出码 " + 设.status + (设.status ? "：" + String(设.stderr || "").slice(0, 200) : ""));

const 起 = vbox(["startvm", 机名, "--type", "headless"]);
console.log("startvm 退出码 " + 起.status
  + (起.status === 0 ? "" : "：" + String(起.stderr || "").slice(0, 300)));
if (起.status !== 0) process.exit(2);

// 虚拟机启动之后才开始监听，所以这里要重试连几次。
//
// 这一次把 socket 的生死也打出来：上次只绑了 data，没有 close 与 error，于是
// 「连上了却一个字节都没有」分不清是「对端不发」还是「这条连接早就断了」。
// 这两件事在主机这一侧的修法完全不同，所以要先分得开。
let 套 = null;
const 连一次 = () => new Promise((解) => {
  const s = net.connect(口, "127.0.0.1");
  s.once("connect", () => 解(s));
  s.once("error", (e) => { console.log("连接出错：" + e.message); s.destroy(); 解(null); });
});
for (let i = 0; i < 30 && !套; i++) {
  睡(300);
  套 = await 连一次();
}
if (!套) { console.log("连不上 " + 口); vbox(["controlvm", 机名, "poweroff"]); process.exit(2); }
console.log("连上了 " + 口);

let 收到 = "";
let 关了 = false;
套.on("data", (b) => { 收到 += b.toString("latin1"); });
套.on("close", () => { 关了 = true; console.log("连接被对端关掉了"); });
套.on("error", (e) => console.log("连接中途出错：" + e.message));

const 发 = process.argv[2] !== "nosend";
if (发) {
  套.write("Z");
  console.log("已发一个 Z");
} else {
  console.log("不发，只看虚拟机会不会说话");
}

// 十四秒不够分辨「慢」与「不通」：Linux 日志里 UART 的临界区等待是每次四万多 ticks，
// 而 serial_wait 那个循环要转十万次。拉长到一个分钟，让「慢」有机会走完。
for (let i = 0; i < 30; i++) {
  睡(2000);
  const 状 = vbox(["showvminfo", 机名, "--machinereadable"]);
  const m = /VMState="([^"]*)"/.exec(String(状.stdout || ""));
  console.log("第 " + (i + 1) + " 个两秒：VM " + (m ? m[1] : "?")
    + "，连接" + (关了 ? "已关" : "还开着") + "，累计 " + 收到.length + " 字节");
}
console.log("共收到 " + 收到.length + " 字节");
console.log(JSON.stringify(收到.replace(/\r/g, "\\r").replace(/\n/g, "\\n").slice(0, 800)));
const 有回显 = 收到.includes("echo Z");
console.log("回显那一段" + (有回显 ? "出现了" : "没出现"));

套.destroy();
vbox(["controlvm", 机名, "poweroff"]);
睡(1500);
// 改回文件模式：这是主判据的依赖，不能留在这条实验通道上
vbox(["modifyvm", 机名, "--uart1", "0x3F8", "4", "--uartmode1", "file", 串口]);
process.exit(有回显 ? 0 : 1);
