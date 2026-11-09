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
    // 全程每一行都出现、指令流四条到齐、并且两次求值都有结果，才收工；否则给满二十秒。
    // 只等前两样是不够的：求值在最后，而它前面那一长串诊断让「读到的」永远像是完整的。
    const 步数 = (读到.match(/Yunooka: op /g) || []).length;
    const 结果数 = (读到.match(/Yunooka: fn116 -> /g) || []).length;
    // 按名字找有两次（后者与前者各一次）。两次都在才收工，否则会在第二次还
    // 没写出来的时候读到只对一半的状态。
    const 按名数 = (读到.match(/Yunooka: byname/g) || []).length;
    if (全程.every((s) => 读到.includes(s)) && 步数 >= 4 && 结果数 >= 2 && 按名数 >= 2) break;
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
    && fs成
    && 打开成
    && 深成
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

if (!留机) {
  vbox(["controlvm", 机名, "poweroff"]);
  console.log("机器已关（--keep 可以留着它，用 GUI 打开看）。");
}
process.exit(成了 ? 0 : 1);
