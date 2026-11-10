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
import net from "node:net";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const 建 = path.join(ROOT, "build");
const 盘 = path.join(建, "disk.vdi");
const 串口 = path.join(建, "serial.log");
// 串口插座。用 tcpserver 而不是文件，因为文件那条路是单向的：虚拟机写得出来，
// 主机写不进去。而回显测试与将来的 shell 都要字节能从主机走进去。
const 串口口 = 47111;
const 截屏 = path.join(建, "screen.png");
const 机名 = "Yunooka";
// 三行里前两行必有，第三行视有没有给种子而定 —— 所以这里只查前两行，
// 第三行落在下面三种之一：seed ok、seed bad、seed unreadable。
// 把它写进「必有」会让没有种子的那一趟假红；完全不查又会漏掉读盘失败。
// 必有的五行：两段引导、保护模式、长模式、堆自检。种子那一条视给不给 --seed 而定，
// 所以它单独报（seed ok 带字节数 / seed bad / seed unreadable 三选一），不进成败线。
const 该有 = [
  "Yunooka: boot ok",
  "Yunooka: stage2 ok",
  "Yunooka: protected mode ok",
  "Yunooka: long mode ok",
  "Yunooka: heap ok",
];
// 全程是「都出现才算跑完」的那串，用来决定什么时候停止等待。它比成败线多几样：
// 种子那一行（不带种子时不会出现，所以那种情况靠满时长兜底）、种子的头、第一个函数、
// 第一条指令。
// 「全程」里那一项曾经跟着 --ata 走，因为 ATA 那条测试当时偶发抛异常、默认不跑。
// 后来查清了：根因是长模式下一直开着中断（BIOS 的 PIC 还在送定时器中断，而 IDT 里
// 32 号往后是空的），long_entry 加了一句 cli 就修好了。它已经回到主链上，所以这里
// 也回到无条件。
const 全程 = [
  "Yunooka: boot ok",
  "Yunooka: stage2 ok",
  "Yunooka: seed ok",
  "Yunooka: protected mode ok",
  "Yunooka: long mode ok",
  "Yunooka: heap ok",
  "Yunooka: fn ",
  "Yunooka: op ",
  "Yunooka: letters -> ",
  "Yunooka: call -> ",
  "Yunooka: byname first -> ",
  "Yunooka: is_digit('a') -> ",
  "Yunooka: ata ",
  "Yunooka: fs ",
  "Yunooka: open ",
  "Yunooka: open docs/",
  "Yunooka: open docs/sub/",
  "Yunooka: second disk ok",
  "Yunooka: wrote -> ",
  "Yunooka: share twice",
  "Yunooka: pci dev ",
  "Yunooka: beta ",
  "Yunooka: read blocked by boundary",
  "Yunooka: secret blocked",
  "Yunooka: pixel ",
  "Yunooka: line ",
  "Yunooka: shell> ",
  "Yunooka: repl> ",
  "Yunooka: math> average -> ",
  // 交互式的那两行：客人机先打各自的一句，然后等主机把键送进来。
  "Yunooka: shell ready",
  "Yunooka: repl ready",
  "Yunooka: prog main",
];
const 种子三种 = ["Yunooka: seed ok", "Yunooka: seed bad", "Yunooka: seed unreadable"];
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
let 有这台 = String(册.stdout || "").includes('"' + 机名 + '"');

// 磁盘控制器必须是 IDE（PIIX4），不能是 AHCI。
//
// 长模式下的读盘走的是 ATA PIO 的 0x1F0 那一组端口，而那组端口属于 IDE 兼容模式；
// AHCI 控制器不映射它们，read 0x1F7 会一直返回 0xFF —— 状态位看着永远「忙」，
// 于是等待循环转到超时，而串口上只留下一句没头没尾的 ata start。
//
// 控制器一换，机器没法就地改，所以旧的直接删了重建。
if (有这台) {
  const 描述 = String(vbox(["showvminfo", 机名, "--machinereadable"]).stdout || "");
  if (!/^storagecontrollername0="IDE"$/m.test(描述)) {
    console.log("控制器不是 IDE，删了重建：" + 机名);
    vbox(["unregistervm", 机名, "--delete"]);
    有这台 = false;
  }
}

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
  vbox(["storagectl", 机名, "--name", "IDE", "--add", "ide", "--controller", "PIIX4", "--portcount", "2"]);
  vbox(["storageattach", 机名, "--storagectl", "IDE", "--port", "0", "--device", "0", "--type", "hdd", "--medium", 盘]);
} else {
  const 卸 = vbox(["storageattach", 机名, "--storagectl", "IDE", "--port", "0", "--device", "0", "--medium", "none"]);
  const 挂 = vbox(["storageattach", 机名, "--storagectl", "IDE", "--port", "0", "--device", "0", "--type", "hdd", "--medium", 盘]);
  // 挂载失败要说出来。以前这里不看返回值，于是问题拖到 startvm 才以另一个面目出现
  // （「UUID 不匹配」），而真正的错在更早的地方。
  if (挂.status !== 0 && !String(挂.stderr || "").includes("already"))
    做不了("挂盘失败：" + String(挂.stderr || "").trim().slice(0, 200));
}

// ---- 二、配置：最小机器，串口写进文件 ----
// 32 MiB 是 VirtualBox 允许的最小内存。这台机器现在只需要把一条指令走完，
// 内存小反而好 —— 它逼着后面加东西时先想清楚要多少。
//
// 关于双向：查完了，结论与原来的猜测不同。tcpserver 后端下主机连得上，但客人机一个
// 字节也送不出来 —— 六十秒仍是 running、仍是零字节；摘掉 uart_init 一样，把握手整个
// 摘掉也一样，连引导扇区那句 boot ok 都出不来。所以问题不在时序，在客人机的串口
// port I/O 在这条后端上出不去。uart_init 加上它还让客人机三重故障（VINF_EM_TRIPLE_FAULT）。
// pipe 的两条语法在 7.2 上都不通。这四条记录抄在 boot/stage2.asm 的串口一节里，
// 因为它们是客户机代码的约束，而不只是这一个脚本的用法。
// 文件模式因此不是权宜之计，而是这条通道现在唯一能用的形态：它单向，但可靠。
for (const 旧 of [串口]) if (fs.existsSync(旧)) fs.unlinkSync(旧);
vbox(["modifyvm", 机名, "--memory", "32", "--cpus", "1", "--firmware", "bios",
  "--boot1", "disk", "--boot2", "none", "--boot3", "none", "--boot4", "none",
  "--audio", "none", "--usb", "off",
  // 网卡：82540EM（Intel E1000）走 MMIO，NAT 不需要额外配置。
  // 换成有网卡之后要做的第一件不是协议，是 PCI 枚举 —— 「有一块网卡」这件事
  // 由它自己的 vendor/device 两个数说出来，而那一步不需要任何协议。
  "--nic1", "nat", "--nictype1", "82540EM", "--cableconnected1", "on",
  "--uart1", "0x3F8", "4", "--uartmode1", "file", 串口]);

// ---- 二·五、信箱 ----
//
// 一块裸盘：主机的普通文件就是它的全部内容，所以写它就是改客人机能读到的输入。
// 这是 input-mailbox 那一条的落地 —— 串口只能往外说，往里送走这。
//
// 布局：扇区 0 是头，魔数八字节、版本 u16、留白 u16、码元数 u32、序列号 u32，
// 内容从第 32 字节起按 UTF-16 码元摆。主人机两侧只共享这一份约定，而它只写在两处：
// 这里，与 stage2 的 mbox_magic。
//
// 盘要先存在。它是一次性造的（createmedium 会注册一个 UUID，重建会让登记里那份失效），
// 所以这里只在缺的时候造，造完就一直改内容。
const 信箱 = path.join(建, "mailbox.raw");
if (!fs.existsSync(信箱)) {
  const 造 = vbox(["createmedium", "disk", "--filename", 信箱, "--size", "1",
    "--format", "RAW", "--variant", "Fixed"]);
  if (造.status !== 0) 做不了("信箱盘造不出来：" + String(造.stderr || "").slice(0, 200));
}
// 挂到 primary slave。BIOS 那边它就成了盘号 0x81，stage2 按这个号读第一扇区。
//
// 条件要看「值是不是 none」，不是「键在不在」：showvminfo 对空槽位也输出
// IDE-0-1="none"，所以只测键名会永远认为已经挂好 —— 而 attach 因此一次也没跑过。
// 这个错很安静：盘造出来了、文件也在、就是没接到机器上。
const 机器信息 = String(vbox(["showvminfo", 机名, "--machinereadable"]).stdout || "");
const 信槽 = /"IDE-0-1"="([^"]*)"/.exec(机器信息);
if (!信槽 || 信槽[1] === "none") {
  const 挂 = vbox(["storageattach", 机名, "--storagectl", "IDE", "--port", "0", "--device", "1",
    "--type", "hdd", "--medium", 信箱, "--mtype", "normal"]);
  if (挂.status !== 0) 做不了("信箱挂不上去：" + String(挂.stderr || "").slice(0, 200));
}
// 这一趟放在信箱里的那一行。它与盘上 cmd.txt 里的那一行是同一个词 —— 先用同一个词
// 对照，两处结果一样，才说明「输入是从信箱来的」这件事没有别的东西在替它干活。
//
// 格式与 cmd.txt 一致：ASCII 字节，一行一个换行。不按 UTF-16 是因为 shell 的比较
// 那一步按字节比，两处的形状一样，run_shell 就只需要在「来源」上分叉。
const 信内容 = "files\n";
const 信字节 = Buffer.from(信内容, "latin1");
const 信格 = Buffer.alloc(512);
信格.write("YUNOMBX\0", 0, "latin1");
信格.writeUInt16LE(1, 8);           // 版本
信格.writeUInt16LE(0, 10);          // 留白：对齐用。曾经借它当 ATA 的开关，现在不用了
信格.writeUInt32LE(信字节.length, 12);
信格.writeUInt32LE(1, 16);          // 序列号：每改一次加一，将来客人机靠它认新
信字节.copy(信格, 32);
const 信fd = fs.openSync(信箱, "r+");
try {
  fs.writeSync(信fd, 信格, 0, 512, 0);
} finally {
  fs.closeSync(信fd);
}

// ---- 二·六、β 盘 ----
//
// 第二块盘：同一套文件系统格式，但自己的超块、自己的根目录、自己的文件。
// 盘符 α 与 β 的分别就是「读哪一块盘」，不是「读哪一种格式」—— 格式一样、代码一样，
// 变的只是 fs_base 与 fs_start 这两个数，而那两个数由盘符决定。
//
// 布局与主盘同形，只是从第 0 个扇区起：超块 0、根目录 1、数据 2。
// 它挂在 secondary master（IDE 的 port 1 device 0），BIOS 那边就是盘号 0x82。
const 二盘 = path.join(建, "disk2.raw");
if (!fs.existsSync(二盘)) {
  const 造 = vbox(["createmedium", "disk", "--filename", 二盘, "--size", "1",
    "--format", "RAW", "--variant", "Fixed"]);
  if (造.status !== 0) 做不了("β 盘造不出来：" + String(造.stderr || "").slice(0, 200));
}
const 机器信息2 = String(vbox(["showvminfo", 机名, "--machinereadable"]).stdout || "");
const 二槽 = /"IDE-1-0"="([^"]*)"/.exec(机器信息2);
if (!二槽 || 二槽[1] === "none") {
  const 挂 = vbox(["storageattach", 机名, "--storagectl", "IDE", "--port", "1", "--device", "0",
    "--type", "hdd", "--medium", 二盘, "--mtype", "normal"]);
  if (挂.status !== 0) 做不了("β 盘挂不上去：" + String(挂.stderr || "").slice(0, 200));
}
const 二内容 = Buffer.from("Yunooka second disk ok\n", "utf8");
// 第二个文件故意不共享。判据要能把「同一家」与「共享过」两件事分开 ——
// 只有一个文件的话，一颗不管共享位的实现也能全过。
const 二秘密 = Buffer.from("Yunooka secret\n", "utf8");
const 二超 = Buffer.alloc(512);
二超.write("YUNOFS", 0, "latin1");
二超.writeUInt16LE(1, 6);               // 版本
二超.writeUInt32LE(2048, 8);            // 1 MB，2048 个扇区
二超.writeUInt32LE(1, 12);              // 根目录第 1 号扇区
二超.writeUInt32LE(1, 16);              // 根目录占一个扇区
二超.writeUInt32LE(2, 20);              // 数据从第 2 号扇区起
二超.writeUInt32LE(2045, 24);           // 空闲扇区数（凑个数，这一版不写盘）
// 偏移 28：家。这里故意与主盘不同 —— 家庭组的「边界」要能被看见，就必须有一块
// 不同的盘来做对照；两块盘同号时，「比较过」与「根本没比较」在串口上一样。
二超.writeUInt32LE(0x11111111, 28);
const 二根 = Buffer.alloc(512);
{
  const 写一条 = (位, 名字, 类型, 起, 长) => {
    二根.writeUInt16LE(名字.length, 位); 位 += 2;
    for (const 字 of 名字) { 二根.writeUInt16LE(字.charCodeAt(0), 位); 位 += 2; }
    二根.writeUInt8(类型, 位); 位 += 1;
    二根.writeUInt32LE(起, 位); 位 += 4;
    二根.writeUInt32LE(长, 位); 位 += 4;
    return 位;
  };
  let 位 = 0;
  位 = 写一条(位, "hello.txt", 0, 2, 二内容.length);
  写一条(位, "secret.txt", 0, 3, 二秘密.length);
}
const 二fd = fs.openSync(二盘, "r+");
try {
  fs.writeSync(二fd, 二超, 0, 512, 0);
  fs.writeSync(二fd, 二根, 0, 512, 512);
  fs.writeSync(二fd, 二内容, 0, 二内容.length, 1024);
  fs.writeSync(二fd, 二秘密, 0, 二秘密.length, 1536);
} finally {
  fs.closeSync(二fd);
}

// ---- 三、跑 ----
const 起 = vbox(["startvm", 机名, "--type", "headless"]);
if (起.status !== 0) 做不了("起不来：" + String(起.stderr || "").slice(0, 200));

// 等串口文件里出现那些行，最多二十秒。同时按阶段送两次键。
//
// 键盘那一步（run_key_poll）只抓一个字节，所以反复送同一个 F 的扫描码 —— 送多次的
// 代价是多几个字节，猜一次的代价是偶尔「没收到」，而后者看起来和「键盘不通」一样。
// 一旦那一行出现就停手：再送下去会落在后面交互式那一行里，被它当成真的按了 f。
//
// 交互式那两行都要的是握手，不是猜：客人机先打 shell ready 或 repl ready，这里看到
// 之后才把那一行送进去。两条路各说一句，因为主机分不清「现在轮到谁等键」。
//
// 送那一行用 keyboardputstring。两件事是实测出来的：它送的是集 1 的扫描码（用集 2 的
// 表去读，回显会是 c3：0x21 被当成 c、0x26 被当成 3），所以客人机的表也统一到集 1；
// 而测试键不能用 f —— run_key_poll 用 keyboardputscancode 21 按下过 f 却从没放开，
// VBox 认为它一直按着，于是 keyboardputstring "f" 不产生新的按下（送 gfiles 得到
// giles，丢的永远是 f）。换成 x（0x2D）之后就通了。
//
// 送一行的办法：一个字符一次，最后补一个回车。
//
// 一次送整行时 8042 的缓冲装不下，头一个会被挤掉（回送 files 得到 iles）。逐字符、
// 每个之间留六十毫秒就好了。回车单独用 keyboardputscancode 送按下码 0x1C。
const 睡 = (毫秒) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 毫秒);
const 送一行 = (文字) => {
  for (const 字 of 文字) {
    vbox(["controlvm", 机名, "keyboardputstring", 字]);
    睡(60);
  }
  睡(100);
  // 回车也要送放开码（集 1：按下 1C、放开 9C）。只送按下时 8042 认为回车一直按着，
  // 重复码会追到下一条命令里 —— 症状是第二条命令收到一个空行。
  vbox(["controlvm", 机名, "keyboardputscancode", "1c", "9c"]);
};
let 读到 = "";
let 送过整行 = false;
let 送过名字 = false;
for (let i = 0; i < 40; i++) {
  睡(500);
  if (!送过整行) {
    if (!读到.includes("Yunooka: key ") && !读到.includes("Yunooka: no key")) {
      vbox(["controlvm", 机名, "keyboardputscancode", "2d"]);
    }
  }
  if (fs.existsSync(串口)) {
    读到 = fs.readFileSync(串口, "utf8");
    if (!送过整行 && 读到.includes("Yunooka: shell ready")) {
      送一行("files");
      送过整行 = true;
    }
    // 第二条要靠第二条握手：repl 在 shell 之后才开始等键，所以它自己说一句 repl ready。
    if (!送过名字 && 读到.includes("Yunooka: repl ready")) {
      送一行("letters");
      送过名字 = true;
    }
    const 步数 = (读到.match(/Yunooka: op /g) || []).length;
    const 结果数 = (读到.match(/Yunooka: fn116 -> /g) || []).length;
    const 按名数 = (读到.match(/Yunooka: byname/g) || []).length;
    // 收手的条件里要有「交互那两行也走完了」：只等 ready 会在这儿就断电，而键刚送出去、
    // 客人机还没处理。那样看到的是一行 ready 加一条空白 —— 与「键没送到」一模一样。
    const 交互完 = /Yunooka: shell ready[\s\S]*?Yunooka: shell> files/.test(读到)
      && /Yunooka: repl ready[\s\S]*?Yunooka: repl-live> letters/.test(读到);
    if (交互完 && 全程.every((s) => 读到.includes(s)) && 步数 >= 4 && 结果数 >= 2 && 按名数 >= 2) break;
  }
}

vbox(["controlvm", 机名, "screenshotpng", 截屏]);

// ---- 四、报 ----
const 缺 = 该有.filter((s) => !读到.includes(s));
// 三条分配地址。分配器给了什么是这一块砖的主要内容，而它只有地址能证明：
// 第一条必须是起点 0x400000，每条末位是 0（按 16 对齐），并且逐块递增。
const 地址批 = [...读到.matchAll(/Yunooka: alloc ([0-9A-F]{16})/g)].map((m) => m[1]);
const 首块对 = 地址批[0] === "0000000000400000";
const 都对齐 = 地址批.length > 0 && 地址批.every((a) => a.endsWith("0"));
const 递升 = 地址批.every((a, i) => i === 0 || Number.parseInt(a, 16) > Number.parseInt(地址批[i - 1], 16));
const 分配成 = 地址批.length === 3 && 首块对 && 都对齐 && 递升;
// 第三行不是必有的：没有种子的那一趟，第二段会说 seed bad 或者 seed unreadable。
// 所以这里只把「它说了哪一种」报出来，不把它算进成败 —— 成败由前两行决定。
const 种子行 = 种子三种.find((s) => 读到.includes(s)) || "(没有第三行)";
const 种子意 = {
  "Yunooka: seed ok": "读到种子，魔数 HMYRB 对",
  "Yunooka: seed bad": "读到了，但前五字节不是 HMYRB",
  "Yunooka: seed unreadable": "第 3 个扇区读不出来",
};
console.log("");
console.log("机器      " + 机名 + "（32 MiB，BIOS 引导，串口写文件）");
console.log("串口读到  " + (读到 ? JSON.stringify(读到.replace(/\r/g, "\\r").replace(/\n/g, "\\n")) : "(空)"));
console.log("种子那一行 " + 种子行 + " —— " + (种子意[种子行] || "第三行没出现"));
// 种子的头是它在 64 位下读出来的东西：版本与函数数。这两样只有真读懂格式才报得出，
// 而且能与真实种子核对 —— 这一份是版本 1、202 个函数。
const 头行 = /Yunooka: seed v(\d+) (\d+)/.exec(读到);
console.log("种子的头  " + (头行 ? "版本 " + 头行[1] + "，" + 头行[2] + " 个函数" : "(没读出来)"));
// 第一个函数与它的第一条指令。这两样只有把格式读到函数表才报得出，而操作码的名字
// 由下面这张表翻 —— 表照抄 HMYR 的 src/code-file.mjs，抄在这里是有意的：判据要
// 独立于被验的那一侧，两边对不上时红的是 Yunooka 而不是那张表。
const 操作码表 = [
  "加", "赋值", "布尔", "调内置", "调函数", "常量", "除", "等", "字段", "大等",
  "全域取", "大", "索引", "跳", "假跳", "假跳留", "真跳", "真跳留", "小等",
  "取", "小", "余", "乘", "不等", "负", "非", "弃", "记录", "返回", "存",
  "减", "组", "调方法", "全域存",
];
const 函数行 = /Yunooka: fn (\S+) params (\d+) slots (\d+) instrs (\d+)/.exec(读到);
// 指令流是四条一组：正则抓全部，因为「只读第一条」与「走完整个指令流」在第一条上
// 看起来一模一样，而在第四条的缺席上一眼就能分开。
const 操作码行集 = [...读到.matchAll(/Yunooka: op (\d+)/g)].map((m) => Number(m[1]));
const 操作码名集 = 操作码行集.map((n) => 操作码表[n] || null);
// 求值那一条：letters 交出来的应当是一个 53 字符的串（26 小写 + 26 大写 + 一个下划线）。
// 这个数是能从那一侧独立算出来的，所以它验的是「真的执行了」，而不是「打了一行字」。
const 结果行 = /Yunooka: letters -> (\w+)(?: (\d+))?/.exec(读到);
// 条件跳转那两行：一个参数真、一个参数假，同一个函数应当交出两个不同的数。
// 这两行合起来才说明「跳转按条件走」—— 只验一个的话，一个永远不跳的解释器也能过。
const 跳转结果 = [...读到.matchAll(/Yunooka: fn116 -> (\d+)/g)].map((m) => m[1]);
const 跳转成 = 跳转结果.length === 2 && 跳转结果[0] === "2147483648" && 跳转结果[1] === "0";
// 调用那一块：块长 在种子里有两个定义（一个返回 256、一个返回 512），而 HMYR 自己的
// 读取器按名字折进 Map 时留的是后一个。判据跟着那一侧走，所以这里认 512。
const 调用行 = /Yunooka: call -> (\d+)/.exec(读到);
const 调用成 = 调用行 !== null && 调用行[1] === "512";
// 按名字找：块长 在种子里两个定义，一个 256 一个 512。走完整张表留最后那个是 512，
// 第一个匹配就收手是 256 —— 两个数都出现在串口上，才是「按名字」与「按顺序」分得开
// 的证据。只验其中一个的话，一个「永远取最后一个函数」的实现也能过。
const 按名行 = /Yunooka: byname -> (\d+)/.exec(读到);
const 先手行 = /Yunooka: byname first -> (\d+)/.exec(读到);
const 按名成 = 按名行 !== null && 按名行[1] === "512"
  && 先手行 !== null && 先手行[1] === "256";
// 第一条真的跑起来的程序：is_digit。它要参数落槽（is_digit 一参、in_set 三参）、
// 调函数、调内置 len、索引、等（串按内容比）、加、大等，以及 in_set 那条十轮的
// 尾递归 —— 少一样就给不出答案。两个答案都要对：只验一个的话，一个永远返回 true
// 的实现照样能过。
const 数字行 = /Yunooka: is_digit\('7'\) -> (true|false)/.exec(读到);
const 字母行 = /Yunooka: is_digit\('a'\) -> (true|false)/.exec(读到);
const 数字成 = 数字行 !== null && 数字行[1] === "true"
  && 字母行 !== null && 字母行[1] === "false";
// 长模式下的读盘：ATA PIO 读 LBA 33，与 BIOS 已经读到 0x20000 的那 512 字节逐字节比。
// 两条完全不同的路给出同样的字节才说明这一段对 —— 「读出来了」本身说明不了什么，
// 读错一个扇区也会读出一个结果。
const ata行 = /Yunooka: ata (same 512|differ at \d+|read failed)/.exec(读到);
const ata成 = ata行 !== null && ata行[1] === "same 512";
// 信箱：第二块盘、扇区 0、八个字节的魔数。三种读数分开，因为它们指向三种坏法 ——
// 没挂上或盘号不对是 no mailbox，挂上了但主机没写是 mailbox bad，只有 ok 才说明
// 「主机用普通文件写进去的那一行，客人机在读盘时认出来了」。
const 信行 = /Yunooka: (mailbox ok|mailbox bad|no mailbox)/.exec(读到);
const 信成 = 信行 !== null && 信行[1] === "mailbox ok";
// 光认出魔数还不够：那句话要真的被当成 shell 的输入。两行读数配合才说得出这件事 ——
// 只打 files 的答案，看不出它是信箱里的还是盘上的（盘上 cmd.txt 那份也是 files）。
// 上一趟红就是靠这一条：把信箱里的词换成 list，读到 shell> list 与 unknown command，
// 列目录的答案同时消失 —— 那才证明输入真的来自信箱。
const 源行 = /Yunooka: input from (mailbox|cmd\.txt)/.exec(读到);
const 源成 = 源行 !== null && 源行[1] === "mailbox";
// IDT：故意跑一条未定义指令（ud2），异常号要打出来是 6，而且处理器不能返回。
// 三件事都验：表装上了（idt ok），它真的被用上了（exception 6），处理器没有假装无事
// 发生（handler returned 不出现）—— 最后这一条是前提式的：没有 trap test 就算红，
// 否则「没出现」会被一个根本跑不到的路径白送。
const idt行 = /Yunooka: idt ok/.test(读到);
const 陷行 = /Yunooka: exception (\d+)/.exec(读到);
const 陷成 = idt行
  && 读到.includes("Yunooka: trap test")
  && 陷行 !== null && 陷行[1] === "6"
  && !读到.includes("Yunooka: handler returned");
// 键盘：主机每轮送一次 set 2 的 F 按下码（0x2B），客人机轮询 0x64 与 0x60 收到它。
// 判据要那个字节本身，不是「有没有收到」—— 收到的码若不对，说明端口读在别处，而
// 「收到一个数」这件事仍然成立，两者要分得开。
const 键行 = /Yunooka: key ([0-9A-F]+)|Yunooka: (no key)/.exec(读到);
// 集 1 的 x 是 0x2D。测试键不用 f：run_key_poll 用 keyboardputscancode 按下过 f 却
// 从没放开，VBox 会认为它一直按着，于是后面 keyboardputstring "f" 不产生新的按下 ——
// 而那条路正是要送 files 的。
const 键成 = 键行 !== null && 键行[1] === "000000000000002D";
// 交互式的那一行：客人机先说 shell ready，主机看到之后才把 files 加回车送进去。
// 判据要三件事连成一条链：ready 出现过、提示符与那一行接在它后面、目录真的列出来。
// 只查「有 hello.txt」会被前面从信箱读的那一次占便宜 —— 那一行也是 files。
const 活行 = /Yunooka: shell ready[\s\S]*?Yunooka: shell> files[\s\S]*?hello\.txt docs/.exec(读到);
const 活成 = 活行 !== null;
// repl 的交互那一半：输入一个名字，运行时求它的值。
// letters 是种子里第一个函数，返回一个 53 字符的串 —— 那个 53 不是打出来的常量，
// 是 exec 真的跑了它才有的。与盘上那份 repl.txt 的 512 区分开：一个是事先写好的名字，
// 一个是运行时打进去的名字。
const 求值活行 = /Yunooka: repl ready[\s\S]*?Yunooka: repl-live> letters[\s\S]*?string 53/.exec(读到);
const 求值活成 = 求值活行 !== null;
// 盘上的程序包：userland 的第一件 —— 一个程序从盘上的哪一份字节开始跑。
// 判据是那个 7：它只存在于 prog.hmtn 的那两条指令里，别处没有，所以「读到了 7」
// 就等于「那个包被读进来、入口被找到、指令流被跑过」。
const 程行 = /Yunooka: prog main -> (\d+)/.exec(读到);
const 程成 = 程行 !== null && 程行[1] === "7";
// 文件系统：超级块的版本、根目录扇区号、以及第一个条目的名字。名字是 build 按
// design/FS.txt 放进去的，所以这一条验的是「读得懂那份布局」，不是「读出了一行字」：
// 版本号与扇区号都来自超级块自己，而名字来自目录条目的 UTF-16 码元。
const fs行 = /Yunooka: fs ok v(\d+) root (\d+) first (\S+)/.exec(读到);
const fs成 = fs行 !== null && fs行[1] === "1" && fs行[2] === "1025" && fs行[3] === "hello.txt";
// 按路径打开：认盘符、跳过 α:/、在根目录里按名字找、把内容读出来。判据是内容本身 ——
// 这四环里任何一环错，读到的都不会是那二十二个字节。
const 打开行 = /Yunooka: open (\S+) -> (.+)/.exec(读到);
const 打开成 = 打开行 !== null && 打开行[1] === "hello.txt"
  && 打开行[2].trim() === "Yunooka filesystem ok";
// 两层：docs 目录里的 note.txt。这一条要的东西比上一条多一层 —— 先拿到目录的扇区，
// 再在那个扇区里找下一个名字。一层与两层在代码上看起来一样，只有真的走两次才分得开。
const 深行 = /Yunooka: open docs\/note\.txt -> (.+)/.exec(读到);
const 深成 = 深行 !== null && 深行[1].trim() === "Yunooka subdirectory ok";
// 三层那一行才是「路径被解析」的判据。两层在旧的写法里也能过 —— 那时是两个手写的
// 段名各占一个变量，三层就要再加一个。现在按斜杠切段，深度只是循环多转一圈。
const 更行 = /Yunooka: open docs\/sub\/deep\.txt -> (.+)/.exec(读到);
const 更成 = 更行 !== null && 更行[1].trim() === "Yunooka three levels ok";
// 第二块盘：同一个名字、同一段查找代码，读的却是另一块盘上的另一份字节。
// 判据必须是那段内容本身 —— 「打开成功了」两行都有，只有内容分得开盘。
// 「两块盘」这件事现在由「共享之后读得到 β 的内容」来证明：同一个名字 hello.txt，
// 主盘读到的是 filesystem ok，β 盘读到的是 second disk ok。
// 原来有一条专门验它的 run_fs_open4，加了边界之后它必然被挡住 —— 而挡住是对的。
const 二集 = [...读到.matchAll(/Yunooka: shared -> (.+)/g)].map((m) => m[1].trim());
const 二成 = 二集.length === 1 && 二集[0] === "Yunooka second disk ok";
// 边界真的有约束力：三次读数各分得开一种坏法。
//   家不同时读不到（不然边界是装饰）／同一家共享过的读到（不然它挡住自家人）
//   ／同一家没共享的读不到（不然共享位是装饰）。
// 第三行最要紧：一颗「只要同一家就放行」的实现，前两行都对。
const 阻成 = /Yunooka: read blocked by boundary/.test(读到);
const 秘成 = /Yunooka: secret blocked/.test(读到);
const 门成 = 阻成 && 二成 && 秘成;
// 像素层：往帧缓冲写两个已知字节、再读回来比。串口这一行只证明「能写能读」——
// 「屏幕上真的有」是截图那件事，而它是给人看的证据，不作自动判据（这台机器 headless，
// 屏幕上有没有东西，串口说不了话）。
const 像行 = /Yunooka: pixel ([0-9A-F]+) ([0-9A-F]+)/.exec(读到);
const 像成 = 像行 !== null && 像行[1] === "000000000000002F"
  && 像行[2] === "000000000000001C";
// 画线：一条从 (0,0) 到 (319,199) 的对角线，读回线上的两个点。两点都是线的颜色才说明
// 「这条线上真的有像素」—— 而那正是 Bresenham 与「按 x 采样」分得开的地方。
const 线行 = /Yunooka: line ([0-9A-F]+) ([0-9A-F]+)/.exec(读到);
const 线成 = 线行 !== null && 线行[1] === "000000000000002F"
  && 线行[2] === "000000000000002F";
// 写：造一个不存在的名字、写一段只有这里才有的字节、再按路径打开它。
// 判据是那段内容本身 —— 而且 files 的列表里也要多出这个名字，因为「目录里多了一条」
// 与「数据落对了地方」是两件事，两件都得成立。
const 写行 = /Yunooka: wrote -> (.+)/.exec(读到);
const 写成 = 写行 !== null && 写行[1].trim() === "Yunooka wrote this"
  && /hello\.txt docs cmd\.txt repl\.txt math\.txt prog\.hmtn new\.txt/.test(读到);
// 家庭组第一步：共享是目录条目上的一个位。走两遍，两遍都只该有一条 ——
// 「往清单里加一条」的实现走两遍会出现两个 docs，而那样第一次也是对的。
const 共集 = [...读到.matchAll(/Yunooka: shares ([^\r\n]*)/g)].map((m) => m[1].trim());
const 共成 = 共集.filter((x) => x === "docs dir").length === 2;
// 共享与边界见面：β 上的共享在「不是一家人」时被挡住、加入之后列得出来。
// 挡住的判据是那一行 not family，不是「没有条目」—— 一块盘上本来就可能一条共享都没有，
// 那种空与这种空看起来一样。
const 家共行 = /Yunooka: shares 0000000011111111 not family/.test(读到);
const 家共列 = /Yunooka: shares 00000000594B4E52 hello\.txt file/.test(读到);
const 家共成 = 家共行 && 家共列;
// 网卡：PCI 配置空间里 vendor 与 device 两个数由硬件自己给出。8086:100E 是 Intel E1000，
// 也就是 --nictype1 指定的那一块。读对它，说明「网卡在这台机器上，而这条总线读得通」。
const 网行 = /Yunooka: pci dev (\d+) ([0-9A-F]+)/g;
const 网集 = [...读到.matchAll(/Yunooka: pci dev (\d+) ([0-9A-F]+)/g)].map((m) => [m[1], m[2]]);
const 网成 = 网集.some(([dev, id]) => id.endsWith("100E8086"));
// 家庭组的边界：两块盘超块里的家 ID。判据要两个数都读对、而且结论是不一家人 ——
// 两块盘故意不同（build 与 run.mjs 各写一个），否则「比较过」与「没比较」分不开。
const 家行 = /Yunooka: home ([0-9A-F]+)/.exec(读到);
const 贝行 = /Yunooka: beta ([0-9A-F]+) (family|not family)/.exec(读到);
const 家成 = 家行 !== null && 家行[1] === "00000000594B4E52"
  && 贝行 !== null && 贝行[1] === "0000000011111111" && 贝行[2] === "not family";
// 加入：把主盘的家写进第二块盘。判据是同一个比较的结论翻过来 ——
// 同一段代码、同一个读法，只有盘上的数变了。这比「又打印了一次 family」结实得多。
const 贝集 = [...读到.matchAll(/Yunooka: beta ([0-9A-F]+) (family|not family)/g)]
  .map((m) => [m[1], m[2]]);
const 加成 = 贝集.length === 2
  && 贝集[0][0] === "0000000011111111" && 贝集[0][1] === "not family"
  && 贝集[1][0] === "00000000594B4E52" && 贝集[1][1] === "family";
// shell 的解释那一半：盘上的 cmd.txt 里写着一行 files，它要认出来并回答。
// 判据是三步都在：提示符打出来、命令被回显、根目录的三个名字按顺序列出来。
// 只验提示符的话，一个只会打字的实现照样能过。
const 壳行 = /Yunooka: shell> files/.exec(读到);
const 列行 = /hello\.txt docs cmd\.txt/.exec(读到);
const 壳成 = 壳行 !== null && 列行 !== null;
// repl 的前半：盘上 repl.txt 里是一个函数名（块长），按名字找它、跑它、把值打出来。
// 判据是那个数：512 只有真的按名字找到了第二个定义、并且跑出它的常量才拿得到。
// 名字本身在串口上打不出来（UTF-16 的汉字），所以那一行打的是码元数 —— 2。
const 求值行 = /Yunooka: repl> 2 units -> (\d+)/.exec(读到);
const 重求成 = 求值行 !== null && 求值行[1] === "512";
// 「除」这条操作码自己的判据：一段四条的迷你流（常量 π、常量 2、除、返回）。
// run_math 里的平均也走同一份 div_f64，但那证明不了 exec 的分发表认操作码 6 ——
// 分发表漏了这一条，average 那一行照样是绿的。六位小数，1.5707963267948966 舍成 1.570796。
const 除行 = /Yunooka: div -> ([0-9.]+)/.exec(读到);
const 除成 = 除行 !== null && 除行[1] === "1.570796";
// 数学控制台的第一半：盘上的 math.txt 是 average: 1,4,19,40,55,29,30.4,6π,24e。
// 两行读数分开记，因为一条判据同时压五件事，错了分不清是谁错：和对而商错是除法或
// 个数的问题，和错而商对是十进制解析或常量的问题。真值在 node 那一侧核过。
const 和行 = /Yunooka: math> sum -> ([0-9.]+)/.exec(读到);
const 均行 = /Yunooka: math> average -> ([0-9.]+)/.exec(读到);
const 数学成 = 和行 !== null && 和行[1] === "262.488320"
  && 均行 !== null && 均行[1] === "29.165369";
// 表达式这一半：y=1/x、f(x)=1/x、f x=1/x 三种左边都要认出来，而且认成同一样东西。
// 判据落在「左边原样」与「右边有没有 x」两处 —— 前者分得开 f(x) 与 f x，后者是
// 「能不能画」的判据。算与画都还没有，所以这三行只证明「读得懂」，不证明「算得出」。
const 曲线集 = [...读到.matchAll(/Yunooka: curve ([^\r\n]*?) -> (has x|no x)/g)].map((m) => [m[1], m[2]]);
const 曲线成 = 曲线集.length === 3
  && 曲线集[0][0] === "y" && 曲线集[0][1] === "has x"
  && 曲线集[1][0] === "f(x)" && 曲线集[1][1] === "has x"
  && 曲线集[2][0] === "f x" && 曲线集[2][1] === "has x";
console.log("第一个函数 " + (函数行
  ? 函数行[1] + "（参 " + 函数行[2] + "、槽 " + 函数行[3] + "、指令 " + 函数行[4] + "）"
  : "(没读出来)"));
console.log("指令流    " + (操作码行集.length
  ? 操作码行集.map((n, i) => n + "=" + (操作码名集[i] || "表里没有这个号")).join("  ")
  : "(没读出来)"));
console.log("求值结果  " + (结果行
  ? 结果行[1] + (结果行[2] ? " " + 结果行[2] + " 个字符" : "")
  : "(没算出来)"));
console.log("跳转      " + (跳转结果.length
  ? 跳转结果.map((n) => "fn116 -> " + n).join("  ") + (跳转成 ? "  —— 真时走一条、假时走另一条" : "  —— 不对：应当是 2147483648 与 0")
  : "(没跑)"));
console.log("调用      " + (调用行
  ? "块长 -> " + 调用行[1] + (调用成 ? "  —— 帧进去又出来了" : "  —— 不对：应当是 512")
  : "(没跑)"));
console.log("按名字    " + (按名行 ? "byname -> " + 按名行[1] : "byname -> (没找到)")
  + "  " + (先手行 ? "first -> " + 先手行[1] : "first -> (没找到)")
  + (按名成 ? "  —— 走完整张表留最后那个，先撞上的那个是另一个数"
    : "  —— 不对：应当是 byname 512 与 first 256"));
console.log("内建      " + (数字行 ? "is_digit('7') -> " + 数字行[1] : "is_digit('7') -> (没跑)")
  + "  " + (字母行 ? "is_digit('a') -> " + 字母行[1] : "is_digit('a') -> (没跑)")
  + (数字成 ? "  —— 十轮递归、索引、len、加，全对才给得出这两行"
    : "  —— 不对：应当是 '7' 真、'a' 假"));
console.log("读盘      " + (ata行 ? "ATA -> " + ata行[1] : "ATA -> (没跑)")
  + (ata成 ? "  —— 与 BIOS 读进来的那 512 字节逐字节相同"
    : "  —— 不对：应当读到同一份字节"));
console.log("信箱      " + (信行 ? 信行[1] : "(没跑到)")
  + "  " + (源行 ? "input from " + 源行[1] : "input from (没跑到)")
  + (信成 && 源成 ? "  —— 主机写进裸盘的那一行，被读出来、并且当成了 shell 的输入"
    : "  —— 不对：应当是 mailbox ok 且 input from mailbox"));
console.log("异常      " + (idt行 ? "idt ok" : "idt (没装)")
  + "  " + (陷行 ? "exception " + 陷行[1] : "exception (没抓到)")
  + (陷成 ? "  —— ud2 触发的 #UD 被接住了，处理者没有返回"
    : "  —— 不对：应当是 exception 6，且没有 handler returned"));
console.log("键盘      " + (键行 ? (键行[1] ? "key " + 键行[1] : "no key") : "(没跑到)")
  + (键成 ? "  —— 主机注入的那一个扫描码，客人机从 0x60 读到了"
    : "  —— 不对：应当是 key 000000000000002D"));
console.log("交互      " + (活行 ? "shell ready -> shell> files" : "(没跑到)")
  + (活成 ? "  —— 键是运行时送进去的：先说 ready，主机再送 files 加回车，然后它照做了"
    : "  —— 不对：应当是 shell ready 之后接上 shell> files 与目录列表"));
console.log("求值活    " + (求值活行 ? "repl ready -> repl-live> letters -> string 53" : "(没跑到)")
  + (求值活成 ? "  —— 打进去的名字被找到、被跑过；那个 53 是 exec 算出来的"
    : "  —— 不对：应当是 repl ready 之后接上 repl-live> letters 与 string 53"));
console.log("程序      " + (程行 ? "prog main -> " + 程行[1] : "(没跑到)")
  + (程成 ? "  —— 包从盘上读进来、main 被找到、跑出了 7；7 只存在于那个包里"
    : "  —— 不对：应当是 prog main -> 7"));
console.log("文件系统  " + (fs行
  ? "v" + fs行[1] + "，根目录第 " + fs行[2] + " 号扇区，第一个名字 " + fs行[3]
  : "(没读出来)")
  + (fs成 ? "  —— 名字与扇区号都来自盘上那份布局"
    : "  —— 不对：应当是 v1、根目录 1025、第一个名字 hello.txt"));
console.log("打开      " + (打开行 ? 打开行[1] + " -> " + 打开行[2].trim() : "(没打开)")
  + (打开成 ? "  —— 盘符、分隔、查找、读盘，四环全对才给得出这一行"
    : "  —— 不对：应当读到 Yunooka filesystem ok"));
console.log("两层      " + (深行 ? "docs/note.txt -> " + 深行[1].trim() : "(没走到)")
  + (深成 ? "  —— 先拿到目录的扇区，再在它里面找下一个名字"
    : "  —— 不对：应当读到 Yunooka subdirectory ok"));
console.log("三层      " + (更行 ? "docs/sub/deep.txt -> " + 更行[1].trim() : "(没走到)")
  + (更成 ? "  —— 按斜杠逐段查，深度只是循环转了几圈"
    : "  —— 不对：应当读到 Yunooka three levels ok"));
console.log("第二块盘  " + (二集.length ? 二集.join("  /  ") : "(没走到)")
  + (二成 ? "  —— 同一个名字，共享之后读到的是 β 的那一份：盘符决定读哪块盘"
    : "  —— 不对：应当读到 Yunooka second disk ok"));
console.log("写        " + (写行 ? "wrote -> " + 写行[1].trim() : "(没跑到)")
  + (写成 ? "  —— 空闲扇区的账、目录条目、数据落点三样都对，再按路径读回来"
    : "  —— 不对：应当读到 Yunooka wrote this，且 files 里有 new.txt"));
console.log("共享      " + (共集.length ? 共集.join("  /  ") : "(没跑到)")
  + (共成 ? "  —— 两次都只有一条 docs dir：标记是改一个位，不是往清单里加一条"
    : "  —— 不对：应当是两行 shares，各一条 docs dir"));
console.log("网卡      " + (网集.length ? 网集.map(([d, i]) => d + ":" + i.slice(-8)).join("  ") : "(没跑到)")
  + (网成 ? "  —— 8086:100E 在 3 号槽上；网卡在，而且配置空间读得通"
    : "  —— 不对：应当看到 100E8086"));
console.log("边界      " + (家行 ? "home " + 家行[1] : "home (没跑到)")
  + "  " + (贝行 ? "beta " + 贝行[1] + " " + 贝行[2] : "beta (没跑到)")
  + (家成 ? "  —— 两个家 ID 都读对了，而且比较的结论是不一家人"
    : "  —— 不对：应当是 home 594B4E52 与 beta 11111111 not family"));
console.log("加入      " + (贝集.length ? 贝集.map(([i, v]) => i + " " + v).join("  /  ") : "(没跑到)")
  + (加成 ? "  —— 同一个比较，写进那个数之后结论翻过来了"
    : "  —— 不对：应当先 not family、后 family"));
console.log("共享见面  " + (家共行 ? "挡住过" : "(没挡住)") + "  " + (家共列 ? "列出来了" : "(没列出来)")
  + (家共成 ? "  —— 共享与边界接上了：同一块盘，加入之前一条不列，加入之后列得出来"
    : "  —— 不对：应当先 not family 挡住、加入后列出 hello.txt file"));
console.log("门        " + (阻成 ? "挡住过" : "(没挡住)") + "  " + (二成 ? "共享的读到" : "(没读到)")
  + "  " + (秘成 ? "没共享的挡住" : "(漏了)")
  + (门成 ? "  —— 边界有约束力：不是一家人读不到，同一家没共享也读不到"
    : "  —— 不对：三次读数应当依次是挡住、读到、挡住"));
console.log("像素      " + (像行 ? "写回 " + 像行[1].slice(-2) + " " + 像行[2].slice(-2) : "(没跑到)")
  + (像成 ? "  —— 帧缓冲能写能读；屏幕上的那点是截图里看见的，不作自动判据"
    : "  —— 不对：应当读回 2F 与 1C"));
console.log("画线      " + (线行 ? "线上两点 " + 线行[1].slice(-2) + " " + 线行[2].slice(-2) : "(没跑到)")
  + (线成 ? "  —— (0,0) 与 x=160 处都是线的颜色：一条连续的对角线"
    : "  —— 不对：两点都该是 2F"));
console.log("壳        " + (壳行 ? "shell> files" : "(没跑到)")
  + (列行 ? "  → " + 列行[0] : "  → (没列出来)")
  + (壳成 ? "  —— 那一行认得出来、回答得出（来源见上一行）"
    : "  —— 不对：应当认出 files 并列出 hello.txt docs cmd.txt"));
console.log("求值      " + (求值行 ? "repl> 2 units -> " + 求值行[1] : "(没跑到)")
  + (重求成 ? "  —— 按名字找到第二个定义，跑出它的常量"
    : "  —— 不对：应当是 512"));
console.log("除法      " + (除行 ? "div -> " + 除行[1] : "(没跑到)")
  + (除成 ? "  —— 操作码 6 在分发表里，并且 π 的八字节位模式读对了"
    : "  —— 不对：应当是 1.570796"));
console.log("数学      " + (和行 ? "sum -> " + 和行[1] : "sum -> (没跑到)")
  + "  " + (均行 ? "average -> " + 均行[1] : "average -> (没跑到)")
  + (数学成 ? "  —— 十进制、π、e、除法、六位小数，五件事一起对才给得出这两行"
    : "  —— 不对：应当是 sum 262.488320 与 average 29.165369"));
console.log("表达式    " + (曲线集.length
  ? 曲线集.map(([名, 判]) => 名 + " -> " + 判).join("  ")
  : "(没跑到)")
  + (曲线成 ? "  —— 三种写法认成同一样东西；括号与空格是给人看的"
    : "  —— 不对：应当是 y、f(x)、f x 三行，右边都含 x"));
// 结构这一条只在带种子时算：没有种子时机器不读种子头，那是对的，不该因此变红。
const 有种子 = 读到.includes("Yunooka: seed ok");
const 求值成 = 结果行 !== null && 结果行[1] === "string" && 结果行[2] === "53";
const 结构成 = 有种子
  ? 函数行 !== null
    && 函数行[1] === "letters"
    && 操作码行集.length === 4
    && 操作码行集.every((n) => n >= 0 && n < 操作码表.length)
    && 操作码行集[0] === 5
    && 求值成
    && 跳转成
    && 调用成
    && 按名成
    && 数字成
    && ata成
    && 信成
    && 源成
    && 陷成
    && 键成
    && 活成
    && 求值活成
    && 程成
    && fs成
    && 打开成
    && 深成
    && 更成
    && 二成
    && 写成
    && 共成
    && 网成
    && 家成
    && 加成
    && 家共成
    && 门成
    && 像成
    && 线成
    && 壳成
    && 重求成
    && 除成
    && 数学成
    && 曲线成
    && 求值成
  : true;
// 成败三条合成一条：缺行、分配、结构。放在这里算，因为它要用到上面那个结构成 ——
// 这也是第一次把它写在前面时的报错原因（Cannot access before initialization）。
const 成了 = 缺.length === 0 && 分配成 && 结构成;
console.log("分配      " + (地址批.length ? 地址批.join("  ") : "(没有)")
  + (分配成 ? "  —— 三条，从 0x400000 起、按 16 对齐、逐块递增"
    : "  —— 不对：应当是三条、首条 0000000000400000、末位为零、递增"));
console.log("截屏      " + 截屏);
console.log("");
console.log(成了
  ? "五行都在，链条是五段：引导、第二段、保护模式、长模式、堆。"
  : 缺.length
    ? "缺：" + 缺.join("、") + " —— 断在那一行前面。"
    // 行都在而仍然红，是「结构不对」：某个数不是该有的那个。上一次红就是这一种 ——
    // 把 first 的期望临时写成 257，串口一行不少，红在数字上。这两种红要说成两件事，
    // 否则「缺：」后面跟一个空名单，读起来像工具坏了。
    : "行都在，但结构不对 —— 上面标着「不对」的那一行就是。");

// 红了就把这一趟的完整输出留下来。
//
// 偶发失败最贵的不是它本身，而是撞上之后没有证据 —— 上一次红的时候只看到「exit=1」，
// 而下面那个「不对：……」的名单当场就随进程一起没了，于是只能重跑；重跑五次全过，
// 什么也没学到。留下一份，下一次撞上时至少知道自己错过了哪一条。
if (!成了) {
  const 落 = path.join(建, "failed-run.txt");
  fs.writeFileSync(落, 读到, "utf8");
  console.log("这一趟红了，完整串口输出留在 " + 落);
}

if (!留机) {
  vbox(["controlvm", 机名, "poweroff"]);
  console.log("机器已关（--keep 可以留着它，用 GUI 打开看）。");
}
process.exit(成了 ? 0 : 1);
