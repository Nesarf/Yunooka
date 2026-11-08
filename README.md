# Yunooka（湯の岡）

HMYR 要跑在上面的那个系统。名字取自小一孁こはね所属学寮都市「カピラ」的寮名。

分工写在 HMYR 仓库的 `design/FULLSELF.txt` 第七节：**Hiou Rengo 负责「写」，Yunooka 负责「跑」**。
宿主口归 OS，其余归 SDK。

## 现在有什么

一块能在 VirtualBox 里引导的盘，和一条判据。

```
boot/boot.asm      512 字节的引导扇区：初始化 COM1、打印一行、停机
tools/build.mjs    编它、检查它的形状、把 512 字节补成 1 MiB 的盘、转成 vdi
tools/run.mjs      挂盘、引导、读串口、比对那行字
```

跑：

```
node tools/build.mjs
node tools/run.mjs
```

## 判据

**串口里出现 `Yunooka: boot ok`。**

走串口而不是屏幕，因为 VBoxManage 能把 COM1 的字节写进主机的一个文件 —— 于是「它说得出
话吗」变成「文件里有没有那段字节」。这件事可以自动比对，不依赖截图、OCR 或者人的眼睛。
屏幕输出照样留着，用来看，不用来判。

`tools/run.mjs` 的退出码：0 那行字出现了，1 引导了但没说话，2 这一台做不了（没有
VirtualBox、没有盘）。

## 这一块砖为什么这么起

512 字节是这个国家里最小的入口。它不需要工具链之外的东西（nasm 就够），而它要么打出那行
字、要么打不出 —— 没有中间状态可以含糊过去。GRUB 与 UEFI 是之后的事，那时这块砖还在。

## 还没有的

- 读文件：它还读不到 `.hmtn`，更读不到 `.hmoca`
- 内存管理、中断、进程、驱动（磁盘、键盘、显示、网络）
- HMYR 的字节码机

## 一条踩过的坑

第一版串口打印不等发送器就绪，跑起来只收到 `nooka: boot ok` —— 开头三个字符丢了。十六个
字节的整句在 9600 波特下本来能靠 FIFO 撑过去，而第一个字节偏偏不行。加上 LSR 的 THR 空位
等待之后完整了。

## 与 HMYR 仓库的关系

Yunooka 不依赖 HMYR 仓库里的任何东西，现在连 HMYR 都还不认识。反过来也一样：拿掉 Yunooka，
HMYR 的套件应当全绿 —— 那条层次关系（基础不依赖附加）在 HMYR 的 `design/FULLSELF.txt`
第十节里写着。
