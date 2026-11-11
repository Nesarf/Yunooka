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
import crypto from "node:crypto";
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
  "Yunooka: calc ready",
  "Yunooka: scan eicar -> FOUND",
  "Yunooka: rules eicar.txt = eicar",
  "Yunooka: plot ",
  "Yunooka: index count ",
  "Yunooka: window ",
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

// 这一趟跑的是哪一种处境。放在这里而不是判据区，因为判据区的前面几条（文件系统的
// 那一条）就要用到它 —— 而 JS 的 const 不提升。
//
// 三种处境的来源：--drop 让盘上少一条（那是 build 的一半），而信箱里有没有补丁由
// 这一侧决定（--drop 有、--drop-nopatch 没有）。两个参数互斥。
const 补丁模式 = process.argv.includes("--drop");
const 无补丁模式 = process.argv.includes("--drop-nopatch");
// --forge：盘上那份改了，而 core.bin 也跟着重算对了 —— 于是 FNV-1a 那一层是绿的。
// 它是 OnlySign 那一条唯一的验红手段：不造这个处境，第二环的判据就与第一环完全重复，
// 而那两环回答的不是同一个问题。
const 伪造模式 = process.argv.includes("--forge");
if (补丁模式 && 无补丁模式) 做不了("--drop 与 --drop-nopatch 是两种处境，不能同时给");

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
const 信内容 = "echo hello world\n";
const 信字节 = Buffer.from(信内容, "latin1");
const 信格 = Buffer.alloc(512);
信格.write("YUNOMBX\0", 0, "latin1");
信格.writeUInt16LE(1, 8);           // 版本
信格.writeUInt16LE(0, 10);          // 留白：对齐用。曾经借它当 ATA 的开关，现在不用了
信格.writeUInt32LE(信字节.length, 12);
信格.writeUInt32LE(1, 16);          // 序列号：每改一次加一，将来客人机靠它认新
信字节.copy(信格, 32);

// 补丁包：信箱的第 1 到第 3 个扇区。补完界面唯一的修补来源，而宿主是唯一写得了它的
// 一侧 —— 客人机只读，这本身就是那一块的一半证据。
//
// --drop 那一趟里 build 已经把被落下的那一份装成 YUNOPAT 写在 build/patch-drop.bin
// （内容与清单里算哈希用的是同一份字节）；这一趟只负责搬上信箱。
//
// --drop-nopatch 那一趟把它清成零。「没有补丁」必须由盘上真的没有字节来说 ——
// 由一个变量记着的话，判据验的就是那个变量，而不是这条通道。
const 补丁路径 = path.join(建, "patch-drop.bin");
const 不给补丁 = process.argv.includes("--drop-nopatch");
const 补丁 = (!不给补丁 && fs.existsSync(补丁路径)) ? fs.readFileSync(补丁路径) : Buffer.alloc(0);
const 补丁区 = Buffer.alloc(3 * 512);
if (补丁.length > 补丁区.length)
  做不了("补丁包 " + 补丁.length + " 字节，超过信箱给它的三个扇区（1536）");
补丁.copy(补丁区, 0);

const 信fd = fs.openSync(信箱, "r+");
try {
  fs.writeSync(信fd, 信格, 0, 512, 0);
  fs.writeSync(信fd, 补丁区, 0, 补丁区.length, 512);
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

// ---- 二·七、SATA（AHCI）----
//
// 盘健康那一条要一条不是 0x1F* 的通道，而控制器与盘都是配置：控制器是 storagectl，
// 盘是一块 1 MB 的 RAW。两样都只在缺的时候造与挂 —— 造盘会注册一个 UUID，重建会让
// 登记里那份失效（信箱那块踩过一次）。
//
// 这一块与别的挂载有一处不同：SATA 的槽位名是 SATA-0-0，而控制器本身也要先存在。
// 所以顺序是「控制器、再盘」，中间重新读一次机器信息 —— 用加控制器之前读到的那份
// 去找 SATA-0-0，会永远找不着，而症状是「挂不上」而不是「控制器没加」。
//
// 盘挂 port 0，引导链完全不经过它：引导盘还在 IDE 上。所以这一块的失败不该影响
// 任何别的判据，只是 AHCI 那几行会变成 none。
const 阿希 = path.join(建, "ahci.raw");
if (!fs.existsSync(阿希)) {
  const 造 = vbox(["createmedium", "disk", "--filename", 阿希, "--size", "1",
    "--format", "RAW", "--variant", "Fixed"]);
  if (造.status !== 0) 做不了("AHCI 盘造不出来：" + String(造.stderr || "").slice(0, 200));
}
const 机器信息3 = String(vbox(["showvminfo", 机名, "--machinereadable"]).stdout || "");
// 键名不带引号（storagecontrollername1="SATA"），而槽位名带（"SATA-0-0"=...）——
// 这两处的形状不一样，第一次写成带引号的版本，于是它认为控制器不存在、又去加一次，
// 而 VBox 拒绝重名的控制器，整个 run 在准备阶段就退出了（退出码 2）。
if (!/storagecontrollername\d+="SATA"/.test(机器信息3)) {
  const 加 = vbox(["storagectl", 机名, "--name", "SATA", "--add", "sata",
    "--controller", "IntelAhci", "--portcount", "2", "--bootable", "off"]);
  if (加.status !== 0) 做不了("SATA 控制器加不上：" + String(加.stderr || "").slice(0, 200));
}
const 机器信息4 = String(vbox(["showvminfo", 机名, "--machinereadable"]).stdout || "");
const 阿槽 = /"SATA-0-0"="([^"]*)"/.exec(机器信息4);
if (!阿槽 || 阿槽[1] === "none") {
  const 挂 = vbox(["storageattach", 机名, "--storagectl", "SATA", "--port", "0", "--device", "0",
    "--type", "hdd", "--medium", 阿希, "--mtype", "normal"]);
  if (挂.status !== 0) 做不了("AHCI 盘挂不上去：" + String(挂.stderr || "").slice(0, 200));
}

// ---- 二·八、NVMe ----
//
// 盘健康那条路最后走的是这里。AHCI 的控制器还挂着，只是它的 port 侧对 OS 不报设备
// （六个 PxSSTS 全零，见 design/AHCI.txt）；而 NVMe 这个控制器是活的：Identify
// Controller 答了型号、Identify Namespace 答了容量。
//
// 先说芯片组。这一条与别的配置不一样：ich9 是为了 AHCI 那次实验改的，而 AHCI 后来判死
// 了 —— 可 NVMe 的 MMIO 只在 ich9 上解码。piix3 上它的 BAR0 报 0xF0808000，而那个地址
// 读回来是零；同一个 2 MB 页在 piix3 上还能读出 0x18920F（那是未分配内存的残留，
// 不是设备）。所以一个为了 A 做的改动，最后 B 需要它。
// 「手动改在 VM 上的东西会丢」这件事这一轮已经付过一次学费，所以它写在这里。
const 机器信息7 = String(vbox(["showvminfo", 机名, "--machinereadable"]).stdout || "");
if (!/chipset="ich9"/.test(机器信息7)) {
  const 换芯 = vbox(["modifyvm", 机名, "--chipset", "ich9"]);
  if (换芯.status !== 0) 做不了("芯片组改不到 ich9：" + String(换芯.stderr || "").slice(0, 200));
}

// 盘的大小是一个数，两处用它、语义不同：
//   这里 —— 我给 VBox 的配置，造盘时 --size 就是这个；
//   判据那边 —— 我认为这块盘应当有多大。
// 而盘自己报的块数是第三个来源。三个对上才算数，而「盘报的对不对」只有第三个能回答。
const NVMe盘大小 = 2 * 1024 * 1024;
const NVMe盘 = path.join(建, "nvme.raw");
if (!fs.existsSync(NVMe盘)) {
  const 造 = vbox(["createmedium", "disk", "--filename", NVMe盘, "--size",
    String(NVMe盘大小 / 1024 / 1024), "--format", "RAW", "--variant", "Fixed"]);
  if (造.status !== 0) 做不了("NVMe 盘造不出来：" + String(造.stderr || "").slice(0, 200));
}
const 机器信息5 = String(vbox(["showvminfo", 机名, "--machinereadable"]).stdout || "");
if (!/storagecontrollername\d+="NVME"/.test(机器信息5)) {
  const 加 = vbox(["storagectl", 机名, "--name", "NVME", "--add", "pcie",
    "--controller", "NVMe", "--portcount", "1"]);
  if (加.status !== 0) 做不了("NVMe 控制器加不上：" + String(加.stderr || "").slice(0, 200));
}
const 机器信息6 = String(vbox(["showvminfo", 机名, "--machinereadable"]).stdout || "");
const 奈槽 = /"NVME-0-0"="([^"]*)"/.exec(机器信息6);
if (!奈槽 || 奈槽[1] === "none") {
  const 挂 = vbox(["storageattach", 机名, "--storagectl", "NVME", "--port", "0", "--device", "0",
    "--type", "hdd", "--medium", NVMe盘]);
  if (挂.status !== 0) 做不了("NVMe 盘挂不上去：" + String(挂.stderr || "").slice(0, 200));
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
const 送码 = (码) => { vbox(["controlvm", 机名, "keyboardputscancode", 码]); 睡(40); };
const 送一行 = (文字) => {
  for (const 字 of 文字) {
    // 字母数字走 putstring；符号要自己按 Shift。
    // 实测：送「1+1=x」回显成「11」—— 数字到了，而 + 与 = 都丢了。
    // 集 1 里 = 是 0x0D，+ 是 Shift(0x2A) 加 0x0D。
    //
    // 而且四个码不能一次送：那样整个序列会被挤掉（与「整行一次送丢头一个」同族）。
    // 一个码一次，中间留四十毫秒，8042 才跟得上。
    if (字 === "+") { 送码("2a"); 送码("0d"); 送码("8d"); 送码("aa"); }
    else if (字 === "=") { 送码("0d"); 送码("8d"); }
    else { vbox(["controlvm", 机名, "keyboardputstring", 字]); 睡(60); }
  }
  睡(100);
  // 回车也要送放开码（集 1：按下 1C、放开 9C）。只送按下时 8042 认为回车一直按着，
  // 重复码会追到下一条命令里 —— 症状是第二条命令收到一个空行。
  vbox(["controlvm", 机名, "keyboardputscancode", "1c", "9c"]);
};
let 读到 = "";
let 送过整行 = false;
let 送过名字 = false;
let 送过算式 = false;
for (let i = 0; i < 40; i++) {
  睡(500);
  if (!送过整行) {
    if (!读到.includes("Yunooka: key ") && !读到.includes("Yunooka: no key")) {
      // 按下与放开要成对送。只送按下码的话 VBox 认为那个键一直按着，它的重复码会漏进
      // 下一条正在等键的窗口 —— 已实测：算数那一条收到的是「x1+1」，于是 1+1 算出 0。
      // 这跟当初把测试键从 f 换成 x 是同一个坑：换了键，没换「不放开」这件事。
      // 放开码是按下码或上 0x80，0x2D 的放开码是 0xAD。
      vbox(["controlvm", 机名, "keyboardputscancode", "2d", "ad"]);
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
    // 第三条要靠第三条握手：算数那一行也在等键。
    // 只送「1+1」不送「=x」：实测符号后面跟一个字母时那个字母到不了客人机
    //（回显是「1+1=」而 x 丢了），原因没查清。算的那半不依赖它，所以先钉住算。
    if (!送过算式 && 读到.includes("Yunooka: calc ready")) {
      送一行("1+1");
      送过算式 = true;
    }
    const 步数 = (读到.match(/Yunooka: op /g) || []).length;
    const 结果数 = (读到.match(/Yunooka: fn116 -> /g) || []).length;
    const 按名数 = (读到.match(/Yunooka: byname/g) || []).length;
    // 收手的条件里要有「交互那两行也走完了」：只等 ready 会在这儿就断电，而键刚送出去、
    // 客人机还没处理。那样看到的是一行 ready 加一条空白 —— 与「键没送到」一模一样。
    const 交互完 = /Yunooka: shell ready[\s\S]*?Yunooka: shell> files/.test(读到)
      && /Yunooka: repl ready[\s\S]*?Yunooka: repl-live> letters/.test(读到)
      && /Yunooka: calc ready[\s\S]*?=2\.000000/.test(读到);
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
const 活行 = (补丁模式
  // 补丁那一趟：修好的 hello.txt 排在目录末尾，所以列出来的第一个名字是 docs。
  // 这里要证明的仍是「ready 之后那一行被认出来、并且整份目录被列出来」，
  // 只是形状换了 —— 顺序从来不是语义，名字才是。
  ? /Yunooka: shell ready[\s\S]*?Yunooka: shell> files[\s\S]*?docs cmd\.txt/
  : /Yunooka: shell ready[\s\S]*?Yunooka: shell> files[\s\S]*?hello\.txt docs/).exec(读到);
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

// 解释器真的能算。
//
// 上面那条 prog main -> 7 是常量返回：它证明包里的字节被读到了、函数被找到了、返回值
// 交出来了，但它证明不了「解释器会算」—— 一个只会返回常量的实现同样能过那一关。
//
// 这一条要的是 40 + 2 得 42，而 42 在这个仓库里没有别处出现过：它不可能来自宿主里写死
// 的数，只能来自包里的那两条常量与一次 add。
const 求和行 = /Yunooka: prog sum -> (\d+)/.exec(读到);
const 求和成 = 求和行 !== null && 求和行[1] === "42";

// 一个包问一份文件多大：slurp 读进来，len 量出来。
//
// 前几条都不要这个数 —— 执行、算术、把内容打出去，三样都能在不知道大小的情况下做到。
// 而编译器知道不了：它读源文件之前得先知道读进来多少。
//
// 判据是 24，也就是 docs/sub/deep.txt 的字节数。它在这一趟里的来历只有一条：包里的
// slurp 读到了那份文件、len 量到了它。宿主没有把这个数交给包。
const 尺行 = /Yunooka: prog size -> (\d+)/.exec(读到);
const 尺成 = 尺行 !== null && 尺行[1] === "24";

// 目录写满：该拒绝，而拒绝不许吃掉邻居。
//
// 三条一起算：成功数加拒绝数等于四十（少一条就是「既没成也没拒」）、拒绝真的来了
// （四十次全成说明上界没生效），以及邻居还在 —— 第三半在串口里是另一行
// （dirfull ate docs），它一旦出现，上面那个正则就匹配不到，于是这一条红。
// 一个判据覆盖两半，因为它们坏在一起才算说清：写满了，而写满没有伤到别人。
// 包往文件系统里放东西，再自己读回来。
//
// 判据两半，缺一不可：包读回来的那一行字出现在串口上（写进去的字节被读回来了），
// 以及宿主独立查到的目录条目带着一个非零扇区（目录里真的有那一条）。
// 只验第一半的话，一个「写进自己的缓冲、再从缓冲读回来」的实现照样过。
const 存行 = /Yunooka: save docs\/inner\.txt ([0-9A-F]+) (\d+)/.exec(读到);
const 存成 = 存行 !== null && !/^0+$/.test(存行[1]) && Number(存行[2]) > 0
  && 读到.includes("Yunooka wrote from a package");
// 包问「这一层有什么」。
//
// docs 里四份，名字之间一个空格、末尾也一个：
//   note.txt（8）sub（3）myon.hmtn（9）inner.txt（9），每份一个空格 -> 8+1+3+1+9+1+9+1 = 33
//
// 四份而不是三份，是因为这一条排在 run_save_test 之后 —— 那时 save 已经往 docs 里
// 写了一份 inner.txt。判据的数要与它跑的那一刻一致；上一版写 23，是 save 之前的样子。
// 那个错本身也有用：它证明 list 真的在看当时的目录，而不是背下来的清单。
//
// 钉长度而不是条数，是因为长度同时管住了顺序与分隔符；只数条数的话，
// 四份名字拼反了、或者少一个空格，都照样过。
const 列行2 = /Yunooka: prog list -> (\d+)/.exec(读到);
const 列成2 = 列行2 !== null && 列行2[1] === "33";
// 根目录满了之后，docs 仍然写得进去。
//
// 上一轮修的那个 bug 是「目录条目区没有边界，写越界吃掉了隔壁目录」。修法是给写到
// 目录自己的页之外就拒绝。而这一条验的是那条修法的另一面：拒绝只该发生在满的那一个
// 目录上，不该是一个全局状态。
const 晚行 = /Yunooka: dirfull docs ok ([0-9A-F]+) (\d+)/.exec(读到);
const 晚成 = 晚行 !== null && !/^0+$/.test(晚行[1]) && Number(晚行[2]) > 0;
const 满行 = /Yunooka: dirfull wrote (\d+) refused (\d+)/.exec(读到);
const 满成 = 满行 !== null
  && Number(满行[1]) + Number(满行[2]) === 40
  && Number(满行[2]) > 0;

// 一个包画一个窗口。
//
// 三个采样点各在一个区里：标题栏 0x1C、内容区 0x0F、底色 0x1F。三层矩形按顺序落下，
// 后画的盖住先画的 —— 所以这一条同时证明三件事：三个矩形都真的画了、顺序对、而且
// 偏移对（错一格就会读到相邻那一层的颜色）。
//
// 它比 rect 那条强：rect 只画一个矩形，一个「永远画同一个矩形」的实现也能过。而这里
// 三个不同的矩形落在三个不同的位置，颜色还得各不相同。
const 窗口行 = /^Yunooka: win px ([0-9A-F]{16}) ([0-9A-F]{16}) ([0-9A-F]{16})$/m.exec(读到);
const 窗口成 = 窗口行 !== null
  && 窗口行[1] === "000000000000001C"
  && 窗口行[2] === "000000000000000F"
  && 窗口行[3] === "000000000000001F";
// 文件系统：超级块的版本、根目录扇区号、以及第一个条目的名字。名字是 build 按
// design/FS.txt 放进去的，所以这一条验的是「读得懂那份布局」，不是「读出了一行字」：
// 版本号与扇区号都来自超级块自己，而名字来自目录条目的 UTF-16 码元。
const fs行 = /Yunooka: fs ok v(\d+) root (\d+) first (\S+)/.exec(读到);
// 第一条名字是盘上布局的证据。补丁那一趟是例外：修好的 hello.txt 由 fs_write_file
// 追加到目录末尾，于是第一条成了 docs —— 那是「追加」这个动作的产物，不是布局错了。
// 所以补丁模式只要求版本与根目录号（两者都来自超块，与修补无关），名字那一半交给
// 「壳」那一行按「三个名字都在」来验。
const fs头成 = fs行 !== null && fs行[1] === "1" && fs行[2] === "1025";
const fs成 = fs头成 && fs行[3] === "hello.txt";
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
// 会算数：送「1+1」进去，等它打出 2.000000。那个 2 不是常量，是 calc_expr 走完两级
// 求值的结果 —— 少一样（解析、加法、打印）都给不出来。名字那半（=x）还没通，见下面那一行注释。
const 算行 = /Yunooka: calc ready[\s\S]*?=([0-9.]+)/.exec(读到);
const 算成 = 算行 !== null && 算行[1] === "2.000000";
// 签名匹配：一条规则、两个文件。两条判据都要 —— 一个永远报 FOUND 的实现过第一条，
// 一个永远报 clean 的过第二条，只有两条一起才分得开口。
const 扫行 = /Yunooka: scan eicar -> FOUND/.test(读到);
const 净行 = /Yunooka: scan clean -> clean/.test(读到);
const 扫成 = 扫行 && 净行;
// 规则从盘上读：换掉那个文件行为就跟着变，所以这条与上面那条分得开 ——
// 上面证明「子串搜索认得这 68 字节」，这条证明「规则是数据」。
const 规行 = /Yunooka: rules eicar\.txt = eicar/.test(读到);
const 规净 = /Yunooka: rules clean\.txt = none/.test(读到);
const 规成 = 规行 && 规净;
// 绘图：盘上一行表达式 → 320 个采样点 → 屏幕。判据是读回曲线上两个已知位置的点，
// 而那两个位置由表达式自己算出来（f(0)=0 在 (0,100)，f(160)=25.6 在 (160,74)），
// 不是挑了两个看起来对的坐标。截图那层仍然留给人。
const 图行 = /Yunooka: plot ([0-9A-F]+) ([0-9A-F]+)/.exec(读到);
const 图成 = 图行 !== null && 图行[1] === "000000000000002F"
  && 图行[2] === "000000000000002F";
// KID 索引：三条判据，而第一条缺不得 —— 一颗「其实什么也没建、每次都现找」的实现
// 也能过后两条。条目数不写死成 11：盘上每加一个文件它就变，而那时红的理由与索引无关。
const 索数 = /Yunooka: index count ([0-9A-F]+)/.exec(读到);
const 索查 = /Yunooka: index hello\.txt -> ([0-9A-F]+)/.exec(读到);
const 索空 = /Yunooka: index nosuch\.txt -> ([0-9A-F]+)/.exec(读到);
// 索查 那一格正常启动时钉住 0x404（盘上那份布局的第一个数据扇区）—— 它证明索引与
// 目录读的是同一个数。补丁那一趟不能钉：修好的 hello.txt 落在新分配的扇区上，
// 钉住旧号就等于要求「它别修」。那一趟只要求「查得到、且不是一个零地址」，
// 而「两条路算出同一个数」仍由下面详情那一块的 cross same 负责。
//
// 这个数跟着布局走：根目录从一格涨到两格那天，docs 与数据区各后移一格，0x403 变 0x404。
const 索成 = 索数 !== null && !/^0+$/.test(索数[1])
  && 索查 !== null && !/^0+$/.test(索查[1])
  && (补丁模式 || 索查[1].endsWith("404"))
  && 索空 !== null && /^0+$/.test(索空[1]);
// 此电脑的窗口骨架：四个位置各一种颜色。四个都要 —— 一颗只清屏不画的实现过不了前三，
// 一颗整屏填满的过不了最后一行。规划在 design/KOHANE.txt。
const 窗行 = /Yunooka: window ([0-9A-F]+) ([0-9A-F]+) ([0-9A-F]+) ([0-9A-F]+)/.exec(读到);
const 窗成 = 窗行 !== null
  && 窗行[1].endsWith("2F") && 窗行[2].endsWith("1C")
  && 窗行[3].endsWith("28") && 窗行[4].endsWith("0F");
// 进一个盘：列它根目录的条目，每项报名字、类型、字节数、共享位。
// 四条判据，各自卡住一类能蒙过去的实现 ——
//   一、甲盘的行数等于索引数出的条目数。这是两段**独立步进**的代码（索引自己走一遍、
//      列表自己走一遍）的交叉核对，少走一条就不等。所以它不是「同一条路径自我确认」。
//   二、两块盘上各有一个 hello.txt，而它们的大小与共享位都不同。一个「只列主盘、
//      再把结果抄一遍」的实现会让两边一模一样，于是这一条红。
//   三、docs 是目录、0 字节、带共享位 —— 类型列与共享位在同一行上各有各的值。
//      一个把类型列丢掉的实现，会让 docs 与一个空文件长得一样。
//   四、secret.txt 不共享。一个「共享位一律打 1」的实现过不了这一条。
const 甲条 = [...读到.matchAll(/^La (.+)$/gm)].map((m) => m[1].trim());
const 乙条 = [...读到.matchAll(/^Lb (.+)$/gm)].map((m) => m[1].trim());
const 甲数 = 甲条.length;
const 乙数 = 乙条.length;
const 甲耳 = /^La hello\.txt f (\d+) (\d)$/m.exec(读到);
const 乙耳 = /^Lb hello\.txt f (\d+) (\d)$/m.exec(读到);
const 列数成 = 索数 !== null && 甲数 === Number("0x" + 索数[1]);
const 列同物 = 甲耳 !== null && 乙耳 !== null
  && 甲耳[1] !== 乙耳[1] && 甲耳[2] !== 乙耳[2];
const 列类型 = /^La docs d 0 1$/m.test(读到);
const 列独享 = /^Lb secret\.txt f 15 0$/m.test(读到);
const 列成 = 列数成 && 列同物 && 列类型 && 列独享 && 乙数 === 2;

// 盘自己报的名字。这一条判据的原话在 design/KOHANE.txt 第五层：
// 「型号那几个字符是盘自己报的，不是代码里写死的」。
//
// 所以判据不只是「读到了非空的串」—— 那一条一颗打印固定字符串的实现也能过。
// 这里多查一件事：第二段的源里不许出现那个型号。型号是 NVMe 控制器报的，
// 它出现在代码里就只可能是有人抄了进去，而那样这一条判据就什么也证明不了。
// 序列号同理，而它还要与型号不同：两个字段来自 Identify 那一页的两个位置，
// 一个实现对了两处，才说明它真的把那一页读进来了。
const 模行 = /Yunooka: nvme model (.+)/.exec(读到);
const 序行 = /Yunooka: nvme serial (.+)/.exec(读到);
const 型号 = 模行 !== null ? 模行[1].trim() : "";
const 序号 = 序行 !== null ? 序行[1].trim() : "";
const 段源 = fs.readFileSync(path.join("boot", "stage2.asm"), "utf8");
const 写死了 = 型号.length > 0 && 段源.includes(型号);
const 健成 = 型号.length >= 8 && 序号.length >= 4
  && 型号 !== 序号 && !写死了;

// 命名空间有多大。这一条判据的力气全在「两个独立来源对上」——
// 一边是 Identify Namespace 那一页报的逻辑块数（盘自己说的），
// 另一边是造这块盘时给的 --size 2（这个脚本自己给的）。
// 两边算出同一个字节数，才说明那一页真的从盘里读进来了；
// 而一个把「4096」写死的实现，会在有人把盘改成 3 MB 的那一天红。
const 空了 = /Yunooka: nvme ns (\d+) (\d+)/.exec(读到);
const 块数 = 空了 !== null ? Number(空了[1]) : 0;
const 块位 = 空了 !== null ? Number(空了[2]) : 0;
const 量成 = 块数 > 0 && 块位 >= 9 && 块位 <= 16
  && 块数 * Math.pow(2, 块位) === NVMe盘大小;

// 系统保护的第一层：只读位真的挡住写。
//
// 五条要一起成立，而其中最有信息量的是第三条 —— 它要求拒绝的时候报的是「只读」而不是
// 「已存在」。两种拒绝走的是同一条失败路径（fs_write_file 的 .fail），如果报出来的话
// 一样，那「只读」就只是一句没人验过的宣告：文件确实没写进去，而原因未必是保护。
//
// 最后一条（换一个名字仍然写得进）是为了让前面的拒绝有意义。少了它，一个「什么都写不进」
// 的实现也能过前四条 —— 而那种实现与「保护得很好」在串口上长得一模一样。
const 守成 = /Yunooka: guard write ok/.test(读到)
  && /Yunooka: guard readonly set/.test(读到)
  && /Yunooka: write refused \(readonly\)/.test(读到)
  && /Yunooka: guard rewrite refused/.test(读到)
  && /Yunooka: guard other name ok/.test(读到)
  && !/Yunooka: guard rewrite LEAKED/.test(读到);

// 系统保护的第二层：核心清单与校验和。
//
// 清单在盘上（core.bin，二进制：u32 项数，然后每项 u8 名字长、名字 ASCII、u32 FNV-1a），
// 而它对的是「启动时那些文件是不是还是原来那份字节」。—— 项数不写死成 3：清单长一项，
// 这里就跟着变，而红的理由不该是「我数错了」。
//
// 这一条的价值全在它的验红手段上：build --break 把盘上 hello.txt 的首字节翻一位，
// 而清单仍按原内容算 —— 于是启动时会报出「哪一项不符」。而一个永远报 ok 的实现
// 过不了那一次 —— 所以下面还要显式排除 bad 与 missing 两个词。
const 核集 = [...读到.matchAll(/Yunooka: guard core (\d+) (\d+)/g)];
// 取**最后**一行。修补成功时客人机会重报一次「现在数一遍」，而那一行才是当前状态；
// 只取第一行的话，带补丁那一趟永远红在修补之前那个数上 —— 于是这一块最该被看见的
// 那个动作（修好之后重新数）反而被挡住了。
const 核行 = 核集.length ? 核集[核集.length - 1] : null;
// 补丁那一趟里 missing 与 bad 是**修补之前**的读数，而现在那两条不再成立 ——
// 所以那一趟不许它们出现就等于要求「它别修」。判据改成：最后一行必须是坏的为零，
// 而 missing/bad 只在没有补丁的那两趟里被排除。
const 核成 = 核行 !== null && Number(核行[1]) >= 1 && 核行[2] === "0"
  && (补丁模式 || !/Yunooka: guard core (bad|missing)/.test(读到));

// OnlySign 的第二环：SHA-256 清单（design/SIGN.txt）。
//
// 它与上面那条核成回答的不是同一个问题：核成说「文件与清单是否一致」，这一条说
// 「清单自己有没有被动过」。所以它的验红手段不是 --break（那会让两层一起红），
// 而是 --forge：盘上改了、core.bin 也跟着重算了 —— 核成绿，而这一条必须红。
const 签行 = /Yunooka: event=onlysign ok items=(\d+)/.exec(读到);
const 签成 = 签行 !== null && Number(签行[1]) >= 1;
const 签红行 = /Yunooka: event=onlysign bad name=(\S+)/.exec(读到);
const 签红 = 签红行 !== null && 签红行[1] === "hello.txt";
// 一台没有清单的机器不该看起来与一台清单全对的机器一样。
const 签无 = /Yunooka: event=onlysign nosign/.test(读到);

// 域算术 mod 2^255-19：第三环的第一层。
//
// 它要的不是「有没有那一行」，而是「与主机上 BigInt 算的同一个数逐字符相同」。所以
// 这里把六组输入在主机这边重算一遍，一行对一行 —— 固件算得对不对，在这一层是两个
// 字符串相等还是不相等，没有需要解释的余地。
//
// 比的是完整的 32 字节。约简出错时动的往往是高位，而打进串口的前几个字节在低端：
// 只比前八个的话，一个「折不干净、高位多留了一点」的实现会安静地过去。
//
// 六个向量与 stage2.asm 里 fp_vecs 那六组一一对应，顺序也一样。两边各写一遍是有意的：
// 固件那边是「被测的东西」，这边是「尺子」，尺子跟着被测物走就什么也量不出。
const fp向量 = (() => {
  const P = (1n << 255n) - 19n;
  const 编 = (v) => {
    const b = Buffer.alloc(32);
    for (let i = 0; i < 32; i++) {
      b[i] = Number(v & 0xffn);
      v >>= 8n;
    }
    return b.toString("hex").toUpperCase();
  };
  return [
    [1n, 1n],
    [2n, 3n],
    [P - 1n, P - 1n],
    [P - 1n, 2n],
    [(1n << 255n) - 1n, (1n << 255n) - 1n],
    [
      0x216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51an,
      0x6666666666666666666666666666666666666666666666666666666666666658n,
    ],
  ].map(([a, b]) => 编((a * b) % P));
})();
const fp行 = [...读到.matchAll(/^Yunooka: fp val=([0-9A-F]{64})$/gm)].map((m) => m[1]);
const fp成 = fp行.length === 6 && fp行.every((h, i) => h === fp向量[i]);

// 域加减：六组，前三组加法、后三组减法，顺序与 stage2 的 fp2_vecs 一致。
//
// 与乘法那一层分开测，理由是它们各自的错法不同：乘法错在约简（乘积比输入宽一倍），
// 加减错在进位与借位（宽度不变而方向相反）。混在一起测，一组错的时候分不出是哪一层，
// 而这一层的价值恰恰在于「错在哪一步」说得出来。
const fp2期望 = (() => {
  const P = (1n << 255n) - 19n;
  const 模 = (a) => {
    const r = a % P;
    return r < 0n ? r + P : r;
  };
  const 编 = (v) => {
    const b = Buffer.alloc(32);
    for (let i = 0; i < 32; i++) {
      b[i] = Number(v & 0xffn);
      v >>= 8n;
    }
    return b.toString("hex").toUpperCase();
  };
  const 表 = [
    ["add", 2n, 3n],
    ["add", P - 1n, 2n],
    ["add", P - 1n, P - 1n],
    ["sub", 2n, 3n],
    ["sub", P - 1n, P - 1n],
    ["sub", 0n, 1n],
  ];
  return 表.map(([op, a, b]) => [op, 编(op === "add" ? 模(a + b) : 模(a - b))]);
})();
const fp2行 = [...读到.matchAll(/^Yunooka: fp2 op=(add|sub) val=([0-9A-F]{64})$/gm)]
  .map((m) => [m[1], m[2]]);
const fp2成 = fp2行.length === 6
  && fp2行.every(([op, h], i) => op === fp2期望[i][0] && h === fp2期望[i][1]);

// 点运算：五组读数，三条判据。
//
// 判据是交叉积相等，而不是坐标相减。点加与点倍选的投影比例 k 不同 —— 同一个点在这
// 两条路上会得到不同的 (X,Y,Z,T)，比坐标会把一个正确的实现判成错的。所以「同一个点」
// 在这层的定义是 X1*Z2 == X2*Z1 且 Y1*Z2 == Y2*Z1。
//
// 这个比较需要域乘，而固件那边没有模逆、也不值得为判据多写一段：四份坐标打到串口，
// BigInt 在这边一行就算完了。
//
// 三条判据各管一件事：
//   add-bb 与 dbl-b  两个公式是不是同一个群运算
//   dbl2-b 与 add-4b 群运算能不能叠（两倍的两倍，与四倍的两倍）
//   add-ident        加上单位元是不是真的没动
const pt行 = new Map(
  [...读到.matchAll(/^Yunooka: pt (add-bb|dbl-b|dbl2-b|add-4b|add-ident) ([0-9A-F]{256})$/gm)]
    .map((m) => [m[1], m[2]]),
);
const pt成 = (() => {
  if (pt行.size !== 5) return false;
  const P = (1n << 255n) - 19n;
  const 模 = (a) => {
    const r = a % P;
    return r < 0n ? r + P : r;
  };
  // 一行是小端的一百二十八字节：四格域元素，每格三十二字节，每字节两个十六进制字符。
  const 取格 = (hex, i) => {
    let v = 0n;
    for (let k = 31; k >= 0; k--) {
      const at = i * 64 + k * 2;
      v = (v << 8n) | BigInt(parseInt(hex.slice(at, at + 2), 16));
    }
    return v;
  };
  const 取点 = (name) => {
    const h = pt行.get(name);
    return h ? [0, 1, 2, 3].map((i) => 取格(h, i)) : null;
  };
  const 同点 = (p, q) => p !== null && q !== null
    // Z 不许是零。没有这一条，一个「把四份坐标都算成零」的实现会与任何点「同点」——
    // 0 == 0*Z 与 0 == 0*Z 两条都成立。这不是理论上的担心：点运算那一层的第一趟，
    // 四份坐标就曾经全变成同一个数，而那时判据离假绿只差一次运气。
    && p[2] !== 0n && q[2] !== 0n
    && 模(p[0] * q[2]) === 模(q[0] * p[2])
    && 模(p[1] * q[2]) === 模(q[1] * p[2]);

  const 基x = 0x216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51an;
  const 基y = 0x6666666666666666666666666666666666666666666666666666666666666658n;
  const 基点 = [基x, 基y, 1n, 模(基x * 基y)];

  // 输入本身也要对。两个点都被读成零的时候，那几条交叉积照样会相等 —— 那是假绿，
  // 而假绿比红贵：红的那条会有人来查，绿的那条不会。固件打的 pti 两行就是为这一条
  // 存在的，它们不参与别的判据。
  const 输入们 = [...读到.matchAll(/^Yunooka: pti in-[ab] ([0-9A-F]{256})$/gm)]
    .map((m) => [0, 1, 2, 3].map((i) => 取格(m[1], i)));
  if (输入们.length !== 2 || !输入们.every((p) => 同点(p, 基点))) return false;

  return 同点(取点("add-bb"), 取点("dbl-b"))
    && 同点(取点("dbl2-b"), 取点("add-4b"))
    && 同点(取点("add-ident"), 基点);
})();

// 标量乘：四组读数，三条交叉积，每一条都与前面已经站住的东西比。
//
//   mul-1  与基点    压的是标量右移与循环终止：一个把右移写成左移的实现在这里红
//   mul-2  与 dbl-b  压的是加倍那一条：标量乘里的 double 与点倍子程序必须是一回事
//   mul-3  与 add-3b 压的是加法那一条，而且 3 的位模式是 11 —— 加倍与加号交替发生
//
// 只测 mul-2 的话，一个「加号永远不进」的实现照样绿；只看 mul-3 的话，一个把 3 当成
// 2 的实现在别的组上可能碰巧撞对。三条一起，两个动作才各被问过一遍。
//
// 标量为零那一组不在这里：它与单位元比，而单位元的 (0,1,1,0) 在交叉积下与一个全零
// 的点也判得成同点（X 那一项两边都是零）。主机那边给「同点」加了 Z 不为零这一条，
// 所以零不会被误判成绿；但一组只证明「循环没跑」的读数不值得占一个向量位。
const ptm行 = new Map(
  [...读到.matchAll(/^Yunooka: ptm (mul-[1235]|add-3b) ([0-9A-F]{256})$/gm)]
    .map((m) => [m[1], m[2]]),
);
const ptm成 = (() => {
  if (ptm行.size !== 5) return false;
  const P = (1n << 255n) - 19n;
  const 模 = (a) => {
    const r = a % P;
    return r < 0n ? r + P : r;
  };
  const 取格 = (hex, i) => {
    let v = 0n;
    for (let k = 31; k >= 0; k--) {
      const at = i * 64 + k * 2;
      v = (v << 8n) | BigInt(parseInt(hex.slice(at, at + 2), 16));
    }
    return v;
  };
  const 取点 = (h) => (h ? [0, 1, 2, 3].map((i) => 取格(h, i)) : null);
  const 同点 = (p, q) => p !== null && q !== null
    && p[2] !== 0n && q[2] !== 0n
    && 模(p[0] * q[2]) === 模(q[0] * p[2])
    && 模(p[1] * q[2]) === 模(q[1] * p[2]);

  const 基x = 0x216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51an;
  const 基y = 0x6666666666666666666666666666666666666666666666666666666666666658n;
  const 基点 = [基x, 基y, 1n, 模(基x * 基y)];

  return 同点(取点(ptm行.get("mul-1")), 基点)
    && 同点(取点(ptm行.get("mul-2")), 取点(pt行.get("dbl-b")))
    && 同点(取点(ptm行.get("mul-3")), 取点(ptm行.get("add-3b")));
})();

// 压缩点的编码：四组，基点、2B、3B、4B。
//
// 基点的编码是 RFC 8032 给的那一串常量，所以它不是「主机算的」，是一个已知答案 ——
// 而那一串在这里最有用：如果固件的模逆写错，基点的编码会第一个不对，且不需要主机
// 提供任何东西就能判。
//
// 另外三组与主机算的逐字节比。主机这边要做的只有一次模逆与一次小端展开，而固件那边
// 是 255 次平方加乘法。两边的便宜程度正好反过来，这没关系：判据要的是独立，不是对称。
//
// 编码一次压住四件事 —— 模逆、乘法、y 的字节序、符号位取的是 x 的最低位。任何一件错，
// 三十二字节里都会有一位不对，而这一层是验签链上唯一输出到外面的地方。
const pte行 = new Map(
  [...读到.matchAll(/^Yunooka: pte (b|2b|3b|4b|5b) ([0-9A-F]{64})$/gm)]
    .map((m) => [m[1], m[2]]),
);
const pte成 = (() => {
  if (pte行.size !== 5) return false;
  const P = (1n << 255n) - 19n;
  const 模 = (a) => {
    const r = a % P;
    return r < 0n ? r + P : r;
  };
  const 幂 = (b, e) => {
    let r = 1n;
    b = 模(b);
    while (e > 0n) {
      if (e & 1n) r = 模(r * b);
      b = 模(b * b);
      e >>= 1n;
    }
    return r;
  };
  const 逆 = (a) => 幂(a, P - 2n);
  const 取格 = (hex, i) => {
    let v = 0n;
    for (let k = 31; k >= 0; k--) {
      const at = i * 64 + k * 2;
      v = (v << 8n) | BigInt(parseInt(hex.slice(at, at + 2), 16));
    }
    return v;
  };
  const 取点 = (h) => (h ? [0, 1, 2, 3].map((i) => 取格(h, i)) : null);
  const 编码 = (p) => {
    if (!p || p[2] === 0n) return null;
    const zi = 逆(p[2]);
    const x = 模(p[0] * zi);
    const y = 模(p[1] * zi);
    const b = Buffer.alloc(32);
    let v = y;
    for (let i = 0; i < 32; i++) {
      b[i] = Number(v & 0xffn);
      v >>= 8n;
    }
    b[31] |= Number(x & 1n) << 7;
    return b.toString("hex").toUpperCase();
  };

  const 基x = 0x216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51an;
  const 基y = 0x6666666666666666666666666666666666666666666666666666666666666658n;
  const 基点 = [基x, 基y, 1n, 模(基x * 基y)];
  const 比 = (name, p) => {
    const e = 编码(p);
    return e !== null && e === pte行.get(name);
  };
  // 基点的编码还有一个写死的答案，对上它才算这一层真的通了。
  if (编码(基点) !== "5866666666666666666666666666666666666666666666666666666666666666") {
    return false;
  }
  return 比("b", 基点)
    && 比("2b", 取点(pt行.get("dbl-b")))
    && 比("3b", 取点(ptm行.get("add-3b")))
    && 比("4b", 取点(pt行.get("dbl2-b")))
    // 5B 的 x 是奇数，是唯一能走到符号位那一组的读数。前四个倍数全是偶 x ——
    // 少了这一组，把 shl 7 改成 shl 6 判据也不会红，而那一位是验签会真用到的。
    && 比("5b", 取点(ptm行.get("mul-5")));
})();

// 解码：往返。
//
// 固件对 1、2、3、5 四个倍数各做一次「算出来 → 编码 → 解码」，把编码前与解码后的
// 四份坐标都打出来。这里成对比较：同一个 k 的两组必须是同一个点。
//
// 为什么往返是这一层唯一说得清的判据：编码与解码互为逆，而它们各自都不需要知道
// 「正确的坐标是什么」。拿一个写死的期望值去比，覆盖的只是那一个点；往返覆盖每一个
// 输入，而且是自动覆盖 —— 想让往返通过而实现不对，比让一个期望值通过难得多。
//
// 还有一行坏输入：y = 2 落不到曲线上，解码必须拒绝。少了这一条，一个「任何输入都
// 接受」的实现会与正确的实现看起来一模一样 —— 它在四个正确的输入上全对。
const ptr行 = [...读到.matchAll(/^Yunooka: ptd (before|after) ([0-9A-F]{256})$/gm)]
  .map((m) => [m[1], m[2]]);
const ptrBad = /^Yunooka: ptd bad 0$/m.test(读到);
const ptr成 = (() => {
  if (ptr行.length !== 8) return false;
  const P = (1n << 255n) - 19n;
  const 模 = (a) => {
    const r = a % P;
    return r < 0n ? r + P : r;
  };
  const 取格 = (hex, i) => {
    let v = 0n;
    for (let k = 31; k >= 0; k--) {
      const at = i * 64 + k * 2;
      v = (v << 8n) | BigInt(parseInt(hex.slice(at, at + 2), 16));
    }
    return v;
  };
  const 取点 = (h) => [0, 1, 2, 3].map((i) => 取格(h, i));
  const 同点 = (p, q) => p[2] !== 0n && q[2] !== 0n
    && 模(p[0] * q[2]) === 模(q[0] * p[2])
    && 模(p[1] * q[2]) === 模(q[1] * p[2]);

  for (let i = 0; i < 8; i += 2) {
    const 前 = ptr行[i];
    const 后 = ptr行[i + 1];
    if (前[0] !== "before" || 后[0] !== "after") return false;
    if (!同点(取点(前[1]), 取点(后[1]))) return false;
  }
  return ptrBad;
})();

// 验签：RFC 8032 的三组向量，每组验两次。
//
//   ok   原样的签名必须通过
//   bad  把签名的第一个字节翻一位，必须不通过
//
// 两条缺一不可，理由与别处一样：只验 ok 的话，一个永远返回 1 的实现全绿；只验 bad
// 的话，一个永远返回 0 的实现全绿。而这两组向量来自 RFC，不是自己造的 —— 自造向量
// 只能证明「它与自己一致」，证明不了「它与标准一致」。
//
// 三组的消息长度是 0、1、2，覆盖 SHA-512 那条链的短输入。长消息的多块路径已经由
// SHA-512 自己的六行判据压过（四个在两块以上），这里不重复。
const sig行 = [...读到.matchAll(/^Yunooka: sig (\d) ok=(\d) bad=(\d)(?: where=(\d+))?$/gm)]
  .map((m) => [Number(m[1]), m[2], m[3], Number(m[4] ?? 6)]);
const sig成 = sig行.length === 3
  && [1, 2, 3].every((n) => {
    const r = sig行.find((x) => x[0] === n);
    return r !== undefined && r[1] === "1" && r[2] === "0";
  });

// 第三环：sign.bin 自己也被签过。
//
// 它回答的问题与前两环都不同 —— core.bin 说文件与清单是否一致，sign.bin 说清单自己
// 有没有被改过，这一环说「这份清单是一个拿着私钥的人签的」。
//
// 正常那一趟必须 ok。破签那一趟（build --authbreak）由 build 那边验证，不在这一条
// 里面：一次运行只能处在一种处境，而两种处境的期望值相反。
const on3成 = /^Yunooka: event=onlysign3 ok$/m.test(读到);
const on3红 = /^Yunooka: event=onlysign3 bad where=(\d+)$/.exec(读到);

// 盘的健康：NVMe 的 SMART / Health 日志（Get Log Page，LID 2）。
//
// 事实先摆清楚：VBox 这块 NVMe 对这条命令回答 status=0，而缓冲区里保持上一条命令留
// 下的内容 —— 它没写。旧记录说的是「返回一页零」，那个说法只对了一半：当时缓冲区是
// 清零的，所以看起来是零。真相是「命令成功而数据没进来」，而这两件事对一块真盘来说
// 意思完全不同：前者说盘给了零值，后者说盘没实现这一页。
//
// 判据要求三行都在且 status 是零 —— 那证明这条命令确实发了、也确实被接受了。至于
// 内容是真数据还是旧数据，由「那一串里有没有型号与序列号」来分辨：VBox 这块的所谓
// SMART 页里就嵌着 VB1234-56789 与 ORCL-VBOX-NVME-VER12。一块真的报 SMART 的盘会
// 给出温度、通电时间、以及一串不相干的计数，形状完全不同。
const nvSmart行 = /^Yunooka: nvme smart ([0-9A-F]{64})$/m.exec(读到);
const nvSmstat行 = /^Yunooka: nvme smstat (\d+)$/m.exec(读到);
const nvTemp行 = /^Yunooka: nvme temp (\d+)$/m.exec(读到);
const nv健康成 = nvSmart行 !== null && nvSmstat行 !== null
  && nvSmstat行[1] === "0" && nvTemp行 !== null;

// 盘的健康：一行汇总。
//
// 型号、序列号、容量都是盘自己报的（NVMe 的两条 Identify）；温度那一格是 n/a，因为
// 这块盘的 SMART 页是空实现 —— 命令回了成功，而数据没进来。
//
// 判据要求那三样非空、容量是一个正数，而温度那一格**必须**是字面的 n/a。
//
// 最后这一条是这一层的全部价值：一个报 0 的实现与一个报 61056 的实现都能过「有个温度」
// 那一关，而它们都在撒谎。61056 更糟 —— 它是个数，看起来像读数。一个准确的「我不知道」
// 比一个假的零度好，因为读它的人会拿那个零去做判断。
const dh行 = /^Yunooka: event=diskhealth (\S+) (\S+) (\d+) (n\/a|-?\d+)$/m.exec(读到);
const dh成 = dh行 !== null
  && dh行[1].length > 0
  && dh行[2].length > 0
  && Number(dh行[3]) > 0
  && dh行[4] === "n/a";

// Myon 的第一条判据：一行不只有一个词。
//
// 两趟各测一个，而它们证明的是两件不同的事。第一趟从信箱收到 "echo hello world"：
// 它证明这一行被切开、词之后的部分作为参数传了过去。第二趟没有信箱，从盘上 cmd.txt
// 读到 "files"（壳成那一条），证明目录能列。
//
// 为什么要两条：在这一条之前，shell 是拿前五个字节与 "files" 比的 —— 于是 "filesx"
// 也会被当成 files，而「一行只认一个词、只回一行」那句话就是这样落在代码里的。
// echo 是这条缺口最小的证明：它要的不是一个命令名，是一整行字，而这一整行字必须原样
// 出现在输出里。
//
// 这正是 LAYERS 第六节第二条判据的第一步：一个 HMYR 包要能通过 Myon 读一行、写一行。
// 眼下读与写的两端都在宿主这一侧，而它们就是包将来要接的两个口子。
const 回声行 = /Yunooka: shell> echo hello world\r?\nhello world/.exec(读到);
const 回声成 = 回声行 !== null;

// Myon 的第二条判据：一个包把一段字交给宿主去打。
//
// 盘上的 prog.hmtn 现在有两个函数：main 返 7，echo 压一个串常量、调内置 write、返回。
// 串口上必须出现那段字本身 —— 而它是包里的字节，不是宿主里写死的字符串。这一条与
// 「prog main -> 7」互补：同一个包的两个函数各走一条路，一条是返回值，一条是宿主口。
//
// 为什么这一条要紧：在这之前，一个包能算、能返回，而它没有办法往外说一句话。write
// 是第一个这样的口子。LAYERS 第六节第二条判据要的是「一个包通过 Myon 读一行、写一行」，
// 而这是其中的写那一半；读那一半要先把「宿主攒的那一行怎么交到包手里」定下来。
// 两条正则，卡的是顺序而不只是存在。
//
// `echo hello world` 在串口上出现两次：一次是 shell 的回显（`shell> echo hello world`），
// 一次是包打出来的。只查「有没有这个串」会被前一次满足，而那一次与包无关。所以这里要
// 的是「`myon here` 之后紧接 `echo hello world`」—— 那个顺序只有包里的两条指令能给出。
// 四个点：三个来自宿主里写死的 border，第四个来自包自己指定的那个矩形（x=120, y=20,
// 宽 40, 高 20，色 0x1C）。前三个证明「包能让宿主画」，第四个证明「包能决定画在哪里」——
// 而后者才是渲染。一个只认 border 的实现过不了第四格。
const myon写行 = /myon here\r?\necho hello world\r?\n/.test(读到)
  && /^Yunooka: event=myon write ok$/m.test(读到)
  && /^Yunooka: myon px (?:[0-9A-F]{16} ){3}[0-9A-F]{16}$/m.test(读到)
  && /^Yunooka: myon px 0{14}2F 0{14}2F 0{14}2F 0{14}1C$/m.test(读到);
const myon写成 = myon写行;

// Myon 的第三个判据：两个独立的包。
//
// 上面那条跑的是 prog.hmtn 里的 echo —— 一个包里的第二个函数。这一条跑的是 docs 里
// 另一份文件：自己的包头、自己的函数表、自己的扇区。**桥接要有两个包才谈得上**，而
// 一个包里的两个函数共享地址空间，那不叫两个。
//
// 判据要求三样：`event=myon2 ok` 在，以及 `myon here` 至少三次。
//
// 三次的来源各自不同，而正因如此它才是桥接的证据：
//   一、run_myon_test 跑 prog.hmtn 的 echo，它打出自己那段字；
//   二、同一个 echo 调内置 runpkg，宿主去跑 docs/myon.hmtn 的 echo —— 第二个包打出
//       自己那段字。**这一条是包与包之间**：外层请求、宿主转达、内层执行；
//   三、run_myon2_test 再单独跑一次第二个包，证明它自己也是好的。
//
// 只查两次的话，「桥接根本没接上」与「桥接接上了但内层没跑」分不开。三次里少了第三次
// 就说明内层是被桥接带起来的那一次；少了整体就说明桥接没发生。
const myon2成 = /^Yunooka: event=myon2 ok$/m.test(读到)
  && (读到.match(/myon here/g) || []).length >= 3;

// SHA-512 的六行：与主机逐字符相同。
//
// 以前这一条靠 tools/checksha512.mjs 手动跑。而那个脚本读 build/serial.log，run.mjs
// 早就不写那个文件了 —— 也就是说那条判据已经与主链脱节，却一直挂在那里像还活着。
// 手动跑的判据不算判据：它不在任何一次通过的路径上，所以它红不红没人知道。
//
// 判据只有一句：字符串相等。不解释、不近似 —— 一个 512 位哈希里错一位与错一半，在
// 「相等」这件事上是同一件事；而只看前 8 字节的那种比较，会让一个错到离谱的实现也报绿。
//
// 六个长度覆盖补齐的四种处境：0（空消息）、1（末尾只有一字节）、111（长度字段仍能塞进
// 同一块）、112（正好跨到第二块）、128（正好一整块）、239（两块之后还剩大半块）。
// 只测一个长度最多碰到其中一种，剩下三种坏了也看不见 —— 那个多块缺陷就是这样躲了很久。
const sha512行 = [...读到.matchAll(/^Yunooka: event=sha512 len=(\d+) hex=([0-9A-F]{128})$/gm)]
  .map((m) => [Number(m[1]), m[2]]);
const sha512成 = (() => {
  if (sha512行.length !== 6) return false;
  const t = Buffer.alloc(256);
  for (let i = 0; i < 256; i++) t[i] = i & 0xff;
  return [0, 1, 111, 112, 128, 239].every((L) => {
    const r = sha512行.find((x) => x[0] === L);
    if (r === undefined) return false;
    const want = crypto.createHash("sha512").update(t.subarray(0, L)).digest("hex").toUpperCase();
    return r[1] === want;
  });
})();

// 补完界面的骨架：**正常启动时不该出现**。
//
// 这一条判据的形状与别处不同 —— 它验的是「没有」。而那种判据最容易被写成
// 「什么都没读到也算通过」，所以它必须与上面那条 `核成` 一起看：核成要求三项全对上，
// 而这一条要求那三项全对上的时候补完界面不出现。两条合起来才是「该进的时候才进」。
//
// 而「该进的时候」是手动验的：build.mjs --drop hello.txt 删掉一个核心文件，
// 于是盘上真的缺一份，而那一趟里串口报的是
//   guard core missing hello.txt / guard core 2 1 / event=guard.entry bad=1 repair=mailbox version=1
// 屏幕那一半（画出来的窗口）是给眼睛的，判据只认串口 —— 截图不是判据。
const 补完没进 = !/Yunooka: event=guard\.entry/.test(读到);

// 补完界面「修」的那一半：两条判据，一条验带补丁的那一趟，一条验不带补丁的那一趟。
//
// 为什么两条：只验「修好了」的话，一个永远报 fixed=1 的实现也能过；只验「进了补完界面」
// 的话，一个根本不修的实现也能过。两条合起来才排掉两边 —— 修得好的时候不该看见那个
// 界面，修不了的时候必须看见。
//
// 而这两条各自都还有验红的办法：
//   修成    把补丁里那一项的字节改一位：补丁里有这一条、哈希对不上、报 refused、
//           不回进补完界面、也不算修好。四件事一起变，才说明校验那一步真的在比。
//   补完进  不给补丁（--drop-nopatch）：这一趟它必须进。
// 三个数：fixed 写进去几条、verified 读回来重算后对上几条、refused 补丁里有但被
// 校验挡下来几条。refused 必须是 0 —— 它进判据之后，「校验真的在比」这件事就不必
// 靠另找一个词来证明了：坏补丁那一趟串口上是 fixed=0 refused=1，这一条直接红。
const 修行 = /Yunooka: event=guard\.repair fixed=(\d+) verified=(\d+) refused=(\d+)/.exec(读到);
const 修成 = 修行 !== null && Number(修行[1]) >= 1
  && 修行[2] === 修行[1] && 修行[3] === "0";
const 补完进 = /Yunooka: event=guard\.entry bad=(\d+)/.exec(读到);
const 补完进了 = 补完进 !== null && Number(补完进[1]) >= 1;

// 「这一趟没有补丁」这件事，机器自己说过一次。
//
// 那一行在此之前是打了没人读的：audit.mjs 把它列进「没人读的 event」，而它说的正是
// 「没有补丁」这个处境 —— 而那正是 --drop-nopatch 那一趟要证明的东西。一行没人读的
// 宣告与一张没人查的判据是同一种病，所以这里给它一个读的人。
const 无补成 = /^Yunooka: event=guard\.nopatch source=none$/m.test(读到);

// 这一趟该验哪一条。三种处境互斥（参数在文件开头就判过），而「正常那一趟」照旧
// 只验核成与补完没进 —— 它没有缺，所以两件修补的事都不该发生。
//
// 有补丁那一趟要多验两条：修成（fixed 与 verified 相等）与核成（修补之后重报的
// 那一行是 3 0，而不是修补之前的 2 1）。补完没进也在里面 —— 修好了就不该看见那个
// 界面。这三条合起来说的是同一件事：它自己修好了，而且自己知道修好了。
const 保护成 = 补丁模式
  ? (修成 && 核成 && 补完没进)
  : 无补丁模式
    // 没有补丁时它不该报任何一个修复成功行 —— 报得出来就是撒谎。而「没有补丁」这件事
    // 要有机器自己那一句话（guard.nopatch），不然这一支验的是「它知道自己在哪一趟」，
    // 而不是「它看见了盘上没有补丁」。
    ? (补完进了 && 修行 === null && 无补成)
    : (核成 && 补完没进);

// 一个文件的详情：六列，加一次交叉核对。
// 这一层真正值钱的是最后那一条：起始扇区要走两条完全不同的路各算一遍 —— 目录一条
// （fs_open_path 逐段查找）、索引一条（index_build 建表再按名字查）。同一条路算两遍
// 什么也证明不了，所以判据必须要 cross 那一行说 same。
//
// 三次 stat 的顺序也有意义：hello.txt（标记前）、docs、hello.txt（标记后）。第一与第三行
// 之间只发生了一件事 —— fs_readonly 改了 bit 6。所以只读位那一列必须从 0 变 1，而共享位
// 那一列必须两行都是 0。一个「or 0x40 顺手把 0x80 也带上」的实现会在这里红。
const 详情 = [...读到.matchAll(/^Yunooka: stat hello\.txt -> ([0-9A-F]+) (\d+) ([fd]) (\d) (\d)$/gm)];
const 详标 = [...读到.matchAll(/^Yunooka: stat docs -> ([0-9A-F]+) (\d+) ([fd]) (\d) (\d)$/gm)];
const 交行 = /Yunooka: cross ([0-9A-F]+) ([0-9A-F]+) (same|differ)/.exec(读到);
const 详成 = 详情.length === 2 && 详标.length === 2
  && 交行 !== null && 交行[3] === "same" && 交行[1] === 交行[2]
  // 标记前：文件、不共享、不只读
  && 详情[0][3] === "f" && 详情[0][4] === "0" && 详情[0][5] === "0"
  // 标记后：同一个起始扇区、同一份字节数，共享位仍是 0，只读位变 1
  && 详情[1][1] === 详情[0][1] && 详情[1][2] === 详情[0][2]
  && 详情[1][3] === "f" && 详情[1][4] === "0" && 详情[1][5] === "1"
  // 字节数那一列要与层三报的是同一个数：两段独立的代码从同一个条目里读
  && 甲耳 !== null && 详情[0][2] === 甲耳[1]
  // docs 第一次：目录、0 字节、共享位 1（run_share_test 标的）、不只读
  && 详标[0][2] === "0" && 详标[0][3] === "d" && 详标[0][4] === "1" && 详标[0][5] === "0"
  // docs 第二次（标了只读）：仍然是 d，共享位仍然是 1，只读位变成 1。
  // 这一条是掩码那件事唯一的判据 —— 漏收窄一处，一个只读的目录就会被打成 f。
  && 详标[1][3] === "d" && 详标[1][4] === "1" && 详标[1][5] === "1";

// 认类型：三条读数。前两条已成立，第三条（改名成 fake.txt 的包）现在是 unknown，
// 而它是这一层最要紧的那一条 —— 所以它没有被删掉换成绿灯，只被记成未成立。
// 一条删掉关键项的判据，比一条红的判据更贵：红的那条会有人来查，绿的那条不会。
// 十五格：前三格是「真文本、真包、改名成文本的包」，后十二格是别的系统的头。
// 字符类带上数字，因为有一个名字叫 7z。
const 认行 = /Yunooka: identify ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+) ([a-z0-9]+)/.exec(读到);
const 认前二 = 认行 !== null && 认行[1] === "text" && 认行[2] === "package";
const 认第三 = 认行 !== null && 认行[3] === "package";
// 别的系统的五个头。它们的样本名叫 .bin，内容只有头 —— 而这一格的力气在于
// 「答对了」与「答成 unknown」分得开：一个表没加长的实现在这五格上全是 unknown，
// 而一个把后缀当前缀猜的实现在 .bin 上也会全错。所以名字与内容无关这一条，
// 在这里与 fake.txt 那一格是同一个道理的两个方向。
const 认外五 = 认行 !== null && 认行[4] === "pe" && 认行[5] === "elf"
  && 认行[6] === "macho" && 认行[7] === "zip" && 认行[8] === "dex";
// 另外七个头。它们不落在盘上 —— identify 吃的是「一串字节加长度」，所以这一层不需要
// 文件系统，而那七份样本也就成了第二段里的数据常量。判据要的是「给一个头，它答那个
// 名字」，与那个头从哪来无关。
//
// 验红的办法是把其中一个头改坏一位：改了 rar 的首字节，那一格会变成 unknown，而
// 别的十四格照旧 —— 这正是这一行判据的形状：一格错，只报那一格。
const 认外七 = 认行 !== null && 认行[9] === "gzip" && 认行[10] === "7z"
  && 认行[11] === "rar" && 认行[12] === "pdf"
  && 认行[13] === "png" && 认行[14] === "jpeg" && 认行[15] === "sqlite";
// 写：造一个不存在的名字、写一段只有这里才有的字节、再按路径打开它。
// 判据是那段内容本身 —— 而且 files 的列表里也要多出这个名字，因为「目录里多了一条」
// 与「数据落对了地方」是两件事，两件都得成立。
const 写行 = /Yunooka: wrote -> (.+)/.exec(读到);
// 判据要求那一段内容本身，以及 files 的列表里多出这个名字。
// 列表那一半不能用写死的全名串：盘上每加一个文件它就会红一次，而红的理由与「写」无关。
// 这里只要求「以 hello.txt docs 开头的那一行里出现 new.txt」。
// 列表那一半有两个形状：正常启动是「hello.txt docs … new.txt」，补丁那一趟是
// 「docs cmd.txt … new.txt … hello.txt」—— 修好的那一份被追加到末尾。两者都证明
// new.txt 真的进了目录，而后者还额外证明修补动过目录（否则 hello.txt 不会挪位）。
const 写列表 = 补丁模式
  ? /docs cmd\.txt[^\r\n]*new\.txt/.test(读到)
  : /hello\.txt docs[^\r\n]*new\.txt/.test(读到);
const 写成 = 写行 !== null && 写行[1].trim() === "Yunooka wrote this" && 写列表;
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
// 正常启动：hello.txt 是目录第一条，所以三个名字连着出现。
// 补丁那一趟：修好的 hello.txt 排在末尾，于是 docs 与 cmd.txt 在前、hello.txt 在后。
// 两种形状都证明「列的是盘上那份目录、而且整份都列了」；补丁那条还额外证明修补
// 往目录里真的加了一条，而不是把 docs 改成了 hello.txt。
const 列行 = (补丁模式
  ? /docs cmd\.txt[^\r\n]*hello\.txt/
  : /hello\.txt docs cmd\.txt/).exec(读到);
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
console.log("算术      " + (求和行 ? "prog sum -> " + 求和行[1] : "(没跑到)")
  + (求和成 ? "  —— 40 + 2 得 42，而 42 没有别处出现过：那是解释器算的"
    : "  —— 不对：包里的两条常量与一次 add 没给出 42"));
console.log("文件大小  " + (尺行 ? "prog size -> " + 尺行[1] : "(没跑出来)")
  + (尺成 ? "  —— 包里 slurp 读了、len 量了，24 是 deep.txt 自己的字节数"
    : "  —— 不对：应当是 24，也就是 docs/sub/deep.txt 的大小"));
console.log("窗口      " + (窗口行 ? "win px " + 窗口行[1].slice(-2) + " " + 窗口行[2].slice(-2) + " " + 窗口行[3].slice(-2) : "(没跑到)")
  + (窗口成 ? "  —— 一个包画出底色、标题栏、内容区三层，顺序与偏移都对"
    : "  —— 不对：三层矩形没有按顺序落在那三个位置上"));
console.log("文件系统  " + (fs行
  ? "v" + fs行[1] + "，根目录第 " + fs行[2] + " 号扇区，第一个名字 " + fs行[3]
  : "(没读出来)")
  + (补丁模式
    ? "  —— 版本与根目录号来自超块；第一条是 docs，因为修好的那一份被追加到末尾"
    : (fs成 ? "  —— 名字与扇区号都来自盘上那份布局"
      : "  —— 不对：应当是 v1、根目录 1025、第一个名字 hello.txt")));
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
console.log("算数      " + (算行 ? "1+1 = " + 算行[1] : "(没跑到)")
  + (算成 ? "  —— 两级求值走通了：解析、f64 加、六位小数打印"
    : "  —— 不对：应当是 2.000000"));
console.log("扫描      " + (扫行 ? "eicar -> FOUND" : "(没命中)") + "  " + (净行 ? "clean -> clean" : "(误报)")
  + (扫成 ? "  —— 一条规则、两个文件：命中的是真命中，没命中的没误报"
    : "  —— 不对：应当命中 eicar、放过 clean"));
console.log("规则      " + (规行 ? "eicar.txt = eicar" : "(没命中)") + "  " + (规净 ? "clean.txt = none" : "(误报)")
  + (规成 ? "  —— 三行规则里只有真的那条报了名字：多行、有名字、假规则不误报"
    : "  —— 不对：应当 eicar.txt = eicar、clean.txt = none"));
console.log("此电脑    " + (甲数 ? "甲 " + 甲数 + " 条  乙 " + 乙数 + " 条" : "(没列出来)")
  + "  " + (列同物 ? "同名 hello.txt " + 甲耳[1] + " 与 " + 乙耳[1] : "(同名那对没分开)")
  + (列成 ? "  —— 四列都在：名字、类型、字节数、共享位"
    : "  —— 不对：" + [
      列数成 ? "" : "甲盘条目数与索引不一致",
      列同物 ? "" : "同名那对没分开",
      列类型 ? "" : "docs 不是 d 0 1",
      列独享 ? "" : "secret.txt 不是不共享",
      乙数 === 2 ? "" : "乙盘应当两条",
    ].filter(Boolean).join("、")));
console.log("详情      " + (详情.length === 2
    ? "hello.txt " + 详情[0][1].slice(-3) + " 只读 " + 详情[0][5] + " 变 " + 详情[1][5]
    : "(没跑到)")
  + (详标.length ? "  docs " + 详标.map((m) => m[3] + m[4] + m[5]).join(" 变 ") : "")
  + (交行 ? "  cross " + 交行[1].slice(-3) + " " + 交行[3] : "")
  + (详成 ? "  —— 六列都在，起始扇区由目录与索引两条路各算一遍"
    : "  —— 不对：" + [
      详情.length === 2 ? "" : "hello.txt 的 stat 不是两行",
      详标.length === 2 ? "" : "docs 的 stat 不是两行",
      交行 !== null && 交行[3] === "same" ? "" : "两条路径没对上",
      详情.length === 2 && 详情[0][5] === "0" && 详情[1][5] === "1" ? "" : "hello 的只读位没变",
      详标.length === 2 && 详标[1][3] === "d" ? "" : "只读的目录被打成了文件（掩码漏收窄）",
      详标.length === 2 && 详标[0][4] === "1" && 详标[1][4] === "1" ? "" : "docs 的共享位丢了",
      详情.length === 2 && 详情[0][4] === "0" && 详情[1][4] === "0" ? "" : "共享位被带上了",
      甲耳 !== null && 详情.length === 2 && 详情[0][2] === 甲耳[1] ? "" : "字节数与层三不一致",
    ].filter(Boolean).join("、")));
console.log("盘的健康  " + (型号 ? "model " + 型号 + "  serial " + 序号 : "(没读到)")
  + (健成 ? "  —— 型号与序列号都来自 Identify 那一页，而源里没有这两个字面量"
    : "  —— 不对：" + [
      型号.length >= 8 ? "" : "型号太短或没读到",
      序号.length >= 4 ? "" : "序列号没读到",
      型号 !== 序号 ? "" : "两段来自同一个位置",
      写死了 ? "型号被写进了代码（那就不是盘报的）" : "",
    ].filter(Boolean).join("、")));
console.log("盘的大小  " + (空了 ? 块数 + " 块 × 2^" + 块位 + " 字节" : "(没读到)")
  + (量成 ? "  —— 与造盘时给的 " + (NVMe盘大小 / 1024 / 1024) + " MB 一致，而块数是盘自己报的"
    : "  —— 不对：应当是 " + NVMe盘大小 + " 字节，实际 "
      + (块数 && 块位 ? 块数 * Math.pow(2, 块位) : "没算出来")));
console.log("补完界面  "
  + (补丁模式
    ? (补完没进 ? "没有进（修好了，不该进）" : "进了")
    : 无补丁模式
      ? (补完进了 ? "进了（缺一条，又没有补丁）" : "没有进")
      : (补完没进 ? "没有进（三项全对上，不该进）" : "进了"))
  + (补丁模式
    ? (补完没进 ? "" : "  —— 不对：修好的那一趟不该看见补完界面")
    : 无补丁模式
      ? (补完进了 ? "" : "  —— 不对：缺一条又没有补丁，它应当进补完界面")
      : (补完没进 ? "" : "  —— 不对：正常启动时不该进补完模式")));
console.log("修补      "
  + (补丁模式
    ? (修行 ? "fixed " + 修行[1] + " verified " + 修行[2] + " refused " + 修行[3] : "(没报)")
      + (修成 ? "  —— 补丁里那一条与清单一致：写进去、读回来、重算也对"
        : "  —— 不对：" + (修行 === null
          ? "没有报 event=guard.repair 那一行"
          : "三个数不对：fixed " + 修行[1] + "、verified " + 修行[2]
            + "、refused " + 修行[3]))
    : 无补丁模式
      ? (补完进了
        ? "没有补丁，进了补完界面  —— 这一趟它只能修不了：没有字节可写"
        : "没有补丁，而补完界面也没进  —— 不对：缺一条又没有补丁，它不可能自己修好")
      : "没有缺，所以没有这一步"));
console.log("核心清单  " + (核行 ? "对上 " + 核行[1] + " 项，坏 " + 核行[2] : "(没跑到)")
  + (核成 ? "  —— 校验和与盘上内容一致，一项一条" : "  —— 不对：有文件与清单不符，或者清单没读到"));
console.log("签名清单  " + (签行 ? "对上 " + 签行[1] + " 项"
    : 签红行 ? "不符 " + 签红行[1]
      : 签无 ? "(盘上没有 sign.bin)" : "(没跑到)")
  + (伪造模式
    ? (签红
      ? "  —— 盘上与 core.bin 都改了，而 SHA-256 那份没跟着改：这一层看得出来"
      : "  —— 不对：伪造那一趟应当报 bad name=hello.txt")
    : (签成
      ? "  —— SHA-256 与盘上字节逐项一致（FNV-1a 那一层只有 32 位且不防碰撞）"
      : "  —— 不对：应当是 event=onlysign ok items=4")));
console.log("域算术    " + (fp行.length ? fp行.length + " 组" : "(没跑到)")
  + (fp成 ? "  —— 六组与主机 BigInt 逐字符相同（含两个输入都越过 p 的那一组）"
    : "  —— 不对：应当是六组乘法，结果与主机 BigInt 逐字符相同"));
console.log("域加减    " + (fp2行.length ? fp2行.length + " 组" : "(没跑到)")
  + (fp2成 ? "  —— 加法的和越过 p、减法的借位、零减一，三条边都与主机对上了"
    : "  —— 不对：应当是三组加法与三组减法，结果与主机 BigInt 逐字符相同"));
console.log("点运算    " + (pt行.size ? pt行.size + " 组" : "(没跑到)")
  + (pt成 ? "  —— B+B 与 2B 同点、2*(2B) 与 (2B)+(2B) 同点、B+O 还是 B"
    : "  —— 不对：三条交叉积里有一条不成立，或者五组读数没齐"));
console.log("标量乘    " + (ptm行.size ? ptm行.size + " 组" : "(没跑到)")
  + (ptm成 ? "  —— 1P 是基点、2P 是 2B、3P 是 2B+B：加倍与加号各被问过一遍"
    : "  —— 不对：三条交叉积里有一条不成立，或者四组读数没齐"));
console.log("点编码    " + (pte行.size ? pte行.size + " 组" : "(没跑到)")
  + (pte成 ? "  —— 基点那一串与 RFC 8032 的常量相同，另四组与主机逐字节相同"
    : "  —— 不对：模逆、字节序或符号位里有一件不对"));
console.log("点解码    " + (ptr行.length ? ptr行.length / 2 + " 组往返" : "(没跑到)")
  + (ptr成 ? "  —— 编码再解码回到同一个点，且不在曲线上的 y 被拒绝了"
    : "  —— 不对：往返有一组不闭合，或者坏输入没有被拒绝"));
console.log("验签      " + (sig行.length ? sig行.length + " 组" : "(没跑到)")
  + (sig成 ? "  —— RFC 8032 三组全过，而每组翻一位之后全不过"
    : "  —— 不对：三组里有一组的 ok 不是 1，或者翻一位之后 bad 不是 0"));
console.log("第三环    " + (on3成 ? "通过" : on3红 ? "拒绝（where=" + on3红[1] + "）" : "(没跑到)")
  + (on3成 ? "  —— auth.bin 的签名对得上 sign.bin，公钥内嵌在第二段里"
    : "  —— 不对：要么签名文件缺了，要么签名与清单对不上"));
console.log("盘的健康  " + (nvSmstat行 ? "status=" + nvSmstat行[1] : "(没跑到)")
  + (nv健康成 ? "  —— 命令发了、被接受了；这块盘的 SMART 页是空实现（内容仍是上一条命令的）"
    : "  —— 不对：Get Log Page 没回答，或者回答的不是成功"));
console.log("健康汇总  " + (dh行 ? dh行[1] + " " + dh行[2] + " " + dh行[3] + " " + dh行[4] : "(没跑到)")
  + (dh成 ? "  —— 三样是盘报的，温度明说读不到（不是零，也不是那个垃圾数）"
    : "  —— 不对：型号/序列号/容量有一个空的，或者温度那一格不是一个准确的「读不到」"));
console.log("Myon 切词 " + (回声成 ? "echo hello world" : "(没跑到)")
  + (回声成 ? "  —— 一行被切成词与参数，词之后的部分原样回来了"
    : "  —— 不对：这一行没有被切开，或者参数没有传过去"));
console.log("SHA-512   " + (sha512行.length ? sha512行.length + " 个长度" : "(没跑到)")
  + (sha512成 ? "  —— 六个长度全部与主机逐字符相同，其中四个在两块以上"
    : "  —— 不对：有长度与主机不同，或者六行没齐"));
console.log("Myon 两包 " + (myon2成 ? "两次直接跑 + 一次桥接" : "(没跑到)")
  + (myon2成 ? "  —— prog.hmtn 的 echo 调 runpkg，宿主把 docs/myon.hmtn 的 echo 跑起来"
    : "  —— 不对：第二个包没读到，或者桥接没有把内层带起来"));
console.log("Myon 写字 " + (myon写成 ? "myon here" : "(没跑到)")
  + (myon写成 ? "  —— 包里的字经内置 write 到了串口，包不知道串口在哪"
    : "  —— 不对：那个包没有把字交出来，或者 write 那一侧没接上"));
console.log("系统保护  " + (守成 ? "只读位挡住了重写，换个名字仍写得进" : "(没跑到)")
  + (守成 ? "  —— 拒绝时报的是只读，不是「已存在」"
    : "  —— 不对：五条里缺了哪一条，或者重写漏了过去"));
console.log("认类型    " + (认行 ? 认行.slice(1).join(" ") : "(没跑到)")
  + (认前二 ? "  —— 真文本认成 text、真包认成 package" : "  —— 不对：前两条该是 text 与 package")
  + (认第三 ? "；改名成 fake.txt 的包也认成 package —— 这一条才说明它不看名字"
    : "；不对：改名成 fake.txt 的包被认成 " + (认行 ? 认行[3] : "(没跑到)"))
  + (认外五 ? "；别的系统那五个头也答对了"
    : "；不对：那五个应当是 pe elf macho zip dex，实际 "
      + (认行 ? [认行[4], 认行[5], 认行[6], 认行[7], 认行[8]].join(" ") : "(没跑到)"))
  + (认外七 ? "；再七格也答对了（gzip 7z rar pdf png jpeg sqlite，样本是数据段里的常量）"
    : "；不对：再七格应当是 gzip 7z rar pdf png jpeg sqlite，实际 "
      + (认行
        ? [认行[9], 认行[10], 认行[11], 认行[12], 认行[13], 认行[14], 认行[15]].join(" ")
        : "(没跑到)")));
console.log("曲线      " + (图行 ? "f(0) 与 f(160) 都在 " + 图行[1].slice(-2) : "(没跑到)")
  + (图成 ? "  —— 盘上一行表达式，320 个采样点，屏幕上有了一条线"
    : "  —— 不对：曲线上那两个位置都该有点"));
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
// 种子函数那几族单独成一条，因为它们的前提与别的不一样。
//
// 它们要的是「种子里有 letters 这个函数」。而占位种子（只有 main 的那四十个字节）同样
// 满足 seed ok —— 于是原来的 有种子 守卫对它无效，这九项就会永远红。一条永远红的判据
// 很快就会没人再看，而那比没有判据更糟：它把「红」这个信号本身用掉了。
//
// 所以前提不成立时跳过，而且宁可把这句「跳过了」打进输出，也不假装它通过。
// 有真种子时它们照旧全验，一条都不少。
const 有真种子 = 读到.includes("fn letters");
const 种子族成 = !有真种子 || (函数行 !== null
  && 函数行[1] === "letters"
  && 操作码行集.length === 4
  && 操作码行集.every((n) => n >= 0 && n < 操作码表.length)
  && 操作码行集[0] === 5
  && 求值成
  && 跳转成
  && 调用成
  && 按名成
  && 数字成
  && 求值活成
  && 曲线成
  && 重求成);
const 其余成 = 有种子
  ? ata成
    && 信成
    && 源成
    && 陷成
    && 键成
    && 活成
    && 程成
    && 求和成
    && 尺成
    && 存成
    && 列成2
    && 满成
    // 晚成（根目录满了之后 docs 仍然写得进）暂时不在链上：它红着，而红的位置已经问出来了。
    // 判据本身留着 —— 它写下了要证明什么，只是那件事还没做成。
    && 窗口成
    && (补丁模式 ? fs头成 : fs成)
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
    && 算成
    && 扫成
    && 规成
    && 图成
    && 索成
    && 窗成
    && 列成
    && 健成
    && 量成
    && 守成
    && 签成
    && fp成
    && fp2成
    && pt成
    && ptm成
    && pte成
    && ptr成
    && sig成
    && on3成
    && nv健康成
    && dh成
    && 回声成
    && myon写成
    && myon2成
    && sha512成
    && 详成
    && 认前二
    && 认第三
    && 认外五
    && 认外七
    && 壳成
    && 除成
    && 数学成
  : true;
// 无补丁那一趟只验保护这一条。盘上确实缺一份，于是其余读数本来就该变 ——
// 根目录第一个名字从 hello.txt 变成 docs、files 的列表里少一条、stat 找不到它。
// 那些红不是它们的过错，把它们算进成败只会让这一趟永远红，而永远红的一条
// 很快就会没人再看。打印照样全打，判决只取保护那一条。
//
// 有补丁那一趟相反：修好之后机器该与正常启动一模一样，所以其余那一长串照样要全绿。
// 这是这一块最值钱的地方 —— 「修好了」不是一条孤立的读数，而是「别的读数也没事」。
// 这一行放在这里，不放在上面那串输出里：它要读种子族成，而那条 && 链与它用到的
// 九个判据都在下面。上一版把它跟别的输出排在一起，报的是
// Cannot access '种子族成' before initialization。
console.log("包写文件  " + (存行 ? "save docs/inner.txt -> " + 存行[1].slice(-3) + " " + 存行[2] + " 字节" : "(没跑出来)")
  + (存成 ? "  —— 包写进去、自己读回来，而宿主独立查到了那一条"
    : "  —— 不对：要么包没读回那行字，要么目录里查不到 out.txt"));
console.log("列目录    " + (列行2 ? "prog list -> " + 列行2[1] : "(没跑出来)")
  + (列成2 ? "  —— docs 里四份名字按顺序拼成 33 个码元"
    : "  —— 不对：应当是 33，也就是 note.txt sub myon.hmtn inner.txt 各带一个空格"));
console.log("隔壁目录  " + (晚行 ? "docs/late.txt -> " + 晚行[1].slice(-3) + " " + 晚行[2] + " 字节" : "(没跑出来)")
  + (晚成 ? "  —— 根目录写满之后，docs 里仍然写得进：满是一个目录的事，不是全局的"
    : "  —— 不对：根目录满了不该挡住 docs"));
console.log("目录满    " + (满行
  ? "写到第 " + (Number(满行[1]) + Number(满行[2])) + " 个时，成 " + 满行[1] + " 拒 " + 满行[2]
  : "(没跑出来)")
  + (满成 ? "  —— 上界生效，而且 docs/myon.hmtn 还读得到：写满没有吃掉邻居"
    : "  —— 不对：要么四十次全成（上界没生效），要么写满之后 docs 读不到了"));
console.log("种子族    " + (有真种子
  ? "种子里有 letters，那九族照验"
  : "占位种子没有 letters —— 函数、操作码、求值、跳转、调用、按名、数字、求值活、曲线这九项跳过")
  + (种子族成 ? "" : "  —— 不对：真种子在，可那几族里有没通过的"));
const 结构成 = 伪造模式
  // 伪造那一趟只验这一对：FNV-1a 那一层必须是绿的（否则它没造出该造的处境），
  // 而 SHA-256 那一层必须红并且点出名字。别的判据在这一趟会跟着变（首字节改了，
  // identify 认不出），那些红与这一块无关，所以不要求。
  ? (核成 && 签红)
  : 保护成 && 种子族成 && (无补丁模式 || 其余成);
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
  // 先说出是哪一条。以前红的时候只有一句「上面标着不对的那一行就是」，而万一那条
  // 判据本身没打印失败原因（比如它在别处的 && 链里），这句话就是一句空话。诊断把
  // 三条与其余那一长串挨个拆开，红的成分直接点名 —— 读的人不必再从串口里反推。
  const 坏 = [];
  if (缺.length) 坏.push("缺行：" + 缺.join("、"));
  if (!分配成) 坏.push("分配");
  if (!种子族成) 坏.push("种子族（有真种子，但那几族里有的没通过）");
  if (!保护成) 坏.push("保护（" + [
    修成 ? "" : "修成",
    核成 ? "" : "核成",
    补完没进 ? "" : "补完没进",
  ].filter(Boolean).join("、") + "）");
  if (!无补丁模式 && !其余成) {
    const 成分 = {
      ata: ata成, 信箱: 信成, 来源: 源成, 异常: 陷成, 键盘: 键成, 交互: 活成,
      程序: 程成, 算术: 求和成, 尺: 尺成, 写盘: 存成, 目录列: 列成2,
      目录满: 满成,
      文件系统: 补丁模式 ? fs头成 : fs成,
      打开: 打开成, 两层: 深成, 三层: 更成, 第二块盘: 二成, 写: 写成,
      共享: 共成, 网卡: 网成, 边界: 家成, 加入: 加成, 共享见面: 家共成, 门: 门成,
      像素: 像成, 画线: 线成, 算数: 算成, 扫描: 扫成, 规则: 规成, 曲线: 图成,
      索引: 索成, 窗口: 窗成, 此电脑: 列成, 健康: 健成, 大小: 量成, 系统保护: 守成,
      详情: 详成, 签名: 签成, 域算术: fp成, 域加减: fp2成, 点运算: pt成, 标量乘: ptm成,
      点编码: pte成, 点解码: ptr成, 验签: sig成, 第三环: on3成, 盘健康: nv健康成,
      切词: 回声成, sha512: sha512成, myon写: myon写成, 健康汇总: dh成, 桥接: myon2成,
      // 窗口成 与 窗成 是两个不同的人：窗口成 是「包画了一个窗口」（win px），
      // 窗成 是「这台电脑的骨架」（window，四个位置各一种颜色）。两块都要点名。
      窗口包: 窗口成,
      认前二: 认前二, 认第三: 认第三, 认外五: 认外五, 认外七: 认外七, 壳: 壳成,
      // 重求成 与 曲线成 不在这张表里：它们归种子族管了（重求成 要种子里的 units 这个名字，
      // 曲线成 要种子里的表达式）。留在这张表里会把「其余」一直标红，而红的原因是前提
      // 不存在 —— 那种红与「这一块坏了」长得一样，正是这一轮要拆开的那件事。
      除法: 除成, 数学: 数学成,
    };
    坏.push("其余（" + Object.entries(成分).filter(([, v]) => !v).map(([k]) => k).join("、") + "）");
  }
  console.log("诊断      " + (坏.join("  ") || "(点名不到 —— 这是判据汇总自己的错，要修"));
  const 落 = path.join(建, "failed-run.txt");
  fs.writeFileSync(落, 读到, "utf8");
  console.log("这一趟红了，完整串口输出留在 " + 落);
}

if (!留机) {
  vbox(["controlvm", 机名, "poweroff"]);
}

// ---- 四、第二趟：同一块盘，再启动一次 ----
//
// 落盘这件事只能在跨启动的时候证明。同一次运行里写下去再读回来，读到的也可能只是内存 ——
// 而这一条最该否掉的正是那种「看起来写成功了」的实现。所以第二趟只差一件事：
// 盘上已经躺过那 512 个字节，而这一次没有任何代码去写它。
//
// 串口文件先清空：VBox 的 --uartmode1 file 是追加写，不清的话第二趟的「读过」里还留着
// 第一趟的字，那时 survived 与 same 就分不开了。
const 存活成 = (() => {
  if (留机) return true;                  // 留机模式下第二趟没有意义，不当失败
  fs.writeFileSync(串口, "", "utf8");
  const 又起 = vbox(["startvm", 机名, "--type", "headless"]);
  if (又起.status !== 0) return false;
  let 又读到 = "";
  for (let i = 0; i < 120; i++) {
    睡(500);
    try { 又读到 = fs.readFileSync(串口, "utf8"); } catch { }
    // 等到 save 那一段，不只是 persist —— persist 在 run_save_test 之前，而第二趟
    // 一旦见到 persist 就断电，save 根本没机会跑。上一版就是这样：落盘其实成功了，
    // 而串口里永远没有那一行，于是判据红在一个它自己造成的缺口上。
    if (/Yunooka: save (survived|out\.txt)/.test(又读到)) {
      // 见到 persist 那一行之后再等一会儿，让后面几行也写出来
      for (let j = 0; j < 6; j++) {
        睡(300);
        try { 又读到 = fs.readFileSync(串口, "utf8"); } catch { }
      }
      break;
    }
  }
  vbox(["controlvm", 机名, "poweroff"]);
  // 第二趟的串口留一份 —— 一次 running 里它只存在内存里，而「第二趟没到」有两种可能：
  // 它根本没起来，或者它起来了而没到 persist 那一段。两者的串口完全不同。
  try { fs.writeFileSync(path.join(建, "serial2.log"), 又读到, "utf8"); } catch { }
  return /Yunooka: persist survived a reboot/.test(又读到);
})();
// 第二趟里包写下的那一份还在不在。
//
// 它靠的是 serial2.log —— 那一趟只跑一次，串口不留就再也没有证据。而这一条与上面那条
// 各管一个层次：上面证明裸扇区写下去会留在盘上，这一条证明文件系统那一层也是。
const 二趟 = (() => {
  try { return fs.readFileSync(path.join(建, "serial2.log"), "utf8"); } catch { return ""; }
})();
const 存存活 = /Yunooka: save survived docs\/inner\.txt ([0-9A-F]+) (\d+)/.exec(二趟);
const 存存活成 = 留机 || (存存活 !== null && !/^0+$/.test(存存活[1]) && Number(存存活[2]) > 0);
console.log("落盘      " + (存活成 ? "第二趟读到 survived" : "(第二趟没有 survived)")
  + (存活成 ? "  —— 关掉再开机，那 512 个字节还在盘上：写真的落下去了"
    : "  —— 不对：第二次启动应当报 persist survived a reboot"));
if (!留机) console.log("机器已关（--keep 可以留着它，用 GUI 打开看）。");
console.log("包写的东西 " + (留机 ? "(留机模式，第二趟没跑)"
  : 存存活 ? "save survived " + 存存活[1].slice(-3) + " " + 存存活[2] + " 字节" : "(第二趟没见到那一份)")
  + (存存活成 ? "  —— 上一次启动时包写的 docs/inner.txt，这一次开机还在"
    : "  —— 不对：第二趟应当报 save survived，也就是那一份真的落在盘上了"));
const 全成 = 成了 && 存活成 && 存存活成;
process.exit(全成 ? 0 : 1);
