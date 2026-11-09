// 试一次 pipe 通道：虚拟机当客户端，主机当服务端。
//
// 与 tcpserver 的区别在谁是服务端。tcpserver 是虚拟机开一个端口等主机连；pipe 是
// 虚拟机去连主机先建好的命名管道。两次 tcpserver 都是「连得上、收不到」，这一次
// 换掉的是「谁先等谁」，所以它值得单独试 —— 试完不管成不成，结论写回 design。
//
// 用法：node tools/try-pipe.mjs
//
// 结论：这一条路不通，脚本留下来只为让结论可复现。VirtualBox 7.2 上
//   --uartmode1 pipe <路径>            → Invalid parameter（它认 pipe 这个词，不认路径）
//   --uart-mode1 "client pipe#名字"    → Failed to open host device (VERR_INVALID_HANDLE)
// 手册写的 server pipe#name / client pipe#name 与实际解析器对不上：它把 # 之后的东西
// 连同 # 一起当成了设备名。所以这个脚本现在跑起来只会在 startvm 那一步报同一句话。
// 完整的四条实测记录在 boot/stage2.asm 的串口一节。
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const 机名 = "Yunooka";
// VBox 7 的语法：--uart-modeN "client pipe#<名字>"。两种 pipe 的分别是谁先等谁 ——
// client 是虚拟机去连主机建好的管道，server 是虚拟机自己建一个等主机连。
// 6.x 及更早的 --uartmode1 "pipe <路径>" 在 7.2 上直接报 Invalid parameter。
const 管道名 = "yunooka-serial";
const 管名 = "\\\\.\\pipe\\" + 管道名;

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

// 上一趟可能还开着
vbox(["controlvm", 机名, "poweroff"]);
睡(1500);

// 先建服务端。虚拟机是客户端，它连的时候这边必须已经在听。
let 连接 = null;
let 收到 = "";
const 服 = net.createServer((s) => {
  连接 = s;
  console.log("虚拟机连上管道了");
  s.on("data", (b) => {
    收到 += b.toString("latin1");
    console.log("收到 " + b.length + " 字节（累计 " + 收到.length + "）");
  });
  s.on("error", (e) => console.log("连接出错：" + e.message));
  s.on("close", () => console.log("连接关了"));
  // 立刻发一个字节：接收 FIFO 会留住它，等 stage2 走到读取那一步
  s.write("Z");
  console.log("已发一个 Z");
});
服.on("error", (e) => { console.log("管道建不起来：" + e.message); process.exit(2); });
服.listen(管名, () => {
  console.log("管道在听：" + 管名);

  const 设 = vbox(["modifyvm", 机名, "--uart1", "0x3F8", "4",
    "--uart-mode1", "client pipe#" + 管道名]);
  if (设.status !== 0) {
    console.log("modifyvm 失败：" + String(设.stderr || "").slice(0, 300));
    process.exit(2);
  }
  console.log("虚拟机已设成 pipe 模式");

  const 起 = vbox(["startvm", 机名, "--type", "headless"]);
  console.log("startvm 退出码 " + 起.status
    + (起.status === 0 ? "" : "：" + String(起.stderr || "").slice(0, 300)));

  睡(12000);
  console.log("");
  console.log("共收到 " + 收到.length + " 字节");
  console.log(JSON.stringify(收到.replace(/\r/g, "\\r").replace(/\n/g, "\\n")));
  const 有回显 = 收到.includes("echo Z");
  console.log("回显那一段" + (有回显 ? "出现了" : "没出现"));

  vbox(["controlvm", 机名, "poweroff"]);
  睡(1500);
  // 改回文件模式：这条通道是这一课的对象，不是主判据的依赖
  vbox(["modifyvm", 机名, "--uart1", "0x3F8", "4",
    "--uart-mode1", "file " + path.join(ROOT, "build", "serial.log")]);
  服.close();
  process.exit(有回显 ? 0 : 1);
});
