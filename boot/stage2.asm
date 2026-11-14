; Yunooka 的第二段：从实模式一路走到 64 位长模式。
;
; 它被引导扇区读进 0x7E00。这一版做四件事：
;   一、还在实模式时，用 BIOS 读完整份种子、验前五字节 HMYRB
;   二、打开 A20、装 GDT、进 32 位保护模式
;   三、建四级页表、置 PAE 与 LME、开分页
;   四、远跳进 64 位长模式，在那里往串口打一行
;
; 为什么中间要打两行：三段之间最容易静默失败的是页表那一段 —— 错了就是三重故障重启，
; 屏幕一片黑，串口什么也没有。所以「保护模式到了」与「长模式到了」各有一行字，
; 失败时能看出断在哪一段，而不是只知道「没成」。
;
; 编译：nasm -f bin stage2.asm -o stage2.bin

[org 0x10000]
[bits 16]

; ======================================================================
; 零、第二段多大、种子从哪起
; ======================================================================
;
; 这两个数原先散在五处：boot.asm 里那句 mov al、本文件里三处 dap_lba、run_ata_test
; 里那个「种子在盘上的第一个扇区」、build.mjs 里的上限与种子偏移。每一次长个子都要
; 把它们一起改，而少改一处的症状各不相同 —— ata differ、种子魔数不对、盘建不起来、
; 编不过 —— 看着像四个不同的毛病。为一个数字返工过六次，第六次就是这一回。
;
; 现在它在这里只出现一次，其余全部由它推出来。build.mjs 会从这一行读出那个数，
; 再与它自己那份上限、boot.asm 那句 mov al、以及种子偏移逐个核对；对不上就建不起来。
; 这个是「真的占了多少」（build 那条检查要求它与实际一致），而「能长到多大」
; 是 build.mjs 里的 第二段上限扇区。两个数不是一回事：上限管 loader 读几批与种子从哪
; 起，而这个数管盘上第二段占到哪里。
stage2_sectors equ 172
loader_sectors equ 8                   ; 加载器占几个扇区，由 build 核对
seed_lba       equ 1 + loader_sectors + stage2_sectors   ; 引导 1 + 加载器 + 主体

; 索引表能装几条。它要 >= 根目录里的名字数 —— 而那个数随盘上的文件增长，
; 所以这一处与 index_buf 的大小、以及 build 那条核对是一组。
; 少一个的症状是「甲盘条目数与索引不一致」：层三列得出二十条，而索引在十六条那里
; 截断了 —— 那个诊断是对的，因为截断是这一层自己做的决定。
index_cap      equ 30

; 等键的两条时间轴，单位是 TSC 计数而不是毫秒 —— 换算成毫秒要宿主的核频，而这一层
; 不知道那个数。实测是：四圈循环走一个计数（rdtsc 跟核频，不跟某个固定晶振），
; 所以同一个数在快机器上等得短、在慢机器上等得长。这不是缺陷，正是想要的形状：
; 环境变快时预算自己变短，而不是把余量吃掉。
;
; 默认六百兆：三 GHz 上约两百毫秒，一 GHz 上约六百毫秒。宿主每 150 毫秒读一次串口，
; 两头都盖得住。盖不住的那一处（键要经过宿主才进来）由调用点把 [wait_budget] 临时加长。
poll_ticks     equ 20000000            ; 两次问信箱之间：四 GHz 上约五毫秒
wait_ticks     equ 600000000           ; 一次等键的默认预算

; 信箱盘一次读几个扇区。第 0 个是头（YUNOMBX：主机送进来的那一行），第 1 个往后
; 是补丁包（YUNOPAT：补完界面拿来修的那一份字节）。
;
; 四个而不是一个，因为补丁包要与头住在同一次读里 —— 长模式下的 ATA PIO 只碰过主盘，
; 信箱是实模式读进来的，多读三个扇区就没有第二套读盘代码要维护。0x50000 到 0x50800
; 落在同一个 64 KB DMA 段内（0x50000 正好是 64 KB 的倍数），不跨边界。
;
; 补丁容量 = (mailbox_sectors - 1) * 512 = 1536 字节，build.mjs 会核对它盖得住
; 它自己写出的补丁包。改这个数要同时看那一处。
mailbox_sectors equ 4

; ======================================================================
; 一、实模式：读种子、验魔数
; ======================================================================
stage2:
    cli
    ; 段基址现在是 0x1000，不是 0。主体住在 0x10000，而实模式的 `mov si, 标签` 只
    ; 取低 16 位 —— 0x10000 的低 16 位正好是 0，所以 ds = 0x1000 时那些标签的低 16 位
    ; 就是「相对 0x10000 的偏移」，`mov si, line2` 依旧对。
    ;
    ; 栈不放在这一段里：主体占 0x10000 到 0x37Exx，而 ss = 0x1000 会把它压在自己身上。
    ; 所以 ss 仍是 0，栈从 0x7C00 往下 —— 那一段（0x7000 到 0x7C00）是空的：
    ; 页表在 0x1000 到 0x7000，加载器在 0x7E00 到 0x8E00。
    mov ax, 0x1000
    mov ds, ax
    mov es, ax
    xor ax, ax
    mov ss, ax
    mov sp, 0x7c00
    sti
    ; 引导扇区跳过来时 dl 还带着盘号（它跳转前刚设过，而跳转不改 dl）。
    mov [drive], dl

    ; 两点实测，写在 uart_init 自己的注释里：文件后端下它无害；换成 tcpserver 后端
    ; 之后它是客人机三重故障的引信。所以它留着，而串口那条通道的结论是「用文件」。
    call uart_init                ; 先把这个 16550 设成已知状态，再往下走
    call serial_wait              ; 握手：主机连上之后才继续，输出的起点由它决定
    mov si, line2
    call serial_print

    ; 三批各读一个段。每一批都自己写一次 LBA —— 这一点是实测出来的：
    ; int 0x13 的 LBA 扩展并不保证把 DAP 里的那个 64 位 LBA 推到下一批（VirtualBox
    ; 就没有），于是第二批会从同一个位置重读。症状很绕：种子读进来了、魔数也对、
    ; 只有一个深处的字节不对（读到 29 而不是 19），因为那一段其实被第一段覆盖了。
    ;
    ; 种子读到 0x70000 起，不是 0x8000 —— 第二段自己被加载在 0x7E00，32 扇区就是
    ; 16 KB，铺到 0xBE00，而 0x8000 起的种子会把它覆盖成零。0x70000 在实模式 1 MB
    ; 之内，离得够远。
    mov dword [dap_lba], seed_lba
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x7000
    mov word [dap_count], 64
    call read_batch
    jc .seed_fail

    mov dword [dap_lba], seed_lba + 64
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x7800
    mov word [dap_count], 64
    call read_batch
    jc .seed_fail

    ; 第三批铺在 0x80000 起，紧接前两批：头一批 0x70000 铺 64 扇区到 0x78000，
    ; 第二批 0x78000 再铺 64 扇区到 0x80000，这一批 18 扇区铺到 0x82400 —— 合起来
    ; 146 个扇区，正好是 74594 字节向上取整的结果。
    ;
    ; 这一段注释原来写的是「目标是 0x30000、18 个扇区铺到 0x32400、主体上限 0x30000」，
    ; 那是种子还在 0x20000、主体上限还是 128 扇区时的账。把种子搬到 0x70000 的时候，
    ; seg 换了而注释里的数字没换，于是它读起来仍然自洽（0x32400 与 146 个扇区对得上），
    ; 三段地址却全错了。改地址的时候注释要重新算一遍，不能只跟着替换 —— 这也是那一次
    ; 全局替换把 0x200000 改成 0x700000 的同一种错。
    ;
    ; 主体（第二段）从 0x10000 起、上限 0x28000（192 扇区），种子从 0x70000 起 ——
    ; 中间空着 0x28000..0x70000 那 288 KB，所以这一批碰不到主体的代码。
    mov dword [dap_lba], seed_lba + 128
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x8000
    mov word [dap_count], 18
    call read_batch
    jc .seed_fail

    ; 魔数在 0x70000 起，所以用 es 指向它，与 ds 里的 seed_magic 比。
    push es
    mov ax, 0x7000
    mov es, ax
    xor di, di
    mov si, seed_magic
    mov cx, 5
    call same_es
    pop es
    jc .seed_bad

    mov si, line3ok
    call serial_print
    ; 这一句原先在 ds = 0x1000 下读 [seed_bytes]，而那条指令是 66 A1 28 03 ——
    ; 16 位地址只取低 16 位（0x328），于是它读的是 0x10328，而不是 0x20328。
    ; 它一直是错的，只是那个地址上以前恰好躺着 40，所以数字看着对 ——
    ; 直到第二段涨到 130 扇区，0x328 处换成了别的东西，4218691752 才露出来。
    ; 修法不是改表达式：低 16 位在 ds = 0x2000 下正好指到 0x20328。
    push ds
    mov ax, 0x2000
    mov ds, ax
    mov eax, [seed_bytes]
    pop ds
    call put_num
    mov si, line_nl
    call serial_print
    jmp .go32

.seed_bad:
    ; 种子读到的东西不对，但它能不能进 64 位是另一件事 —— 两件事分开报，所以这里
    ; 不停机，继续往下走。判据因此能同时回答两个问题：种子对了吗、长模式到了吗。
    mov si, line3bad
    call serial_print
    jmp .go32
.seed_fail:
    mov si, line3fail
    call serial_print
    jmp .go32
.hang:
    cli
    hlt
    jmp .hang

; ---- 进 32 位保护模式 ----
.go32:
    ; 从这里到 build_idt 装好之前，任何中断都是三重故障 —— IDT 里那些项还是零
    ; （present = 0），而处理器遇到一个没有处理者的中断只会一路往下栽。
    ; 症状是一行字打到一半就没了：实测见过「protected mod」断在半路，看起来像串口
    ; 出了问题，其实是 CPU 复位了。
    ;
    ; 这一句 cli 与 long_entry 里那一句是同一个治法，理由也一样。而它是**偶发**的：
    ; 定时器在 stage2 开头的 sti 之后一直在走，撞不撞上只看那几毫秒里恰不恰好来一次。
    ; 所以这类东西「一次绿」从来不算验过。
    cli
    ; 设 VGA 320x200x256：一个字节一个像素，帧缓冲落在 0xA0000。
    ;
    ; 为什么在实模式做：长模式里没有 BIOS，而「设显示模式」只有 BIOS 会。所以这件事
    ; 与读盘一样，必须发生在还叫得上 int 的时候。
    ;
    ; 为什么不设更高（比如 VBE 的 1024x768）：这一版只要「一块能写能读的内存」。
    ; 0x13 是唯一一个不需要额外协议、不需要问能力就能得到的模式 —— 它老、它小、它一定在。
    ;
    ; 设完不清屏反而好：屏上留着模式切换那一刻的内容，而「写进去的东西出现在屏幕上」
    ; 这件事要由截图看，串口只能证明内存可写可读。
    mov ax, 0x0013
    int 0x10
    ; 文件系统的扇区先读进来：超级块、根目录、docs 目录、docs/sub、hello.txt、
    ; note.txt、cmd.txt、repl.txt、math.txt、prog.hmtn、eicar.txt、clean.txt、
    ; rules.txt、plot.txt、fake.txt、core.bin —— 一共十七个，从第 1024 号起。
    ;
    ; 这个数曾经是十五，而盘上那时已经有十六份了：fake.txt 落在第 1039 号扇区，
    ; 而预读只盖到 1038。于是 fs_load(1039) 照样算出地址，只是那个地址在预读区之外，
    ; 里面不是这个文件 —— 症状是 identify 把 fake.txt 认成 unknown，而「魔数不对」与
    ; 「根本没读进来」在输出上分不开，于是那一条红着挂了好几轮。
    ;
    ; 盘上的东西每多一份，这个数就要跟一次；而它也必须与 build 写进去的布局一致，
    ; 否则预读区里少一份、fs_load 却照算不误。
    ;
    ; 为什么不留给长模式：长模式里没有 BIOS，而 ATA PIO 在虚拟机模拟的 IDE 上不稳定 ——
    ; 重试、0xFF、drain、逐 word、读前延迟，五轮补丁都没让它站住。BIOS 读盘从加电到
    ; 现在一次没出过错，所以这里把不可靠的那一步换成可靠的那一步。
    ;
    ; 代价是真的：「能打开哪些文件」从此在启动时定死。换来的是文件系统这一层不用再跟
    ; PIO 的时序搏斗，而 fs_lookup 与两层布局本来就不在怀疑范围内。
    mov dword [dap_lba], 1024
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x4000
    mov word [dap_count], 40       ; preread-sectors: 预读几个扇区，这个数由 build 核对
    call read_batch
    jnc .fs_ready
    mov si, line_fs_preread
    call serial_print
.fs_ready:

    ; 信箱：第二块 IDE 盘，primary slave，BIOS 盘号 0x81。
    ;
    ; 为什么要有它：串口那条通道只能往外说（四条实测写在下面那一节里），而「主机往里送
    ; 一行」这件事必须有另一条路。这块盘是裸的 —— 主机用普通文件写入、客人机只读它的
    ; 第 0 个扇区 —— 所以换一条输入不必重建主盘。
    ;
    ; 三条读数分开，因为它们指向三种不同的坏法：no mailbox 是盘都读不到（没挂上、或盘号
    ; 不对），mailbox bad 是读到了但魔数不对（主机没写、或写到了别的偏移），
    ; mailbox ok 才是这条通道成立。
    ; 一次读四个扇区：头（YUNOMBX）在前 512 字节，补丁包（YUNOPAT）从第 512 字节起。
    ; 四个扇区落在同一个 64 KB 段内（0x50000 正好是那一段的起点），所以不跨 int 0x13
    ; 那条 DMA 边界 —— 那条界在引导扇区那一层已经咬过一次，主体原先 64 扇区的上限就是它。
    ;
    ; 曾经有一次运行死在这一段之后：串口停在「protected mode ok」的第一个字后面，
    ; 既不报错也不重启；而同样的代码在两次重跑里都正常跑完全程。所以那一次当成偶发
    ; 记着，不当成结论。形状留在这里，证据留在 design/GUARD.txt 的后记里。
    mov al, [drive]
    mov [mbox_save], al
    mov byte [drive], 0x81
    mov dword [dap_lba], 0
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x5000
    mov word [dap_count], mailbox_sectors
    call read_batch
    setc al
    mov [mbox_carry], al
    mov al, [mbox_save]
    mov [drive], al
    cmp byte [mbox_carry], 0
    jne .mbox_fail
    push es
    mov ax, 0x5000
    mov es, ax
    xor di, di
    mov si, mbox_magic
    mov cx, 8
    call same_es
    pop es
    jc .mbox_bad
    mov si, line_mbox_ok
    call serial_print
    jmp .mbox_done
.mbox_bad:
    mov si, line_mbox_bad
    call serial_print
    jmp .mbox_done
.mbox_fail:
    mov si, line_mbox_fail
    call serial_print
.mbox_done:

    ; β 盘：另一块盘、另一个文件系统、同一个格式。挂成 secondary master，BIOS 盘号 0x82，
    ; 预读扇区 0 到 0x60000。
    ;
    ; 为什么不与 α 共用「预读」那一段：两块盘的地址不能重叠，而 0x60000 与 0x40000 之间
    ; 隔了 128 KB，α 那 11 个扇区（5.5 KB）碰不到它。读失败也照走 —— 盘没挂上时，
    ; β:/… 会在查找那一步说 not found，而不是让整个启动停下来。
    mov al, [drive]
    mov [mbox_save], al
    mov byte [drive], 0x82
    mov dword [dap_lba], 0
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x6000
    mov word [dap_count], 4
    call read_batch
    jnc .fs2_ok
    mov si, line_fs2_fail
    call serial_print
.fs2_ok:
    mov al, [mbox_save]
    mov [drive], al

    ; A20 用 BIOS 的 int 0x15, ax=0x2401 来开，不走 8042 键盘控制器那一路。
    ; 原先那一版（out 0x64 / 0x60）在 VirtualBox 上直接把 out 卡住了 —— 串口停在
    ; 观测字节后面，看起来像挂在保护模式上。BIOS 调用失败了也不管：这块固件
    ; 通常已经把 A20 打开，而 1 MB 以上的读写在后面的测试里会自己露馅。
    mov ax, 0x2401
    int 0x15

    lgdt [gdt_desc]

    mov eax, cr0
    or eax, 0x1                   ; PE
    mov cr0, eax
    ; 远跳要带 dword 前缀 —— 也就是 32 位偏移。目标是 32 位代码段，而 16 位模式下
    ; 默认的 `jmp 0x08:label` 只送 16 位偏移，段基址是 0，于是跳到
    ; 「label 的低 16 位」那个地址上。
    ;
    ; 这一处原来是对的，而那是**碰巧**：主体住在 0x7E00 的时候，0x7E00 + 偏移还不到
    ; 0x10000，低 16 位正好等于绝对地址。主体搬到 0x10000 之后，低 16 位就只剩偏移，
    ; 而绝对地址是 0x1xxxx —— 于是这一次跳到 0x0000 附近，症状是「mailbox ok 之后
    ; 没有下文」，看起来像保护模式那一段自己崩了。
    jmp dword 0x08:protected

; ---- 实模式下的四个例程 ----
; 它们只在进保护模式之前用得到。32 位与 64 位各有一份自己的打印，因为那两段里
; 栈宽与寄存器都变了；共用要靠一个统一的调用约定，而这一层还不值那个钱。

; ---- 串口这一层的实测记录 ----
;
; 这一节不是设计，是四趟实验的结果。写在这里是因为它约束了客户机代码能怎么写。
;
; 一、文件后端（--uartmode1 file <路径>）单向，可靠。VM 说得出来，主机写不进去。
;     现在主判据走的就是这一条。加不加 uart_init 都一样，二十六行全在。
;
; 二、tcpserver 后端（--uartmode1 tcpserver <端口>）：主机连得上，客人机一个字节也
;     送不出来。跑到六十秒仍是 running、仍是零字节。摘掉 uart_init 一样，把 serial_wait
;     整个摘掉也一样 —— 连引导扇区那句 boot ok 都出不来。
;     所以原因不在握手，也不在初始化，在「客人机的串口 port I/O 在这条后端上出不去」。
;     两次旧实验记成「时序不对、输出早了」，那个解释是错的：真相是输出从来没出去过。
;
; 三、uart_init 加上 tcpserver，客人机会三重故障（VINF_EM_TRIPLE_FAULT），发生在从硬盘
;     引导之后约零点一秒。注释掉 uart_init 就不再崩 —— 于是「崩」与「不通」是两件事，
;     别混成一件。崩的原因没查到底：FCR 清 FIFO 与 MCR 拉 DTR/RTS 这两条最可疑，
;     但它们各自在文件后端下都无害。
;
; 四、pipe 后端两条语法都不通。--uartmode1 pipe <路径> 在 7.2 上报 Invalid parameter；
;     --uart-mode1 "client pipe#名字" 把整串当设备名，报 Failed to open host device
;     (VERR_INVALID_HANDLE)。手册里的 server pipe#name / client pipe#name 与实际
;     解析器对不上，这一条到此为止，不值得再猜。
;
; 结论：在 VirtualBox 7.2 上，这台机器的串口只有文件模式能用，而它是单向的。要让主机
; 把字节送进客户机，得换一条完全不同的路 —— 一块小盘当信箱是眼下最直的候选。
;
; 把 UART 设成 8N1、115200、FIFO 打开、DTR 与 RTS 拉起来。
;
; 为什么现在才补：这一路的输出一直是对的，于是「串口能用」看起来早已成立。但输出只
; 用到发送那一侧，而上电默认值对发送够用 —— 接收那一侧从来没被设过。两次 tcpserver
; 「连得上、收不到」都把怀疑放在通道上，而这里三个寄存器一次也没被检查过：
;
;   LCR（0x3FB）上电是 0，恰好就是 8N1 且 DLAB=0 —— 运气好而已，不是设过
;   FCR（0x3FA）上电是 0，FIFO 关着 —— 只收一个字节，读走才收下一个，不致命
;   MCR（0x3FC）上电是 0，DTR 与 RTS 都没拉起来 —— 这一条才是要命的：对端看到
;   「设备没准备好」，可能一个字节都不发过来，而主机那一侧只看到「连上了」
;
; 所以这个例程不为猜，只为把三个变量变成常量。加完之后即使通道照旧不通，也排除了
; 「设备侧没准备好」这一种解释。
uart_init:
    push ax
    push dx
    mov dx, 0x3FB                   ; LCR
    mov al, 0x80                    ; DLAB=1：接下来两行写的是分频数
    out dx, al
    mov dx, 0x3F8                   ; DLL
    mov al, 0x01                    ; 分频数 1 → 115200
    out dx, al
    mov dx, 0x3F9                   ; DLM
    xor al, al
    out dx, al
    mov dx, 0x3FB                   ; LCR
    mov al, 0x03                    ; 8 位、无校验、1 停止位，DLAB=0
    out dx, al
    mov dx, 0x3FA                   ; FCR
    mov al, 0xC7                    ; 开 FIFO、两个方向各清一次、触发点 14 字节
    out dx, al
    mov dx, 0x3FC                   ; MCR
    mov al, 0x0B                    ; DTR | RTS | OUT2
    out dx, al
    mov dx, 0x3F9                   ; IER
    xor al, al                      ; 全程轮询，不接中断
    out dx, al
    pop dx
    pop ax
    ret

; 等主机发来一个字节 —— 握手。
;
; 原本的理由是「主机连得晚，启动那二十来行已经写完，输出丢了」。这一条被推翻了：
; 现在知道在 tcpserver 后端下，客人机连第一个串口写都做不出来（见下面那段记录）。
; 所以这个握手在文件模式下没有对象，只是一个很短的等待 —— 十万次约零点一秒。
;
; 留着它是因为它不花钱，而一旦串口那条通道以后有真双向的后端，它就是输出的起点开关。
serial_wait:
    mov ecx, 100000
.w1:
    mov dx, 0x3FD
    in al, dx
    test al, 0x01
    jnz .got
    dec ecx
    jnz .w1
    ret
.got:
    mov dx, 0x3F8
    in al, dx
    ret

; 一批读：按 DAP 里的段:偏移与 LBA 读进去。进位由 int 0x13 给出，原样交回。
read_batch:
    push si
    mov si, dap
    mov ah, 0x42
    mov dl, [drive]
    int 0x13
    pop si
    ret

; 比较 ds:si 与 ds:di 各 cx 字节。相等清进位，不等置进位。
same:
    push si
    push di
.loop:
    test cx, cx
    jz .yes
    lodsb
    cmp al, [di]
    jne .no
    inc di
    dec cx
    jmp .loop
.yes:
    pop di
    pop si
    clc
    ret
.no:
    pop di
    pop si
    stc
    ret

; 比较 ds:si 与 es:di 各 cx 字节。种子读在 0x70000 起，超出 ds 能指的偏移，
; 所以那一侧用 es。相等清进位，不等置进位。
same_es:
    push si
    push di
.loop:
    test cx, cx
    jz .yes
    lodsb
    cmp al, es:[di]
    jne .no
    inc di
    dec cx
    jmp .loop
.yes:
    pop di
    pop si
    clc
    ret
.no:
    pop di
    pop si
    stc
    ret

; 串口打印字符串（以零结尾）。每字节先等 LSR 的发送器空位 —— 没有这个等待，
; 头几个字节会丢（这一条是第三块砖时踩出来的）。
serial_print:
    lodsb
    test al, al
    jz .done
    mov dx, 0x3FD
.wait:
    in al, dx
    test al, 0x20
    jz .wait
    mov al, [si-1]
    mov dx, 0x3F8
    out dx, al
    jmp serial_print
.done:
    ret

; 打印 eax 的十进制值。除法先给出低位，所以余数压栈、最后倒着弹出来。
; 用 32 位是因为种子七万多字节，十六位装不下。
put_num:
    push ebx
    push ecx
    push edx
    mov ebx, 10
    xor ecx, ecx
.divide:
    xor edx, edx
    div ebx
    push edx
    inc cx
    test eax, eax
    jnz .divide
.emit:
    pop eax
    add al, '0'
    call put_ch
    loop .emit
    pop edx
    pop ecx
    pop ebx
    ret

; 一个字节进串口（值在 al 里），带发送器就绪等待。
put_ch:
    push ax
    push dx
    mov ah, al
    mov dx, 0x3FD
.wait:
    in al, dx
    test al, 0x20
    jz .wait
    mov al, ah
    mov dx, 0x3F8
    out dx, al
    pop dx
    pop ax
    ret

; ======================================================================
; 二、32 位保护模式：打一行、建页表、进长模式
; ======================================================================
[bits 32]
protected:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    mov esi, line4
    call puts32

    ; 清 0x1000 到 0x4000（三个页表），再从零填起。清是因为这段内存里原本是什么
    ; 我们不知道 —— 一个残留的非零位会让 page fault 出现在别处。
    mov edi, 0x1000
    xor eax, eax
    mov ecx, 0x0C00
    rep stosd

    ; PML4[0] -> 0x2000（PDPT），present + writable
    mov dword [0x1000], 0x2003
    ; PDPT[0] -> 0x3000（PD），present + writable
    mov dword [0x2000], 0x3003
    ; PD：512 个 2 MB 大页，映前 1 GB。内核还小，全映上比挑着映省事，
    ; 而且以后加东西不用回来改页表。
    ;
    ; 这个 0x3000 是 PD 的地址，不是 PML4 的 0x1000 —— 写错的话 510 行那一句
    ; 立刻被覆盖，而页表遍历会去物理 0 找 PDPT（那里是中断向量表），
    ; 症状是进长模式那一跳之后没有任何输出。这一处曾经被一次「全局把 0x3000 换成
    ; 0x1000」的替换误伤过：那次替换本意只改主体的段基址。
    mov edi, 0x3000
    mov eax, 0x83                 ; present + writable + large page
    mov ecx, 512
.fill_pd:
    mov [edi], eax
    add eax, 0x200000
    add edi, 8
    loop .fill_pd

    ; CR3 指向的是**最上面那一级** —— 也就是 PML4（0x1000），不是 PD（0x1000）。
    ; 这一处写错一次：第一版把 0x1000 放进了 CR3，于是开分页的那一瞬间 CPU 把 PD
    ; 当成 PML4 去走，走出来的地址全是垃圾，表现是远跳之后没有任何输出。
    mov eax, 0x1000
    mov cr3, eax

    mov eax, cr4
    or eax, 0x20                  ; PAE
    or eax, 0x600                 ; OSFXSR | OSXMMEXCPT —— 长模式下 SSE 指令要用这一位
    mov cr4, eax

    mov ecx, 0xC0000080           ; EFER
    rdmsr
    or eax, 0x100                 ; LME
    wrmsr

    mov eax, cr0
    or eax, 0x80000000            ; PG
    or eax, 0x2                   ; MP，与上面那两位配套
    mov cr0, eax

    jmp 0x18:long_entry

; 32 位下的串口打印。每个字节先等 LSR 的发送器空位 —— 与实模式那一份同一个理由，
; 只是这里不能用 BIOS，得直接碰端口。
puts32:
    lodsb
    test al, al
    jz .done
    call putc32
    jmp puts32
.done:
    ret
putc32:
    push eax
    push edx
    mov ah, al
    mov dx, 0x3FD
.wait:
    in al, dx
    test al, 0x20
    jz .wait
    mov al, ah
    mov dx, 0x3F8
    out dx, al
    pop edx
    pop eax
    ret

; ======================================================================
; 三、64 位长模式
; ======================================================================
[bits 64]
long_entry:
    ; 关中断。这一行是被一次偶发崩溃逼出来的：串口、ATA、键盘三条路都在不同位置
    ; 抛过 #GP 与 #DF，位置不固定、号码不固定 —— 那是「有东西随时插进来」的样子，
    ; 不是某条指令写错了的样子。进长模式这一路上从没关过中断，而 BIOS 装的 PIC
    ; 在长模式下仍然会送中断来，IDT 里 32 号往后全是 0（present=0），于是一次定时器
    ; 中断就是一次 #GP，而 #GP 处理里再撞一次就成了 #DF。
    ;
    ; 这一版全部靠轮询，没有任何东西需要中断，所以关掉它不损失什么。以后要收中断时，
    ; 得先把 PIC 重映射到 0x20 之后、把用到的 IRQ 在 IDT 里填上，再 sti —— 顺序反了
    ; 就会像这次一样，症状落在完全无关的三条路上。
    cli
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov rsp, 0x90000

    mov rsi, line5
    call puts64

    ; ---- 三·零、IDT ----
    ; 放在这一串测试之前：从这一刻起，任何一个异常都有名字，而不只是一次重启。
    call build_idt
    mov rsi, line_idt_ok
    call puts64

    ; ---- 三块分配 ----
    ; 每一块分配到的地址都打到串口上，因为「分配器能不能用」这件事没有别的观测点：
    ; 不打印地址，就只能知道它没崩，而不知道它给了什么。
    mov rax, 16
    call alloc64
    call show_alloc

    mov rax, 48
    call alloc64
    call show_alloc

    mov rax, 100
    call alloc64
    call show_alloc

    ; ---- 堆自检 ----
    ; 上面三条只证明分配器「在递增且对齐」，没有证明那些地址真的可读写。
    ; 这一块补上那一半：分配 64 字节、填一个已知模式、再原地读回来逐字节比。
    ; 写得进去、读得出来、并且读到的是自己写的东西 —— 三件都成立，才算这块内存属于它。
    mov rax, 64
    call alloc64
    mov rbx, rax              ; 保住首地址：rep stosb 会把 rdi 推到末尾
    mov rdi, rax
    mov rcx, 64
    mov al, 0xA5
    rep stosb

    mov rdi, rbx
    mov rcx, 64
    mov al, 0xA5
    repe scasb                ; 每一字节都与 al 比，不等就提前停
    jne .heap_bad

    mov rsi, line_heap_ok
    call puts64

    ; ---- 时钟自检 ----
    ; 在这一格之前，这台机器没有「现在过去了多久」这个概念。等键的预算是循环次数，
    ; 而同一个数字在两台机器上是不同的墙钟时长 —— 那正是同级那一条判据卡住的地方：
    ; 宿主每 150 毫秒读一次串口，客人机却在几十毫秒里把预算烧完了。
    ;
    ; rdtsc 不需要端口、不需要中断、不需要校准就能读。它的绝对频率不能假定（那是
    ; 宿主的事），所以这里不换算成秒，只问一件事：让一段真有指令在跑的活过去之后，
    ; 这个数变了没有、变了多少。变了才谈得上「等一会儿」。
    call tsc_now
    mov [clock_a], rax
    mov rcx, 4000
.clock_spin:
    add rax, rcx
    dec rcx
    jnz .clock_spin
    call tsc_now
    sub rax, [clock_a]
    mov rsi, line_clock_head
    call puts64
    call put_num64
    call put_nl64

    ; 第二件：这个计数每秒走多少。第一件只说「它在走」，这一件给出换算率 ——
    ; 有了它，超时打印的那个数才是一段时间，而不是一个只有自己看得懂的量。
    call clock_calibrate
    mov rsi, line_clock_rate
    call puts64
    call put_num64
    call put_nl64

    ; 没有种子就不读它的头。否则从零里会读出一个「版本 0、0 个函数」，而第一条指令
    ; 那个 0 还会被翻成「加」—— 垃圾被翻译成漂亮数字，看起来像真读懂了。
    ; 判据要的是「读得懂」，不是「读得出数」。
    cmp dword [seed_bytes], 0
    je .hang64

    call seed_header
    call fn_probe
    call run_and_report
    call run_fn116_twice
    call call_test
    call call_report
    call run_by_name_twice
    call run_is_digit
    call run_serial_echo
    call run_key_poll
    ; 这一条曾经被挪开过：当时它偶发抛 #GP/#DF，于是用信箱里一个开关把它踢出主链。
    ; 后来查到根因不在 PIO —— 是长模式下一直开着中断，BIOS 的 PIC 仍在送定时器中断，
    ; 而 IDT 里 32 号往后全是 0。long_entry 加了一句 cli 之后，三趟连着都是 same 512。
    ; 所以它回到主链上，无条件跑。
    ; 自查自修放在一切文件读取之前。
    ;
    ; 这不只是顺序偏好。修补真的要写文件系统，而 fs_write_file 是把新条目追加到目录
    ; 末尾的 —— 于是「修好之后」与「修好之前」的目录顺序不同。放在前面，后面每一条
    ; 读数看到的都是修好那份盘；放在后面，前面几条会先撞上缺的那一份，而它们的红与
    ; 保护这一块无关，只是被时序牵连。一条因为别的原因变红的判据比没有判据更费人。
    call run_core_test
    call run_sign_test
    ; 第三环紧跟在第二环后面：它要读的 sign.bin 正是上一行刚刚逐项核对过的那一份。
    ; 顺序反过来的话，第三环会给一份还没被第二环看过的清单作证 —— 而那不是它该答的问题。
    call run_onlysign3_test
    ; SHA-512 回到主链上了。
    ;
    ; 它曾经被摘下来一整轮，原因是「单块全对、两块全错」，而错因最后落在 feed-forward
    ; 的位置上：加回初值是**每个块**各做一次（H(i+1) = H(i) + rounds(H(i), block)），
    ; 而那时写成了「所有块跑完之后加一次初值」—— 对单块的消息恰好等价，两块起就全错。
    ; 那个错法在串口上和「压缩函数写错」分不开，所以它花了很久才被找到。
    ;
    ; 摘下来的理由现在不成立了，所以它回来了，判据照旧先验红：六行摘要要与主机逐字符相同。
    call run_sha512_test
    ; 第三环的第一块砖：域算术 mod 2^255-19。
    ;
    ; 它排在 SHA-512 后面是有讲究的：验签要的那次哈希是 SHA-512 算的，而域算术要的
    ; 那条链是乘法。两条都错的时候，串口上只能看到「验签不过」一句，分不出是谁。
    ; 所以两条各自先有判据，各自与自己主机上的对应物逐字符对，之后才允许它们合流。
    call run_fp_test
    call run_fp2_test
    ; 点运算压在域算术之上。它的判据是三条交叉积相等，由主机那边判 —— 固件只把四份
    ; 坐标打出来，因为「两个投影表示是不是同一个点」需要乘，而那一侧已经有 BigInt。
    call run_pt_test
    ; 标量乘压在点加与点倍上。它的三条判据全部与前面已经站住的东西比 —— 一个能过
    ; 前两层的实现，不该在这里才第一次被问到「3P 是不是 2P 加 P」。
    call run_pt_mul_test
    ; 编码是验签链上唯一输出到外面的地方：验签比的是两个点的编码。它压住模逆、乘法、
    ; 字节序与符号位四件事，所以它单独有一组判据，而不是躲在验签里。
    call run_pt_enc_test
    ; 解码压在编码上，判据是往返：编码再解码必须回到同一个点。它同时压住「拒绝坏输入」
    ; 这一半 —— 一个任何输入都接受的实现在四个正确输入上全对，而在那一个上露馅。
    call run_pt_dec_test
    ; 第三环的最后一块：把上面每一层串起来。它是唯一一条「不引入新原语」的判据 ——
    ; 只验串得对不对，而串错了几乎总是下面某一层的意思，不是这一段的。
    call run_pt_verify_test
    call run_ata_test
    call run_fs_test
    ; 第二个包（docs/myon.hmtn）必须排在那些写操作之前。
    ;
    ; 预读区是启动时读进来的一份快照，而 fs_write_file 与修补会往它里面写。docs 那一页
    ; 在后来的某一次写之后就不再是盘上那一份了：诊断打出来的 80 字节里，note.txt 那一条
    ; 的起始与长度都变了（1049 与 19，而盘上是 1028 与 24）。
    ;
    ; 所以「查不到」不是查找的错，是它查的那一份内存已经不干净。排在写之前，它读到的
    ; 就是盘上的原样 —— 而这也解释了为什么同一目录的 note.txt 那条判据一直是绿的：
    ; 它查得早。
    call run_myon2_test
    call run_fs_open
    call run_fs_open2
    call run_fs_open3
    call run_fs_write
    call run_guard_test
    call run_share_test
    call run_home_test
    call run_gate_blocked
    call run_homeshare_test
    call run_gate_test
    call run_clear_test
    call run_pixel_test
    call run_line_test
    call run_calc_live
    call run_scan_test
    call run_rules_multi
    call run_plot_test
    call run_persist_test
    call run_index_test
    call run_explorer_test
    call run_kohane_list_test
    call run_kohane_stat_test
    call run_identify_test
    ; 第十六格那份样本不是只有四个字节，它按 design/HMGK.txt 的布局写成一份真的头。
    ; 这一条把布局读一遍：版本、BPM、结构段字节数、pattern 数。
    call run_hmgk_test
    ; 同一份格式的另一种活法：它被嵌在别的程序里，魔数不在偏移 0。
    call run_hmgk_embed_test
    call run_pci_scan
    ; AHCI 那两个探测不再上主链。它在两个芯片组上都判死了（六个 port 的 PxSSTS 全零，
    ; 而 BIOS 通过同一个控制器访问过盘），而一条已经查清的失败不该继续占着串口 ——
    ; 与 run_health_test / run_smart_test 同一个处理。
    ; 代码留着不删：map_page_2m 与 pci_write 是通用的（一 GB 之外的物理地址、以及
    ; 配置空间的写），而整条链、九条读数与六条排除写在 design/AHCI.txt 里。
    call run_nvme_probe
    call run_nvme_health
    call run_shell
    call run_repl
    call run_div_test
    call run_div_report
    call run_math
    call run_shell_live
    call run_repl_live
    call run_program
    ; 同一份包里的第三个函数：算 40 + 2。上面那条是常量返回，这一条要走算术。
    call run_prog_sum_test
    ; 第四个函数：画一个窗口。三层矩形，三种颜色。
    call run_win_test
    ; 包自己写字：内置 text。
    call run_prog_text_test
    ; 包把宿主递进来的那一行画到屏幕上：界面对话的前一半。
    call run_prog_echo_test
    ; 窗口与文字合起来：一个框加上它自己说的话。
    call run_prog_title_test
    ; 裁剪：字画到窗口外面该消失。
    call run_prog_clip_test
    ; 窗口里显示一个文件：第三个内容来源。
    call run_prog_file_test
    ; 写槽：包里第一次能改自己的状态。
    call run_prog_set_test
    ; 循环：包里第一次转起来。
    call run_prog_loop_test
    ; 全局：包里第一样比一次调用更长寿的东西。
    call run_prog_global_test
    ; 拖动：同一个函数画在两个地方。
    call run_prog_drag_test
    ; 一帧：擦旧位置、改坐标、画新位置。
    call run_prog_frame_test
    ; 重绘：同一个函数，两帧画出不同的字。
    call run_prog_retitle_test
    ; 过桥：内层包返回的值被原样带回来。
    call run_prog_bridge_test
    ; 送值：外层把 7 递进桥里，内层加一，带回来 8。
    call run_prog_bump_test
    ; 重画：擦窗口、按全局选标题、把输入的那一行画进内容区。
    call run_prog_redraw_test
    ; 移位：窗口的位置来自全局，而不是包里的常量。
    call run_prog_shift_test
    ; 两值：两个值一起过桥，内层把它们加起来。
    call run_prog_sum2_test
    ; 顺序：减法不交换，于是「谁落进哪个槽」第一次有判据。
    call run_prog_sub_test
    ; 落点：内层拿到的两个值是坐标，它在上面画字。
    call run_prog_draw_test
    ; 尺寸：宽与高也来自全局，窗口能变大变小。
    call run_prog_size_test
    ; 高位：全局区扩到三十二格，编号 20 可用。
    call run_prog_high_test
    ; 两窗：两个窗口各有自己一组格子，挪第二个不伤第一个。
    call run_prog_two_test
    ; 信箱：运行时的第二条输入路 —— 没有人按键，键从第二块盘上来。它排在所有键盘等待
    ; 之前，因为空转时轮询意味着「谁在等，谁拿到」—— 消息只有一条，而前面任何一个等待
    ; 都会先把它吃掉（实测：移窗那一次的等待拿走了它，而它恰好也是右键的码，所以窗口
    ; 真的挪了，只是判据没看在它身上）。
    call run_mbox_live_test
    ; 同级：同一个窗口被两条路各操作一次 —— 这一格挂起过一轮，等的正是刚刚落地的时钟。
    ;
    ; 挂起时挡路的是：两趟必须由两条不同的路送，而第一趟的键盘键要靠宿主「看到握手之后
    ; 再送」。宿主每 150 毫秒读一次串口，而当时 wait_arrow 的预算数的是循环次数 —— 在虚拟
    ; 机上几十毫秒就烧完，于是键总在放手之后才到。调预算是猜，三个量级都试过，没有变好。
    ;
    ; 现在预算是 rdtsc 量的墙钟，于是「等多久」成了这一层能说清的事 —— 这一格因此
    ; 又能往下推一步：超时的时候串口会说等掉了多少个计数，于是「预算不够」与「键没来」
    ; 第一次能分开。而分开之后看到的是第二件：把预算加大十倍（三乘十的十次方）也照样
    ; 等满，而同一段代码、同一个送法在相邻的「事件行」那一处，用默认预算（六乘十的八次方）
    ; 就等到了。所以这一次不是时钟的事，是那一次宿主没把键送到 8042 —— 差别在那一刻
    ; 宿主自己的处境里，而不在等待长度里。下一步是先量宿主那一侧（看到 same ready 到
    ; vbox 返回之间有多少毫秒），而不是再动这个数。
    ;
    ; 那个数量出来了：四十五毫秒（按下）加一百七十五毫秒（放开），两次都返回 0、没有错误。
    ; 而校准给出的换算率是三到四个 Ghz，于是「三乘十的十次方个计数」读成七点七秒 ——
    ; 七点七秒里键没到，那不是等待太短。
    ;
    ; 后来知道那七点七秒为什么白等：宿主的键盘分支在那之前每轮都送一次 x，十五次
    ; vbox 调用（每次四十五到一百七十五毫秒）堆在一起，正压在 same ready 那一段上。
    ; 那一段修好之后（读串口提到循环开头、run_key_poll 加了 key ready 握手），这一处
    ; 的等待回到正常量级：四乘十的九次方，约一点四秒。
    ;
    ; 一点四秒也等不到，而宿主那一侧同时报的是四十六毫秒加一百六十六毫秒、两次都返回 0。
    ; 所以这件事与时间、与送法、与那十五个 x 都无关：VBoxManage 说它收了，而 8042 的
    ; 输出缓冲一次都没亮。相邻的「事件行」用的是同一段代码与同一种送法，它在默认预算里
    ; 拿到了键 —— 差别只剩「那一次注入有没有落到控制器上」，而这不是这一层能看见的。
    ; 这一条第三次挂起，而每一次挂起都比上一次更窄：这一次排掉的是「等待长度」。
    ; 而 drain_keys 那一探给出了否证：整趟只有一次清到字节，且不在 same ready 那里 ——
    ; 等待开始时缓冲是空的。所以「键没到」不是被旧字节挡住的，是真的没有落进控制器。
    ; 这一条第四次挂起，而这一次排掉的是「缓冲里有东西挡着」。剩下的只有一条路要看：
    ; 宿主那一次 controlvm 调用在 VBox 自己的日志里是什么结果 —— 而 VBox 没有留日志。
    ; 于是换一个更便宜的可能：等待期间每五毫秒读一次盘，而每次 in 都是一次虚拟机退出。
    ; 轮询间隔放到五十毫秒，看键是不是就能进来 —— 结果一样：四乘十的九次方等满。
    ; 于是这也排掉了。第五次挂起，排掉的是「读盘把键盘挡住了」。
    ; 五次挂起：不知道卡在哪、预算、时间、缓冲、读盘干扰。剩下的是 VBox 那一侧，
    ; 而它没有日志 —— 所以这一次跑起来是为了让虚拟机写日志，不是为了判据（同成不在链上）。
    ;
    ; 而它把别的判据推红了：这一条会消耗信箱里的一条消息（它自己换队头），于是后面那几条
    ; 拿不到它们等的那一条。一条不挂链的测试照样能弄坏链上的东西 —— 这是它的第二个理由。
    ; call run_same_test

    ; 日志捞到了，而它给出的答案是决定性的：/PDM/Queue/Keyboard/Insert 是 0 calls ——
    ; 整趟运行里虚拟机的键盘队列一次插入都没有。所以宿主那些返回 0 的调用没有落成键，
    ; 但那次读数是拿挂起版本跑的 —— 没有注入就没有插入，所以它不算数。
    ; 重跑那一次撞上了另一件事：VBox 的盘锁没有释放（「另一个程序正在使用此文件」），
    ; 于是虚拟机根本没起来，日志自然也没有。下一次先 list runningvms 确认端口与盘都干净，
    ; 再动这一行 —— 杀 VBoxHeadless 不等于盘锁放了，而锁着的盘会让 build 与 run 都以
    ; 一句与真正原因无关的话失败。
    ; 而实测的证据比这句话更狠：VM 仍挂在 runningvms 里、四块盘全是 locked write，
    ; 直到 controlvm poweroff 才真的放行。正确的收法就是它。
    ;
    ; 而盘锁还有第二个持有者：VBoxSDS。杀掉之后 build 立刻过 —— 但它会自己回来。
    ; 这三处现在都处理完了（build 前、开工前、两趟之间都 poweroff 并等状态真的变）。
    ; 而打开它之后 vbox.log 仍然没被留下：这一趟在中途就红了，没走到复制那一步。红的原因
    ; 已知 —— 这一条会消耗信箱里的一条消息。这一次临时打开，只为了让虚拟机的键盘队列
    ; 计数里出现一次真正的注入；判据仍然不挂链，红就红。
    call run_same_test
    ; 移窗：方向键从键盘进来，策略在包里，窗口自己走。
    call run_prog_move_test
    ; 事件行：一次按键成为一行带源与目标的记录。
    call run_event_line_test
    ; 未登记被拒：同一个键，源在清单里就放行、不在就留一行拒绝。
    call run_event_reject_test
    ; 未绑定被拒：同一个源 id，这次它登记了却没有主人 —— 拒绝的理由换一格。
    call run_event_unbound_test
    ; 工程失活：同一个工程的四条判决 —— 没名字、失活、被信任、接受。
    call run_project_test
    ; 伪装可被识破：两个同名工程，只有签名在清单里。
    call run_disguise_test
    ; 注册：一份完整的、两份各缺一项的 —— 而两道缺项给出同一行字。
    call run_register_test
    ; 不锁定：缺一位、只给那一位、再给完整的一份。
    call run_nolock_test
    ; 窗口那一层到现在只有线与框。这一条让它能写字。
    call run_glyph_test
    ; 一个字母到一行字：字模成表，字距由判据量出来。
    call run_text_test
    ; 数字到字母：字体表的第二张。
    call run_upper_test
    ; 一行到一段：换行与行距。
    call run_lines_test
    ; 小写：字体只有大写 26 个，折叠发生在绘制层。
    call run_lower_test
    ; 第五个函数：读一个文件，返回它的字节数。
    call run_filesize_test
    ; 第六个函数：写一份文件，再读回来打出去。它要排在 dirfull 之前 —— 那一条会把
    ; 根目录占满，之后写什么都进不去。
    call run_save_test
    ; 第七个函数：数一个目录里有几个名字。
    call run_list_test
    ; 第八个函数：删掉一份文件，再数一数那一层还剩几个名字。
    call run_remove_test
    ; Myon 的第二步：盘上那个只有三条指令的包，靠内置 write 把一段字打到串口。
    call run_myon_test
    ; 目录写满：该拒绝，而且不许吃掉邻居。排在最后，因为它会把根目录占满。
    call run_dirfull_test
    ; 根目录满了之后别的目录仍然写得进 —— 这一条不在主链上。
    ;
    ; 它第一趟就红，而红的形状有信息：串口是 dirfull docs lost，紧跟一个 1027，也就是
    ; docs 的扇区号。所以 lookup 找到了 docs、fs_write_file 也说成功，而 α:/docs/late.txt
    ; 查不到 —— 两个出口里是第二个，问题在「写进去的那一条」与「查它的那一段」之间。
    ; 这一轮没有余量再往下分（第二段只剩两百来字节），所以先摘下来，把问题留在
    ; design/LAYERS.txt 里，而不是让它占着串口 —— 一条已经问对了方向的失败，与
    ; run_health_test 那几条同一个处理。
    call run_docs_after_full
    call run_trap_test
    jmp .hang64
.heap_bad:
    mov rsi, line_heap_bad
    call puts64

.hang64:
    cli
    hlt
    jmp .hang64

; 读种子的头并报出来。格式在 HMYR 的 design/C-VM.txt 里：
;   HMYRB（5 字节）| 版本 u16 | 函数数 u16 | 每个函数：名字、参数量、槽数、效果名、指令数、指令流
; 这里只碰前九个字节。能报出版本与函数数，就说明它读懂了种子的开头 —— 而那一行数字
; 是可以拿真实种子核对的（这一份是版本 1、202 个函数）。
seed_header:
    mov rsi, 0x70000
    movzx eax, word [rsi + 5]      ; 版本
    mov r12, rax
    movzx eax, word [rsi + 7]      ; 函数数
    mov r13, rax

    mov rsi, line_seed_hdr
    call puts64
    mov rax, r12
    call put_num64
    mov rsi, line_seed_mid
    call puts64
    mov rax, r13
    call put_num64
    jmp put_nl64

; 读时间戳计数，回来 rax = 64 位的那一个数。
;
; 为什么是 rdtsc 而不是 RTC 或 PIT：后两者都要走端口，而端口读的是 BCD 秒（分辨率
; 一秒）或者 1.19 MHz 的 16 位计数（每 55 毫秒绕回一次），拿它们量「几百毫秒」都要
; 自己数绕回。rdtsc 一条指令就给出单调递增的 64 位数，唯一不肯说的是它的频率 ——
; 所以调用它的人只许比较两次读数的差，不许把那个差当成秒。
;
; 这一点要写死在心里：同一个差在 1 GHz 与 4 GHz 的宿主上是四倍的墙钟时长。凡是
; 拿它当预算的地方，预算都要留够余量，宁可多等也不许假定快。
tsc_now:
    rdtsc                          ; edx:eax，高 32 位在 edx
    shl rdx, 32
    or rax, rdx
    ret

; 读 RTC 的秒字段，回来 al 是那一个字节。
;
; 不解析 BCD、不检查 UIP 位、不管它是 12 小时还是 24 小时制 —— 这一层只用它做一件事：
; 等它变。变一次是一秒，这个判断不需要知道现在是几点，也不需要知道那个字节怎么读。
rtc_second:
    mov al, 0x00                   ; CMOS 里的秒
    out 0x70, al
    in al, 0x71
    ret

; 把 ticks 换成秒。回来 rax = 每秒多少个 TSC 计数。
;
; 为什么需要它：上一格知道了宿主四十五毫秒送完、客人机三乘十的十次方个计数等满，
; 而这两个数没法比 —— 一个是毫秒，一个是没有单位的计数。没有换算率的时候，所有
; 「等得太久」与「键没到」的判断都只能靠假定频率，而假定就是猜。
;
; 为什么是「等秒变三次」而不是「等一次」：一次变化之间的跨度是「不到一秒到一秒」，
; 误差等于真值本身；三次变化之间恰好是两秒（每一次间隔都精确是一秒，读的延迟在微秒
; 量级），误差千分之几。两秒换一个能用的常数，是这一层少有的划算买卖 ——
; 而这两秒不是白花的：它把整趟测试的总时长改了，而这一套判据对时序很敏感。第一次
; 试的是五次（四秒），四秒就把「算数」那一条推红了 —— 不是算错，是先前送出去、没被
; 当场读走的键盘字节积在输入流里，忽然挤进了 shell 的输入。所以这里取两秒，够准，
; 也够短。
;
; 而它仍然不是「绝对时间」：RTC 的两秒里，虚拟机可能被暂停过。所以这个数只用来
; 事后换算，不用来等待 —— 等待仍然用 ticks 比，那一条是单调的，不受暂停影响。
clock_calibrate:
    call rtc_second
    mov r9b, al                    ; 记住现在这一秒
    xor r10, r10                   ; 数它变了几次
    call tsc_now
    mov [clock_cal_t0], rax
.moved:
    call rtc_second
    cmp al, r9b
    je .moved
    mov r9b, al
    inc r10
    cmp r10, 3                     ; 三次变化之间恰好两秒
    jb .moved
    call tsc_now
    sub rax, [clock_cal_t0]
    shr rax, 1                     ; 除以二：回来就是每秒钟的计数
    ret

; 打印 rax 的十进制值。与 16 位那一份同一个算法，换 64 位寄存器。
; emit 那一步不用保存 rax：pop 出来的余数用掉就丢，下一个 pop 会覆盖。
put_num64:
    push rbx
    push rcx
    push rdx
    mov rbx, 10
    xor rcx, rcx
.divide:
    xor rdx, rdx
    div rbx
    push rdx
    inc rcx
    test rax, rax
    jnz .divide
.emit:
    pop rax
    add al, '0'
    call putc64
    dec rcx
    jnz .emit
    pop rdx
    pop rcx
    pop rbx
    ret

; xmm0 除以 xmm1，结果留在 xmm0。只碰 xmm 那一侧，不动通用寄存器。
; 加与减就地展开，除单独成一小段：平均值的最后一个动作就是它，run_math 也要用，
; 而两处各写一遍 divsd 就等于把「除怎么算」写了两份。
div_f64:
    divsd xmm0, xmm1
    ret

; 打印 xmm0，六位小数，四舍五入。
;
; 先乘一百万、加半个单位、再截断，就把「保留几位」折成一次整数除法：商是整数部分，
; 余数是那六位。只用到一条 cvttsd2si，不必逐位判进位。
;
; 负数先摘符号位再按非负走 —— 这一版的小数只来自 average，它不会给出负数，
; 但把负数留给无符号 div 会溢出成一个巨大的错值，而那种错值看起来像个正常的答案。
put_f64:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    movq rax, xmm0
    test rax, rax
    jns .positive
    movsd xmm1, [const_signmask]
    xorpd xmm0, xmm1                ; 清符号位：与 0x8000... 异或
    mov r10, 1
    jmp .scaled
.positive:
    xor r10, r10
.scaled:
    movsd xmm1, [const_1e6]
    mulsd xmm0, xmm1
    addsd xmm0, [const_half]
    cvttsd2si rbx, xmm0             ; 六位定点数
    mov rax, rbx
    xor edx, edx
    mov rcx, 1000000
    div rcx                         ; rax = 整数部分，rdx = 六位小数
    test r10, r10
    jz .int_part
    push rax
    mov al, '-'
    call putc64
    pop rax
.int_part:
    push rdx                        ; 六位小数留着，put_num64 会用到 rdx
    call put_num64
    mov al, '.'
    call putc64
    pop rax
    xor r8, r8
    lea r9, [frac_places]
.frac:
    mov rcx, [r9 + r8 * 8]          ; 这一位的位权：100000、10000 …… 1
    xor edx, edx
    div rcx                         ; rax = 这一位，rdx = 剩下的
    add al, '0'
    call putc64                     ; 它保护 rax 与 rdx
    mov rax, rdx
    inc r8
    cmp r8, 6
    jb .frac
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; 读第一个函数的头与它的第一条指令。格式按 src/code-file.mjs 的读程序：
;   名（串：u16 长度 + 每字符 u16）| 参数量 u16 | 槽数 u16 |
;   效果数 u16 + 每效果（串）| 指令数 u32 | 每条指令：操作码 u8 + 立即数
; 只碰第一个函数与它的第一条指令。再往下就要按立即数形状算长度，而那是「能执行
; 字节码」那一块的活，不是这一块的 —— 这里要证明的是「读得懂结构」。
fn_probe:
    mov rsi, 0x70000 + 9

    ; 名字：UTF-16，但函数名都是 ASCII，所以只取每字符的低字节
    movzx ecx, word [rsi]
    add rsi, 2
    push rsi
    push rcx
    mov rsi, line_fn
    call puts64
    pop rcx
    pop rsi
.name:
    test ecx, ecx
    jz .named
    mov al, [rsi]
    call putc64
    add rsi, 2
    dec ecx
    jmp .name
.named:
    movzx eax, word [rsi]          ; 参数量
    add rsi, 2
    mov r14, rax
    movzx eax, word [rsi]          ; 槽数
    add rsi, 2
    mov r15, rax

    ; 效果表：数一数，然后把每个效果串跳过
    movzx ecx, word [rsi]
    add rsi, 2
.eff:
    test ecx, ecx
    jz .effed
    movzx edx, word [rsi]
    add rsi, 2
    lea rsi, [rsi + rdx * 2]
    dec ecx
    jmp .eff
.effed:
    mov edx, [rsi]                 ; 指令数，u32
    add rsi, 4
    mov r13, rdx
    ; 把指令流起点存进 r12 再打印。rsi 一身二职：这一段里它是游标，而 puts64 要把它
    ; 当成字符串指针用 —— 不先存一遍，打印完那三行之后游标就丢了，读到的操作码是
    ; 消息尾巴里的字节（第一次读出来是 89，而真实值是 5）。
    mov r12, rsi

    mov rsi, line_fn_params
    call puts64
    mov rax, r14
    call put_num64
    mov rsi, line_fn_mid
    call puts64
    mov rax, r15
    call put_num64
    mov rsi, line_fn_instrs
    call puts64
    mov rax, r13
    call put_num64
    call put_nl64

    ; 第一条指令的操作码单独占一行：它要拿 src/code-file.mjs 那张表来核对，
    ; 而这张表的权威在那一侧，所以这里只报号，翻译留给读的人。
    mov rsi, r12
    xor rbx, rbx
.instr_loop:
    cmp rbx, r13
    jae .instr_done
    movzx eax, byte [rsi]          ; 操作码
    mov r14, rax
    push rsi
    push rbx
    mov rsi, line_op
    call puts64
    mov rax, r14
    call put_num64
    call put_nl64
    pop rbx
    pop rsi
    inc rsi                        ; 跳过操作码那一个字节
    movzx eax, byte [imm_shape + r14]
    call skip_imm                  ; 按立即数形状把这一条的其余部分跳过
    inc rbx
    jmp .instr_loop
.instr_done:
    ret

; 读一个值（code-file.mjs 的值编码），返回 rax = 种类、rdx = 内容，rsi 前进到下一个字节：
;   种类 0 空（rdx 无意义）、1 数（rdx 是 f64 的八字节原样）、
;   2 串（rdx 是字符数，内容留在原地不搬）、3 布尔（rdx 是 0 或 1）
; 元组与记录这一版不展开 —— 第一个函数用不到，而展开它们要一层递归。
read_value:
    movzx eax, byte [rsi]
    inc rsi
    cmp eax, 0
    je .null
    cmp eax, 1
    je .num
    cmp eax, 2
    je .str
    cmp eax, 3
    je .bool
    jmp .null
.null:
    xor edx, edx
    ret
.num:
    mov rdx, [rsi]
    add rsi, 8
    ret
.str:
    ; 串的值是一根指针，指向种子里那个「u16 长度 + 码元」的开头 —— 内容不搬。
    ; 长度随时能从指针那里读出来，而指针是「索引」与「等」都要的东西。
    ; 上一版把长度当值，于是两个相同的串只要在种子里位置不同就不相等，
    ; 而那种不相等看起来和「真的不同」一模一样。
    mov rdx, rsi
    movzx ecx, word [rsi]          ; 长度放 ecx：rax 是 read_value 的返回值种类，不能动
    lea rsi, [rsi + 2 + rcx * 2]   ; 把字符数据跳过，好让下一条指令读得对
    ret
.bool:
    movzx edx, byte [rsi]
    inc rsi
    ret

; 最小的求值循环：只认「常量」与「返回」。
;
; 这不是解释器，是解释器最小的那副骨架 —— 它证明「读一条指令、按它动一下状态、再读
; 下一条」这条缝是通的。真正的解释器要在此之上加跳转、算术、调用，而那是后面的砖；
; 现在这一块要的是「它真的执行了，而不只是读过去了」。
;
; 栈只有一格：letters 的四条指令里，「常量」与「返回」各出现两次，而从入口到第一个
; 「返回」只压过一次 —— 一格够用。不够用的时候会露出来，那时再加深度也不迟。
run_first:
    mov rsi, r12                   ; 指令流起点
    xor rbx, rbx
.loop:
    cmp rbx, r13
    jae .none
    movzx eax, byte [rsi]
    inc rsi
    mov r14, rax
    cmp r14, 5                     ; 常量
    je .const
    cmp r14, 28                    ; 返回
    je .ret
    jmp .none                      ; 别的指令这一版不认，直接停下说「没算出来」
.const:
    call read_value
    mov [stack_kind], rax
    mov [stack_val], rdx
    inc rbx
    jmp .loop
.ret:
    mov rax, [stack_kind]
    mov rdx, [stack_val]
    ret
.none:
    xor rax, rax
    xor rdx, rdx
    ret

; 跑第一个函数并报出结果。种类先报，内容按种类 —— 第一个函数是串，所以这里只把
; 串的长度报出来，够与那一侧对账。
run_and_report:
    call run_first
    mov r14, rax                   ; 种类
    mov r15, rdx                   ; 内容
    mov rsi, line_letters
    call puts64
    cmp r14, 2
    je .str
    cmp r14, 1
    je .num
    cmp r14, 3
    je .bool
    cmp r14, 0
    je .empty
    mov rsi, line_unknown_kind
    jmp puts64
.str:
    mov rsi, line_string
    call puts64
    mov rax, r15
    movzx eax, word [rax]          ; 值是指针，长度在它指的地方
    call put_num64
    jmp put_nl64
.num:
    mov rsi, line_number
    jmp puts64
.bool:
    mov rsi, line_bool
    jmp puts64
.empty:
    mov rsi, line_empty
    jmp puts64

; ======================================================================
; 最小的解释器：值栈、指令偏移预扫、取/常量/弃/等/布尔/假跳/真跳/跳/返回
; ======================================================================

; 按索引走到某个函数，返回 rsi 指向它的指令流开头、r13 = 指令数。
; 沿途要跳过每个函数的头与整条指令流 —— 而「跳过整条指令流」正是上一块做出来的
; skip_imm 的用处，所以这一段没有任何新东西，只是把它接到遍历上。
find_fn:
    mov rsi, 0x70000 + 9
    xor rbx, rbx
.each:
    cmp rbx, r15
    ja .notfound
    movzx ecx, word [rsi]           ; 名字
    lea rsi, [rsi + 2 + rcx * 2]
    add rsi, 4                      ; 参数量、槽数
    movzx ecx, word [rsi]           ; 效果表
    add rsi, 2
.eff:
    test ecx, ecx
    jz .effed
    movzx eax, word [rsi]
    lea rsi, [rsi + 2 + rax * 2]
    dec ecx
    jmp .eff
.effed:
    ; 指令数是 u32，所以要按 32 位读。mov r13, [rsi] 会连下一条指令的 opcode
    ; 一起读进高 32 位，循环上限就变成两万多亿 —— 而「跳过指令流」那一段于是
    ; 一路跑到 rbx 撞上 10000 才停，看起来只是「找得慢」，实际上一个函数都没跳过。
    ; 这个错 find_fn 里也有，但它从不跳过任何指令流（第 0 个就找到了），所以没露。
    mov r13d, [rsi]
    add rsi, 4
    cmp rbx, r15
    je .found
    push rbx
    xor rbx, rbx
.skip:
    cmp rbx, r13
    jae .skipdone
    ; 防御：一个函数不可能有上万条指令。真读到这么大的数，说明 rsi 已经越界，
    ; 而那时如果继续按它循环，机器会停在那儿几十亿次 —— 症状是「后面什么也不出现」，
    ; 看起来像卡在别的地方。宁可说「没找到」，也不要把一个越界变成一次长跑。
    cmp rbx, 10000
    ja .notfound
    movzx eax, byte [rsi]
    inc rsi
    movzx eax, byte [imm_shape + rax]
    call skip_imm
    inc rbx
    jmp .skip
.skipdone:
    pop rbx
    inc rbx
    jmp .each
.found:
    ret
.notfound:
    xor r13, r13
    ret

; 预扫：把每条指令的字节偏移记进 instr_offsets。跳转目标是「指令索引」，而 rsi 是
; 字节游标 —— 没有这张表，跳转就只能从头发扫一遍，那样每次跳都是线性的。
scan_instrs:
    mov rsi, r12
    xor rcx, rcx
.loop:
    cmp rcx, r13
    jae .done
    ; 与 find_fn 那条同一个理由：上限在这里，垃圾指令数才不会变成一次长跑。
    cmp rcx, 10000
    ja .done
    mov [instr_offsets + rcx * 8], rsi
    movzx eax, byte [rsi]
    inc rsi
    ; 形状表现在有 35 项（opcode 0 到 34）。越界读到的会是紧跟着的那串字符
    ; （line_letters 的 'Y'），而 'Y' = 89 会落到「8 tuple」那一支上跳两字节 ——
    ; 于是偏移表从某一条起全部错位，而执行时才以 unknown op 的形式露出来。
    ;
    ; 这一条只写一次，而且它走在真正的循环前面：如果它出现，后面那些 unknown op 就有
    ; 一个明确的来源。
    ;
    ; 上限是硬编码的，所以「加一条 opcode」是三处而不是两处：形状表加一项、分派链加两行，
    ; 还有这里这个数。漏掉第三处的症状最难看 —— 它不报错，只是提前停下，而 instr_offsets
    ; 里剩下那几格是上一个函数留下的旧偏移，于是这个函数跑到别人的代码上去。
    cmp eax, 36
    jbe .shape_ok
    ; 越界：把 opcode 与它所在的地址一起打出来。
    ;
    ; 前几轮一直在推位置，而每一次都要先相信一个不在眼前的计算。这一条直接给地址：opcode
    ; 落在哪一个字节上，而那个地址可以直接拿到盘上去对。
    ;
    ; rsi 已经 inc 过（指向 opcode 之后），所以 opcode 在 rsi - 1。
    mov r15, rax
    mov [dbg_a], rsi
    mov rsi, line_op_bad
    call puts64
    mov rax, r15
    call put_num64
    mov al, ' '
    call putc64
    mov rax, [dbg_a]
    dec rax
    call put_hex64
    call put_nl64
    jmp .done
.shape_ok:
    ; 诊断撤了，而它给出的一个数是这一轮的结论：shape=7、skip 的实际差是 9 字节。
    ;
    ; 也就是说 skip_imm 对 win 的第一条（常量 60）完全正确：读种类一字节、再跳八个
    ; 字节的 f64。imm_shape[5] = 7 与 .value → .v_num 那条路都是通的。
    ;
    ; 而上一轮那十八行「scan at」是误读：打印条件里的 cmp rax, 0x41100 比较时，rax 已经
    ; 被前面的 movzx eax, byte [rsi] 改成了 opcode（5），于是 5 < 0x41100 永远成立、那些
    ; 行来自别的调用。一个诊断自己也会犯它要查的那种错 —— 这是第二次。
    movzx eax, byte [imm_shape + rax]
    call skip_imm
    inc rcx
    jmp .loop
.done:
    ret

; ---- 值栈 ----
push_val:
    mov rcx, [stack_top]
    mov [stack_kinds + rcx * 8], rax
    mov [stack_vals + rcx * 8], rdx
    inc rcx
    mov [stack_top], rcx
    ret

pop_val:
    mov rcx, [stack_top]
    dec rcx
    mov [stack_top], rcx
    mov rax, [stack_kinds + rcx * 8]
    mov rdx, [stack_vals + rcx * 8]
    ret

; 判真：rax 种类、rdx 内容。清进位为真，置进位为假。
; 数的零判断只比低八字节 —— 0.0 的位模式是全零，而这一版只需要 0 与非零分得开。
truthy:
    cmp rax, 0
    je .false
    test rdx, rdx
    jz .false
    clc
    ret
.false:
    stc
    ret

; 跑一个函数：入口处栈里已经有参数（这一版只有一个），rsi/r13 由 find_fn 给好。
exec:
    call scan_instrs
    xor rbx, rbx                    ; pc
.loop:
    cmp rbx, r13
    jae .none
    mov rsi, [instr_offsets + rbx * 8]
    movzx eax, byte [rsi]
    inc rsi
    mov r14, rax
    cmp r14, 5                      ; 常量
    je .op_const
    cmp r14, 19                     ; 取
    je .op_get
    cmp r14, 34                     ; 存（本侧追加的号，不在 HMYR 的 34 条里）
    je .op_set
    cmp r14, 35                     ; 全域取
    je .op_getglobal
    cmp r14, 36                     ; 全域存
    je .op_setglobal
    cmp r14, 26                     ; 弃
    je .op_drop
    cmp r14, 7                      ; 等
    je .op_eq
    cmp r14, 2                      ; 布尔
    je .op_bool
    cmp r14, 14                     ; 假跳
    je .op_jf
    cmp r14, 16                     ; 真跳
    je .op_jt
    cmp r14, 13                     ; 跳
    je .op_jmp
    cmp r14, 28                     ; 返回
    je .op_ret
    cmp r14, 3                      ; 调内置
    je .op_builtin
    cmp r14, 4                      ; 调函数
    je .op_call
    cmp r14, 9                      ; 大等
    je .op_ge
    cmp r14, 12                     ; 索引
    je .op_index
    cmp r14, 0                      ; 加（号是 0，不是 30 —— 30 是减）
    je .op_add
    cmp r14, 30                     ; 减：左减右。形状表里它本来就有（无立即数），只是分派链上
    je .op_sub                      ; 一直没接 —— 而这正是「加一条 opcode 是三处」的又一次
    cmp r14, 6                      ; 除
    je .op_div
    ; 不认的指令：把号报出来。静默返回「空」会让一个陌生的操作码看起来像「算出了空值」，
    ; 而这两件事在串口上应该分得开。
    mov rsi, line_unknown_op
    call puts64
    mov rax, r14
    call put_num64
    call put_nl64
    jmp .none

.op_const:
    call read_value
    call push_val
    inc rbx
    jmp .loop
.op_get:
    ; 槽号是这一帧的偏移，不是全局偏移：帧 0 的槽 0 在值栈第 0 格，
    ; 帧 0 的槽 3 在第 3 格，帧 1 的槽 0 在第八格 —— 八格一帧。
    movzx eax, word [rsi]           ; 槽号
    mov rcx, [frame_sp]
    mov rcx, [frame_slotbase + rcx * 8]
    add rcx, rax
    mov rax, [stack_kinds + rcx * 8]
    mov rdx, [stack_vals + rcx * 8]
    call push_val
    inc rbx
    jmp .loop
.op_set:
    ; 写槽：立即数是一个 u16 槽号，值从栈顶取一个。与 .op_get 共用同一段地址算术 ——
    ; 帧基址加槽号，所以「读」与「写」看到的一定是同一个格子。
    ;
    ; 这是包里第一条能改自己状态的指令。在它之前，所有函数都是「读参数、算、返回」，
    ; 一个计数器都写不出来，也就一个循环都写不出来。所以这一条比它看起来重要：它是
    ; 「包能有状态」与「包只能算一次」之间的分界。
    ;
    ; rcx 要 push 起来：pop_val 会用它自己的一套寄存器，而槽地址算完之后不能丢。
    movzx eax, word [rsi]           ; 槽号
    mov rcx, [frame_sp]
    mov rcx, [frame_slotbase + rcx * 8]
    add rcx, rax
    push rcx
    call pop_val                    ; rax = 种类，rdx = 内容
    pop rcx
    mov [stack_kinds + rcx * 8], rax
    mov [stack_vals + rcx * 8], rdx
    inc rbx
    jmp .loop
.op_getglobal:
    ; 全域取：立即数是一个 u16 编号，取的是那一格的名字，不是帧里的槽。
    ;
    ; 它与「取」的差别只有一处，而那一处就是全部：槽在帧里，函数一返回就没了；全局在
    ; 帧外，所以它能跨调用活下来。拖动要用它，而它是包里第一样「比一次调用更长寿」的东西。
    ;
    ; 编号从 0 数到 31。上限不做检查：越界读到的会是自己那两张表后面的内存，而那不是
    ; 「安全的错」，是「读到别人的东西」。这一版不出界就够了 —— 包是我们自己写的。
    ;
    ; 「不做检查」这四个字付过一次代价：窗口尺寸第一次放在 16 与 17（那时只有十六格），
    ; 越界写到 global_vals 后面，save 判据红成「save docs/inner.txt lost」，与窗口毫无
    ; 关系。扩到三十二格之后，20 号编号才真的可用 —— 而这条注释的上界也跟着改了。
    movzx ecx, word [rsi]
    mov rax, [global_kinds + rcx * 8]
    mov rdx, [global_vals + rcx * 8]
    call push_val
    inc rbx
    jmp .loop
.op_setglobal:
    ; 全域存：与全域取共用同一格，所以写进去的一定读得出来。
    movzx ecx, word [rsi]
    push rcx
    call pop_val                    ; rax = 种类，rdx = 内容
    pop rcx
    mov [global_kinds + rcx * 8], rax
    mov [global_vals + rcx * 8], rdx
    inc rbx
    jmp .loop
.op_drop:
    call pop_val
    inc rbx
    jmp .loop
.op_eq:
    call pop_val
    mov r14, rax
    mov r15, rdx
    call pop_val
    ; 种类必须相同；数比位模式，串比内容。
    cmp rax, r14
    jne .eq_false
    cmp rax, 2
    je .eq_str
    cmp rdx, r15
    jne .eq_false
    jmp .eq_true
.eq_str:
    ; 两个指针各自指向「u16 长度 + 码元」。长度先比，再逐码元比。
    ; 按内容比是必须的：同一个单字符串在种子里可能出现在两处，按指针比会把它们
    ; 判成不相等 —— 那种错让 in_set 永远交出 false，而 false 看起来是个正常答案。
    mov rcx, rdx
    mov rsi, r15
    movzx r8d, word [rcx]
    movzx r9d, word [rsi]
    cmp r8, r9
    jne .eq_false
    xor r10, r10
.eq_str_loop:
    cmp r10, r8
    jae .eq_true
    mov ax, [rcx + 2 + r10 * 2]
    cmp ax, [rsi + 2 + r10 * 2]
    jne .eq_false
    inc r10
    jmp .eq_str_loop
.eq_true:
    mov rax, 3                      ; 布尔
    mov rdx, 1
    call push_val
    inc rbx
    jmp .loop
.eq_false:
    mov rax, 3                      ; 布尔
    xor edx, edx
    call push_val
    inc rbx
    jmp .loop
.op_bool:
    xor eax, eax
    ; 布尔没有立即数：真假的来源是栈顶？—— 不。回到表里看清：布尔是「把常量真假压栈」，
    ; 而它的立即数形状是 none，所以值来自……没有。这一版把它当「压真」处理并记下这一处。
    mov rax, 3
    mov rdx, 1
    call push_val
    inc rbx
    jmp .loop
.op_jf:
    mov eax, [rsi]                  ; 目标
    push rax
    call pop_val
    call truthy
    pop rax
    jc .take_jump
    inc rbx
    jmp .loop
.op_jt:
    mov eax, [rsi]
    push rax
    call pop_val
    call truthy
    pop rax
    jnc .take_jump
    inc rbx
    jmp .loop
.op_jmp:
    mov eax, [rsi]
    mov rbx, rax
    jmp .loop
.take_jump:
    mov rbx, rax
    jmp .loop
.op_ret:
    call pop_val
    mov rcx, [frame_sp]
    test rcx, rcx
    jz .ret_outer                   ; 帧 0 的返回就是这个 exec 的返回
    ; 返回值先入机器栈：换帧要重扫指令偏移表，而重扫会把 rax 与 rdx 都用掉。
    push rax
    push rdx
    dec rcx
    mov [frame_sp], rcx
    mov rbx, [frame_pc + rcx * 8]
    mov r12, [frame_instr + rcx * 8]
    mov r13, [frame_count + rcx * 8]
    call scan_instrs
    pop rdx
    pop rax
    call push_val
    inc rbx                         ; 调用者的 pc 指向「调函数」，返回后跨过它
    jmp .loop
.ret_outer:
    ret

.op_builtin:
    ; 立即数：名字（u16 长度 + 码元）再跟一个 u16 的参数个数。
    ;
    ; 找处理者靠一张表，不是一条跳转链。上一版每加一个内置就要回头改上一个的失败出口，
    ; 而同一个「忘了改」在一轮里犯了两次，症状都是 unknown builtin —— 那看起来像名字
    ; 写错了，而不像「分派链少接了一段」。
    ;
    ; 表项三样：名字长度、名字指针、处理者。长度为零是表尾。加一个内置就是加一行数据，
    ; 不动任何跳转 —— 而这一条正是这张表存在的全部理由。
    movzx r8d, word [rsi]
    lea rdi, [rsi + 2]
    lea rsi, [rsi + 2 + r8 * 2]
    movzx r14d, word [rsi]          ; 参数个数
    lea r9, [builtin_table]
.bt_next:
    mov rcx, [r9]
    test rcx, rcx
    jz .builtin_unknown
    cmp rcx, r8
    jne .bt_step
    mov r10, [r9 + 8]
    xor r11, r11
.bt_cmp:
    cmp r11, rcx
    jae .bt_hit
    mov ax, [rdi + r11 * 2]
    cmp ax, [r10 + r11 * 2]
    jne .bt_step
    inc r11
    jmp .bt_cmp
.bt_hit:
    mov rax, [r9 + 16]
    jmp rax
.bt_step:
    add r9, 24
    jmp .bt_next

; len：一个参数，返回串的长度。
.op_len:
    cmp r14, 1
    jne .builtin_unknown
    call pop_val
    movzx eax, word [rdx]           ; 串的值是指针，长度在它指的地方
    cvtsi2sd xmm0, rax
    movq rdx, xmm0
    mov rax, 1                      ; 数
    call push_val
    inc rbx
    jmp .loop

.op_write:
    cmp r14, 1
    jne .builtin_unknown
    ; write：把那一串码元打出去，再换行。
    ;
    ; 串在包里是 UTF-16 码元，而串口只送 8 位，所以取低字节。这一版不处理非 ASCII：
    ; 一个码元超过 0xFF 时打出来的是一个问号，而不是一个错位的字节 —— 那比默默送出
    ; 半个字符好，因为它至少看得出来「这里有个字没能打出来」。
    call pop_val
    mov rsi, rdx
    movzx ecx, word [rsi]
    add rsi, 2
.wr_loop:
    test ecx, ecx
    jz .wr_done
    lodsw
    cmp ax, 0xFF
    jbe .wr_out
    mov al, '?'
.wr_out:
    call putc64
    dec ecx
    jmp .wr_loop
.wr_done:
    call put_nl64
    xor eax, eax                    ; 空
    xor edx, edx
    call push_val
    inc rbx
    jmp .loop

.op_readline:
    cmp r14, 0
    jne .builtin_unknown

    ; readline：把宿主攒的那一行交给包，形状是包里认的「u16 长度 + 码元」。
    ;
    ; 这一条与 write 合起来就是 LAYERS 第六节第二条判据：一个包通过 Myon 读一行、
    ; 写一行。而它比 write 多证明一件事 —— 包拿到的字不是自己写死的，是这一趟运行时
    ; 从外面进来的。一个「打印固定字符串」的实现过不了它。
    ;
    ; 长度截到 255 个码元。超出的部分不交给包，而不是静默截断：这一版没有「包读到一半
    ; 还想再要」的机制，所以给它的必须是一整行，或者一个明说的短行。
    mov rsi, [sh_line_ptr]
    test rsi, rsi
    jz .rl_empty
    lea rdi, [myon_line]
    xor ecx, ecx
.rl_copy:
    mov al, [rsi + rcx]
    test al, al
    jz .rl_done
    cmp al, 10
    je .rl_done
    cmp ecx, 255
    jae .rl_done
    movzx eax, al
    mov [rdi + 2 + rcx * 2], ax
    inc ecx
    jmp .rl_copy
.rl_done:
    mov [rdi], cx                   ; u16 长度
    mov rax, 2                      ; 串
    mov rdx, rdi
    call push_val
    inc rbx
    jmp .loop
.rl_empty:
    xor eax, eax
    xor edx, edx
    call push_val
    inc rbx
    jmp .loop

.op_border:
    cmp r14, 0
    jne .builtin_unknown
    ; border：画一个窗口的框。
    ;
    ; 这就是 LAYERS 第六节第三条判据说的「Ichiwatashi 那一小块」的最小版本 —— 一个包
    ; 要画东西，而它不必知道帧缓冲在 0xA0000、也不必知道一行是 320 字节。坐标与颜色
    ; 写死在这里不是偷懒：这一步要证明的是「包能让宿主画」，而通用绘图是 Ichiwatashi
    ; 自己的事，排在它后面。
    ;
    ; 四条边用同一个 draw_line，所以这一条内置换来的是十六个像素而不是四段画线代码。
    ;
    ; r12 到 r15 必须先存起来：draw_line 不保存它们，而 exec 用 r12 指指令流、用 r13
    ; 数指令数。改坏了它们，症状是「包跑完第一条就乱跳」，与画图毫无关系。
    push r12
    push r13
    push r14
    push r15
    mov dl, 0x2F
    mov r12, 10
    mov r13, 10
    mov r14, 100
    mov r15, 10
    call draw_line                  ; 上
    mov r12, 10
    mov r13, 60
    mov r14, 100
    mov r15, 60
    mov dl, 0x2F
    call draw_line                  ; 下
    mov r12, 10
    mov r13, 10
    mov r14, 10
    mov r15, 60
    mov dl, 0x2F
    call draw_line                  ; 左
    mov r12, 100
    mov r13, 10
    mov r14, 100
    mov r15, 60
    mov dl, 0x2F
    call draw_line                  ; 右
    pop r15
    pop r14
    pop r13
    pop r12
    xor eax, eax
    xor edx, edx
    call push_val
    inc rbx
    jmp .loop

.op_runpkg:
    ; 桥接：一个包请求宿主去跑另一个包。
    ;
    ; 这是 LAYERS 第六节第四条判据说的那一半 —— 「两个包之间的东西由它转」。前三个判据
    ; 都是包与宿主之间（读、写、画），而这一条是包与包之间：外层在跑 prog.hmtn 的 echo，
    ; 它请求宿主把 docs/myon.hmtn 的 echo 也跑一趟。
    ;
    ; 零参数、路径写死，因为它要证明的是「这件事能发生」，不是「包名可以任意传」。
    ; 传包名要先把串拼成 UTF-16 路径，那是另一件事。
    ;
    ; 保存与恢复是这一条的全部难点：exec 用 r12 指指令流、r13 数指令数、rbx 当 pc，
    ; 而 pkg_base / stack_top / frame_sp 是全局的。少存一样，症状是外层在回来后跳到
    ; 别处，或者栈从头开始 —— 两种都不会说「嵌套调用坏了」。
    push rbx
    push r12
    push r13
    push r14
    push r15
    push qword [pkg_base]
    push qword [stack_top]
    push qword [frame_sp]

    ; 刷新 docs 那一页再查。
    ;
    ; 预读区是启动时的快照，而 fs_write_file 会往它里面写 —— 外层包跑到这里时，docs
    ; 那一页早就不是盘上那一份了。所以这一条不能靠「排在写之前」来救：它由 shell 之后
    ; 的包发起，而 shell 本身排在写之后。能做的只有一件事：读一次盘。
    ;
    ; 1026 是 docs 的扇区号，而 fs_load 把它算成预读区里的地址 —— ata_read 就往那里写。
    ; 于是紧接着的 fs_open_path 查到的就是盘上的原样。
    mov rdi, 1026
    call fs_load
    mov rdi, 1026
    call ata_read

    mov rdi, fs_myon_path
    call fs_open_path
    test rax, rax
    jz .rp_fail
    mov rax, [last_addr]
    mov [pkg_base], rax
    mov rdi, name_echo
    mov r8, 4
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .rp_fail
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    ; 内层的返回值就摆在 exec 停下时的 rax 与 rdx 里 —— 帧 0 的返回直接就是那句 ret，值不经过
    ; 别的任何地方。这里把它存到内存而不是留在寄存器里：下面那串 pop 要把 r12 到 r15 与 rbx
    ; 全部还原，一个通用寄存器都不空。
    push rax
    push rdx
    jmp .rp_done
.rp_fail:
    ; 桥没接上时给空。空与「内层恰好返回空」在读数上是同一件事，而这是对的 —— 两者都表示
    ; 没有值过桥。给别的东西（比如上一个值）才会让红变成一种说不清的样子。
    xor eax, eax
    xor edx, edx
    push rax
    push rdx
.rp_done:
    pop qword [rp_val]
    pop qword [rp_kind]
    pop qword [frame_sp]
    pop qword [stack_top]
    pop qword [pkg_base]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ; 指令偏移表是全局的，而内层 exec 已经把它换成了内层函数的那一份。上面恢复的 r12 与 r13
    ; 只是字节流与条数 —— 表还是别人的。不重算的话，下一条指令会按内层的偏移去外层的字节里
    ; 取，于是 exec 跳进一串乱字节，而症状是「桥回来之后崩在一个毫不相干的指令上」。
    ;
    ; 这是一个在桥接落地那天就存在的缺口，只是当时唯一从桥上回来就收尾的调用者让它没有露头。
    call scan_instrs
    mov rax, [rp_kind]
    mov rdx, [rp_val]
    call push_val
    inc rbx
    jmp .loop

.op_runpkg1:
    ; 带参数的桥。与 runpkg 同一条路，差别只有三处：先弹一个参数、跑内层的 bump 而不是
    ; echo、把参数写进内层帧的第一个槽。
    ;
    ; 三处差异各对应一件要证明的事：值能送进去、内层真的用了它、结果能带回来。少一处，
    ; 这一格就退化成上一格 —— 证明的是「桥能跑」，而不是「桥能传东西」。
    ;
    ; 为什么另起一个内置而不是给 runpkg 加参数：runpkg 已经有两个调用者（shell 那条链与
    ; prog.hmtn 的 echo），改它的参数表会把两处一起动过，而这一格要说的是新的一句话。
    call pop_val                    ; rax = 种类，rdx = 内容
    mov [rp_kind], rax
    mov [rp_val], rdx

    push rbx
    push r12
    push r13
    push r14
    push r15
    push qword [pkg_base]
    push qword [stack_top]
    push qword [frame_sp]

    mov rdi, 1026
    call fs_load
    mov rdi, 1026
    call ata_read

    mov rdi, fs_myon_path
    call fs_open_path
    test rax, rax
    jz .rp1_fail
    mov rax, [last_addr]
    mov [pkg_base], rax
    mov rdi, name_bump
    mov r8, 4
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .rp1_fail
    mov r12, rsi
    ; 参数进内层的第一格。槽就是值栈最前面那八格，而 exec 从不清理槽区 —— 写在这里，
    ; 内层第一条「读槽 0」就读得到。
    mov rax, [rp_kind]
    mov rdx, [rp_val]
    ; 验红：这两行一旦拿掉，判据读到的是 4。
    ;
    ; 4 而不是 1 —— 槽区不清理，上一格跑 loopthree 时留在槽 0 的 3 还在那里，加一得 4。
    ; 这比「空的槽」更值得记：残留可以是任何一个旧值，所以这一格的判据必须挑一个不会被
    ; 残留碰到的数（7），而不是挑 0 —— 0 加一与「没送到」加一，在读数上是一样的 1。
    mov [stack_kinds], rax
    mov [stack_vals], rdx
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    push rax
    push rdx
    jmp .rp1_done
.rp1_fail:
    xor eax, eax
    xor edx, edx
    push rax
    push rdx
.rp1_done:
    pop qword [rp_val]
    pop qword [rp_kind]
    pop qword [frame_sp]
    pop qword [stack_top]
    pop qword [pkg_base]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ; 与 runpkg 同一个理由：指令偏移表被内层换掉了，恢复字节流之后必须重算。
    call scan_instrs
    mov rax, [rp_kind]
    mov rdx, [rp_val]
    call push_val
    inc rbx
    jmp .loop

.op_runpkg2:
    ; 两个值的桥。与 runpkg1 只差两处：弹两个实参、调内层的 sum2。
    ;
    ; 顺序是这一条唯一的难点。栈顶是最后那个实参，所以先弹出来的是第二个值；而槽 0 必须是
    ; 第一个实参。于是先弹的那个要先放下（rp_b 与 rp_kb），等第一个也弹出来、写进槽 0 之后，
    ; 再把它写进槽 1。
    ;
    ; 加法交换，所以这一格测不出顺序错 —— 它测的是「两个值都到了」。而「两个都到了」与
    ; 「只到了一个」分得开：后者会把残留加到那一个数上，读数不会是 43。
    call pop_val                    ; 第二个实参（栈顶）
    mov [rp_b], rdx
    mov [rp_kb], rax
    call pop_val                    ; 第一个实参
    mov [rp_val], rdx
    mov [rp_kind], rax

    push rbx
    push r12
    push r13
    push r14
    push r15
    push qword [pkg_base]
    push qword [stack_top]
    push qword [frame_sp]

    mov rdi, 1026
    call fs_load
    mov rdi, 1026
    call ata_read

    mov rdi, fs_myon_path
    call fs_open_path
    test rax, rax
    jz .rp2_fail
    mov rax, [last_addr]
    mov [pkg_base], rax
    mov rdi, name_sum2
    mov r8, 4
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .rp2_fail
    mov r12, rsi
    ; 两个实参各就各位：槽 0 是第一个、槽 1 是第二个
    mov rax, [rp_kind]
    mov rdx, [rp_val]
    mov [stack_kinds], rax
    mov [stack_vals], rdx
    ; 验红那一次只写槽 0：读数变成 90，也就是「第一个实参 30 加槽 1 里的残留 60」。
    ; 两个值缺一不可 —— 而 90 恰好说明第一个确实到了它该到的那一格。
    mov rax, [rp_kb]
    mov rdx, [rp_b]
    mov [stack_kinds + 8], rax
    mov [stack_vals + 8], rdx
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    push rax
    push rdx
    jmp .rp2_done
.rp2_fail:
    xor eax, eax
    xor edx, edx
    push rax
    push rdx
.rp2_done:
    pop qword [rp_val]
    pop qword [rp_kind]
    pop qword [frame_sp]
    pop qword [stack_top]
    pop qword [pkg_base]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    call scan_instrs
    mov rax, [rp_kind]
    mov rdx, [rp_val]
    call push_val
    inc rbx
    jmp .loop

.op_runpkg3:
    ; 减法桥。与 runpkg2 逐条一样，只有一处不同：它跑内层的 sub2 而不是 sum2。
    ;
    ; 另起一个内置而不是给 runpkg2 加一个「用哪个函数」的参数：函数名在包格式里是立即数
    ; （u16 长度加码元），把它变成运行时选出来的串，要连 find_fn_by_name 的接口一起改。
    ; 那是另一件事，而这一格要说的是「顺序」。
    call pop_val                    ; 第二个实参（栈顶）
    mov [rp_b], rdx
    mov [rp_kb], rax
    call pop_val                    ; 第一个实参
    mov [rp_val], rdx
    mov [rp_kind], rax

    push rbx
    push r12
    push r13
    push r14
    push r15
    push qword [pkg_base]
    push qword [stack_top]
    push qword [frame_sp]

    mov rdi, 1026
    call fs_load
    mov rdi, 1026
    call ata_read

    mov rdi, fs_myon_path
    call fs_open_path
    test rax, rax
    jz .rp3_fail
    mov rax, [last_addr]
    mov [pkg_base], rax
    mov rdi, name_sub2
    mov r8, 4
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .rp3_fail
    mov r12, rsi
    ; 验红那一次把这两个落槽的顺序调过来，读数从 42 变成 -42 —— 减法一换就变号，
    ; 「槽 0 是第一个实参」这句话于是有了判据。而这一次红能看见，还多亏了 print_value
    ; 补上的那个减号：它原来只看指数与尾数，负数一律以绝对值回来。
    mov rax, [rp_kind]
    mov rdx, [rp_val]
    mov [stack_kinds], rax
    mov [stack_vals], rdx
    mov rax, [rp_kb]
    mov rdx, [rp_b]
    mov [stack_kinds + 8], rax
    mov [stack_vals + 8], rdx
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    push rax
    push rdx
    jmp .rp3_done
.rp3_fail:
    xor eax, eax
    xor edx, edx
    push rax
    push rdx
.rp3_done:
    pop qword [rp_val]
    pop qword [rp_kind]
    pop qword [frame_sp]
    pop qword [stack_top]
    pop qword [pkg_base]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    call scan_instrs
    mov rax, [rp_kind]
    mov rdx, [rp_val]
    call push_val
    inc rbx
    jmp .loop

.op_runpkg4:
    ; 位置桥。与 runpkg3 逐条一样，只把内层函数换成 drawat。
    ;
    ; 前三个桥送进去的值都被内层拿去算数，这一格第一次让它变成坐标 —— 槽 0 与槽 1 就是 x 与
    ; y，内层直接在上面写字。于是「桥」这件事从「能把数送过去」变成「能让对方在你指定的位置
    ; 做事」，而后者才是两个组件真的接上。
    call pop_val                    ; 第二个实参（栈顶）
    mov [rp_b], rdx
    mov [rp_kb], rax
    call pop_val                    ; 第一个实参
    mov [rp_val], rdx
    mov [rp_kind], rax

    push rbx
    push r12
    push r13
    push r14
    push r15
    push qword [pkg_base]
    push qword [stack_top]
    push qword [frame_sp]

    mov rdi, 1026
    call fs_load
    mov rdi, 1026
    call ata_read

    mov rdi, fs_myon_path
    call fs_open_path
    test rax, rax
    jz .rp4_fail
    mov rax, [last_addr]
    mov [pkg_base], rax
    mov rdi, name_drawat
    mov r8, 6
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .rp4_fail
    mov r12, rsi
    mov rax, [rp_kind]
    mov rdx, [rp_val]
    mov [stack_kinds], rax
    mov [stack_vals], rdx
    mov rax, [rp_kb]
    mov rdx, [rp_b]
    mov [stack_kinds + 8], rax
    mov [stack_vals + 8], rdx
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    push rax
    push rdx
    jmp .rp4_done
.rp4_fail:
    xor eax, eax
    xor edx, edx
    push rax
    push rdx
.rp4_done:
    pop qword [rp_val]
    pop qword [rp_kind]
    pop qword [frame_sp]
    pop qword [stack_top]
    pop qword [pkg_base]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    call scan_instrs
    mov rax, [rp_kind]
    mov rdx, [rp_val]
    call push_val
    inc rbx
    jmp .loop

.builtin_unknown:
    mov rsi, line_unknown_builtin
    call puts64
    call put_nl64
    jmp .none

.op_list:
    ; 一参：目录路径（可以是空串 —— 那就是根目录）。回来一个串，名字之间一个空格、
    ; 末尾也一个。
    ;
    ; 与宿主自己打的那份同形，于是「包看到的目录」与「宿主看到的目录」能直接对起来。
    ; 而这一条是包第一次问一个开放的问题：前七个函数都是它知道要什么，而遍历源文件
    ; 之前得先知道有几份。
    ;
    ; 两块缓冲都不新开：路径用 save_name（132 个码元，比 130 的上限多两格），结果用
    ; slurp_path（520 个码元）。它们不会同时在跑 —— 第二段只剩九百来字节，而四百字节
    ; 的缓冲换不来什么。
    ;
    ; 空目录也交给一个长度为零的串，不是交「空」：调用者拿到的种类一致，它自己决定
    ; 怎么处理。这与 slurp 读不到时交空串是同一条。
    cmp r14, 1
    jne .builtin_unknown
    call pop_val
    mov rsi, rdx
    movzx ecx, word [rsi]           ; 路径码元数
    mov qword [list_dir], 1025      ; 根目录
    test rcx, rcx
    jz .list_ready
    cmp rcx, 128
    ja .list_empty
    lea rdi, [save_name]
    mov word [rdi], 0x03B1
    mov word [rdi + 2], 0x003A
    mov word [rdi + 4], 0x002F
    xor r8, r8
.list_pcopy:
    cmp r8, rcx
    jae .list_pdone
    mov ax, [rsi + 2 + r8 * 2]
    mov [rdi + 6 + r8 * 2], ax
    inc r8
    jmp .list_pcopy
.list_pdone:
    mov word [rdi + 6 + rcx * 2], 0
    mov rdi, save_name
    push rbx                        ; fs_open_path 把字节数交在 rbx 里，而那是 pc
    call fs_open_path
    pop rbx
    test rax, rax
    jz .list_empty                  ; 这个目录不存在：交一个空串
    mov [list_dir], r15
.list_ready:
    mov rdi, [list_dir]
    call fs_load
    mov r9, rsi                     ; 当前条目
    lea r10, [slurp_path]           ; 串的头（前两字节是长度）
    xor r8, r8                      ; 已经写进去几个码元
.list_entry:
    movzx ecx, word [r9]
    test ecx, ecx
    jz .list_done                   ; 名字长度为 0：这一层到头了
    xor r11, r11
.list_name:
    cmp r11, rcx
    jae .list_space
    cmp r8, 500                     ; 缓冲满了就收手，绝不写穿
    jae .list_done
    mov ax, [r9 + 2 + r11 * 2]
    mov [r10 + 2 + r8 * 2], ax
    inc r11
    inc r8
    jmp .list_name
.list_space:
    cmp r8, 500
    jae .list_done
    mov word [r10 + 2 + r8 * 2], 0x0020
    inc r8
    mov rax, rcx
    lea r9, [r9 + 11 + rax * 2]     ; 下一条（同 fs_lookup 的步进）
    jmp .list_entry
.list_done:
    mov word [r10], r8w             ; 长度字段
    mov rax, 2                      ; 串
    mov rdx, r10
    call push_val
    inc rbx
    jmp .loop
.list_empty:
    mov word [slurp_path], 0
    mov rax, 2
    lea rdx, [slurp_path]
    call push_val
    inc rbx
    jmp .loop

.op_remove:
    ; 一参：路径。回来一个数：1 删掉 / 0 没有。
    ;
    ; 这一段还没有成功过一次，所以它的判据不在链上 —— 两轮都红在 prog remove -> 33。
    ; 它现在已经编译、能跑、返回零，而 fs_delete 那段的匹配与紧凑化还没被证明过。
    ; 留在这里而不是删掉，是因为它把「目录链怎么紧凑化」这个形状写下来了，
    ; 而那是下一轮要接着查的地方。
    ;
    ; 路径解析与 save 同形 —— 最后一个斜杠之前是目录，之后是名字；没有斜杠就是根目录。
    ; 只改内存，不落盘：save 落盘是因为它有跨重启的判据，remove 没有。需要它留下来的时候
    ; 再补，而那时也该有一条判据先红。
    cmp r14, 1
    jne .builtin_unknown
    call pop_val
    mov rsi, rdx
    movzx ecx, word [rsi]
    cmp rcx, 200
    ja .remove_fail
    xor r8, r8
    xor r9, r9
.rfindslash:
    cmp r8, rcx
    jae .rslashdone
    mov ax, [rsi + 2 + r8 * 2]
    cmp ax, 0x002F
    jne .rnextch
    lea r9, [r8 + 1]
.rnextch:
    inc r8
    jmp .rfindslash
.rslashdone:
    lea rdi, [save_name]
    xor r8, r8
.rnbody:
    mov rax, r9
    add rax, r8
    cmp rax, rcx
    jae .rndone
    mov ax, [rsi + 2 + rax * 2]
    mov [rdi + r8 * 2], ax
    inc r8
    jmp .rnbody
.rndone:
    mov word [rdi + r8 * 2], 0
    ; fs_load 会把 rsi 改成它算出来的地址，而下面拼父路径还要用原来那个指针。
    ; 第六次了 —— 这一次的症状是「remove 说没删掉」，而它连 docs 都没查过。
    push rsi
    mov rdi, 1024
    call fs_load
    pop rsi
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r13d, [rax + 12]
    test r9, r9
    jz .rhave_dir
    lea rdi, [slurp_path]
    mov word [rdi], 0x03B1
    mov word [rdi + 2], 0x003A
    mov word [rdi + 4], 0x002F
    mov r10, r9
    dec r10
    xor r8, r8
.rpbody:
    cmp r8, r10
    jae .rpdone
    mov ax, [rsi + 2 + r8 * 2]
    mov [rdi + 6 + r8 * 2], ax
    inc r8
    jmp .rpbody
.rpdone:
    mov word [rdi + 6 + r8 * 2], 0
    mov rdi, slurp_path
    push rbx
    call fs_open_path
    pop rbx
    test rax, rax
    jz .remove_fail
    mov r13, r15
.rhave_dir:
    mov rdi, save_name
    mov rsi, r13
    call fs_delete
    test rax, rax
    jz .remove_zero
    mov rdx, 0x3FF0000000000000     ; 1.0
    jmp .remove_put
.remove_zero:
.remove_fail:
    xor edx, edx
.remove_put:
    mov rax, 1                      ; 种类：数
    call push_val
    inc rbx
    jmp .loop

.op_save:
    ; 两参：名字（串，不带路径）、内容（串）。回来一个数：1 写成 / 0 没写成。
    ;
    ; 与 slurp 对称：那边把字节摊成码元，这边把码元压回字节。文件是按字节计的，而包里的
    ; 串是 UTF-16，所以两边各做一次同一个近似 —— 非 ASCII 会走样，而这一版没有编码表。
    ; 那个限制只该记住一处，所以这里不另立一套规矩。
    ;
    ; 名字不带路径：fs_write_file 只会往根目录追加条目，它还不认子目录。让接口先长成实现
    ; 做得到的样子，比让包以为它能写任何地方好 —— 后者失败的时候，包会以为是自己写错了。
    ;
    ; 返回 1 或 0，不返回字节数：字节数在失败时也有值（它本来要写那么多），拿它当成功
    ; 标志会把「没写成」读成「写成了」。
    cmp r14, 2
    jne .builtin_unknown
    call pop_val                    ; 内容（最后一个参数在栈顶）
    mov rsi, rdx
    movzx ecx, word [rsi]           ; 码元数
    cmp rcx, 511
    ja .save_fail
    lea rdi, [save_buf]
    xor r8, r8
.save_body:
    cmp r8, rcx
    jae .save_copied
    mov ax, [rsi + 2 + r8 * 2]
    mov [rdi + r8], al              ; 低字节，与 slurp 的读取对称
    inc r8
    jmp .save_body
.save_copied:
    mov [save_len], rcx
    call pop_val                    ; 名字
    mov rsi, rdx
    movzx ecx, word [rsi]
    cmp rcx, 200
    ja .save_fail
    ; 名字里可以带一层路径（docs/inner.txt）。先找最后一个斜杠 —— 它前面是目录、
    ; 后面是名字。没有斜杠就是写根目录，与上一版一样。
    xor r8, r8
    xor r9, r9                      ; 斜杠之后的位置，0 表示没有斜杠
.save_findslash:
    cmp r8, rcx
    jae .save_slashdone
    mov ax, [rsi + 2 + r8 * 2]
    cmp ax, 0x002F
    jne .save_nextch
    lea r9, [r8 + 1]
.save_nextch:
    inc r8
    jmp .save_findslash
.save_slashdone:
    ; 名字那一段先拷出来：斜杠之后的所有码元。
    lea rdi, [save_name]
    xor r8, r8
.save_nbody:
    mov rax, r9
    add rax, r8
    cmp rax, rcx
    jae .save_ndone
    mov ax, [rsi + 2 + rax * 2]
    mov [rdi + r8 * 2], ax
    inc r8
    jmp .save_nbody
.save_ndone:
    mov word [rdi + r8 * 2], 0      ; fs_write_file 要的是以零码元收尾的名字
    mov qword [write_dir], 0
    test r9, r9
    jz .save_write                  ; 没有斜杠：根目录
    ; 有斜杠：拼出 α:/ 加斜杠之前那一段，查出那个目录的扇区。
    ;
    ; 拼法照 slurp 的样子 —— 内置自己补盘符与冒号，包不必知道盘符。两个内置共用
    ; slurp_path 是安全的：它们不会同时在跑。
    lea rdi, [slurp_path]
    mov word [rdi], 0x03B1
    mov word [rdi + 2], 0x003A
    mov word [rdi + 4], 0x002F
    mov r10, r9
    dec r10                         ; 斜杠之前那一段的长度
    xor r8, r8
.save_pbody:
    cmp r8, r10
    jae .save_pdone
    mov ax, [rsi + 2 + r8 * 2]
    mov [rdi + 6 + r8 * 2], ax
    inc r8
    jmp .save_pbody
.save_pdone:
    mov word [rdi + 6 + r8 * 2], 0
    mov rdi, slurp_path
    ; fs_open_path 把字节数交在 rbx 里，而 rbx 是 exec 的 pc —— slurp 那一处早就 push/pop 过，
    ; 这里漏了。症状是 #GP：inc rbx 把 pc 推到一个垃圾地址，而报出来的位置在别处。
    push rbx
    call fs_open_path
    pop rbx
    test rax, rax
    jz .save_fail                   ; 那个目录不存在：写不进去
    mov [write_dir], r15
.save_write:
    mov rdi, save_name
    lea rsi, [save_buf]
    mov rcx, [save_len]
    call fs_write_file              ; 它自己 push/pop 了 rbx，所以 exec 的 pc 不用外面保
    mov qword [write_dir], 0        ; 用过就清：写根目录是常态，而留着的状态会害下一处
    test rax, rax
    jz .save_zero
    ; 落盘：目录那一页与数据那一页，各写回盘一次。
    ;
    ; save 与 fs_write_file 的差别就在这两次 PIO。fs_write_file 是内存那一层 —— 它改的是
    ; 预读区，重启就没了；而包要的是一份留在盘上的东西。两件事分开，是因为一次全改成落盘
    ; 会让 guard 那几条判据每写一次都多两次写盘，而它们要证的只是「目录里多了一条」。
    ;
    ; 写盘失败就不许说「写成了」：那正是「看起来成功」最会伪装的地方。
    ;
    ; 目录不止一页：根目录占两格，而条目会跨过页边界 —— new.txt 那一条就是前七个字节留在
    ; 第一页、其余落到第二页。只写第一页的话，跨页的那一条在盘上就只剩半截，而第二页
    ; 在盘上仍是零。症状是「第二趟看不到 out.txt」，而写盘本身没有报错。
    xor r9, r9
.dir_save:
    mov rdi, [last_dir_sec]
    add rdi, r9
    call fs_load                    ; rsi = 这一页在预读区里的地址
    mov rdi, [last_dir_sec]
    add rdi, r9
    call ata_write
    jc .save_zero
    inc r9
    cmp r9, [last_dir_pages]
    jb .dir_save
    mov rdi, [last_write_sec]
    call fs_load
    mov rdi, [last_write_sec]
    call ata_write
    jc .save_zero
    mov rdx, 0x3FF0000000000000     ; 1.0
    jmp .save_put
.save_zero:
.save_fail:
    xor edx, edx                    ; 0.0 的位模式是全零
.save_put:
    mov rax, 1                      ; 种类：数
    call push_val
    inc rbx
    jmp .loop

.op_slurp:
    ; 一个参数：路径（从 α:/ 之后的部分，UTF-16 码元）。返回那一份文件的内容，成一个串。
    ;
    ; 这一条是 self-host 的第一块。它的 notes 原先说「读源文件、写目标文件那两件事要的
    ; 对象模型与文件写入都还没有」—— 写入早就有了（fs_write_file），缺的是读。而「读」
    ; 在这之前只有一个口子：readline 读的是宿主攒的那一行，不是文件。
    ;
    ; 路径的拼法：内置自己补上 α:/ 三个码元，参数从第四个位置接上去。让包写全 α:/ 也
    ; 可以，但那样每一个包都要知道盘符 —— 而那正是「包不必知道宿主细节」要避免的。
    cmp r14, 1
    jne .builtin_unknown
    call pop_val                    ; 路径串：rdx 是指针，[rdx] 是长度
    mov rsi, rdx
    movzx ecx, word [rsi]           ; 路径码元数
    cmp rcx, 200
    ja .slurp_too_long
    lea rdi, [slurp_path]
    mov word [rdi], 0x03B1          ; α
    mov word [rdi + 2], 0x003A      ; :
    mov word [rdi + 4], 0x002F      ; /
    xor r8, r8
.slurp_copy:
    cmp r8, rcx
    jae .slurp_end
    mov ax, [rsi + 2 + r8 * 2]
    mov [rdi + 6 + r8 * 2], ax
    inc r8
    jmp .slurp_copy
.slurp_end:
    mov word [rdi + 6 + rcx * 2], 0 ; 结尾零码元
    ; 到这里路径已拼好，接下来 fs_open_path 的返回值决定成败：零则 r15 = 2。
    push rbx
    call fs_open_path
    mov r9, rbx
    pop rbx
    test rax, rax
    jnz .slurp_ok
    mov r15, 2
    jmp .slurp_miss
.slurp_ok:
    ; 内容在预读区里：[last_addr] 是起点，rbx 是字节数（fs_open_path 交回来的）。
    ; 这一版按 ASCII 一刀切：每个字节当一个码元。非 ASCII 的文件会走样，而这一版没有
    ; 编码表 —— 那件事该由包自己决定，不该藏在内置里。
    mov rsi, [last_addr]
    lea rdi, [slurp_buf]
    mov rcx, r9
    cmp rcx, 255
    jbe .slurp_len_ok
    mov rcx, 255                    ; 串的长度字段是一个 u16，而这一版的缓冲吃 255
.slurp_len_ok:
    mov [rdi], cx
    xor r8, r8
.slurp_body:
    cmp r8, rcx
    jae .slurp_done
    mov al, [rsi + r8]
    movzx eax, al
    mov [rdi + 2 + r8 * 2], ax
    inc r8
    jmp .slurp_body
.slurp_done:
    mov rax, 2                      ; 串
    mov rdx, rdi
    call push_val
    inc rbx
    jmp .loop
.slurp_too_long:
    mov r15, 1
    jmp .slurp_miss

.slurp_miss:
    ; 读不到就交一个空串，而不是「空」—— 包拿到的东西种类一致，它自己决定怎么处理。
    ;
    ; 而「读不到」有两种：路径太长（在拼之前就退），或者 fs_open_path 返回零。两条各打
    ; 一行，因为它们要查的地方不同。用的串口行是普通诊断，不是 event —— 它只给人看。
    mov [slurp_dbg], r15
    mov rsi, line_slurp_miss
    call puts64
    mov rax, [slurp_dbg]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [fs_base]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [last_addr]
    call put_hex64
    call put_nl64
    lea rdi, [slurp_buf]
    mov word [rdi], 0
    mov rax, 2
    mov rdx, rdi
    call push_val
    inc rbx
    jmp .loop

.op_rect:
    ; 画一个由包指定的填充矩形：五个参数，从栈顶往下是颜色、高、宽、y、x。
    ;
    ; 这是 border 的下一格。border 的坐标写死在宿主里，而那只能证明「包能让宿主画」；
    ; 这一条证明的是「包能决定画在哪里、画多大」—— 而后者才是渲染，前者只是一次演示。
    ;
    ; 参数从栈顶往下读，因为压栈的顺序就是从左到右：x、y、w、h、颜色。所以第一个
    ; pop_val 拿到的是最后压进去的颜色。
    cmp r14, 5
    jne .builtin_unknown
    call pop_val                    ; 颜色
    movq xmm4, rdx
    call pop_val                    ; 高
    movq xmm3, rdx
    call pop_val                    ; 宽
    movq xmm2, rdx
    call pop_val                    ; y
    movq xmm1, rdx
    call pop_val                    ; x
    movq xmm0, rdx
    cvttsd2si rdi, xmm0
    cvttsd2si rsi, xmm1
    cvttsd2si rdx, xmm2
    cvttsd2si rcx, xmm3
    cvttsd2si rax, xmm4
    mov r8b, al
    call fill_rect
    xor eax, eax
    xor edx, edx
    call push_val
    inc rbx
    jmp .loop

.op_text:
    ; 让包自己写字：四个参数，x、y、串、颜色。
    ;
    ; 这是 rect 的下一格。rect 证明包能决定「画在哪里、画多大」，而这一条证明包能让屏幕
    ; 说出它想说的话 —— 一个画不出字的界面只能算一块画布。
    ;
    ; 颜色是这一轮才交给包的。上一版固定成 0x2F，理由是「参数表已经三项」；而那个理由
    ; 站不住：位置与内容都归包了，颜色没有理由留在宿主手里 —— 一个界面里深浅两种字是
    ; 常态，而不是特例。
    ;
    ; 参数从栈顶往下读，因为压栈的顺序就是从左到右：x、y、串、颜色。所以第一个 pop_val
    ; 拿到的是最后压进去的颜色。
    cmp r14, 4
    jne .builtin_unknown
    call pop_val                    ; 颜色
    movq xmm2, rdx
    call pop_val                    ; 串
    push rdx                        ; 后面两次 pop_val 会用到 rdx，所以串指针先上机器栈
    call pop_val                    ; y
    movq xmm1, rdx
    call pop_val                    ; x
    movq xmm0, rdx
    pop rdx                         ; 串指针回来
    cvttsd2si rdi, xmm0
    cvttsd2si rsi, xmm1
    cvttsd2si rax, xmm2
    mov r8b, al
    call draw_utf16
    xor eax, eax
    xor edx, edx
    call push_val
    inc rbx
    jmp .loop

.op_clip:
    ; 设定裁剪矩形：四个参数 x0、y0、x1、y1，左闭右开。
    ;
    ; 四参全零表示关闭。一个「关闭」的内置比再来一个 unclip 省一个名字，而 (0,0,0,0)
    ; 这个矩形本身没有意义（宽高都是零），所以不会有人真想用它。
    ;
    ; 只裁文字。矩形与线不裁，因为它们现有的判据都画在窗口里面 —— 而「需要被裁的矩形」
    ; 要到拖动窗口那天才出现，那时再给它一份同样的检查，位置在这一段的注释里。
    cmp r14, 4
    jne .builtin_unknown
    call pop_val                    ; y1
    movq xmm0, rdx
    cvttsd2si rax, xmm0
    mov [clip_y1], rax
    call pop_val                    ; x1
    movq xmm0, rdx
    cvttsd2si rax, xmm0
    mov [clip_x1], rax
    call pop_val                    ; y0
    movq xmm0, rdx
    cvttsd2si rax, xmm0
    mov [clip_y0], rax
    call pop_val                    ; x0
    movq xmm0, rdx
    cvttsd2si rax, xmm0
    mov [clip_x0], rax
    mov qword [clip_on], 1
    mov rax, [clip_x0]
    or rax, [clip_y0]
    or rax, [clip_x1]
    or rax, [clip_y1]
    test rax, rax
    jnz .clip_set
    mov qword [clip_on], 0
.clip_set:
    xor eax, eax
    xor edx, edx
    call push_val
    inc rbx
    jmp .loop

.op_call:
    ; 立即数：名字（u16 长度 + 码元）再跟一个 u16 的参数个数。
    movzx r8d, word [rsi]           ; 名字长度
    lea rdi, [rsi + 2]              ; 名字的码元
    lea rsi, [rsi + 2 + r8 * 2]
    movzx r14d, word [rsi]          ; 参数个数
    ; 调用者的三样先入机器栈：找函数要用 rbx 数数、还会改写 r13 与 rsi。
    push rbx
    push r12
    push r13
    push r14
    xor r15, r15                    ; 后者胜：与 HMYR 的读程序同一条规矩
    call find_fn_by_name
    pop r14
    test rax, rax
    jz .call_miss_fn
    ; 还原调用者的 pc。find_fn_by_name 把 rbx 用成了自己的循环计数，收工时是
    ; 走到的那个 401 —— 直接拿 rbx 当 pc 的话，尾调用判断会去读 instr_offsets[402]，
    ; 那已经出了表，于是每一处调用都被判成非尾，帧三两下就用完。
    mov rbx, [rsp + 16]
    ; 尾调用？下一条是「返回」就复用当前帧 —— in_set 的递归全靠这一条，
    ; 否则十轮递归就要十帧，而帧深只有四。
    mov rax, [rsp + 0]              ; 调用者的指令数
    lea rcx, [rbx + 1]
    cmp rcx, rax
    jae .call_notail
    mov rax, [instr_offsets + rcx * 8]
    cmp byte [rax], 28              ; 返回
    je .call_bind                   ; 尾：不压帧，槽基址照旧
.call_notail:
    mov rcx, [frame_sp]
    mov rdx, rcx
    inc rcx
    cmp rcx, 4
    jae .call_miss_frame            ; 帧用完了：宁可停下，也不要盖掉别人的帧
    mov [frame_sp], rcx
    mov rax, [frame_slotbase + rdx * 8]
    add rax, 8                      ; 八格一帧
    mov [frame_slotbase + rcx * 8], rax
    mov rax, [rsp + 0]
    mov [frame_count + rdx * 8], rax
    mov rax, [rsp + 8]
    mov [frame_instr + rdx * 8], rax
    mov [frame_pc + rdx * 8], rbx
.call_bind:
    ; 实参从运算栈搬到槽。栈顶是最后一个实参，所以先倒着入机器栈，
    ; 再正着写槽 —— 槽 0 必须是第一个实参。
    ;
    ; 上限放 r9 而不是 rcx：pop_val 自己就用 rcx 当游标，把它一起改掉的话
    ; 这个循环永远到不了头，而症状是机器卡住、串口停在上一行 —— 看起来像
    ; 「后面那段没被调到」，而不是「这一圈出不去」。
    mov r9, r14
    xor r15, r15
.pop_args:
    cmp r15, r9
    jae .args_done
    call pop_val
    push rdx
    push rax
    inc r15
    jmp .pop_args
.args_done:
    mov rax, [frame_sp]
    mov rax, [frame_slotbase + rax * 8]
    mov r15, rax
    xor rcx, rcx
.write_args:
    cmp rcx, r14
    jae .write_done
    pop rax
    pop rdx
    mov [stack_kinds + r15 * 8], rax
    mov [stack_vals + r15 * 8], rdx
    inc r15
    inc rcx
    jmp .write_args
.write_done:
    add rsp, 24                     ; 调用者的 r13、r12、rbx：三个都不再需要
    mov r12, rsi                    ; 被调方的指令流
    call scan_instrs
    xor rbx, rbx
    jmp .loop
.call_miss_fn:
    ; 栈上依次是 r13、r12、rbx（r14 已弹掉），三个一起丢掉。
    add rsp, 24
    mov rsi, line_miss_fn
    call puts64
    jmp .none
.call_miss_frame:
    add rsp, 24
    mov rsi, line_miss_frame
    call puts64
    jmp .none

.op_ge:
    call pop_val                    ; 右
    mov r14, rdx
    call pop_val                    ; 左
    movq xmm0, rdx
    movq xmm1, r14
    comisd xmm0, xmm1
    setae al                        ; 左 >= 右
    movzx rdx, al
    mov rax, 3
    call push_val
    inc rbx
    jmp .loop

.op_add:
    call pop_val                    ; 右
    movq xmm1, rdx
    call pop_val                    ; 左
    movq xmm0, rdx
    addsd xmm0, xmm1
    movq rdx, xmm0
    mov rax, 1
    call push_val
    inc rbx
    jmp .loop

.op_sub:
    ; 减：左减右。它与加只差一条指令，而它比加多证明一件事 —— 减法不交换。
    ;
    ; 桥接那一格用加法验证「两个值都到了」，可加法测不出「谁放进哪个槽」：顺序反了和还是那
    ; 个和。减法一换就变号，于是「槽 0 是第一个实参」这句话第一次有了判据。
    call pop_val                    ; 右
    movq xmm1, rdx
    call pop_val                    ; 左
    movq xmm0, rdx
    subsd xmm0, xmm1
    movq rdx, xmm0
    mov rax, 1
    call push_val
    inc rbx
    jmp .loop

.op_div:
    call pop_val                    ; 右
    movq xmm1, rdx
    call pop_val                    ; 左
    movq xmm0, rdx
    call div_f64
    movq rdx, xmm0
    mov rax, 1
    call push_val
    inc rbx
    jmp .loop

.op_index:
    call pop_val                    ; 下标
    mov r14, rdx
    call pop_val                    ; 目标串
    push rdx                        ; 串指针：f64_to_int 会用掉 rdx
    mov rax, r14
    call f64_to_int
    mov rcx, rax
    pop rdx
    movzx eax, word [rdx + 2 + rcx * 2]   ; 第 i 个码元
    push rax
    mov rax, 4                      ; 一个单字符串：u16 长度 + 一个 u16 码元
    call alloc64
    mov rdx, rax
    mov word [rdx], 1
    pop rax
    mov [rdx + 2], ax
    mov rax, 2                      ; 串
    call push_val
    inc rbx
    jmp .loop

.none:
    ; 没有值可交的时候把 pc 与指令数报出来：卡在哪一条、还是跑过了整条流，
    ; 这两件事在串口上应当分得开。正常返回不走这里。
    mov rsi, line_exec_none
    call puts64
    mov rax, rbx
    call put_num64
    mov rsi, line_seed_mid
    call puts64
    mov rax, r13
    call put_num64
    call put_nl64
    xor rax, rax
    xor rdx, rdx
    ret

; 一次最小的函数调用：把调用者的 pc 与指令流保存起来，切到被调方，跑完再恢复。
;
; 这不是解释「调函数」指令 —— 那还要按名字找函数、传参数、算返回值占哪个槽。
; 这一块只试通那条缝：同一个 exec 能不能跑另一个函数、并且回到调用者原来那一步。
; 帧栈的骨架就在这几行 push/pop 里；往后加参数与局部槽，加的是这几行之间的内容，
; 而不是换一种结构。
;
; 被调方是 块长 —— 但这个名字在种子里出现了**两次**（偏移 50814 与 65950），
; 一个返回 256、一个返回 512。这里用后一个，因为 HMYR 自己的读取器把重名折进
; 一个 Map 时会留下最后那个，而判据要与那一侧对得上。种子里 main 出现七次、
; 块长与 is_punct 各两次 —— 重名不是异常，是这个种子的常态。
call_test:
    push rbx                        ; 调用者的 pc
    push r12                        ; 调用者的指令流
    push r13                        ; 调用者的指令数

    mov r12, 0x70000 + 65950
    mov r13, 2
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    call scan_instrs                ; 换一张偏移表：它只对当前这段指令流有意义
    xor rbx, rbx
    call exec

    pop r13
    pop r12
    pop rbx
    ret

call_report:
    mov r12, rax
    mov rbx, rdx
    mov rsi, line_call
    call puts64
    cmp r12, 1
    jne .bad
    mov rax, rbx
    call f64_to_int
    call put_num64
    jmp put_nl64
.bad:
    mov rsi, line_bad_kind
    call puts64
    mov rax, r12
    call put_num64
    call put_nl64

; ======================================================================
; 按名字找函数，然后真的调它
; ======================================================================
;
; 上一块的 call_test 是硬编码偏移：它证明「帧能换、能回来」，但绕过了一件事 ——
; 一条真实的「调函数」指令拿到的是一个名字，不是一个偏移。
;
; 这个种子里重名是常态：main 七次，块长与 is_punct 各两次。而 HMYR 的读程序把函数
; 折进 Map 时后写覆盖前写，所以「按名字找」在这一侧必须等于「最后一个同名定义」。
; 第一处匹配就收手会拿到另一个函数的返回值 —— 而两个数都漂亮，谁也不报错。
;
; 所以判据要两个数：byname 给出 512（后者），byname first 给出 256（前者）。
; 一行读数分不开两种语义，两行可以。

; rdi = 名字的 UTF-16 码元，r8 = 码元数，r15 = 模式（0 走完整张表 / 1 第一个就停）
; 回来 rax = 1 找到 / 0 没有，rsi = 指令流起点，r13 = 指令数。
find_fn_by_name:
    ; 从哪个包开始扫：读 pkg_base，不是写死 0x70000。种子只是「启动时就在那里的那个包」，
    ; 而盘上读进来的包住在别处 —— 同一段查找代码两处都用，靠这一个变量分。
    mov rsi, [pkg_base]
    add rsi, 9                     ; 头九个字节：HMYRB + 版本 u16 + 函数数 u16
    xor rbx, rbx
    xor r11, r11                   ; 还没找到
.each:
    cmp rbx, 400                   ; 函数数不会超过这个数；越界就说没找到，不长跑
    ja .done
    ; 诊断撤了，而它给出的数留在这里 —— 那是这一轮唯一的产出。
    ;
    ; prog.hmtn 的头五个函数头位置：第一个读成 0x43009（名字长度 4，正是 main），而
    ; 跳过 main 的体之后 rsi 落在 0x43043，名字长度 0。而 main 的指令体只有 11 个字节：
    ; 常量 7（1 + 1 + 8）加返回（1）。所以正确的下一个函数头是 0x43009 + 20 + 11 =
    ; 0x43028，而它落在 0x43043 —— 差了 27。
    ;
    ; 27 不是 11 的倍数，也不是函数头的长度。所以更可能不是「跳过算错」，而是「读第二个
    ; 函数头时 rsi 已经从别处来过」—— 下一轮要在 .skip 循环里逐条打印 rsi 才知道。
    mov rbp, rsi                   ; 本函数头的起点 —— 稍后回头比名字
    movzx ecx, word [rsi]
    lea rsi, [rsi + 2 + rcx * 2]   ; 跳过名字
    add rsi, 4                     ; 参数量、槽数
    movzx ecx, word [rsi]          ; 效果表
    add rsi, 2
.eff:
    test ecx, ecx
    jz .effed
    movzx eax, word [rsi]
    lea rsi, [rsi + 2 + rax * 2]
    dec ecx
    jmp .eff
.effed:
    mov r13d, [rsi]                ; 32 位读：8 位读会把后面那个 opcode 也带进来
    add rsi, 4                     ; 现在 rsi 就是指令流起点
    ; 名字：先比长度，再逐个码元比
    movzx ecx, word [rbp]
    cmp rcx, r8
    jne .nomatch
    xor rdx, rdx
.cmp:
    cmp rdx, r8
    jae .match
    movzx eax, word [rbp + 2 + rdx * 2]
    movzx ecx, word [rdi + rdx * 2]
    cmp eax, ecx
    jne .nomatch
    inc rdx
    jmp .cmp
.match:
    mov r9, rsi                    ; 记住这一次的位置
    mov r10, r13
    mov r11, 1
    test r15, r15
    jnz .done                      ; 第一个模式：立刻收手
.nomatch:
    push rbx
    xor rbx, rbx
.skip:
    cmp rbx, r13
    jae .skipdone
    cmp rbx, 10000
    ja .skipout
    ; 诊断撤了，而它给出的两组数留在这里，因为它们是这一轮的结论。
    ;
    ; 用正确的地址（0x41000）之后，跳过那十九行全部对得上：main 的两条、echo 的十三条、
    ; sum 的四条，每一条的相邻差值都等于它该有的长度（10、22、15、21、17、13……）。
    ; 所以前面的函数体跳得一点没错。
    ;
    ; 而 win 的指令流从 0x41121 起、共二十一条（3 + 18），总长应当是 38 + 15 + 15 + 3*63
    ; = 257 = 0x101，于是最后一条在 0x41221。而诊断打出来的是 0x41205 —— 差 28。
    ;
    ; 所以「错」只在 win 自己的体里，而且不是从头就错：前面的常量与调用都对得上。
    ; 下一轮要在 win 的第十八条之后那一段找 —— 三个矩形各是「五个常量加一次调用」，
    ; 而六十三条一条不差的话，第二十个位置不该差二十八。
    movzx eax, byte [rsi]
    inc rsi
    movzx eax, byte [imm_shape + rax]
    call skip_imm
    inc rbx
    jmp .skip
.skipout:
    pop rbx
    jmp .done
.skipdone:
    pop rbx
    inc rbx
    jmp .each
.done:
    mov rax, r11
    mov rsi, r9
    mov r13, r10
    test rax, rax
    jz .miss
    ret
.miss:
    xor r13, r13
    ret

; 按名字调一次块长。两个模式合在一起跑，因为只跑后者的话，一个「取最后一个函数」
; 的实现与一个「走完整张表、留最后那个匹配」的实现看起来一模一样 —— 而前者是错的。
run_by_name_twice:
    mov rdi, name_kuaichang
    mov r8, 2
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz byname_missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    call byname_report

    mov rdi, name_kuaichang
    mov r8, 2
    mov r15, 1
    call find_fn_by_name
    test rax, rax
    jz byname_missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    call byname_first_report
    ret

byname_missing:
    ; 三个数一次给全：走了几个函数、名字指针、码元数。打印本身会用掉寄存器，
    ; 所以先入栈；第一次只打 rbx，读出来是 0 —— 那是 puts64 把 rbx 用掉了，
    ; 不是循环没跑。
    push r8
    push rdi
    push rbx
    mov rsi, line_byname_missing
    call puts64
    pop rax
    call put_num64
    mov rsi, line_seed_mid
    call puts64
    pop rax
    call put_hex64
    mov rsi, line_seed_mid
    call puts64
    pop rax
    call put_num64
    call put_nl64
    ret

byname_report:
    mov rsi, line_byname
    jmp byname_report_common
byname_first_report:
    mov rsi, line_byname_first
byname_report_common:
    push rdx
    push rax
    call puts64
    pop rax
    pop rdx
    cmp rax, 1
    jne byname_report_bad
    mov rax, rdx
    call f64_to_int
    call put_num64
    jmp put_nl64
byname_report_bad:
    push rax
    mov rsi, line_bad_kind
    call puts64
    pop rax
    call put_num64
    jmp put_nl64

; ======================================================================
; 判据：is_digit('7') 真，is_digit('a') 假
; ======================================================================
;
; 这一条要的东西很多，少一样就不对：参数落槽（is_digit 一参、in_set 三参）、
; 调函数、调内置 len、索引、等、加、假跳，以及 in_set 那条十轮的尾递归。
; 它给出的答案只有两个字，对不上时说不清断在哪 —— 所以它验的是「全都对」，
; 不是「某一处对」；分开验的那些在上面各节里。
run_is_digit:
    mov rdi, name_is_digit
    mov r8, 8
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz is_digit_missing
    mov r12, rsi
    xor rbx, rbx
    mov qword [frame_sp], 0
    mov qword [stack_top], 32
    mov rax, 2                      ; 串
    mov [stack_kinds], rax
    mov rax, char7
    mov [stack_vals], rax
    call exec
    call is_digit_report

    mov rdi, name_is_digit
    mov r8, 8
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz is_digit_missing
    mov r12, rsi
    xor rbx, rbx
    mov qword [frame_sp], 0
    mov qword [stack_top], 32
    mov rax, 2
    mov [stack_kinds], rax
    mov rax, chara
    mov [stack_vals], rax
    call exec
    call is_digit_report_false
    ret

is_digit_missing:
    mov rsi, line_isdigit_missing
    call puts64
    ret

is_digit_report:
    mov rsi, line_isdigit7
    jmp is_digit_report_common
is_digit_report_false:
    mov rsi, line_isdigita
is_digit_report_common:
    push rdx
    push rax
    call puts64
    pop rax
    pop rdx
    cmp rax, 3                      ; 布尔
    jne is_digit_report_bad
    test rdx, rdx
    jz is_digit_report_no
    mov rsi, line_true
    jmp puts64
is_digit_report_no:
    mov rsi, line_false
    jmp puts64
is_digit_report_bad:
    push rax
    mov rsi, line_bad_kind
    call puts64
    pop rax
    call put_num64
    jmp put_nl64

; ======================================================================
; ATA PIO：长模式下的第一块读盘能力
; ======================================================================
;
; 文件系统的前提不是路径语法，是「进了长模式之后还读得到盘」。BIOS 的 int 0x13
; 只活在实模式，所以这一段必须自己碰端口 —— 主通道 0x1F0 那一组，LBA28 的 PIO 读。
;
; 判据不是「读出来了」，而是「与 BIOS 读的是同一份」：种子已经由 int 0x13 读到
; 0x70000，这里再用 ATA 读同一个扇区（LBA 33，种子在盘上的第一个扇区），
; 512 字节逐字节比。两条完全不同的路给出同样的字节，才说明这一段对。

; rdi = LBA，rsi = 目标缓冲区（512 字节）。进位清表示读到。
ata_read:
    ; rdi = LBA，rsi = 目标缓冲（512 字节）。进位清表示读到。
    ;
    ; 这一版把「一次没成」当成正常情况处理，而不是异常：虚拟机的 IDE 在连续调用的
    ; 第三、第四次上会偶发地不理人，而症状是卡住 —— 加一句诊断就好、删掉又坏，
    ; 所以它不是某个寄存器写错，是时序。做法是三条：读 0x1F7 见到 0xFF 就认定这组
    ; 端口上没有盘（不是「忙」）；超时就整条命令重来一次；重试之前不再相信任何残留状态。
    push rsi
    push rdi
    mov r11, 3                      ; 一次不成再试两次
.try:
    ; 总线浮空也当成「这一次没成」而不是「永远不成」：虚拟机会偶发地让状态读成 0xFF，
    ; 而它下一次可能就是好的。真没盘的时候三次都这样，最后还是 .fail —— 慢一点，
    ; 但比「一次浮空就放弃」诚实。
    mov dx, 0x1F7
    in al, dx
    cmp al, 0xFF
    je .retry
    mov r10, 200000
.busy:
    mov dx, 0x1F7
    in al, dx
    cmp al, 0xFF
    je .retry
    test al, 0x80
    jz .idle
    dec r10
    jnz .busy
    jmp .retry
.idle:
    mov rdi, [rsp]                  ; LBA（重试时也要还在）
    ; 设备/头：LBA 模式、再带上 LBA 的高四位，而「哪一块盘」由 ata_dev 决定。
    ;
    ; bit4 是设备选择：0 是 primary master（主盘，文件系统住的那块），0x10 是 primary
    ; slave（信箱盘）。这一格之前它是写死的 0xE0 —— 于是 ata_read 只能读主盘，
    ; 而信箱盘在从盘上，所以「用 ata_read 读信箱」这件事以前根本没成立过：
    ; 读是读成功了的，读回来的却是主盘同一号扇区的字节。
    mov rax, rdi
    shr rax, 24
    and al, 0x0F
    or al, 0xE0
    or al, byte [ata_dev]
    mov dx, 0x1F6
    out dx, al
    ; 扇区数
    mov dx, 0x1F2
    mov al, 1
    out dx, al
    ; LBA 低三位
    mov rax, rdi
    mov dx, 0x1F3
    out dx, al
    mov rax, rdi
    shr rax, 8
    mov dx, 0x1F4
    out dx, al
    mov rax, rdi
    shr rax, 16
    mov dx, 0x1F5
    out dx, al
    ; 命令：读扇区
    mov dx, 0x1F7
    mov al, 0x20
    out dx, al
    ; 等 BSY 落、DRQ 起
    mov r10, 200000
.wait:
    mov dx, 0x1F7
    in al, dx
    cmp al, 0xFF
    je .retry
    test al, 0x80
    jnz .next
    test al, 0x08                 ; DRQ
    jnz .ready
.next:
    dec r10
    jnz .wait
    jmp .retry
.ready:
    mov rdi, [rsp + 8]            ; 目标缓冲区
    ; 逐 word 读，不用 rep insw。rep insw 在虚拟机模拟的 IDE 控制器上偶尔会挂住：
    ; 两个实现都能跑，而挂住的那一个只在「前一行的时序稍有不同」时才挂。
    ;
    ; 这里曾经试过在读之前插一段延迟（4096 次 dec），依据是「加诊断就好、删掉就坏」
    ; 说明它要时间。延迟没有用，已撤掉 —— 留一个无效的补丁比留一个空缺更糟。
    mov rcx, 256
    mov dx, 0x1F0
.read:
    in ax, dx
    mov [rdi], ax
    add rdi, 2
    dec rcx
    jnz .read
    ; 读完再等 BSY 落，好让下一条命令发得出去
    mov r10, 200000
.drain:
    mov dx, 0x1F7
    in al, dx
    cmp al, 0xFF
    je .done
    test al, 0x80
    jz .done
    dec r10
    jnz .drain
.done:
    add rsp, 16
    clc
    ret
.retry:
    dec r11
    jnz .try
.fail:
    add rsp, 16
    stc
    ret

; 把扇区号算成预读区里的地址。接口与 ata_read 一样（rdi = 扇区号），但它不读盘 ——
; 它只是算地址。
;
; 两个变量而不是两个常量：α 盘的预读区在 0x40000、从第 1024 个扇区起；β 盘在 0x60000、
; 从第 0 个扇区起。盘符不同，这两个数就不同 —— 而「盘符对一块盘」这件事在
; design/FS.txt 二节里就是这么定的，所以地址该跟着盘符走，不该写死在代码里。
fs_load:
    sub rdi, [fs_start]
    shl rdi, 9
    mov rsi, [fs_base]
    add rsi, rdi
    ret

; 从串口读一个字节，放进 al。等 LSR 的 bit 0（数据就绪）。
; 有上限：没有上限的话，没人在另一端的时候这里会永远等，而「在等」与「坏了」
; 在串口上看起来完全一样 —— 这一课在前面几块里已经付过一次学费。
read_char:
    ; 2000 次不是「等多久」，是一次探测。串口在插座模式下会立刻告诉有没有字节；
    ; 而 200000 次 in 在这台虚拟机上要几十秒 —— 那与卡住在串口上看起来一样，
    ; 这一课刚在上一趟付过。
    mov r10, 2000
.wait:
    mov dx, 0x3FD
    in al, dx
    test al, 0x01
    jnz .ready
    dec r10
    jnz .wait
    stc
    ret
.ready:
    mov dx, 0x3F8
    in al, dx
    clc
    ret

; 收到一个字节就回显它，收不到就说 no input。
run_serial_echo:
    call read_char
    jc .none
    push rax
    mov rsi, line_serial_got
    call puts64
    pop rax
    call putc64                   ; puts64 用 lodsb，会改 al —— 所以字符先入栈
    call put_nl64
    ret
.none:
    mov rsi, line_serial_none
    call puts64
    ret

; ======================================================================
; 键盘：运行时收字节的第二条路
; ======================================================================
;
; 串口那条路在 tcpserver 后端上出不去（四条实测在 stage2 的串口一节），所以「运行时
; 收到东西」要换一条。键盘是现成的：主机能用 VBoxManage controlvm keyboardputscancode
; 直接注入扫描码，不需要窗口焦点，也不需要 guest 装任何驱动。
;
; 这一版用轮询 0x64 而不是中断：8042 的状态口会告诉我们「输出缓冲里有没有东西」，
; 而中断要先配 8259、再在 IDT 里给 IRQ1 开门。先证明「能读到码」，那两件之后再说 ——
; 顺序反了的话，读不到码时会在中断配置里找问题，而那里本来没问题。
;
; 注意这里只读 0x64 与 0x60。当初 A20 那一版是往 0x64 写，把 out 卡住了；读是另一回事。
;
; 扫描码集用集 1，与主机那一侧一致（理由写在 keymap 的注释里）。所以主机送 0x2D
; 表示按下 X，送来 0xAD 表示放开。这一版不翻译，只把收到的码打出来 —— 翻译表可以后加，
; 而「究竟收到了什么」是一张表替代不了的事实。
run_key_poll:
    ; 先报一声「我在等」，宿主听到才送键。
    ;
    ; 这一句是补上的握手，而它补得很晚：此前这一段不打招呼，宿主只能猜着送 —— 猜的结果
    ; 是它在几十毫秒里连送十五次，客人机只读走一个，剩下的顺着输入流进了 shell，于是
    ; 「1+1」变成「xxxxx1+1」，算出 0。移窗、事件行、未登记那几处都有握手，所以它们一直
    ; 是干净的；只有这一处没有，而它坏起来的样子是「算数那一条偶尔不对」。
    mov rsi, line_key_ready
    call puts64
    ; 半秒，用时钟量。这里原先数的是轮次，而那是个陷阱：in 是一条要退出虚拟化的指令，
    ; 一千万轮在真实机器上是几十毫秒，在虚拟机上能是几分钟。八亿轮试过一次 —— 第二趟
    ; 没有人送键，于是它停在这一条上直到宿主的窗口用完，串口停在 key ready 就再没下文。
    ; 这正是这一格的主题：能等多久要用时钟说，不能用轮次说。
    mov rax, 2000000000
    mov [wait_budget], rax
    call tsc_now
    add rax, [wait_budget]
    mov [clock_deadline], rax               ; 大约几秒：够主机在这段窗口里送一个键
.wait:
    mov dx, 0x64
    in al, dx
    test al, 0x01                  ; bit 0：输出缓冲有数据
    jnz .got
    call tsc_now
    cmp rax, [clock_deadline]
    jb .wait
    mov qword [wait_budget], wait_ticks
    mov rsi, line_key_none
    call puts64
    ret
.got:
    mov dx, 0x60
    in al, dx                      ; 扫描码
    movzx r15, al
    mov rsi, line_key
    call puts64
    mov rax, r15
    call put_hex64
    call put_nl64
    ret

; 等一个方向键的「按下」。回来 eax = 0x4B（左）或 0x4D（右），或者 0 表示预算用完。
;
; 为什么读两次 0x60：方向键不是单字节的键。集 1 里它由两个码组成 —— 前缀 0xE0，后面
; 才是方向本身。而 8042 的输出缓冲一次只放一个字节：不把 0xE0 读走，后面那个就进不来。
; 所以「读一次」在这里是不够的，而不够的症状很有欺骗性 —— 读到的永远是 0xE0，看起来
; 像「主机根本没送键」。
;
; 为什么第二个字节也要挑：放开码同样带 0xE0 前缀。右方向键按下是 E0 4D、放开是 E0 CD，
; 两者形状一样。第一版读到的第二字节原样返回，于是同一个键的按下与放开被数成了两次 ——
; 判据第二点 (28,20) 读 1F 而不是 00，而原因不是擦旧坏了，是窗口只挪了一次：第二次
; 「按键」拿到的 205 不等于 77，keymove 什么都不做。
;
; 所以这里只认方向键的按下码，其他的（放开码、别的键、别的扩展键）都回到等待。判断
; 「哪一边算右」不在这里 —— 那是界面的意见，归包里的 keymove。宿主只负责说「按了哪个
; 方向键」。
; 把 8042 输出缓冲里剩下的字节全部读掉，回来不说别的，只报读到了几个。
;
; 为什么要有这一段：同级那一条一直在说「等不到键」，而宿主同时说「我送出去了」。两边
; 都没有说谎的时候，剩下的可能是「键其实到了，只是在等待开始之前就到了，于是躺在缓冲里
; 挡住了后来的那个」。读数是一个字面的事实：清到几个字节。
;
; 而它也是安全的位置：wait_arrow 在客人机刚刚报完一句自己已经动手了之后被调用，那时宿主
; 还没来得及看见那一句（它每 150 毫秒才看一次串口），所以此刻缓冲里的东西一定是旧的。
drain_keys:
    xor r11, r11                   ; 数清掉了几个
.spin:
    mov dx, 0x64
    in al, dx
    test al, 0x01                  ; 输出缓冲空了吗
    jz .done
    mov dx, 0x60
    in al, dx                      ; 读走一个
    inc r11
    jmp .spin
.done:
    test r11, r11
    jz .quiet
    mov rsi, line_drain
    call puts64
    mov rax, r11
    call put_num64
    call put_nl64
.quiet:
    ret

wait_arrow:
    ; 先清一次再等。清到的数会打在串口上 —— 若它一直是零，那「键没到」就是字面意思；
    ; 若它非零，那么此前那些「没等到」里有一部分其实是「等到了却晚了」，两件事的修法
    ; 完全不同：前者要找注入的路，后者要清场。
    call drain_keys
    ; 预算是墙钟，不是循环次数。
    ;
    ; 以前这里数的是「还能转几圈」，而那个数字什么也不算：同一台机器上转一圈的时间
    ; 被 ATA 读、被缓存、被宿主的调度拉得很开，于是两百万轮可能是二十五毫秒，也可能
    ; 是半秒。宿主是每 150 毫秒读一次串口文件的 —— 于是「宿主看到握手、再把键送进来」
    ; 这件事，能不能赶上完全取决于这台机器今天跑多快。症状是事件行的 payload 全零，
    ; 读起来像键没送到，而实测是等待早就结束了。
    ;
    ; 现在起点与终点都是 rdtsc 读出来的数，同单位、单调、与机器快慢无关。默认预算
    ; 放在 [wait_budget] 里，为的是让某个调用点能临时加长 —— 等一个要经过宿主的键，
    ; 和「看看有没有键」不是同一件事，不该用同一个数。
    call tsc_now
    mov [clock_start], rax
    add rax, [wait_budget]
    mov [clock_deadline], rax
    call tsc_now
    add rax, poll_ticks
    mov [clock_nextpoll], rax
    ; 硬上界留在 r8：万一这台机器上 rdtsc 不动（某些虚拟化配置会冻结它），上面那条
    ; 比较就永远不成立，而这里至少还能转完就放手。它不是预算，是保险丝。
    mov r8, 1000000000
    xor r9d, r9d
.wait_first:
    ; 到点了没有，每轮问一次时钟。rdtsc 是几条指令，比一次真实的 ATA 读便宜两个
    ; 数量级，所以「问时间」可以每轮做，「问信箱」只能按节拍做。
    call tsc_now
    cmp rax, [clock_deadline]
    jae .timeout
    cmp rax, [clock_nextpoll]
    jb .no_mbox
    add qword [clock_nextpoll], poll_ticks
    push r8
    push r9
    call mbox_poll
    pop r9
    pop r8
    test rax, rax
    jnz .from_mbox
.no_mbox:
    mov dx, 0x64
    in al, dx
    test al, 0x01
    jnz .first
    dec r8
    jnz .wait_first
.timeout:
    ; 超时的时候把等掉的时间打出来。一个「没等到」有两件完全不同的事要做：预算太短
    ; （那就把数调大），或者根本没人在送（那调多大都一样）。它们在这行之前的串口上
    ; 长得一模一样，而这一行把差别摆出来：第二趟会是一场真实的往返，那个数就是它的量。
    call tsc_now
    sub rax, [clock_start]
    mov rsi, line_wait_timeout
    call puts64
    call put_num64
    call put_nl64
    xor eax, eax
    ret
.first:
    mov dx, 0x60
    in al, dx
    cmp al, 0xE0
    je .wait_second                ; 前缀到手，接下来那个才是方向字节
    ; 不是前缀就丢掉，继续等。这里曾经打一行「读到了什么」做侦查，而它给出的答案是：
    ; 十倍预算的十秒里只有一次读到字节，而且是 0x00 —— 那个字节连扫描码都不是，
    ; 只是输出缓冲的标志位亮过一次。所以真正的结论是「键没到」，不是「键被丢掉」。
    ; 那一行因此收了：侦查完的打印不该留在串口里，它会让每一次等键都多两行噪声。
    jmp .wait_first
    ; 前缀已到手，第二字节紧跟着来 —— 而预算不再重设。总预算只有一份：两个字节之间
    ; 真要等那么久，那已经不是「键在路上的延迟」，而是有一边没说清。重设预算会把一次
    ; 等待变成两次，而两次加起来仍然超时的时候，日志里看不出是哪一个先到。这里曾经
    ; 就是那样：第一趟读到前缀、等不到方向字节，而串口上什么也不说 —— 因为那条路径
    ; 是「静悄悄返回 0」，与「真的没有键」长得一模一样。
.wait_second:
    mov dx, 0x64
    in al, dx
    test al, 0x01
    jnz .second
    dec r8
    jnz .wait_second
    jmp .timeout                   ; 第二字节没来，与「一个字节都没来」是同一件事
.second:
    mov dx, 0x60
    in al, dx
    cmp al, 0x4B                   ; 左
    je .done
    cmp al, 0x4D                   ; 右
    je .done
    jmp .wait_first                ; 不是方向键的按下：继续等，预算不补
.done:
    movzx eax, al
    ; 键盘这一路不碰源：它是调用者默认的那一条，而调用者会自己设（或什么都不设，
    ; 那就是上一次的值）。只有信箱那一路要改源 —— 因为调用者不知道这次是信箱。
    ;
    ; 这里曾经也设了一次源，于是「设源 2、等键、仲裁」那一条变成了「设源 2、等键、
    ; 源被改回 1、仲裁」，读数从 input src=2 变成 event src=1。判据当场红了。
    ret
.from_mbox:
    ; 信箱这一路的源 id 是 5。它在收尾处设，与键盘那一路对称：两条路的差别只在源那一格，
    ; 键码与返回值形状完全一样 —— 这正是「同级」在代码里的第一次落地。
    mov r15, rax
    mov rax, 0x4014000000000000      ; 5.0
    mov [global_vals + 26 * 8], rax
    mov rax, r15
    ret

; ======================================================================
; 空转时问一次信箱：序列号变了就是一条新输入
; ======================================================================
;
; 这条通道一直存在，但它以前只在启动时读一次（实模式，int 0x13，落在 0x50000）。
; 这一格让它变成运行时的：长模式下用 ata_read 读第 0 个扇区，比序列号。
;
; 为什么比序列号而不是比内容：内容可以相同（同一个命令送两次是合法的），而「来了一条新的」
; 这件事只能由发送方的计数说明。序列号写在头偏移 16，是 run.mjs 与 stage2 共享的那一份
; 约定里早就有的一格 —— 注释里当时写着「将来客人机靠它认新」，这一格就是那个将来。
;
; 键码借的是偏移 10 那两个留白字节。它曾经被借去当 ATA 的开关，后来不用了；现在它是
; 「这一条输入是什么键」。留白可以换用途，但换一次要在两边同时写下来，否则下一次有人
; 读到旧用途。
;
; 返回 rax = 键码（0 表示没有新的）。它只在 wait_arrow 的空转里被调用。
mbox_poll:
    cmp qword [mbox_serial0], 0
    jne .ready
    ; 第一次：只记基准。基准取自启动时那份快照 —— 它是「我们知道盘上原本是什么」。
    mov eax, [0x50000 + 16]
    mov [mbox_serial0], rax
    mov r14, rax
    mov rsi, line_mbox_base
    call puts64
    mov rax, r14
    call put_num64
    call put_nl64
    xor eax, eax
    ret
.ready:
    ; 读第 4 个扇区。为什么不是第 0 个：第 0 到第 3 是启动时读的那四个（头与补丁包），
    ; 而这一格要证明的正是「运行时还能读到一份启动时没读过的内容」。同一个扇区做不到
    ; 那件事 —— 启动时读的与运行时读的若是同一处，两次读到的必然是同一份字节。
    mov byte [ata_dev], 0x10        ; 从盘：信箱住在 primary slave
    mov rdi, [mbox_head]
    mov rsi, mbox_buf
    call ata_read
    mov byte [ata_dev], 0           ; 读完立刻放回去：文件系统那一整套读的是主盘
    jc .readfail
    mov rdi, mbox_buf
    mov rsi, mbox_magic
    mov rcx, 8
    call bytes_eq
    jc .none
    mov eax, [mbox_buf + 16]
    cmp rax, [mbox_serial0]
    je .none
    ; 记下新的：同一条消息不会被读成两条。这一步就是「新」这个字在代码里的全部含义。
    mov [mbox_serial0], rax
    inc qword [mbox_head]           ; 队头前进：下一条从下一个扇区读
    mov r14, rax
    mov rsi, line_mbox_new
    call puts64
    mov rax, r14
    call put_num64
    call put_nl64
    movzx eax, word [mbox_buf + 10]
    test rax, rax
    jz .none
    ret
.readfail:
    mov rsi, line_mbox_readfail
    call puts64
.none:
    xor eax, eax
    ret

; 比较两段字节。rdi 与 rsi 是地址，rcx 是字节数。相等清进位。
; 为什么不用 same：那个是实模式那份的例程，指令编码是 16 位的 —— 长模式下执行会错。
bytes_eq:
.l:
    test rcx, rcx
    jz .yes
    mov al, [rdi]
    cmp al, [rsi]
    jne .no
    inc rdi
    inc rsi
    dec rcx
    jmp .l
.yes:
    clc
    ret
.no:
    stc
    ret

; ======================================================================
; 三·零、IDT：让异常有名字
; ======================================================================
;
; 在这之前，任何一个异常都是三重故障：CPU 找不到处理者，用 #DF 再失败一次，然后重启。
; 症状只有一种 —— 串口停住，什么也不说。加上 tcpserver 那个「一崩就静音」的教训，
; 「没有输出」与「还没跑到」在这台机器上曾经分不开过。
;
; 所以这张表的第一价值不是「处理异常」，是「让错误有名字」。异常号是唯一能指向出错原因
; 的线索，而它现在只值三条指令。
;
; 只填六个项：除零、断点、未定义指令、双重故障、通用保护、页不存在。其余留零（present=0），
; 访问到会 #GP —— 而 #GP 已经填了，于是还有话说。
;
; 每项 16 字节，64 位布局：offset 低 16、段选择子、IST、类型、offset 中 16、offset 高 32。
build_idt:
    push rax
    push rdi
    push rsi
    mov rdi, 0x5000
    mov rsi, idt_stub_0
    call idt_set
    mov rdi, 0x5000 + 3 * 16
    mov rsi, idt_stub_3
    call idt_set
    mov rdi, 0x5000 + 6 * 16
    mov rsi, idt_stub_6
    call idt_set
    mov rdi, 0x5000 + 8 * 16
    mov rsi, idt_stub_8
    call idt_set
    mov rdi, 0x5000 + 13 * 16
    mov rsi, idt_stub_13
    call idt_set
    mov rdi, 0x5000 + 14 * 16
    mov rsi, idt_stub_14
    call idt_set
    lidt [idt_desc]
    pop rsi
    pop rdi
    pop rax
    ret

; rdi = 项地址，rsi = 处理器地址。类型 0x8E：present、DPL 0、64 位中断门。
;
; 选择子必须是 0x18（64 位代码段），不是 0x08（32 位那个）。这一处写错一次：填了 0x08
; 之后 ud2 触发，CPU 试着调用那扇门、发现长模式下不能用 32 位代码段，于是 #GP；而 #GP
; 走的是同一张表、同一处写错，再变成 #DF，然后三重故障 —— 表现是串口停在「trap test」
; 上一行，连异常号都打不出来。一个错的选择子会把整张表一起废掉，这比「某个处理器写错」
; 更值得记。
idt_set:
    mov rax, rsi
    mov word [rdi], ax              ; offset 低 16
    mov word [rdi + 2], 0x18        ; 64 位代码段（0x08 是 32 位那个，用错会三重故障）
    mov byte [rdi + 4], 0           ; IST：不用
    mov byte [rdi + 5], 0x8E
    shr rax, 16
    mov word [rdi + 6], ax          ; offset 中 16
    shr rax, 16
    mov dword [rdi + 8], eax        ; offset 高 32
    mov dword [rdi + 12], 0
    ret

; 六个入口。号码由 stub 自己压 —— 有的异常会在栈上压错误码、有的不压，去数栈会把
; 「号码」与「错误码」搞混，而这两样看起来都是小整数。
idt_stub_0:
    push 0
    jmp idt_common
idt_stub_3:
    push 3
    jmp idt_common
idt_stub_6:
    push 6
    jmp idt_common
idt_stub_8:
    push 8
    jmp idt_common
idt_stub_13:
    push 13
    jmp idt_common
idt_stub_14:
    push 14
    jmp idt_common

; 打印号码与出错位置，然后停机。
;
; 为什么要打位置：只打号码只能说「出的是哪一类」，说不出「出在哪里」。而没有位置的
; 异常号在这台机器上帮助有限 —— 它会把一次崩溃变成一次猜测。
;
; 栈的形状取决于异常带不带错误码：#DF(8)、#GP(13)、#PF(14) 会压一个错误码，RIP 就在
; 号码、错误码之上；其余不压，RIP 紧跟着号码。所以先按号码分岔，再去取 —— 数错一格
; 会把错误码当成 RIP，而两者都是小整数附近的数，看错不会报错。
;
; 不恢复：这一版没有「异常之后继续跑」的地基（没有进程，也没有可以回到的干净状态），
; 假装能继续会让错误在后面更远的地方出现，那时线索更少。
idt_common:
    mov r15, [rsp]                  ; 号码
    lea r14, [rsp + 8]              ; 先指向「无错误码时的 RIP」
    cmp r15, 8
    je .has_code
    cmp r15, 13
    je .has_code
    cmp r15, 14
    jne .print
.has_code:
    lea r14, [rsp + 16]             ; 带错误码的三个：RIP 在错误码之后
.print:
    mov r14, [r14]
    mov rsi, line_exception
    call puts64
    mov rax, r15
    call put_num64
    mov rsi, line_exception_at
    call puts64
    mov rax, r14
    call put_hex64
    call put_nl64
.hang:
    cli
    hlt
    jmp .hang

; 故意的异常：证明那张表真的装上了、也真的被用上了。
;
; 选 ud2 而不是除零：除零的结果依赖浮点环境（x87 与 SSE 的处理不同），而未定义指令
; 在任何 CPU 上都只有一个答案。判据要的是一个不会漂的数。
; ======================================================================
; 包删掉一份文件，再数一数那一层
; ======================================================================
;
; 前面七个函数都在「加」。这一条是包第一次「减」，而减在文件系统里比加难：目录是一条链，
; 把条目的名字长度置零会把后面整条链切断。所以实现要把后面的条目往前挪，而判据要的
; 正是「挪过之后链还通着、而少了一条」—— 若只把名字弄没而链断了，list 会数到第一条
; 就停，长度是 9 而不是 24。
run_remove_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_removetest
    mov r8, 10
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000
    mov rsi, line_prog_remove
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    call put_nl64
    ret
.missing:
    mov rsi, line_prog_remove_bad
    call puts64
    ret

; ======================================================================
; 包问「这一层有什么」
; ======================================================================
;
; 前六个函数都是包知道它要什么。这一条是它第一次问一个开放的问题 —— 而编译器要遍历
; 源文件，遍历之前得先知道有几份。
;
; 判据落在长度上：docs 目录里四份（note.txt、sub、myon.hmtn、inner.txt）—— 第四份是
; save 在它之前写的。名字之间一个空格、末尾也一个，合起来 8 + 1 + 3 + 1 + 9 + 1 + 9 + 1 = 33。
; 33 这个数在别处没有出现过，而它同时钉住了顺序与分隔符 —— 只数条数的话，四份名字
; 拼反了也过。
run_list_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_listtest
    mov r8, 8
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000
    mov rsi, line_prog_list
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    call put_nl64
    ret
.missing:
    mov rsi, line_prog_list_bad
    call puts64
    ret

; ======================================================================
; 包往文件系统里放东西，再自己读回来
; ======================================================================
;
; 上面五样都只往一个方向走：执行、算术、读、画。这一条是包第一次写 —— 而它自己把写进去
; 的读回来，所以「写」与「读」两半都在这一行里。
;
; 而包自己的读回不足以证明写成功：两半各错一半恰好抵消也是可能的。所以宿主随后独立查
; 一次目录，那一步不吃包里任何东西。两条都成立才算数 —— 包说写成了，并且目录里真的有。
run_save_test:
    ; 第二趟该走的门：上一次启动时包写下的那一份应当还在盘上。
    ;
    ; 这一条与 persist 那条同一个道理 —— 同一次运行里写下去再读回来，读到的也可能只是内存。
    ; 而那正是「看起来写成功了」最会伪装的样子。区别是 persist 用的是裸扇区，这一条用的是
    ; 文件系统：目录里那一条、以及它指向的那一页，两样都得在。
    mov rdi, fs_save_path
    call fs_open_path
    test rax, rax
    jz .first
    mov rsi, line_save_survived
    call puts64
    mov rax, r15
    call put_num64
    mov al, ' '
    call putc64
    mov rax, rbx
    call put_num64
    call put_nl64
    ret
.first:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9                       ; "prog.hmtn"
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_savetest
    mov r8, 8
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov qword [pkg_base], 0x70000   ; 种子是默认的那个包
    ; 宿主自己查一次：包说它写成了，而目录里是不是真有那一条
    mov rdi, fs_save_path
    call fs_open_path
    test rax, rax
    jz .lost
    mov rsi, line_save_ok
    call puts64
    mov rax, r15
    call put_num64
    mov al, ' '
    call putc64
    mov rax, rbx
    call put_num64
    call put_nl64
    ret
.lost:
    mov rsi, line_save_lost
    call puts64
    ret
.missing:
    mov rsi, line_save_missing
    call puts64
    ret

; ======================================================================
; 目录写满：该拒绝，而且不许吃掉邻居
; ======================================================================
;
; 这一条验的是 fs_write_file 里那个上界。没有它的时候，条目写满就沿着预读区往后写，
; 而紧跟着的是下一个目录的条目区 —— 症状是「另一个目录里的文件凭空消失」，而不是
; 「写失败」。docs 的 sub 就是这么消失的，而它花了几轮才查出来。
;
; 判据三条，第三条才是这一条的意义：
;   一、一直写到被拒，而拒绝真的会来（不是四十次全成 —— 那说明上界没生效）。
;   二、成功数加拒绝数等于四十。少一条就是「既没成也没拒」，那是另一件事。
;   三、写满之后 docs/myon.hmtn 仍然读得到。少了这条，前两条只是「它说它拒绝了」，
;       而「拒绝」与「写坏了」在这里看起来一样。
;
; 名字用 f00..f39：每条三码元，二十五字节左右，而根目录只剩五百来字节 —— 四十次
; 一定撞到边界。名字各不相同，所以拒绝只可能来自上界，不可能来自重名。
run_dirfull_test:
    xor r15, r15                    ; 成功
    xor r14, r14                    ; 拒绝
    xor r12, r12                    ; 第几次
.walk:
    cmp r12, 40
    jae .done
    lea rdi, [fs_full_name]
    mov word [rdi], 0x0066          ; f
    mov rax, r12
    xor rdx, rdx
    mov rbx, 10
    div rbx                         ; rax = 十位，rdx = 个位
    add al, '0'
    add dl, '0'
    mov [rdi + 2], al
    mov [rdi + 4], dl
    mov word [rdi + 6], 0           ; 结尾零码元
    mov rsi, fs_full_data
    mov rcx, 1                      ; 一字节
    call fs_write_file
    test rax, rax
    jz .refused
    inc r15
    jmp .next
.refused:
    inc r14
.next:
    inc r12
    jmp .walk
.done:
    ; 两个计数先存起来：fs_open_path 会改 r15 与 r14（它用 r15 交扇区、r14 不当自己的）
    mov [dirfull_ok], r15
    mov [dirfull_no], r14
    mov rdi, fs_myon_path
    call fs_open_path
    test rax, rax
    jz .eaten
    mov rsi, line_full_ok
    call puts64
    mov rax, [dirfull_ok]
    call put_num64
    ; 两个数之间要有那个词：判据那边写的是 "wrote N refused M"，而在这一版之前
    ; 串口打的是 "wrote 29 11" —— 两个裸数字，读的人不知道第二个是什么，
    ; 而判据直接匹配不到。判据先写下形状，这里补上能对上的形状。
    mov rsi, line_full_mid
    call puts64
    mov rax, [dirfull_no]
    call put_num64
    call put_nl64
    ret
.eaten:
    mov rsi, line_full_eaten
    call puts64
    ret

; ======================================================================
; 根目录满了之后，docs 仍然写得进去
; ======================================================================
;
; 上一条证明根目录会被挡住。这一条证明挡住的地方只是根目录自己 —— 若「满」被当成一个
; 全局状态（那是最省事的写法：一个 bool，或者干脆不实现 write_dir），那么这里会红，
; 而串口上它与「写对了」长得一样：文件确实写进去了，只是写错了地方。
;
; 判据两条：fs_write_file 说成功，而且 α:/docs/late.txt 查得到、扇区非零。
; 只验前一条的话，一个总往根目录写的实现会骗过它 —— 而根目录那时已经满了，
; 所以它其实会失败，于是前一条也过不了。两条一起才说明「写进了 docs」。
run_docs_after_full:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]            ; 根目录
    mov r8, fs_docs_name
    mov r9, 4                       ; "docs"
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .lost                        ; 根目录里没有 docs：那不是这一条要查的事
    mov [write_dir], r15            ; docs 的扇区
    mov rdi, fs_late_name
    mov rsi, fs_late_data
    mov rcx, 2
    call fs_write_file
    mov qword [write_dir], 0        ; 用过就清
    test rax, rax
    jz .blocked
    ; 写完立刻直接查那一页，不走 fs_open_path。这样两件事就分得开了：
    ; 「条目不在 docs 那一页里」与「fs_open_path 的第二段没走到那一页」。
    ; 上一趟的三个数是 0 1027 1085：write_dir 那个零是清过之后的值，而 last_dir_sec
    ; 是 1027 —— 所以写确实进了 docs，剩下的疑问全在查的那一侧。
    mov r8, fs_late_name
    mov r9, 8
    mov rsi, 1027
    call fs_lookup
    mov [late_probe], rax
    mov [late_probe_sec], r15
    mov rdi, fs_late_path
    call fs_open_path
    test rax, rax
    jz .lost
    mov rsi, line_late_ok
    call puts64
    mov rax, r15
    call put_num64
    mov al, ' '
    call putc64
    mov rax, rbx
    call put_num64
    call put_nl64
    ret
.blocked:
    mov rsi, line_late_blocked
    call puts64
    ret
.lost:
    ; 三个数，一次把「写到哪」问清：
    ;   write_dir     —— 传给 fs_write_file 的目录扇区。0 就是「它没听」。
    ;   last_dir_sec  —— fs_write_file 实际算出来的目录页。
    ;   last_write_sec—— 它把数据放进了哪个新扇区。
    ; 三者里任何一个与 docs 对不上，问题就在那一处。
    mov rsi, line_late_lost
    call puts64
    mov rax, [write_dir]
    call put_num64
    mov al, ' '
    call putc64
    mov rax, [last_dir_sec]
    call put_num64
    mov al, ' '
    call putc64
    mov rax, [last_write_sec]
    call put_num64
    mov al, ' '
    call putc64
    mov rax, [late_probe]           ; 直接查那一页成不成
    call put_num64
    mov al, ' '
    call putc64
    mov rax, [late_probe_sec]       ; 成了的话，它给的扇区
    call put_num64
    mov al, 0x20
    call putc64
    ; 第 6 个数：docs 页里「四条之后」那一格的名字长度。写入成功的话它该是 8。
    ; 若是 0，说明条目没落在那儿；若是 8 而 lookup 仍找不到，那就是匹配那一侧。
    push rsi
    mov rdi, 1027
    call fs_load
    movzx eax, word [rsi + 102]
    pop rsi
    call put_num64
    call put_nl64
    ret

run_trap_test:
    mov rsi, line_trap_before
    call puts64
    ud2
    mov rsi, line_trap_after
    call puts64
    ret

; ======================================================================
; shell 的解释那一半
; ======================================================================
;
; 交互那一半要串口能收字节，而那条路还没通（连试两次都是「连上、无数据」）。
; 所以命令先写在盘上：cmd.txt 里是一行 files。这一半做的是「读到一行、认它、
; 回答」—— 与将来的键盘输入走同一条解释路径，只是输入的来源不同。
;
; 认得出与认不出都要有声音：只回答一个文件列表，看不出「认」这件事发生过；
; 而认不出时给 unknown command，才说明比较那一步是真的在比。
run_shell:
    ; 输入从哪来：先看信箱。
    ;
    ; 信箱那一块是实模式读进来的，落在物理 0x50000（页表把前 1 GB 身份映射，所以
    ; 长模式里这个常量就是地址）。头 32 字节，内容从 0x50020 起，形状与 cmd.txt 一样
    ; 是 ASCII 字节 —— 所以下面「认命令」那一段一个字都不用改，变的只是来源。
    ;
    ; 为什么值得这么分：串口只能往外说，于是「主机往里送一行」一直只有一个办法 ——
    ; 重建整块盘。现在换一行输入不必再碰主盘。
    mov rdi, 0x50000
    mov rsi, mbox_magic
    mov rcx, 8
    call bytes_eq
    jc .from_disk
    mov r15d, [0x50000 + 12]      ; 字节数：32 位读，高半边是序列号
    test r15, r15
    jz .from_disk
    mov r14, 0x50020
    mov rsi, line_shell_from_mbox
    call puts64
    jmp .have_line
.from_disk:
    mov rsi, line_shell_from_disk
    call puts64
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]          ; 根目录扇区（32 位读）
    mov r8, fs_cmd_name
    mov r9, 7
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz shell_missing
    mov rdi, r15                  ; cmd.txt 所在的扇区
    call fs_load
    mov r14, rsi                  ; 命令内容 —— r14 从此换了身份，目录扇区已经用完
.have_line:
    ; 记住这一行在哪：内置 readline 要从这里取。
    ;
    ; 存指针而不是抄内容，是因为 shell 这一侧的行本来就在原地不动 —— 而 readline
    ; 那一步才把 ASCII 字节转成包里认的「u16 长度 + 码元」。转换放在被调用的那一刻，
    ; 而不是存下来的那一刻，理由很简单：一个包不一定读它，而转换是有代价的。
    mov [sh_line_ptr], r14

    mov rsi, line_shell_prompt
    call puts64
    mov rsi, r14
.echo:
    lodsb
    test al, al
    jz .echo_end
    cmp al, 10
    je .echo_end
    call putc64
    jmp .echo
.echo_end:
    call put_nl64

    ; 切出第一个词，按「词长 + 词」分派。
    ;
    ; 以前这里是拿前五个字节与 "files" 比 —— 于是 "filesx" 也会被当成 files，而
    ; 「一行只认一个词、只回一行」那句话就是这样落在代码里的。切成「词 + 其余」之后，
    ; 多一个词只是多一个分支，而参数就在「其余」里。
    mov rdi, r14
    xor ecx, ecx
.split:
    mov al, [rdi + rcx]
    test al, al
    jz .split_done
    cmp al, 10
    je .split_done
    cmp al, ' '
    je .split_done
    inc rcx
    jmp .split
.split_done:
    mov [sh_wordlen], rcx

    cmp qword [sh_wordlen], 5
    jne .try_echo
    mov rdi, r14
    mov rsi, fs_cmd_files
    mov rcx, 5
    call bytes_eq
    jc .try_echo
    jmp .do_files

.try_echo:
    cmp qword [sh_wordlen], 4
    jne shell_unknown
    mov rdi, r14
    mov rsi, fs_cmd_echo
    mov rcx, 4
    call bytes_eq
    jc shell_unknown

    ; echo：把第一个空格之后的全部原样打回来。
    ;
    ; 它看着比 files 简单，而它证明的是另一件事：这一行不只有「一个词」，还有「词之后
    ; 的部分」，而那一段是参数。Myon 作为宿主口的第一步就是它 —— 一个包要能收到一整行
    ; 字，而不是一个命令名。
    mov rsi, r14
    add rsi, 4
    cmp byte [rsi], ' '
    jne .ec
    inc rsi
.ec:
    lodsb
    test al, al
    jz .done
    cmp al, 10
    je .done
    call putc64
    jmp .ec

.do_files:
    ; files：把根目录里的名字逐个打出来
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov edi, [rax + 12]
    call fs_load
    mov rsi, rsi
.entry:
    movzx ecx, word [rsi]
    test ecx, ecx
    jz .done
    push rsi
    push rcx
    mov rdi, rsi
    add rdi, 2
    call put_utf16_n              ; 按长度打：名字之后紧跟的不是码元
    mov al, ' '
    call putc64
    pop rcx
    pop rsi
    lea rsi, [rsi + 11 + rcx * 2]
    jmp .entry
.done:
    call put_nl64
    ret

shell_unknown:
    mov rsi, line_shell_unknown
    call puts64
    ret
shell_missing:
    mov rsi, line_shell_missing
    call puts64
    ret

; ======================================================================
; 交互式的那一行：等键盘送来的键，攒成一行，回车之后解释它
; ======================================================================
;
; 这是 shell 的第三半。前两半分别解决了「认一行」与「那一行从哪来」：认的部分从
; fs_cmd_files 那几行开始就有，来源先是盘上的 cmd.txt，然后是信箱里的一行。可这两样
; 都是事先写好的 —— 换一行要重建或重启。键盘是第一条真正在运行时进来的路。
;
; 为什么先打一行 shell ready：主机不知道客人机什么时候开始轮询，而猜错的代价是
; 「没收到」，那看起来和「键盘不通」一模一样。让客人机先说一句、主机再送键，
; 就把时序从猜测变成了握手。
;
; 超时也要说话：不说的话，一个没送到的键与一个坏掉的键盘在串口上是同一行空白。
; 收一行按键到 line_buf。调用者先打自己的握手行 —— 这里只管收。
;
; 为什么抽出来：shell 与 repl 要收的是同一种东西（一行 ASCII），而「读 0x64、查表、
; 攒缓冲、回车收尾」这四步抄两遍，改一处就会漏另一处。抽出来之后两条路的差别只剩
; 「拿到这一行之后做什么」。
;
; 出：rax = 1 表示收到一行（长度在 line_len，line_buf 以零收尾），0 表示超时。
read_line_keys:
    mov qword [line_len], 0
    mov r10, 20000000              ; 窗口：主机逐个送键，每个之间留五十毫秒，这里等着
.key:
    mov dx, 0x64
    in al, dx
    test al, 0x01
    jz .next
    mov dx, 0x60
    in al, dx
    movzx r14, al
    ; Shift 要在跳过高位码之前处理：放开码 0xAA 与 0xB6 本身就 ≥ 128。
    ; 表里只有小写与不用 Shift 的那几个字符，所以 Shift 只用来把 = 变成 +。
    cmp r14, 0x2A
    je .shift_on
    cmp r14, 0x36
    je .shift_on
    cmp r14, 0xAA
    je .shift_off
    cmp r14, 0xB6
    je .shift_off
    cmp r14, 128
    jae .next                      ; 集 1 的放开码是「按下码或上 0x80」，一律跳过
    lea rax, [keymap]
    movzx eax, byte [rax + r14]
    test al, al
    jz .next
    cmp al, '='
    jne .plain
    cmp byte [shift_state], 0
    je .plain
    mov al, '+'                    ; Shift 加 = 是 +
.plain:
    cmp al, 13
    je .done
    mov rcx, [line_len]
    cmp rcx, 63
    jae .next                      ; 满了就丢：截断会变成另一条命令
    lea rdi, [line_buf]
    mov [rdi + rcx], al
    inc rcx
    mov [line_len], rcx
    call putc64                    ; 回显：串口上看得出正在打字
    jmp .next
.shift_on:
    mov byte [shift_state], 1
    jmp .next
.shift_off:
    mov byte [shift_state], 0
    jmp .next
.next:
    dec r10
    jnz .key
    xor eax, eax
    ret
.done:
    call put_nl64
    mov rcx, [line_len]
    lea rdi, [line_buf]
    mov byte [rdi + rcx], 0        ; 收尾的零：puts64 与 bytes_eq 都要它
    mov rax, 1
    ret

; shell 的交互那一行：先说 ready、收一行、解释它。
run_shell_live:
    mov rsi, line_shell_ready
    call puts64
    call read_line_keys
    test rax, rax
    jz .timeout
    mov rsi, line_shell_prompt
    call puts64
    lea rsi, [line_buf]
    call puts64
    call put_nl64
    lea rdi, [line_buf]
    mov rsi, fs_cmd_files
    mov rcx, 5
    call bytes_eq
    jc shell_unknown
    ; files：列根目录。与 run_shell 里那一段同一份形状 —— 两处都留一份，是因为
    ; 抽成子程序要在两条路上各加一次调用与一次栈对齐，而这里只有十来行。
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov edi, [rax + 12]
    call fs_load
.entry:
    movzx ecx, word [rsi]
    test ecx, ecx
    jz .list_done
    push rsi
    push rcx
    mov rdi, rsi
    add rdi, 2
    call put_utf16_n
    mov al, ' '
    call putc64
    pop rcx
    pop rsi
    lea rsi, [rsi + 11 + rcx * 2]
    jmp .entry
.list_done:
    call put_nl64
    ret
.timeout:
    mov rsi, line_shell_timeout
    call puts64
    ret

; ======================================================================
; repl 的交互那一半：输入一个名字，机器在运行时求它的值
; ======================================================================
;
; 盘上那份 repl.txt 是事先写好的名字。这一半要的是运行时打进去的名字 —— 两者用的是
; 同一条路（find_fn_by_name 找到它、exec 跑它、把返回值打出来），差别只在名字从哪来。
; 这正是 repl 那一条要的「给 exec 一个门」：门开了之后，求值不再由编译期决定。
;
; 名字要走 UTF-16：种子里存的是码元，而键盘给的是 ASCII 字节。转一次比另写一个
; 「按 ASCII 比名字」的查找器便宜，也少一处会分岔的地方 —— 两种查找器迟早会比出
; 不一样的结果，而那种不一样很难看出来。
run_repl_live:
    mov rsi, line_repl_ready
    call puts64
    call read_line_keys
    test rax, rax
    jz .timeout
    mov rsi, line_repl_live_prompt
    call puts64
    lea rsi, [line_buf]
    call puts64
    call put_nl64
    lea rdi, [line_buf]
    lea rsi, [line_buf16]
    mov rcx, [line_len]
    test rcx, rcx
    jz .unknown                    ; 空名字不该被当成一个函数去查
    xor rdx, rdx
.conv:
    cmp rdx, rcx
    jae .converted
    movzx eax, byte [rdi + rdx]
    mov [rsi + rdx * 2], ax
    inc rdx
    jmp .conv
.converted:
    lea rdi, [line_buf16]
    mov r8, rcx                    ; 名字长度，find_fn_by_name 要这个
    xor r15, r15                   ; 后者胜，与读程序 同一条规矩
    call find_fn_by_name
    test rax, rax
    jz .unknown
    mov r12, rsi                   ; 指令流
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    call print_value
    call put_nl64
    ret
.unknown:
    mov rsi, line_repl_live_unk
    call puts64
    ret
.timeout:
    mov rsi, line_repl_live_to
    call puts64
    ret

; 打印 exec 交回来的值：rax = 种类，rdx = 内容。不打换行，由调用者收尾。
;
; 认不出的种类把号码打出来，而不是当成空 —— 「算出了空」与「算出了不认识的类型」
; 在串口上看起来一样，而它们的修法完全不同。
print_value:
    cmp rax, 1
    je .num
    cmp rax, 2
    je .str
    cmp rax, 3
    je .bool
    mov rsi, line_bad_kind
    call puts64
    jmp put_num64
.num:
    ; f64_to_int 只看指数与尾数，不看符号位 —— 所以负数会以绝对值回来。打印之前先看符号位：
    ; 置位就先打一个减号，再把那一位清掉。
    ;
    ; 这一条是减法那一格逼出来的：-42 与 42 在串口上长得一样，于是「交换两个实参」这个
    ; 验红根本红不了。判据的形状里有一个字漏了，而那个字恰好是这一格唯一要证明的东西。
    test rdx, rdx
    jns .num_pos
    push rdx
    mov al, '-'
    call putc64
    pop rdx
    btc rdx, 63
.num_pos:
    mov rax, rdx
    call f64_to_int
    jmp put_num64
.str:
    push rdx
    mov rsi, line_string
    call puts64
    pop rdx
    movzx eax, word [rdx]          ; 串的头两个字节是长度
    jmp put_num64
.bool:
    mov rax, rdx
    test rax, rax
    jz .false
    mov rsi, line_true_flat
    jmp puts64
.false:
    mov rsi, line_false_flat
    jmp puts64

; ======================================================================
; 从盘上加载一个程序，跑它
; ======================================================================
;
; 这是 userland 的第一件：一个程序从盘上的哪一份字节开始跑。
;
; 答案很朴素 —— 一个与种子同格式的包（HMYRB 头 + 函数表），从文件系统读进预读区，
; 在里面找 main，跑它。朴素但成立：包住在盘上、不在启动时的内存里，于是「程序是什么」
; 与「种子是什么」分开了。种子是启动时就在的那一个包，prog.hmtn 是之后从盘上取的
; 另一个 —— 而两者用同一段查找代码，靠 pkg_base 分。
;
; 没有做的：地址空间（包与系统共用同一片内存）、权限、多个程序同时存在。那些都要
; 先有「一个程序占一块地方」的概念，而那要等进程。
run_program:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9                       ; "prog.hmtn"
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz prog_missing
    mov rdi, r15
    call fs_load
    mov r14, rsi                    ; 包在预读区里的地址
    mov rdi, r14
    mov rsi, seed_magic
    mov rcx, 5
    call bytes_eq
    jc prog_bad
    ; 这个包成为当前包，然后按名字找 main
    mov [pkg_base], r14
    mov rdi, name_main
    mov r8, 4
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz prog_nomain
    mov r12, rsi                    ; 指令流
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    ; 结果先存进寄存器：恢复 pkg_base 那两句会用到 rax
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000   ; 种子是默认的那个包，别让后面的测试读错地方
    mov rsi, line_prog
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    call put_nl64
    ret

; ======================================================================
; 解释器真的能算：一个包返回 40 + 2
; ======================================================================
;
; 「住得下 HMYR」里最要紧的一条是解释器真的能算 —— 一份编译器产出的字节码不会只有
; 常量与内置调用。main 返 7、echo 打字，两者都没用到算术。
;
; 40 与 2 挑得没有讲究，只要和是 42；而 42 在这里没有别处出现过 —— 它不可能来自宿主
; 里写死的数，只能来自包里的那两条常量与一次 add。
run_prog_sum_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9                       ; "prog.hmtn"
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_sum
    mov r8, 3
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi                    ; 指令流
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000
    mov rsi, line_prog_sum
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    call put_nl64
    ret
.missing:
    mov rsi, line_prog_sum_bad
    call puts64
    ret

; ======================================================================
; 一个包在屏幕上写字
; ======================================================================
;
; 上面几条（border、rect、win）都是「包让宿主画」：坐标或写死、或由包指定，而画出来的
; 东西是宿主决定的。这一条换了方向 —— 包给出一个串，内容是它自己写的。
;
; 一个画不出字的界面只能算一块画布：用户读到的第一句话应当是某个程序说出来的，而不是
; 宿主替它说。
;
; 包里那个函数叫 textline，六条指令：三个常量（x 是 40、y 是 120、颜色是 0x1C）、一个串
; 常量（O、换行、K）、调内置 text、返回。
;
; 串里那个换行（0x0A）是这一格的重点：它让包写出一段话，而不是一行。固件的 draw_utf16
; 认了 0x0A，行距十像素 —— 与 draw_lines 同一套约定。
;
; 判据读三个点：
;   (42,120) 是 O 顶边中段，0x3C 的 bit5 是 1，该亮
;   (42,130) 是 K 顶边中段，0x66 的 bit5 是 1，该亮 —— 它落在 120 + 10 上，所以换行真的
;     发生了；若换行没实现，0x0A 会被当成未知字符跳过，K 会画在 40 + 8 = 48 上，这一点
;     就是零
;   (42,140) 是第三行该在的位置，没有第三行，该暗 —— 它防的是「每一行都在同一个 y 上
;     累加」这种错法
;
; 颜色期望 0x1C 而不是 0x2F：只要与本侧曾经写死的那个值不同，「这个像素是谁给的」就能
; 从串口上分开。
run_prog_text_test:
    ; 先把这三格抹掉：别的测试在同一片屏幕上画过东西，而「该暗」那一点要求背景是零。
    mov rdi, 40
    mov rsi, 120
    xor dl, dl
    call clear_block
    mov rdi, 40
    mov rsi, 130
    xor dl, dl
    call clear_block
    mov rdi, 40
    mov rsi, 140
    xor dl, dl
    call clear_block

    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_textline
    mov r8, 8
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov qword [pkg_base], 0x70000
    mov rsi, line_progtext
    call puts64
    mov rdi, 42
    mov rsi, 120
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 42
    mov rsi, 130
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 42
    mov rsi, 140
    call read_pixel
    call put_hex64
    jmp put_nl64
.missing:
    mov rsi, line_progtext_bad
    call puts64
    ret

; ======================================================================
; 一个包把宿主递进来的那一行画到屏幕上
; ======================================================================
;
; 上一格画的是包里的常量；这一格画的是运行时从外面进来的东西。这是「界面对话」的前一半
; —— 一个只能显示自己写死内容的界面，与一块牌子没有区别。
;
; 包里那个函数叫 echo2text，六条指令：两个坐标常量（40、150）、调内置 readline、一个颜色
; 常量（0x1C）、调内置 text、返回。
;
; 那一行是信箱盘里的 "echo hello world"：全小写，而字体只有大写 —— 所以这一条同时验着
; 上一格做的折叠。字体若没有折叠，屏幕上会是空白，而 readline 那边一切正常。
;
; 判据读三个点：
;   (40,150) 是 E 顶边最左列，0x7E 的 bit7 是 0，该暗
;   (41,150) 是它右边一位，bit6 是 1，该亮
;   (129,150) 是第十一个字符（w 折成 W）顶边的 bit6：索引 11 从 40 + 11 * 8 = 128 起，
;     W 的顶边 0x63 的 bit6 落在 128 + 1 = 129。这一点验的是「整串被铺下来了」——
;     只读开头两点的话，一个画完第一个字就停的实现照样能过。
run_prog_echo_test:
    ; 先抹掉三格：屏幕上前面的测试画过东西，而「该暗」那一点要求背景是零。
    mov rdi, 40
    mov rsi, 150
    xor dl, dl
    call clear_block
    mov rdi, 48
    mov rsi, 150
    xor dl, dl
    call clear_block
    mov rdi, 128
    mov rsi, 150
    xor dl, dl
    call clear_block

    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_echo2text
    mov r8, 9
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov qword [pkg_base], 0x70000
    mov rsi, line_progecho
    call puts64
    mov rdi, 40
    mov rsi, 150
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 41
    mov rsi, 150
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 129
    mov rsi, 150
    call read_pixel
    call put_hex64
    jmp put_nl64
.missing:
    mov rsi, line_progecho_bad
    call puts64
    ret

; ======================================================================
; 一个包画一个带标题的窗口
; ======================================================================
;
; 这是把已有的两样合起来：win 画三层矩形（底色 0x1F、标题栏 0x1C、内容区 0x0F），
; text 写字。合起来的结果是屏幕上第一个「窗口」而不是一块画布 —— 一个框加上它自己说的话。
;
; 包里那个函数叫 titlewin，七条指令：调 win、两个坐标常量（70、84）、一个串常量（MYON）、
; 一个颜色常量（0x0F）、调 text、返回。标题的 y 是 84：标题栏从 81 到 92，字高八，所以
; 84 到 91 都在栏内，上下各留三像素。
;
; 判据读三个点：
;   (70,84) 是 M 顶边最左列，0x63 的 bit7 是 0，该露出标题栏底色 0x1C
;   (71,84) 是它右边一位，bit6 是 1，该是字色 0x0F
;   (80,84) 是第二个字符（Y）顶边的 bit5，起点 70 + 8 = 78，78 + 2 = 80，该是 0x0F
; 第一点与后两点合起来说的是同一件事的两面：字画上去了，而且它周围的底色没被吃掉 ——
; 只读后两点的话，一个把整条标题栏刷成字色的实现照样能过。
run_prog_title_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_titlewin
    mov r8, 8
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov qword [pkg_base], 0x70000
    mov rsi, line_progtitle
    call puts64
    mov rdi, 70
    mov rsi, 84
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 71
    mov rsi, 84
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 80
    mov rsi, 84
    call read_pixel
    call put_hex64
    jmp put_nl64
.missing:
    mov rsi, line_progtitle_bad
    call puts64
    ret

; ======================================================================
; 裁剪：字画到窗口外面该消失
; ======================================================================
;
; 上一格把窗口与文字合起来了，但内容会溢出去：画到窗口外的字照画不误，两个窗口挨着就
; 互相脏。这一格补的是那条界线。
;
; 包里那个函数叫 clipped，十六格指令：设裁剪（60、80、260、170）、调 clip、把 LONG 写
; 在 (240, 84)、关裁剪、返回。四个字符占 240 到 271，而裁剪的右边界是 260 —— 第三个字符
; 的后半与第四个字符整个落在外面。
;
; 判据读两个点：
;   (241,84) 是 L 顶边的 bit6，该是字色 0x0F —— 它在裁剪里
;   (261,84) 是 N 顶边的 bit2。那里本来会被画上 0x0F，而裁剪该让它保住底色
; 第二点前面先被写成 0x05 —— 只有这样「没被覆盖」才是有内容的断言：屏幕那一格本来是
; 零，而零与「裁掉了」在串口上分不开。
run_prog_clip_test:
    ; 先在被裁的那一格上写 0x05，让它有个不该被动的内容。
    mov rdi, 261
    mov rsi, 84
    mov dl, 0x05
    call clear_block

    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_clipped
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov qword [pkg_base], 0x70000
    mov rsi, line_progclip
    call puts64
    mov rdi, 241
    mov rsi, 84
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 261
    mov rsi, 84
    call read_pixel
    call put_hex64
    jmp put_nl64
.missing:
    mov rsi, line_progclip_bad
    call puts64
    ret

; ======================================================================
; 窗口里显示一个文件的内容
; ======================================================================
;
; 到上一格为止，窗口里的字有两个来源：包里的常量，与宿主递进来的一行。这一格是第三个
; 来源 —— 磁盘上的文件。三个来源合起来，一个「文本查看器」的形状就齐了。
;
; 包里那个函数叫 showfile，七条指令：两个坐标常量（70、100）、一个路径常量、调 slurp、
; 一个颜色常量、调 text、返回。
;
; 这一格只加包，固件一个字没改：slurp 返回的串形状（u16 长度 + 码元）正是 draw_utf16
; 吃的那一种，而 text 已经把这两头接起来了。所以「能显示文件」这件事在上一格就已经具备，
; 只差有人把它连起来 —— 而连起来的那一句是压栈顺序：slurp 的返回值直接压在 x、y 上面，
; 栈上依次就是 x、y、串、颜色。
;
; 判据读三个点：
;   (70,100) 是 Y 顶边最左列，0x66 的 bit7 是 0，该露出内容区底色 0x0F
;   (72,100) 是 bit5，该是字色 0x2F
;   (80,100) 是第二个字符（u 折成 U）顶边的 bit5，从 70 + 8 = 78 起，78 + 2 = 80，也该是 0x2F
; 第二点与第三点之间隔着八像素 —— 「一个字」与「一整行」在这里分得开。
run_prog_file_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_showfile
    mov r8, 8
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov qword [pkg_base], 0x70000
    mov rsi, line_progfile
    call puts64
    mov rdi, 70
    mov rsi, 100
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 72
    mov rsi, 100
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 80
    mov rsi, 100
    call read_pixel
    call put_hex64
    jmp put_nl64
.missing:
    mov rsi, line_progfile_bad
    call puts64
    ret

; ======================================================================
; 写槽：包里第一次能改自己的状态
; ======================================================================
;
; 在 opcode 17（写槽）之前，包里所有函数都是「读参数、算、返回」—— 一个计数器都写不出来，
; 也就一个循环都写不出来。所以这一条比它看起来重要：它是「包能有状态」与「包只能算一次」
; 之间的分界。
;
; 包里那个函数叫 slotwrite，四条指令：常量 42、写槽 1、读槽 1、返回。它短得几乎不像一课，
; 而那是刻意的 —— 这一条验的是「写与读看到同一个格子」，掺进循环或条件就分不清是哪一环
; 坏的。
;
; 判据的力气在分辨力上：若写槽是空操作，读槽读到的是一格初始值零，于是返回 0 而不是 42。
; 所以「跑出 42」证明的是写进去了，不只是「没有报错」。
;
; 槽 1 而不是槽 0：槽 0 是第一个参数的位置。这个函数零参，所以槽 0 空着；用槽 1 是为了
; 顺手把「槽号从 0 数」这个约定也钉住 —— 若哪天它变成从 1 数，这一条会红。
run_prog_set_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_slotwrite
    mov r8, 9
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000
    mov rsi, line_progset
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    call put_nl64
    ret
.missing:
    mov rsi, line_progset_bad
    call puts64
    ret

; ======================================================================
; 循环：包里第一次转起来
; ======================================================================
;
; 上一格给了包「写槽」，这一格把那件事用起来。二十六条指令，形状是任何一门语言的第一个
; 循环：槽 0 数次数、槽 1 记当前的 x；每轮画一个 8x8 的方块、x 加二十、计数加一；条件
; 是「计数 >= 三」就跳出去。
;
; 三样零件都已在：写槽（34）、真跳（16）、大等（9）。所以这一格没有改一行固件 —— 它是
; 前面几格攒出来的第一件「程序」，而不是又一条指令。
;
; 没有乘法：x 用槽累加而不是 i 乘二十。这一版的算术只有加、除、等与大等四条，而加乘
; 是为了一个能被累加替代的算式。
;
; 判据读四个点：(44,174)、(64,174)、(84,174) 是三个方块的中心，该是 0x2F；(104,174) 是
; 第四个方块本该在的位置，该是零 —— 那一点防的是「条件坏了，一直画下去」。
;
; y 用 174 而不是 154：150 那一行是输入回显画的字，两者会叠在一起，而「没有第四个方块」
; 那个点必须落在干净的位置上。所以先把 104 那一格抹成零。
run_prog_loop_test:
    ; 四个格子先抹成零，包括三个方块要占的位置 —— 它们底下原本有别的东西（实测有一格是
    ; 0x28）。若不抹，判据就变成「方块盖住了那格」而不是「方块画在了那格」，而一个恰好
    ; 是 0x2F 的旧像素会让「少画一个方块」这件事假绿。
    mov rdi, 40
    mov rsi, 170
    xor dl, dl
    call clear_block
    mov rdi, 60
    mov rsi, 170
    xor dl, dl
    call clear_block
    mov rdi, 80
    mov rsi, 170
    xor dl, dl
    call clear_block
    mov rdi, 104
    mov rsi, 174
    xor dl, dl
    call clear_block

    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_loopthree
    mov r8, 9
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000
    mov rsi, line_progloop
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    mov rsi, line_space
    call puts64
    mov rdi, 44
    mov rsi, 174
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 64
    mov rsi, 174
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 84
    mov rsi, 174
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 104
    mov rsi, 174
    call read_pixel
    call put_hex64
    jmp put_nl64
.missing:
    mov rsi, line_progloop_bad
    call puts64
    ret

; ======================================================================
; 全局：包里第一样比一次调用更长寿的东西
; ======================================================================
;
; 槽随帧生死，全局不随。这个差别在同一个函数里看不出来 —— 槽也能写完再读，上一格已经
; 证过。所以这一格的判据必须跨两次 exec：先跑 globalset 把 7 写进第 3 号，再跑 globalget
; 把它读回来。若「全局」其实落在了槽里，第二次读到的是空，因为那时已经是另一帧、另一次
; exec 了。
;
; 两次 exec 之间不做任何清扫。这不是疏忽：全局的意思正是「不清扫也还在」，而清扫一下
; 再读，判据就变成「它在清扫之后被留住」而不是「它跨调用活着」。
run_prog_global_test:
    ; 第一次：写。
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_globalset
    mov r8, 9
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    ; 这里不能把 pkg_base 拨回 0x70000：第二次 find_fn_by_name 还要在同一个包里找
    ; globalget。拨回去就变成在种子里找它，而种子没有这个函数 —— 症状是 missing，
    ; 一个与「全局没生效」毫无关系的报法。

    ; 第二次：读。
    mov rdi, name_globalget
    mov r8, 9
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000
    mov rsi, line_progglobal
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    call put_nl64
    ret
.missing:
    mov rsi, line_progglobal_bad
    call puts64
    ret

; ======================================================================
; 拖动：同一个函数画在两个地方
; ======================================================================
;
; 全局有了之后，窗口位置就能跨调用活下来。这一格是那件事的第一个用处：包里三个函数分工
; —— resetpos 把位置设回 (40,180)、mark 照全局的位置画一个方块、right60 把 x 加六十。
;
; 判据的形状是「同一个 mark 画在两处」：resetpos + mark 之后读第一处，right60 + mark 之后
; 读第二处。若 mark 忽略全局、把坐标写死，第二次读到的就是零。
;
; 这就是「界面」与「一幅画」的分界：前者同一个东西在两帧之间会变，而变的是它的状态，而
; 不是画它的那串指令。
;
; 三次 find_fn_by_name 都在同一个包里，所以 pkg_base 从头到尾不拨 —— 上一格刚踩过这个坑。
run_prog_drag_test:
    ; 两块要读的地方先抹成零。
    mov rdi, 40
    mov rsi, 180
    xor dl, dl
    call clear_block
    mov rdi, 100
    mov rsi, 180
    xor dl, dl
    call clear_block

    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14

    ; 一、设位置
    mov rdi, name_resetpos
    mov r8, 8
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec

    ; 二、画第一处
    mov rdi, name_mark
    mov r8, 4
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec

    mov rsi, line_progdrag
    call puts64
    mov rdi, 44
    mov rsi, 184
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64

    ; 三、改位置
    mov rdi, name_right60
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec

    ; 四、画第二处
    mov rdi, name_mark
    mov r8, 4
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec

    mov rdi, 104
    mov rsi, 184
    call read_pixel
    call put_hex64
    mov qword [pkg_base], 0x70000
    jmp put_nl64
.missing:
    mov rsi, line_progdrag_bad
    call puts64
    ret

; ======================================================================
; 一帧：擦旧位置、改坐标、画新位置
; ======================================================================
;
; 上一格证明「同一个 mark 能画在两个地方」，但旧的那个留在屏幕上 —— 拖过去就是一路撒方块。
; 这一格补的是顺序：擦、改、画，三步连起来才是一帧。
;
; 包里那个 erase 与 mark 逐条一样，只有最后那个颜色常量不同（0 而不是 0x2F）。所以橡皮
; 没有引入任何新机制 —— rect 本来就是填充矩形，涂成背景色就是擦除。
;
; 判据读四个点，顺序本身就是这一格的内容：
;   mark 之后读旧位置        该是 0x2F
;   erase 之后读同一处       该是 0x00      —— 擦真的发生了
;   right60 + mark 之后读新位置  该是 0x2F
;   再看旧位置                仍是 0x00     —— 擦掉的东西没有被谁画回去
run_prog_frame_test:
    mov rdi, 40
    mov rsi, 180
    xor dl, dl
    call clear_block
    mov rdi, 100
    mov rsi, 180
    xor dl, dl
    call clear_block

    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14

    mov rsi, line_progframe
    call puts64

    ; 一、设位置并画
    mov rdi, name_resetpos
    mov r8, 8
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run
    mov rdi, name_mark
    mov r8, 4
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run
    mov rdi, 44
    mov rsi, 184
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64

    ; 二、擦
    mov rdi, name_erase
    mov r8, 5
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run
    mov rdi, 44
    mov rsi, 184
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64

    ; 三、改位置再画
    mov rdi, name_right60
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run
    mov rdi, name_mark
    mov r8, 4
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run
    mov rdi, 104
    mov rsi, 184
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 44
    mov rsi, 184
    call read_pixel
    call put_hex64
    mov qword [pkg_base], 0x70000
    jmp put_nl64
.reset_and_run:
    ; 每次 exec 前把解释器的状态归零：栈顶、帧号、pc。三样都是上一个函数留下的。
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    jmp exec
.missing:
    mov rsi, line_progframe_bad
    call puts64
    ret

; ======================================================================
; 同一个函数，两帧不同的字
; ======================================================================
;
; 上一格证明的是「一帧可以擦、可以改、可以画」，但那三步是宿主依次调三个函数做出来的，
; 屏幕上画的仍然是同一块方块换个地方。这一格要的是内容本身会变：同一个 retitle 调两次，
; 画出来的字不一样，而它的指令一个字节都没动。
;
; 选择子是全局 9，由宿主在两次调用之间改。这不越权：宿主在这里扮的是「用户按了一下」，
; 而窗口怎么重绘是包自己的事 —— 包做的事没变，只是它读到的状态变了。全局 9 而不是全局 3，
; 是因为全局 3 早被 globalset 那一格写成了 7，而串口的判据是按顺序跑的：一条判据若依赖
; 另一条判据留下的状态，它红了也说不清为什么红。
;
; 四个读数是按内容挑的，不是按方便挑的：
;   (73, 84) 落在 'O' 顶横的中央，'X' 在那里是空的
;   (73, 87) 落在 'X' 中心交叉处，'O' 在那里是空洞
; 于是同一个函数的两帧在两点上正好互换，读数 0F 1C 1C 0F 的顺序就是「先 O 后 X」。
run_prog_retitle_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14

    mov rsi, line_progretitle
    call puts64

    ; 一、先把窗口骨架画出来：标题栏是 0x1C，字才有地方落
    mov rdi, name_win
    mov r8, 3
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    ; 二、选择子归零，调一次：应当画出 O
    mov qword [global_kinds + 9 * 8], 1
    mov qword [global_vals + 9 * 8], 0
    mov rdi, name_retitle
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run
    mov rdi, 73
    mov rsi, 84
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 73
    mov rsi, 87
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64

    ; 三、选择子改成一，再调同一个函数：应当换成 X
    ;
    ; 这里必须存 1.0 的位模式，不是整数 1。全局那一格存的是 double 的位模式：写整数 1 进去，
    ; 解释器按 double 读出来是 4.9e-324（最小次正规数），于是「大于等于 1」仍然是假，第二帧
    ; 会继续画 O —— 屏幕上看起来像「重绘没生效」，其实是那个数根本不是我写的那个数。
    mov rax, 0x3FF0000000000000
    mov [global_vals + 9 * 8], rax
    mov rdi, name_retitle
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run
    mov rdi, 73
    mov rsi, 84
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 73
    mov rsi, 87
    call read_pixel
    call put_hex64
    mov qword [pkg_base], 0x70000
    jmp put_nl64
.reset_and_run:
    ; 每次 exec 前把解释器的状态归零：栈顶、帧号、pc。三样都是上一个函数留下的。
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    jmp exec
.missing:
    mov rsi, line_progretitle_bad
    call puts64
    ret

; ======================================================================
; 值过桥
; ======================================================================
;
; 已有的「Myon 两包」判据只证明桥能让内层跑起来 —— 内层是用 write 说话的，话说完就完，
; 返回值没人看。所以一个「把内层返回值永远换成空」的 runpkg 照样过它。这一条看的是另一
; 半：内层的 echo 现在返回 7，外层的 bridge 原样把它带回来，宿主读到 7。
;
; 三端都要对得上才叫桥 —— 内层返回什么、外层拿到什么、宿主读到什么。少一端，「桥没接上」
; 与「桥接上了而值被丢掉」在读数上就是一样的。
run_prog_bridge_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_bridge
    mov r8, 6
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    ; exec 停下时 rax 与 rdx 就是 bridge 的返回值，而它是 runpkg 带回来的那一份。
    ; 先搬到两个不会被下面的调用用掉的寄存器，再打印。
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000
    mov rsi, line_progbridge
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    jmp put_nl64
.missing:
    mov rsi, line_progbridge_bad
    call puts64
    ret

; ======================================================================
; 值送进桥
; ======================================================================
;
; 上一格证明值能带回来，这一格证明它能送过去 —— 而且内层真的用了它。
;
; 判据是 8，而不是 7 或 1，因为这三个数各自排除一种可能：
;   1  参数根本没到，槽 0 是空，空加一得 1
;   7  参数到了，而内层没加一（或者加一那一步没跑到）
;   8  只有一个来路：7 过去了、内层读到它、加一、再带回来
;
; 所以这一个读数比「能过桥」细得多 —— 它同时钉住方向、位置与算术三件事。
run_prog_bump_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_bridge1
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000
    mov rsi, line_progbump
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    jmp put_nl64
.missing:
    mov rsi, line_progbump_bad
    call puts64
    ret

; ======================================================================
; 一帧重画：擦旧、画新、记住新
; ======================================================================
;
; redraw 现在把上一帧的位置留在全局 14 与 15。测试调它两次：第一次在 (100,60)，第二次先把
; 全局位置改到 (140,90) 再调 —— 于是第二趟进来时它记着的旧位置就是 (100,60)，该被擦掉。
;
; 判据三点：
;   (0, 0)     清屏之后宿主人为画的记号。第一趟标志是 0，不该擦它，所以它还在（2F）
;   (100, 60)  第一帧的左上角。第二趟标志已是 1，先擦这一块，所以是背景色 00
;   (141, 90)  第二帧的左上角（窗口在 140,90），底色 1F
;
; 第一点与第二点合起来才是这一格的话：第一次不擦（别人的像素留着）、第二次擦（自己的旧帧
; 清掉）。一个标志位，两句话一起成立。
run_prog_redraw_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14

    mov rsi, line_progredraw
    call puts64

    ; 一、清屏，然后在左上角画一块记号 —— 那是「别人的像素」：第一次调用不该碰它
    xor dl, dl
    call clear_screen
    xor rdi, rdi
    xor rsi, rsi
    mov dl, 0x2F
    call clear_block

    ; 二、第一次：位置 (100, 60)、尺寸 200x90、选择子归零（画 O）、标志清零。
    ;    标志必须是 0 —— 同一趟里前面的测试可能调过 redraw，已经把它置成过 1。
    mov qword [global_kinds + 10 * 8], 1
    mov rax, 0x4059000000000000      ; 100.0
    mov [global_vals + 10 * 8], rax
    mov qword [global_kinds + 11 * 8], 1
    mov rax, 0x404E000000000000      ; 60.0
    mov [global_vals + 11 * 8], rax
    ; 宽与高也进全局 7 与 8：这一格固定成 200x90，与从前的默认尺寸一致，判据点才不用改
    ;
    ; 用 7 与 8 而不是 16 与 17 —— 全局区只有十六格。第一次写这一格时用了 16，越界写到
    ; global_vals 后面的内存上，save 判据当场红成「save docs/inner.txt lost」，而这与窗口
    ; 毫无关系。.op_getglobal 那一处早就写过「上限不做检查」。
    mov qword [global_kinds + 7 * 8], 1
    mov rax, 0x4069000000000000      ; 200.0
    mov [global_vals + 7 * 8], rax
    mov qword [global_kinds + 8 * 8], 1
    mov rax, 0x4056800000000000      ; 90.0
    mov [global_vals + 8 * 8], rax
    mov qword [global_kinds + 9 * 8], 1
    mov qword [global_vals + 9 * 8], 0
    mov qword [global_kinds + 4 * 8], 1
    mov qword [global_vals + 4 * 8], 0
    mov rdi, name_redraw
    mov r8, 6
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    ; 三、第二次：把位置改到 (140, 90)，再调一次。
    ;    这一趟标志已经是 1，所以它先擦 (100,60) 那一块，再在 (140,90) 画新的。
    mov qword [global_kinds + 10 * 8], 1
    mov rax, 0x4061800000000000      ; 140.0
    mov [global_vals + 10 * 8], rax
    mov qword [global_kinds + 11 * 8], 1
    mov rax, 0x4056800000000000      ; 90.0
    mov [global_vals + 11 * 8], rax
    mov rdi, name_redraw
    mov r8, 6
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    ; 四、三点：记号还在（第一次没擦）、旧位置空了（第二次擦了）、新窗口在
    xor rdi, rdi
    xor rsi, rsi
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 100
    mov rsi, 60
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 141
    mov rsi, 90
    call read_pixel
    call put_hex64
    mov qword [pkg_base], 0x70000
    jmp put_nl64
.reset_and_run:
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    jmp exec
.missing:
    mov rsi, line_progredraw_bad
    call puts64
    ret

; ======================================================================
; 窗口跟着全局走
; ======================================================================
;
; 在此之前，窗口的位置是包里的常量：win 的三层写死在 (60,80)。而「窗口」若不能移动，它就
; 只是一幅画。这一格把位置搬进全局 10 与 11，再由一个零参的 shiftwin 取出来交给 winat。
;
; 为什么要一个零参外壳：宿主调用包函数时不能压参数 —— 它直接 exec，没有「调用者」那一层，
; 实参是从运算栈搬进槽的，而宿主的栈是空的。所以「参数从哪来」只能由函数自己去取，全局
; 就是那个来源。winat 本身接受两个参数，供包内的调用者用。
;
; 判据三点，先清屏再画，所以每一点都只可能来自这一次调用：
;   (100, 60)  新窗口的左上角，应当是底色 1F
;   (110, 70)  新窗口的标题栏，应当是 1C
;   (60, 80)   旧窗口的左上角 —— 清屏之后若没人往那里画，它就是 00
; 第三点是这一格的关键。它必须落在「旧窗口有、而新窗口没有」的地方：第一次挑的是 (160,86)，
; 那是旧窗口标题栏的中央，可它同时也在新窗口的内容区里（两个位置互相重叠），于是正确实现的
; 读数也是 0F，判据红在一个选错的点上。新窗口从 x=100 起，旧窗口左上角在 x=60，隔着四十列。
run_prog_shift_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14

    mov rsi, line_progshift
    call puts64

    ; 一、清屏：这一格的三点都只该来自这一次调用
    xor dl, dl
    call clear_screen

    ; 二、位置进全局，然后画
    mov qword [global_kinds + 10 * 8], 1
    mov rax, 0x4059000000000000      ; 100.0
    mov [global_vals + 10 * 8], rax
    mov qword [global_kinds + 11 * 8], 1
    mov rax, 0x404E000000000000      ; 60.0
    mov [global_vals + 11 * 8], rax
    ; winat 现在要四个参数，宽高也从全局来
    mov qword [global_kinds + 7 * 8], 1
    mov rax, 0x4069000000000000      ; 200.0
    mov [global_vals + 7 * 8], rax
    mov qword [global_kinds + 8 * 8], 1
    mov rax, 0x4056800000000000      ; 90.0
    mov [global_vals + 8 * 8], rax
    mov rdi, name_shiftwin
    mov r8, 8
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov qword [pkg_base], 0x70000

    mov rdi, 100
    mov rsi, 60
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 110
    mov rsi, 70
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 60
    mov rsi, 80
    call read_pixel
    call put_hex64
    jmp put_nl64
.missing:
    mov rsi, line_progshift_bad
    call puts64
    ret

; ======================================================================
; 两个值一起过桥
; ======================================================================
;
; 上一格把位置从常量搬进全局，winat 于是有了两个参数 —— 但那是包内的调用，桥还只会送一个
; 值。这一格让两个值一起过桥：外层压 30 与 13，内层的 sum2 把它们加起来，带回 43。
;
; 判据 43 排除的东西比前几格多：只送到 30 会读到「30 加残留」，只送到 13 会读到「13 加
; 残留」，两个都没送到读到的是残留自己 —— 三种都不会凑巧是 43。
run_prog_sum2_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_bridge2
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000
    mov rsi, line_progsum
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    jmp put_nl64
.missing:
    mov rsi, line_progsum_bad
    call puts64
    ret

; ======================================================================
; 顺序：减法把「谁落进哪个槽」钉住
; ======================================================================
;
; 上一格用加法验证「两个值都到了」，可加法测不出顺序 —— 顺序反了，和还是那个和。减法不交换：
; 50 减 8 得 42，8 减 50 得 -42。于是「槽 0 是第一个实参」这句话第一次有了判据。
;
; 这个读数还带着第三种可能：只送到一个。那时内层算的是「那个数减残留」，结果既不是 42 也
; 不是 -42 —— 三种情况各有各的数，一个读数全部分得开。
run_prog_sub_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_bridge3
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000
    mov rsi, line_progsub
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    jmp put_nl64
.missing:
    mov rsi, line_progsub_bad
    call puts64
    ret

; ======================================================================
; 位置过桥：内层拿到的不是数，是坐标
; ======================================================================
;
; 前三个桥送进去的值都被内层拿去算数。这一格让它们变成坐标：内层的 drawat 读槽 0 与槽 1，
; 直接在上面画一个 'A'。
;
; 判据三点，第二点比第一点重要：'A' 的顶行是 0x18，只在中间两格亮，所以 (x+3, y) 有字而
; (x, y) 是空的。两点挨着，一次调用就同时证明「画了」与「画在哪儿」。
;
; 第三点是调两次的理由：位置从全局 12 与 13 来，第二次给另一组坐标。若内层把坐标写死，
; 两次会落在同一处，第三点就空了。
run_prog_draw_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14

    mov rsi, line_progdraw
    call puts64

    xor dl, dl
    call clear_screen

    ; 一、第一次：(100, 120)
    mov qword [global_kinds + 12 * 8], 1
    mov rax, 0x4059000000000000      ; 100.0
    mov [global_vals + 12 * 8], rax
    mov qword [global_kinds + 13 * 8], 1
    mov rax, 0x405E000000000000      ; 120.0
    mov [global_vals + 13 * 8], rax
    mov rdi, name_bridge4
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    mov rdi, 103
    mov rsi, 120
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 100
    mov rsi, 120
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64

    ; 二、第二次：(180, 160)
    mov qword [global_kinds + 12 * 8], 1
    mov rax, 0x4066800000000000      ; 180.0
    mov [global_vals + 12 * 8], rax
    mov qword [global_kinds + 13 * 8], 1
    mov rax, 0x4064000000000000      ; 160.0
    mov [global_vals + 13 * 8], rax
    mov rdi, name_bridge4
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    mov rdi, 183
    mov rsi, 160
    call read_pixel
    call put_hex64
    mov qword [pkg_base], 0x70000
    jmp put_nl64
.reset_and_run:
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    jmp exec
.missing:
    mov rsi, line_progdraw_bad
    call puts64
    ret

; ======================================================================
; 尺寸也来自全局
; ======================================================================
;
; 位置进全局之后，尺寸还写死在 winat 里（200x90）。这一格把它也搬出来：全局 16 是宽、
; 17 是高，winat 改成四个参数，redraw 与 shiftwin 都跟着传。
;
; 判据用一个非默认的尺寸 —— 160x70 —— 读窗口的两只角：
;   (259, 129)  内角（100+160-1, 60+70-1），应当是底色 1F
;   (260, 130)  外角，应当在窗口外面，也就是背景色 00
;
; 两个点一起才问得出「尺寸从哪来」：只读内角的话，一个画成 200x90 的实现照样能过 ——
; 它盖住了内角。外角才是这一格的判据。
run_prog_size_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14

    mov rsi, line_progsize
    call puts64

    xor dl, dl
    call clear_screen

    ; 位置 (100, 60)、尺寸 160x70、选择子归零（画 O）
    mov qword [global_kinds + 10 * 8], 1
    mov rax, 0x4059000000000000      ; 100.0
    mov [global_vals + 10 * 8], rax
    mov qword [global_kinds + 11 * 8], 1
    mov rax, 0x404E000000000000      ; 60.0
    mov [global_vals + 11 * 8], rax
    mov qword [global_kinds + 7 * 8], 1
    mov rax, 0x4064000000000000      ; 160.0
    mov [global_vals + 7 * 8], rax
    mov qword [global_kinds + 8 * 8], 1
    mov rax, 0x4051800000000000      ; 70.0
    mov [global_vals + 8 * 8], rax
    mov qword [global_kinds + 9 * 8], 1
    mov qword [global_vals + 9 * 8], 0
    mov rdi, name_redraw
    mov r8, 6
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    mov rdi, 259
    mov rsi, 129
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 260
    mov rsi, 130
    call read_pixel
    call put_hex64
    mov qword [pkg_base], 0x70000
    jmp put_nl64
.reset_and_run:
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    jmp exec
.missing:
    mov rsi, line_progsize_bad
    call puts64
    ret

; ======================================================================
; 全局区扩到三十二格
; ======================================================================
;
; 十六格的时候这一层够用；而「两个窗口」要两组位置加两组尺寸，立刻见底。这一格把两张表各
; 扩到三十二格，判据用编号 20 —— 它在旧的十六格之外、在新的三十二格之内。
;
; 判据只有一个读数 5，但它排除的东西比看起来多：若表还是十六格，编号 20 会落到 global_vals
; 里别的格子上（那是一组旧值），读数不会是 5，而是一个说不清来处的数。上一格验红时读到 1，
; 走的正是这条越界的路。
run_prog_high_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14

    mov rsi, line_proghigh
    call puts64

    ; 编号 20 写一个 5，再让包读回来
    mov qword [global_kinds + 20 * 8], 1
    mov rax, 0x4014000000000000      ; 5.0
    mov [global_vals + 20 * 8], rax
    mov rdi, name_highslot
    mov r8, 8
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000
    mov rax, r15
    mov rdx, r14
    call print_value
    jmp put_nl64
.missing:
    mov rsi, line_proghigh_bad
    call puts64
    ret

; ======================================================================
; 两个窗口
; ======================================================================
;
; 到这一格为止，屏幕上只可能有一个窗口。redraw 的位置在全局 10 与 11、尺寸在 7 与 8、
; 旧位置在 14 与 15、标志在 4 —— 它画得再完整，也只是「那一个」。这一格要两。
;
; 做法：包里加第三十二个函数 redraw2，它读另一组格子（位置 16 与 17、尺寸 18 与 19、
; 旧位置 24 与 25、标志 21），三层矩形的相对关系照旧交给 winat。所以两份窗口的差别只剩
; 「读哪一组格子」与「标题字母是几」。
;
; 判据读三点，而三点各占一个区，互不重叠 —— 这一点必须算清楚，因为挑错点的代价是
; 一条正确实现也过不了的判据：
;   (100, 60)   第一窗口的左上角。它在第二窗口的整个生命周期里都该是 1F —— 三个判据点里
;               只有它证明「第二个窗口没有伤到第一个」。
;   (20, 20)    第二窗口的旧左上角。挪走之后它应当回到背景色 00 —— 一个只画新位置、不擦
;               旧位置的实现会把 1F 留在那里。
;   (20, 100)   第二窗口的新左上角。挪完之后是 1F。
;
; 几何：第一窗口 (100,60) 起、200x90，占 x 100..299；第二窗口 (20,20) 起、60x50，占 x 20..79，
; 拉开二十列的间隔。所以第一窗口那一点既不在第二窗口的旧位置里，也不在它的新位置里 ——
; 把边界推成「刚好相邻」就说不清了，两个矩形相切时那一个像素归谁是实现细节。
;
; 验红那一次把 redraw2 擦旧指令里的宽高（读全局 18、19）换成第一窗口的尺寸（7、8），
; 于是第二窗口一挪，擦的范围变成 (20,20,200,90)，伸到 (100,60) 上。读数从
; 1F 00 1F 变成 00 00 1F —— 只翻第一点，而它翻的理由恰好是「尺寸必须是自己那一组」。
; 两次调用都是 exec，中间不重置屏幕，所以第三点的 1F 只可能是第二次调用画的。
run_prog_two_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14

    mov rsi, line_progtwo
    call puts64

    ; 一、清屏。之后的每一个非零像素都只能来自这两次调用
    xor dl, dl
    call clear_screen

    ; 二、第一窗口：位置 (100,60)、尺寸 200x90、标题选择子归零、标志清零。
    ;    标志必须自己写成 0 —— 同一趟前面的测试调过 redraw，已经把它置成过 1，
    ;    而那样第一次调用就会去擦一个与本测试无关的旧位置。
    mov qword [global_kinds + 10 * 8], 1
    mov rax, 0x4059000000000000      ; 100.0
    mov [global_vals + 10 * 8], rax
    mov qword [global_kinds + 11 * 8], 1
    mov rax, 0x404E000000000000      ; 60.0
    mov [global_vals + 11 * 8], rax
    mov qword [global_kinds + 7 * 8], 1
    mov rax, 0x4069000000000000      ; 200.0
    mov [global_vals + 7 * 8], rax
    mov qword [global_kinds + 8 * 8], 1
    mov rax, 0x4056800000000000      ; 90.0
    mov [global_vals + 8 * 8], rax
    mov qword [global_kinds + 9 * 8], 1
    mov qword [global_vals + 9 * 8], 0
    mov qword [global_kinds + 4 * 8], 1
    mov qword [global_vals + 4 * 8], 0
    mov rdi, name_redraw
    mov r8, 6
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    ; 三、第二窗口：位置 (20,20)、尺寸 60x50、标志清零。它落在第一窗口左边那一条空处，
    ;    两个矩形隔着二十列 —— 判据第一点因此不会被它碰到。
    mov qword [global_kinds + 16 * 8], 1
    mov rax, 0x4034000000000000      ; 20.0
    mov [global_vals + 16 * 8], rax
    mov qword [global_kinds + 17 * 8], 1
    mov rax, 0x4034000000000000      ; 20.0
    mov [global_vals + 17 * 8], rax
    mov qword [global_kinds + 18 * 8], 1
    mov rax, 0x404E000000000000      ; 60.0
    mov [global_vals + 18 * 8], rax
    mov qword [global_kinds + 19 * 8], 1
    mov rax, 0x4049000000000000      ; 50.0
    mov [global_vals + 19 * 8], rax
    mov qword [global_kinds + 21 * 8], 1
    mov qword [global_vals + 21 * 8], 0
    mov rdi, name_redraw2
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    ; 四、把第二窗口挪到 (20,100)：标志已是 1，所以它先擦 (20,20) 那一块，再画新的。
    mov qword [global_kinds + 17 * 8], 1
    mov rax, 0x4059000000000000      ; 100.0
    mov [global_vals + 17 * 8], rax
    mov rdi, name_redraw2
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    ; 五、三点：第一个没被伤、旧的擦干净了、新的画出来了
    mov rdi, 100
    mov rsi, 60
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 20
    mov rsi, 20
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 20
    mov rsi, 100
    call read_pixel
    call put_hex64
    mov qword [pkg_base], 0x70000
    jmp put_nl64
.reset_and_run:
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    jmp exec
.missing:
    mov rsi, line_progtwo_bad
    call puts64
    ret

; ======================================================================
; 窗口跟着按键走
; ======================================================================
;
; 前面每一格挪窗口，都是测试自己改全局 10/11 或 16/17 —— 窗口没有动过，是别人替它动了。
; 这一格不同：挪它的那一步来自一次真的按键。
;
; 路分三段：主机送扫描码（VBoxManage controlvm keyboardputscancode）→ 宿主读 8042 的
; 0x60、把方向键的第二个字节写进全局 22 → 包里的 keymove 判「这是右键」、把全局 16 加
; 八、再调 redraw2 重画。策略在包里，键码在全局，宿主只管读 —— 这条分工与「输入是宿主口、
; 渲染与策略归包」是同一条。
;
; 握手两次。串口只能往外说，所以「现在轮到按键了」必须由客人机自己报出来：先打
; move ready，主机看到才送第一个右方向键；挪完打 move again，主机再送一个。靠时间猜的
; 话，送早了键还在缓冲里、送晚了这个测试已经超时，而两种坏法在串口上都只表现为
; 「progmove 后面没有数」。
;
; 判据三点：
;   (90, 20)    窗口右边界内侧。它只在「位置真的到了 36」时才亮 —— 窗口宽六十，起点
;               20 时右边界 79、28 时 87，两者都盖不到九十。第一版这点读的是 (36,20)，
;               而那个点分不开「没挪」与「只挪一次」：窗口只要到过 28，36 就落在它里面。
;               验红那一次读数 1F 1F 1F，三种坏法共用一个读数，等于没问。
;   (28, 20)    第一次的位置。第二次调用该把它擦成背景色
;   (100, 60)   第一窗口的左上角。从头到尾没有人碰过它
;
; 三点合起来把三种情况分开：没挪与只挪一次都会让第一点读 00，而对了的那一趟是 1F。
run_prog_move_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14

    mov rsi, line_progmove
    call puts64

    ; 一、清屏，画第一窗口 (100,60) 200x90。标志清零，所以第一次不擦别人的像素。
    xor dl, dl
    call clear_screen
    mov qword [global_kinds + 10 * 8], 1
    mov rax, 0x4059000000000000      ; 100.0
    mov [global_vals + 10 * 8], rax
    mov qword [global_kinds + 11 * 8], 1
    mov rax, 0x404E000000000000      ; 60.0
    mov [global_vals + 11 * 8], rax
    mov qword [global_kinds + 7 * 8], 1
    mov rax, 0x4069000000000000      ; 200.0
    mov [global_vals + 7 * 8], rax
    mov qword [global_kinds + 8 * 8], 1
    mov rax, 0x4056800000000000      ; 90.0
    mov [global_vals + 8 * 8], rax
    mov qword [global_kinds + 9 * 8], 1
    mov qword [global_vals + 9 * 8], 0
    mov qword [global_kinds + 4 * 8], 1
    mov qword [global_vals + 4 * 8], 0
    mov rdi, name_redraw
    mov r8, 6
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    ; 二、第二窗口 (20,20) 60x50。它是接下来要被挪的那一个。
    mov qword [global_kinds + 16 * 8], 1
    mov rax, 0x4034000000000000      ; 20.0
    mov [global_vals + 16 * 8], rax
    mov qword [global_kinds + 17 * 8], 1
    mov rax, 0x4034000000000000      ; 20.0
    mov [global_vals + 17 * 8], rax
    mov qword [global_kinds + 18 * 8], 1
    mov rax, 0x404E000000000000      ; 60.0
    mov [global_vals + 18 * 8], rax
    mov qword [global_kinds + 19 * 8], 1
    mov rax, 0x4049000000000000      ; 50.0
    mov [global_vals + 19 * 8], rax
    mov qword [global_kinds + 21 * 8], 1
    mov qword [global_vals + 21 * 8], 0
    mov rdi, name_redraw2
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    ; 三、第一次握手与第一次按键
    mov rsi, line_move_ready
    call puts64
    call wait_arrow
    call .send_key

    ; 四、第二次握手与第二次按键
    mov rsi, line_move_again
    call puts64
    call wait_arrow
    call .send_key

    ; 五、三点
    mov rdi, 90
    mov rsi, 20
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 28
    mov rsi, 20
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 100
    mov rsi, 60
    call read_pixel
    call put_hex64
    mov qword [pkg_base], 0x70000
    jmp put_nl64
; 把等到的那个键码写进全局 22，再让包里的 keymove 去决定怎么动。
; 键码用 cvtsi2sd 转成双精度：全局存的是 double，一个整数放进去必须按同一个格式写，
; 否则读回来的是一位一位拼出来的、说不清来处的东西。
.send_key:
    mov r15, rax
    cvtsi2sd xmm0, r15
    movq rax, xmm0
    mov qword [global_kinds + 22 * 8], 1
    mov [global_vals + 22 * 8], rax
    mov rdi, name_keymove
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run
    ret
.reset_and_run:
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    jmp exec
.missing:
    mov rsi, line_progmove_bad
    call puts64
    ret

; ======================================================================
; 事件行：一次按键成为一行带源与目标的记录
; ======================================================================
;
; 这是「复数控制器」那一批设计的第一块砖，而它取的是最小的一块：不碰第二个源、不碰绑定、
; 不碰授权，只把「一次按键成为一行事件」这条形状做出来。
;
; 形状取自 design/INPUT.txt 第四节，四个字段：
;   src      那个控制器属于哪一路输入源（全局 26）
;   kind     按下、放开、移动、滚轮之一；这一格只有按下，所以写死成 key
;   payload  键码；这一格是方向键的第二个字节
;   target   那个源当前焦点所指的窗口（全局 27）
;
; 源与目标从全局来，而这一格只打一行事件。它要证明的正是「那两个字段不是宿主写死的那两个
; 常数」：判据读 src=1 与 target=2，而这两个数是这一格刚写进全局的 —— 换成 3 与 4，判据
; 就红（验红那一次改成 3）。
;
; 为什么源与目标放全局而不是当参数：事件行是宿主自己打的，它不经过包，也就不存在「包的
; 参数槽」这一说。而更实在的理由是它们本来就是状态 —— 焦点是状态，源也是。
;
; 这一格没有判据去验「同一个键不会变成两行」：那是按键去抖该管的事，而这一层还没有它。

; ----------------------------------------------------------------------
; 三个例程：登记、发射、仲裁
; ----------------------------------------------------------------------
;
; 上一格把「一次按键成为一行事件」写在一处。这一格把它拆成两件事 —— 发射一行，与决定
; 要不要发射。拆的理由是判据：一个「打了拒绝行却照样把事件放过去」的实现，在只有发射
; 的时候完全看不出来，因为它打的那一行每个字段都对。
;
; 顺序照依赖写：先有清单，才有查清单的人，才有查完之后的一放一挡。

; 登记一个源。输入 rdi = 源 id，填第一个空位。
;
; 表满的时候什么都不做。一个真实的登记在填不进去时要报出来，而这一格只登记一个源、
; 表有四个位置，「满了」是这一格里唯一没有人读的分支 —— 让它先空着，等第二个源。
register_source:
    xor rcx, rcx
.scan:
    cmp rcx, 4
    jae .full
    cmp qword [src_registry + rcx * 8], 0
    je .put
    inc rcx
    jmp .scan
.put:
    mov [src_registry + rcx * 8], rdi
.full:
    ret

; 把一个源绑到一个操作员。输入 rdi = 源 id，rsi = 操作员 id。
;
; 两张表同下标：第 i 格的源，它的主人写在第 i 格。分开放是因为它们回答两个不同的问题 ——
; 登记回答「这个源存在吗」，绑定回答「它属于谁」。合成一张表也跑得动，但那样「登记过」与
; 「有主人」就再也分不开了，而这一格的判据问的正是这两件事之间的那个差。
;
; 找不到那个源就什么都不做：绑定一个不存在的源，在真实系统里要报出来，而这一格只在一个
; 登记过的源上绑，那个分支先空着。
bind_source:
    xor rcx, rcx
.scan:
    cmp rcx, 4
    jae .none
    cmp qword [src_registry + rcx * 8], rdi
    je .put
    inc rcx
    jmp .scan
.put:
    mov [src_bind + rcx * 8], rsi
.none:
    ret

; 打一行事件。输入 r15 = 负载，源与目标从全局 26 / 27 读。
;
; 它只管形状，不管该不该打 —— 判断在 arbitrate 里。这六条指令是上一格原样搬来的，
; 一个字节没改，所以上一格那条判据仍然指着同一段代码。
emit_event:
    mov rsi, line_event_head
    call puts64
    mov rax, [global_vals + 26 * 8]
    call f64_to_int
    call put_num64
    mov rsi, line_event_kind
    call puts64
    mov rax, r15
    call put_hex64
    mov rsi, line_event_target
    call puts64
    mov rax, [global_vals + 27 * 8]
    call f64_to_int
    call put_num64
    jmp put_nl64

; 仲裁一次按键。输入 r15 = 负载：源在清单里、而且绑在某个操作员上，才发射。
;
; 三种待遇在这里第一次分开，而分开的次序是这一条真正的判断：先问「这个源存在吗」，再问
; 「它属于谁」。次序不能颠倒 —— 一个没有 id 的源连查绑定表的下标都没有，而「说不出你是谁」
; 比「说不出你属于谁」更原始。反过来做的话，一个没登记的源会先撞上绑定表的一个空位、报出
; 「未绑定」，于是查错的人会去翻绑定表，而问题在登记表里。
;
; 理由做成字段（rejected=...）而不是散文，这一格兑现了上一格留下的那句话：两种拒绝的差别
; 只在这里分岔 —— 各给 r11 装一个字符串地址，拒绝行本身的形状一个字没动。加第三种拒绝
; 就是再加一个标签，而那正是一个理由字段值钱的地方。
;
; 查表是线性的四格，不建哈希：四格的表用哈希，只是把「查什么」藏进一个函数里。
arbitrate:
    mov rax, [global_vals + 26 * 8]
    call f64_to_int
    mov r14, rax
    xor rcx, rcx
.scan:
    cmp rcx, 4
    jae .unregistered
    cmp qword [src_registry + rcx * 8], r14
    je .found
    inc rcx
    jmp .scan
.found:
    ; 找到这一格，接着问它有没有主人。绑定的操作员 id 写在同一个下标上，0 是空位。
    cmp qword [src_bind + rcx * 8], 0
    je .unbound
    jmp emit_event
.unbound:
    mov r11, line_input_unbound
    jmp .reject
.unregistered:
    mov r11, line_input_unregistered
.reject:
    mov rsi, line_input_head
    call puts64
    mov rax, r14
    call put_num64
    mov rsi, line_input_reason
    call puts64
    mov rsi, r11
    jmp puts64

run_event_line_test:
    ; 一、两个全局：源 1、焦点窗口 2。全局存的是双精度，所以按双精度写。
    mov qword [global_kinds + 26 * 8], 1
    mov rax, 0x3FF0000000000000      ; 1.0
    mov [global_vals + 26 * 8], rax
    mov qword [global_kinds + 27 * 8], 1
    mov rax, 0x4000000000000000      ; 2.0
    mov [global_vals + 27 * 8], rax

    ; 二、握手。串口只能往外说，所以「现在轮到按键了」必须由客人机自己报 —— 与移窗那一格
    ;    同一个理由：靠时间猜的话，送早了键还在缓冲里、送晚了这一格已经超时。
    mov rsi, line_event_ready
    call puts64

    ; 三、等一个方向键。等不到时 wait_arrow 交回 0，于是 payload 会是零，判据红。
    call wait_arrow
    mov r15, rax

    ; 四、一行事件。源与目标各自从全局读回来，所以这一行证明那两个字段有来处。
    ;    这一段本身抽成了 emit_event —— 下一个测试要在同一个「发射」上再套一层仲裁，
    ;    两处各写一遍的话，仲裁那一条红起来就有一半的理由落在「发射」上。
    jmp emit_event

; ======================================================================
; 未登记被拒：一个没有名字的源送来的一次按键被挡下
; ======================================================================
;
; 判据取自 design/INPUT.txt 第十二节第二条：把一个没有名字的源 id 送进仲裁，事件被挡下，
; 而串口上留一行拒绝。
;
; 这一条最容易被一个「打了一行拒绝、但仍然把事件放过去」的实现骗过 —— 那种实现打的那一行
; 完全正确，只有把整份串口读一遍、确认没有 event src=2 才分得开。所以这一格的两次按键送
; 的是同一个键，只差源 id 一格：源 1 那一行进事件行，源 2 那一行只留拒绝。两次负载相同
; 这件事有用 —— 它让「同一个东西，两种待遇」在串口上直接看得见。
;
; 清表那四行不是客套：上一格没有这张表，所以这一格的起点必须是一张确定的空表。不清的话，
; 「源 1 放行」也可能只是上一次运行留在内存里的东西 —— 而那看起来与真登记完全一样。
;
; 下一格把「登记」与「有主人」分成两张表，于是这一格的源 1 也得先有主人才放行 —— 那个变化
; 不在这一格的代码里，在它依赖的前提里。它当场红了：reject ready 之后那一行变成
; input src=1 rejected=unbound。一条判据依赖的前提一变就自己说出来，这正是「判在链上」
; 该有的样子 —— 而没有判据的话，这次改动会在没人注意的地方把「放行」变成「拒绝」。
run_event_reject_test:
    ; 一、空表。绑定表也要清 —— 这一格做完之后，「登记」与「有主人」是两件事，而这一格
    ;    要的源 1 是既有名字又有主人的那一种。不绑它的话，它会被下面的仲裁挡下，而那个红
    ;    会长在「登记过的源照旧放行」这一条上，读起来像登记表坏了。
    mov qword [src_registry + 0 * 8], 0
    mov qword [src_registry + 1 * 8], 0
    mov qword [src_registry + 2 * 8], 0
    mov qword [src_registry + 3 * 8], 0
    mov qword [src_bind + 0 * 8], 0
    mov qword [src_bind + 1 * 8], 0
    mov qword [src_bind + 2 * 8], 0
    mov qword [src_bind + 3 * 8], 0

    ; 二、只登记 1 号源，并把它绑给操作员 1。2 号故意两样都没有 —— 它就是下一半的被拒者。
    mov rdi, 1
    call register_source
    mov rdi, 1
    mov rsi, 1
    call bind_source

    ; 三、源 1、焦点窗口 2，与上一格同一组全局。这一次走仲裁，所以它同时也验了
    ;    「登记过的源照旧放行」—— 少了这一半，一个永远拒绝的实现也能过。
    mov qword [global_kinds + 26 * 8], 1
    mov rax, 0x3FF0000000000000      ; 1.0
    mov [global_vals + 26 * 8], rax
    mov qword [global_kinds + 27 * 8], 1
    mov rax, 0x4000000000000000      ; 2.0
    mov [global_vals + 27 * 8], rax

    mov rsi, line_reject_ready
    call puts64
    call wait_arrow
    mov r15, rax
    call arbitrate

    ; 四、同一个键，源换成 2。它不在清单里，所以这一次该被挡下。
    mov qword [global_kinds + 26 * 8], 1
    mov rax, 0x4000000000000000      ; 2.0
    mov [global_vals + 26 * 8], rax

    mov rsi, line_reject_again
    call puts64
    call wait_arrow
    mov r15, rax
    jmp arbitrate

; ======================================================================
; 未绑定被拒：一个说得出名字、却说不出主人是谁的源
; ======================================================================
;
; 判据取自 design/INPUT.txt 第十二节第三条：拒绝行说的是「未绑定」，而它与「未登记」那一行
; 不是同一行。两种拒绝的修法不同 —— 一种是材料里缺了一项（去补绑定），一种是这个源根本
; 不该在这里（去问它是谁放进来的）—— 而串口上分不开就等于没分。
;
; 这一格用同一个源 id 做两次拒绝：上一格那次源 2 没登记，这一次源 2 登记了却没有主人。
; 同一个身份、两种状态、两行字只差理由那一格 —— 这比换一个源结实得多，因为它把「谁被拒」
; 那一格固定住了，剩下能变的只有理由。
;
; 次序也在这里被钉住：先问存在，再问主人。反过来做的话，一个没登记的源会先撞上绑定表的
; 空位、报出「未绑定」，于是查错的人会去翻登记表，而问题在绑定表里。
run_event_unbound_test:
    ; 一、两张表都清空。绑定表上一格还没有，清它不只是整洁 —— 不清的话源 1 可能带着上一次
    ;    运行留下的主人，而那种「有主人」与被真的绑过一模一样。
    mov qword [src_registry + 0 * 8], 0
    mov qword [src_registry + 1 * 8], 0
    mov qword [src_registry + 2 * 8], 0
    mov qword [src_registry + 3 * 8], 0
    mov qword [src_bind + 0 * 8], 0
    mov qword [src_bind + 1 * 8], 0
    mov qword [src_bind + 2 * 8], 0
    mov qword [src_bind + 3 * 8], 0

    ; 二、登记 1 与 2 两个源，只把 1 号绑给操作员 1。2 号是这一格的主角：有名字，没有主人。
    mov rdi, 1
    call register_source
    mov rdi, 2
    call register_source
    mov rdi, 1
    mov rsi, 1
    call bind_source

    ; 三、源 2 送一次按键 —— 它登记过，所以不该报「未登记」；它没有主人，所以该报「未绑定」。
    mov qword [global_kinds + 26 * 8], 1
    mov rax, 0x4000000000000000      ; 2.0
    mov [global_vals + 26 * 8], rax

    mov rsi, line_unbound_ready
    call puts64
    call wait_arrow
    mov r15, rax
    jmp arbitrate

; ======================================================================
; 工程失活：主体不被信任，于是它驱动的行为全部无效
; ======================================================================
;
; 判据取自 design/INPUT.txt 第十二节第四条：一个签名不在清单里的工程请求创建控制器，整个
; 工程失活、串口上留一行；而同一份请求在签名进了清单之后被接受 —— 两条都要验，只验前一条
; 的话，一个「永远拒绝」的实现也能过。
;
; 这一格与前几格不是同一类东西。前三格判的是一次事件，这一格判的是一个主体的状态，而状态
; 与判决的差在这里可测：一个逐次查清单的实现在第二次请求上会再报一次「不在清单里」，正确
; 的实现在第二次报的是「失活」—— 两行字不同，而那不是措辞的差别，是两种实现的差别。
;
; 三态（0 空位 · 1 失活 · 2 信任）要第三态，正因为「没见过」与「见过而失活」必须分开：
; 合成两态的话，第一次与第二次请求会给出同一行读数，而这一格的判据问的就是它们的不同。

; 找一条工程记录。输入 rdi = 工程 id，输出 rax = 下标，找不到是 -1。
find_project:
    xor rcx, rcx
.scan:
    cmp rcx, 4
    jae .none
    cmp qword [proj_id + rcx * 8], rdi
    je .found
    inc rcx
    jmp .scan
.found:
    mov rax, rcx
    ret
.none:
    mov rax, -1
    ret

; 建一条工程记录，状态 0。输入 rdi = 工程 id，输出 rax = 新下标，表满时 -1。
;
; 表满与寄存器满了都返回 -1 而不是悄悄丢掉：一个建不出来的记录若被当成「建好了」，
; 接下来那次查询会读出空位，而空位在这个状态机里的含义是「失活」—— 结果是拒绝，
; 但拒绝的理由是错的，而那比拒绝本身更难查。
new_project:
    xor rcx, rcx
.scan:
    cmp rcx, 4
    jae .none
    cmp qword [proj_id + rcx * 8], 0
    je .put
    inc rcx
    jmp .scan
.put:
    mov [proj_id + rcx * 8], rdi
    mov qword [proj_state + rcx * 8], 0
    mov rax, rcx
    ret
.none:
    mov rax, -1
    ret

; 打一行工程判决。输入 r14 = 工程 id，r11 = 状态字符串（自带换行）。
emit_project:
    mov rsi, line_proj_head
    call puts64
    mov rax, r14
    call put_num64
    mov rsi, line_proj_what
    call puts64
    mov rsi, r11
    jmp puts64

; 一个工程请求创建控制器。输入 rdi = 工程 id，四种结局在串口上各是一行。
;
; 它建记录、改状态，所以调用者不要指望 rdi / rax 还能用 —— 而这一格只有测试在调它。
request_controller:
    mov r14, rdi
    call find_project
    cmp rax, -1
    jne .have
    call new_project
    cmp rax, -1
    je .full
.have:
    mov rcx, rax
    mov rax, [proj_state + rcx * 8]
    cmp rax, 2
    je .accepted
    cmp rax, 1
    je .inactive
    ; 状态 0：第一次撞门。它从「没见过」变成「失活」—— 一次不合格的尝试让主体进入这个
    ; 状态，之后它的每一次请求都从状态出发，不再回头去查清单。这就是「判定落在主体启用
    ; 的时候，不落在每一次行为上」落到指令上的样子。
    mov qword [proj_state + rcx * 8], 1
    mov r11, line_proj_untrusted
    jmp emit_project
.inactive:
    mov r11, line_proj_inactive
    jmp emit_project
.accepted:
    ; 接受要有一个可读的后果：控制器真的建出来。用工程 id 加十来编号，所以串口上那一格
    ; 说的是「哪个控制器」，而不只是「接受了」。
    mov rdi, r14
    add rdi, 10
    call register_source
    mov rsi, line_proj_head
    call puts64
    mov rax, r14
    call put_num64
    mov rsi, line_proj_what
    call puts64
    mov rsi, line_proj_accepted
    call puts64
    mov rax, r14
    add rax, 10
    call put_num64
    jmp put_nl64
.full:
    ret

; 把一个工程写进信任清单。输入 rdi = 工程 id，没有记录就建一条。
;
; 它只改状态，不碰控制器：撤销要沿着链往下走（工程、操作员、控制器），而这一格只做最上面
; 那一环 —— 下面的传递要等控制器真的带着工程 id，而那还没有。
trust_project:
    mov r14, rdi
    call find_project
    cmp rax, -1
    jne .have
    call new_project
    cmp rax, -1
    je .done
.have:
    mov qword [proj_state + rax * 8], 2
.done:
    mov r11, line_proj_trusted
    jmp emit_project

; ----------------------------------------------------------------------
; 伪装：两个同名工程，只有签名在清单里
; ----------------------------------------------------------------------
;
; 判据取自 design/INPUT.txt 第十二节第五条：两个工程同名、同声明的能力，只有一个的签名
; 在清单里。两者各请求创建一个控制器，一个成功、一个失活，而串口上那两行不同。
;
; 这一条的力气在于「名字上完全不可分，只在签名上可分」—— 所以它的验红方式与前面几格不同：
; 把查找从签名改成名字，判据必须红。一个按名字判断的实现在前面每一格都能通过，因为那些格
; 里名字与签名没有人故意撞在一起。
;
; 三行，因为它是一次对照而不是一个状态：被信任的那一行也在里面，否则读的人看不出「名字 1
; 只属于签名 7」这件事 —— 而那是剩下两行唯一能比较的基准。

; 按签名信任一个工程，并记下它的名字。输入 rdi = 签名，rsi = 名字。
;
; 与 trust_project 的差只有「顺手记名字」这一列：状态机完全相同。这一列能记下来，
; 却不能当主键 —— 而这一格要的正是这个区别。
trust_named:
    mov r14, rdi
    mov r13, rsi
    call find_project
    cmp rax, -1
    jne .have
    call new_project
    cmp rax, -1
    je .done
    mov rcx, rax
    mov [proj_name + rcx * 8], r13
.have:
    mov qword [proj_state + rax * 8], 2
.done:
    mov r11, line_proj_trusted
    jmp emit_disguise

; 打一行伪装判决。输入 r14 = 签名，r13 = 名字，r11 = 状态串。
emit_disguise:
    mov rsi, line_disguise_head
    call puts64
    mov rax, r14
    call put_num64
    mov rsi, line_disguise_name
    call puts64
    mov rax, r13
    call put_num64
    mov rsi, line_disguise_what
    call puts64
    mov rsi, r11
    jmp puts64

; 按签名请求创建控制器，并把名字一起记下来。输入 rdi = 签名，rsi = 名字。
;
; 状态判断与 request_controller 逐条相同 —— 它多出来的只有「记名字」与「打名字」。
; 两份请求例程并存而不合并，是因为合并要一个「要不要打名字」的开关，而一个为了两处
; 输出差异而存在的开关，比两份各二十条指令更难读。
request_disguise:
    mov r14, rdi
    mov r13, rsi
    call find_project
    cmp rax, -1
    jne .have
    call new_project
    cmp rax, -1
    je .full
    mov rcx, rax
    mov [proj_name + rcx * 8], r13
.have:
    mov rcx, rax
    mov rax, [proj_state + rcx * 8]
    cmp rax, 2
    je .accepted
    cmp rax, 1
    je .inactive
    mov qword [proj_state + rcx * 8], 1
    mov r11, line_proj_untrusted
    jmp emit_disguise
.inactive:
    mov r11, line_proj_inactive
    jmp emit_disguise
.accepted:
    ; 接受仍然有可读的后果：控制器登记成「签名加十」，所以这一行带 src=17。
    mov rdi, r14
    add rdi, 10
    call register_source
    mov rsi, line_disguise_head
    call puts64
    mov rax, r14
    call put_num64
    mov rsi, line_disguise_name
    call puts64
    mov rax, r13
    call put_num64
    mov rsi, line_disguise_what
    call puts64
    mov rsi, line_proj_accepted
    call puts64
    mov rax, r14
    add rax, 10
    call put_num64
    jmp put_nl64
.full:
    ret

; ======================================================================
; 工程失活：四条判决，同一个工程
; ======================================================================
;
; 四行读数是一条序列，而判据把它们当一条序列来读：没名字、失活、被信任、接受。分开成四个
; 独立的正则也能过，但那样一个「每次都报 untrusted」的实现会在第一行与第三行以外全对，
; 而任何一行单看都像个正常答案。
run_project_test:
    ; 一、两张表清空。
    mov qword [proj_id + 0 * 8], 0
    mov qword [proj_id + 1 * 8], 0
    mov qword [proj_id + 2 * 8], 0
    mov qword [proj_id + 3 * 8], 0
    mov qword [proj_state + 0 * 8], 0
    mov qword [proj_state + 1 * 8], 0
    mov qword [proj_state + 2 * 8], 0
    mov qword [proj_state + 3 * 8], 0

    ; 二、工程 3 第一次请求 —— 从没出现过，所以报不在清单里，并被置为失活。
    mov rdi, 3
    call request_controller

    ; 三、同一个工程再请求 —— 这一次该报失活，因为上一行把它写成了失活。若实现是逐次
    ;    查清单的，这里会再报一次 untrusted，而那一行与上一行完全一样。
    mov rdi, 3
    call request_controller

    ; 四、把 3 写进信任清单。
    mov rdi, 3
    call trust_project

    ; 五、同一份请求 —— 这一次该被接受，并且真的建出一个控制器（编号 13）。
    mov rdi, 3
    jmp request_controller

; ======================================================================
; 伪装可被识破：同名不算数，签名才算
; ======================================================================
;
; 三行读数成对看：名字 1 属于签名 7（第一行），所以它请求时被接受（第二行）；而签名 8
; 也报名字 1 的时候，它不在清单里，于是被挡下（第三行）。第一行是基准 —— 少了它，
; 剩下两行看不出「名字 1 只属于 7」。
run_disguise_test:
    ; 一、三张表清空。名字列也要清 —— 不清的话「同名」可能是上一格留下的痕迹。
    mov qword [proj_id + 0 * 8], 0
    mov qword [proj_id + 1 * 8], 0
    mov qword [proj_id + 2 * 8], 0
    mov qword [proj_id + 3 * 8], 0
    mov qword [proj_state + 0 * 8], 0
    mov qword [proj_state + 1 * 8], 0
    mov qword [proj_state + 2 * 8], 0
    mov qword [proj_state + 3 * 8], 0
    mov qword [proj_name + 0 * 8], 0
    mov qword [proj_name + 1 * 8], 0
    mov qword [proj_name + 2 * 8], 0
    mov qword [proj_name + 3 * 8], 0

    ; 二、签名 7 进清单，名字记 1。
    mov rdi, 7
    mov rsi, 1
    call trust_named

    ; 三、签名 7 请求 —— 它在清单里，该被接受，控制器编号 17。
    mov rdi, 7
    mov rsi, 1
    call request_disguise

    ; 四、签名 8、同一个名字 1 —— 名字一样而签名不一样，该被挡下。一个按名字判断的
    ;    实现会在这里把它放过去，而那正是这一条要抓的东西。
    mov rdi, 8
    mov rsi, 1
    jmp request_disguise

; ======================================================================
; 注册是全有或全无：两道缺项，同一行字
; ======================================================================
;
; 判据取自 design/INPUT.txt 第十二节第六条：一份完整的注册材料成功；同一份删掉任意一项就
; 失败，而失败那一行与「缺了哪一项」无关 —— 两种不同的缺项必须给出同一行字。
;
; 这一条测的不是「会不会拒绝」，是「拒绝说不说得清」。一个把缺项写进那行的实现完全能拒绝，
; 而它会送出一个可以逐项收敛的信号：试错的人改一位、看行变不变，几十次之后就凑齐了。
; 所以判据要比较的是那两行**是否逐字节相同**，不是「两行都以 denied 开头」。
;
; 材料在这里是三个位：源、操作员、签名。只有 7 算完整 —— 多出来的位也不合格，
; 因为一份材料不该带着它没声明的字段，那与缺项是同一个问题的另一面。
register_material:
    ; 输入 rdi = 材料。输出一行。
    mov r14, rdi
    cmp rdi, 7
    jne .denied
    ; 完整：真的登记一个源（编号 21），然后说成功。
    mov rdi, 21
    call register_source
    mov rsi, line_register_ok
    jmp puts64
.denied:
    ; 两道不同的缺项都落在这里，而这里只有一句字 —— 这正是这一条要的形状。
    mov rsi, line_register_denied
    jmp puts64

; ======================================================================
; 注册：一份完整的、两份各缺一项的
; ======================================================================
;
; 三行读数：ok、denied、denied。判据要的是后两行相等 —— 而它们相等这件事，
; 只有把整行读下来才看得见。
run_register_test:
    ; 一、清登记表，让 ok 那一次真的登记得进去（表满时 register_source 会静默丢掉）。
    mov qword [src_registry + 0 * 8], 0
    mov qword [src_registry + 1 * 8], 0
    mov qword [src_registry + 2 * 8], 0
    mov qword [src_registry + 3 * 8], 0

    ; 二、完整材料。
    mov rdi, 7
    call register_material

    ; 三、缺签名位（0b011）。
    mov rdi, 3
    call register_material

    ; 四、缺源位（0b110）—— 缺的是另一项，而那一行必须与上一条逐字节相同。
    mov rdi, 6
    jmp register_material

; ======================================================================
; 失败不留状态、也不锁定：两次失败之后，完整材料仍然成功
; ======================================================================
;
; 判据取自 design/INPUT.txt 第十二节第七条：连着若干次失败的尝试之后，一份正确的材料仍然
; 成功；而一次「差一点就对」的尝试不会让下一次变短。两样合起来才是「不锁定」那个取舍的
; 可测形式 —— 少了任何一样，一个把状态留在某处、或者试几次就锁死的实现也能过。
;
; 第二半（不让下一次变短）比第一半难测，因为「变短」在串口上不显形。它的可测形式在这里：
; 第一次给「缺签名位」的材料，第二次只给签名位 —— 一个记住了「前两位已经对了」的实现会
; 让第二次成功，而一个每次从头比 7 的实现会拒绝它。所以第二行必须是 denied。
;
; 这一格读三行，而它们必须按这个顺序：denied、denied、ok。第三行是「不锁定」，第二行是
; 「不留状态」，缺一条，判据就只测了一半。
nolock_material:
    ; 输入 rdi = 材料。它不读任何上一次的状态 —— 这一格要测的正是这一点。
    mov r14, rdi
    cmp rdi, 7
    jne .denied
    mov rdi, 22
    call register_source
    mov rsi, line_nolock_ok
    jmp puts64
.denied:
    mov rsi, line_nolock_denied
    jmp puts64

; ======================================================================
; 不锁定：缺一位、只给那一位、再给完整的一份
; ======================================================================
run_nolock_test:
    ; 一、清登记表。
    mov qword [src_registry + 0 * 8], 0
    mov qword [src_registry + 1 * 8], 0
    mov qword [src_registry + 2 * 8], 0
    mov qword [src_registry + 3 * 8], 0

    ; 二、缺签名位，失败。
    mov rdi, 3
    call nolock_material

    ; 三、只给签名位。一个记住了上一次的实现在这里会成功 —— 而那正是漏洞。
    mov rdi, 4
    call nolock_material

    ; 四、完整的一份。连着两次失败之后它仍然成功：不锁定的那一半。
    mov rdi, 7
    jmp nolock_material

; ======================================================================
; 信箱：运行时的第二条输入路
; ======================================================================
;
; 这一格不是「又有一个测试」，是第二条运行时输入路第一次真的存在。在此之前只有一条
; （8042 键盘），而 design/INPUT.txt 第十二节明说过：把同一路注入改个名字当第二源，
;; 比没有第二源更坏 —— 它会给出一个绿，理由是名字不同。
;
; 这里两条路真的不同：一条来自 8042 的输出缓冲，一条来自第二块 IDE 盘的第一个扇区。
; 而它们在汇合处只差一样东西 —— 源 id 那一格。这正是第八条判据（同级）要的形状，
; 而这一格只立它自己的那一半：信箱送来的键，走的是与键盘同一个仲裁。
run_mbox_live_test:
    ; 一、清两张表，登记 5、绑 5。源 5 是信箱这一路的约定编号（键盘是 1）。
    mov qword [src_registry + 0 * 8], 0
    mov qword [src_registry + 1 * 8], 0
    mov qword [src_registry + 2 * 8], 0
    mov qword [src_registry + 3 * 8], 0
    mov qword [src_bind + 0 * 8], 0
    mov qword [src_bind + 1 * 8], 0
    mov qword [src_bind + 2 * 8], 0
    mov qword [src_bind + 3 * 8], 0
    mov rdi, 5
    call register_source
    mov rdi, 5
    mov rsi, 1
    call bind_source

    ; 二、焦点窗口 2。
    mov qword [global_kinds + 27 * 8], 1
    mov rax, 0x4000000000000000      ; 2.0
    mov [global_vals + 27 * 8], rax

    ; 三、握手：宿主看到这一行，就把信箱盘上的序列号加一。
    mov rsi, line_mbox_ready
    call puts64

    ; 四、等一次输入。这一趟没有人按键 —— 所以拿到的那个必然是从盘上来的，
    ;    而它走的是与键盘同一个 wait_arrow 与同一个 arbitrate。
    call wait_arrow
    mov r15, rax
    jmp arbitrate

; ======================================================================
; 同级：同一个窗口被两条路各操作一次
; ======================================================================
;
; 判据取自 design/INPUT.txt 第十二节第八条：同一个窗口被真实键鼠与虚拟键鼠各操作一次，
; 两趟的读数完全相同，而事件行只在源 id 那一格不同。
;
; 前面那些格子各证了一半：信箱那一格证明「另一条路能送一个键」，工程与绑定那几格证明
; 「谁在送由源说话」。这一条问的是它们合起来的那句 —— 同一个动作从两条路来，结果一样吗。
;
; 两趟必须由两条不同的路送，而这件事不能靠「谁先等谁先得」：轮询在 4096 轮就发生，而
; 键盘要一百毫秒才到，于是第一趟几乎必然拿到信箱的键。所以队头是可安排的 —— 第一趟把
; 它摆到一个没有 YUNOMBX 的扇区（空转问不到东西，只能等键盘），第二趟摆回有消息的那一格。
; 安排时序、而不是碰运气，判据才有意义。
run_same_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14

    ; 一、清屏，第二窗口起点 (20,20) 60x50，标志清零（第一次不擦别人的像素）。
    xor dl, dl
    call clear_screen
    mov qword [global_kinds + 16 * 8], 1
    mov rax, 0x4034000000000000      ; 20.0
    mov [global_vals + 16 * 8], rax
    mov qword [global_kinds + 17 * 8], 1
    mov rax, 0x4034000000000000      ; 20.0
    mov [global_vals + 17 * 8], rax
    mov qword [global_kinds + 18 * 8], 1
    mov rax, 0x404E000000000000      ; 60.0
    mov [global_vals + 18 * 8], rax
    mov qword [global_kinds + 19 * 8], 1
    mov rax, 0x4049000000000000      ; 50.0
    mov [global_vals + 19 * 8], rax
    mov qword [global_kinds + 21 * 8], 1
    mov qword [global_vals + 21 * 8], 0
    mov rdi, name_redraw2
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    ; 二、两条路都登记并绑好同一个操作员 —— 「同级」说的是地位，绑定说的是身份，
    ;    所以两条路都要有身份，谁都不例外。
    mov qword [src_registry + 0 * 8], 0
    mov qword [src_registry + 1 * 8], 0
    mov qword [src_registry + 2 * 8], 0
    mov qword [src_registry + 3 * 8], 0
    mov qword [src_bind + 0 * 8], 0
    mov qword [src_bind + 1 * 8], 0
    mov qword [src_bind + 2 * 8], 0
    mov qword [src_bind + 3 * 8], 0
    mov rdi, 1
    call register_source
    mov rdi, 1
    mov rsi, 1
    call bind_source
    mov rdi, 5
    call register_source
    mov rdi, 5
    mov rsi, 1
    call bind_source

    ; 三、焦点窗口记成 3。这是一个别处不用的编号，于是判据能在整份串口里认出这两行
    ;    事件，而不用按位置去切 —— 按位置切的东西，加一行就会错位。
    mov qword [global_kinds + 27 * 8], 1
    mov rax, 0x4008000000000000      ; 3.0
    mov [global_vals + 27 * 8], rax

    ; 四、源先设成 1。键盘那一路不改源（它只管键），所以这一趟是谁，得由这里说。
    mov qword [global_kinds + 26 * 8], 1
    mov rax, 0x3FF0000000000000      ; 1.0
    mov [global_vals + 26 * 8], rax

    ; 五、旧帧位置也设成 (20,20)。redraw2 的「擦旧」用全局 24/25，而它们第一次是 0 ——
    ;    于是第一趟挪动时擦的是屏幕左上角，而 (20,20) 留着上一次的底色。移窗那一格
    ;    看不出来，因为它挪了两次；这一格只挪一次，那一片残留就把第一点读成 1F 了。
    mov qword [global_kinds + 24 * 8], 1
    mov rax, 0x4034000000000000      ; 20.0
    mov [global_vals + 24 * 8], rax
    mov qword [global_kinds + 25 * 8], 1
    mov rax, 0x4034000000000000      ; 20.0
    mov [global_vals + 25 * 8], rax

    ; 四、第一趟：队头摆到 63（那一格没有 YUNOMBX），所以这一趟只能等键盘。
    ;
    ; 这一处把预算临时加长：要等的是「宿主看到 same ready、起一个 VBoxManage、把键送进来」
    ; 整条往返。宿主每 150 毫秒读一次串口，而一次 VBoxManage 调用本身要起一个进程 ——
    ; 实测三乘十的九次方（三 GHz 上约一秒）不够用，所以这里给到十倍。等待一旦有键就
    ; 立刻返回，所以这个数大不拖慢成功的那一趟，只决定「放弃」要多久。
    mov rax, 4000000000
    mov [wait_budget], rax
    mov qword [mbox_head], 63
    mov rsi, line_same_ready
    call puts64
    call wait_arrow
    mov qword [wait_budget], wait_ticks
    mov r15, rax
    call arbitrate
    mov rax, r15
    call .send_key
    mov rsi, line_same_a
    call puts64
    call .three
    ; 诊断：两趟的读数差在第一点，而第一点的擦除用的是全局 24/25（上一帧位置）。
    ; 所以把四个格子照原样打出来 —— 猜「擦到哪儿去了」不如让它们自己说。
    mov rsi, line_same_g
    call puts64
    movsd xmm0, [global_vals + 24 * 8]
    call put_f64
    mov rsi, line_space
    call puts64
    movsd xmm0, [global_vals + 25 * 8]
    call put_f64
    mov rsi, line_space
    call puts64
    movsd xmm0, [global_vals + 16 * 8]
    call put_f64
    mov rsi, line_space
    call puts64
    movsd xmm0, [global_vals + 17 * 8]
    call put_f64
    call put_nl64

    ; 五、把窗口画回起点：第二趟要从同一个地方出发，否则「两趟读数相同」测的是两件
    ;    不同的事碰巧给出同一个数。
    mov qword [global_kinds + 16 * 8], 1
    mov rax, 0x4034000000000000      ; 20.0
    mov [global_vals + 16 * 8], rax
    mov qword [global_kinds + 17 * 8], 1
    mov rax, 0x4034000000000000      ; 20.0
    mov [global_vals + 17 * 8], rax
    mov rdi, name_redraw2
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run

    ; 六、第二趟：队头摆回有消息的那一格（第 5 个扇区），所以这一趟从盘上来。
    mov qword [mbox_head], 5
    mov rsi, line_same_again
    call puts64
    call wait_arrow
    mov r15, rax
    call arbitrate
    mov rax, r15
    call .send_key
    mov rsi, line_same_b
    call puts64
    call .three
    mov qword [pkg_base], 0x70000
    jmp put_nl64

; 三点：(20,20) 是窗口挪走之后该空的地方，(28,20) 是新左上角的底色，
; (40,20) 落在窗口里 —— 一个什么都不画的实现三点全空，过不了中间那两点。
.three:
    mov rdi, 20
    mov rsi, 20
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 28
    mov rsi, 20
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 40
    mov rsi, 20
    call read_pixel
    call put_hex64
    ret
; 把等到的那个键码写进全局 22，再让包里的 keymove 去决定怎么动 —— 与移窗那一格同一份。
.send_key:
    mov r15, rax
    cvtsi2sd xmm0, r15
    movq rax, xmm0
    mov qword [global_kinds + 22 * 8], 1
    mov [global_vals + 22 * 8], rax
    mov rdi, name_keymove
    mov r8, 7
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    call .reset_and_run
    ret
.reset_and_run:
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    jmp exec
.missing:
    mov rsi, line_same_nopkg
    call puts64
    ret

; ======================================================================
; 一个包画一个窗口
; ======================================================================
;
; 上面那条 rect 证明的是「包能指定画在哪里」；这一条要的是「包能画出有结构的东西」——
; 底色、标题栏、内容区，三层矩形落在一起。
;
; 而它也是 LAYERS 第六节第三条判据说的「Ichiwatashi 那一小块」最接近的一次：窗口碎片
; 的形状就是三种颜色的关系，而不是一个盒子。
;
; 判据读三个点，各在一个区里：标题栏 (160,86)、内容区 (160,120)、底色左上 (60,80)。
run_win_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_win
    mov r8, 3
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov qword [pkg_base], 0x70000
    mov rdi, 0xA0000
    movzx r8d, byte [rdi + 27680]   ; (160, 86) 标题栏
    movzx r9d, byte [rdi + 38560]   ; (160,120) 内容区
    movzx r10d, byte [rdi + 25660]  ; (60, 80)  底色左上
    mov rsi, line_win_px
    call puts64
    mov rax, r8
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, r9
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, r10
    call put_hex64
    call put_nl64
    ret
.missing:
    mov rsi, line_win_bad
    call puts64
    ret

; ======================================================================
; slurp 的返回值参与计算：读一个文件，返回它的字节数
; ======================================================================
;
; 上面那条让包读一个文件再打出来 —— 读到的值只有一条去向：交给 write。这一条要的是
; 「读到的值能当值用」：slurp 之后接 len，而 len 读的是那个串的长度字段。
;
; 判据要 prog size -> 24（docs/sub/deep.txt 是 24 字节）。24 这个数在别处没有出现过，
; 所以它只能来自那个文件。
run_filesize_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov [pkg_base], r14
    mov rdi, name_filesize
    mov r8, 8
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .missing
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov r15, rax
    mov r14, rdx
    mov qword [pkg_base], 0x70000
    mov rsi, line_size
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    call put_nl64
    ret
.missing:
    mov rsi, line_size_bad
    call puts64
    ret

prog_missing:
    mov rsi, line_prog_missing
    call puts64
    ret

; ======================================================================
; Myon 的第二步：一个包把一段字交给宿主去打
; ======================================================================
;
; LAYERS 第六节第二条判据的第一步。这个包只有三条指令 —— 压一个串常量、调内置
; write、返回 —— 而它要证明的是：包里的字能出去，而包不必知道串口在哪个端口。
;
; 为什么先做「写」不做「读」：写这一侧只有一条路（到串口），而读那一侧要先定「宿主
; 攒到哪一行、包怎么拿到它」。两件事各自都值得先单独站住，而写完读是自然顺序 ——
; 写对之后，「那一行确实到了包手里」才有地方显示。
run_myon_test:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_prog_name
    mov r9, 9                       ; "prog.hmtn"
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz .missing
    mov rdi, r15
    call fs_load
    mov r14, rsi
    mov rdi, r14
    mov rsi, seed_magic
    mov rcx, 5
    call bytes_eq
    jc .bad
    mov [pkg_base], r14
    mov rdi, name_echo
    mov r8, 4
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .nofn
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov qword [pkg_base], 0x70000

    ; 画完之后读几个点。三个位置都在框的四条边上，而它们之间隔着三百二十字节的步长 ——
    ; 所以这一条不只证明「有一个像素亮了」，还证明那个框的尺寸与位置是对的。
    ;
    ; 三条值都该是 0x2F。0x2F 是配色表里的一个色，而这几个点在此之前从没被写过。
    mov rdi, 0xA0000
    movzx r8d, byte [rdi + 3210]    ; (10,10) 左上角
    movzx r9d, byte [rdi + 3250]    ; (50,10) 上边中间
    movzx r10d, byte [rdi + 19300]  ; (100,60) 右下角
    ; 再读矩形中心那一点：包自己指定的位置与颜色。
    movzx r11d, byte [rdi + 30 * 320 + 140]
    mov rsi, line_myon_px
    call puts64
    mov rax, r8
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, r9
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, r10
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, r11
    call put_hex64
    call put_nl64

    mov rsi, line_myon_done
    call puts64
    ret
.missing:
    mov rsi, line_myon_missing
    call puts64
    ret
.bad:
    mov qword [pkg_base], 0x70000
    mov rsi, line_myon_bad
    call puts64
    ret
.nofn:
    mov qword [pkg_base], 0x70000
    mov rsi, line_myon_nofn
    call puts64
    ret

; ----------------------------------------------------------------------
; 第二个包：docs/myon.hmtn
;
; 上面那一条跑的是 prog.hmtn 里的 echo —— 一个包里的第二个函数。这一条跑的是另一份
; 文件、另一块内存、另一个函数表。
;
; 为什么它值得单独一条：**桥接要有两个包才谈得上**，而一个包里的两个函数共享包头与
; 地址空间，那不叫两个。这一份从盘上的另一条路径读进来，是第一个「真正的第二个包」。
;
; 它放在 docs 里而不是根目录，因为根目录只有一个扇区、已经满了。而 fs_open_path 本来
; 就能逐段查 —— 这一条同时也在证明「包可以住在子目录里」。
run_myon2_test:
    mov rdi, fs_myon_path
    call fs_open_path
    test rax, rax
    jz .missing
    mov r14, [last_addr]
    mov rdi, r14
    mov rsi, seed_magic
    mov rcx, 5
    call bytes_eq
    jc .bad
    mov [pkg_base], r14
    mov rdi, name_echo
    mov r8, 4
    xor r15, r15
    call find_fn_by_name
    test rax, rax
    jz .nofn
    mov r12, rsi
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    mov qword [pkg_base], 0x70000
    mov rsi, line_myon2_ok
    call puts64
    ret
.missing:
    ; 诊断：把 fs_load(1026) 实际读到的那 80 字节打出来。
    ;
    ; 这一条与上一条诊断配成一对。上一条说「fs_lookup 一条候选都没命中」，而这一条说
    ; 它手上有的是什么字节 —— 两者一比就能分开两种可能：读错了地方（hex 与盘上不同），
    ; 还是遍历逻辑错（hex 与盘上相同而仍然没命中）。
    mov rdi, 1026
    call fs_load
    mov [myon_dbg_a], rsi
    mov rsi, line_myon2_hex
    call puts64
    mov rdi, [myon_dbg_a]
    mov rcx, 80
    call put_hex_bytes
    call put_nl64
    mov rsi, line_myon2_missing
    call puts64
    ret
.bad:
    mov qword [pkg_base], 0x70000
    mov rsi, line_myon2_bad
    call puts64
    ret
.nofn:
    mov qword [pkg_base], 0x70000
    mov rsi, line_myon2_nofn
    call puts64
    ret
prog_bad:
    mov qword [pkg_base], 0x70000
    mov rsi, line_prog_bad
    call puts64
    ret
prog_nomain:
    mov qword [pkg_base], 0x70000
    mov rsi, line_prog_nomain
    call puts64
    ret

; ======================================================================
; repl 的前半：从盘上读一个名字，按名字调它，把值打出来
; ======================================================================
;
; 这不是「读一行表达式」—— 那一半要编译器，属于 HMYR。它是「求一个东西并打出来」的
; 最小形态，而按名字调用与把值打到串口这两件 exec 那一侧已经有了。盘上那份 repl.txt
; 里就是一个函数名（UTF-16 码元，没有换行），所以读的人不必再切一行。
run_repl:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]          ; 根目录扇区
    mov r8, fs_repl_name
    mov r9, 8                     ; "repl.txt"
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz repl_missing
    mov rdi, r15                  ; repl.txt 的扇区
    call fs_load
    mov r14, rsi                  ; 名字的 UTF-16 码元
    mov rcx, rbx
    shr rcx, 1                    ; 字节数折成码元数
    push rcx
    mov rsi, line_repl_prompt
    call puts64
    pop rcx
    push rcx
    mov rax, rcx
    call put_num64                ; 打码元数而不是名字本身：块长 的低字节是 0x57 与 0x7F，
    mov rsi, line_repl_units      ; 八位串口打出来是 W 加一个看不见的字符 —— 那是打印
    call puts64                   ; 这一层的限制，不是名字错了
    mov rsi, line_repl_arrow
    call puts64
    pop r8                        ; r8 = 名字长度，find_fn_by_name 要这个
    mov rdi, r14
    xor r15, r15                  ; 后者胜，与读程序 同一条规矩
    call find_fn_by_name
    test rax, rax
    jz repl_unknown
    mov r12, rsi                  ; 指令流
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    xor rbx, rbx
    call exec
    cmp rax, 1                    ; 数
    jne repl_badkind
    mov rax, rdx
    call f64_to_int
    call put_num64
    call put_nl64
    ret
repl_badkind:
    mov rsi, line_bad_kind
    call puts64
    call put_num64
    call put_nl64
    ret
repl_unknown:
    mov rsi, line_repl_unknown
    call puts64
    ret
repl_missing:
    mov rsi, line_repl_missing
    call puts64
    ret

; ======================================================================
; 数学：把 average: 那一串算出一个数
; ======================================================================
;
; design/MATH.txt 三节定了右边两种形状：带 x 的表达式（能画也能求值）与不带 x 的具名
; 运算（只有结果）。这一块只做第二种 —— 它不是取舍，是顺序：第一种要表达式求值，
; 那是 HMYR 编译器的活；第二种只要「读几个数、加起来、除以个数」，而这三件事这台机器
; 现在都有（十进制解析、f64 加、f64 除）。
;
; 所以这一块不是「数学控制台做完了」，是它的第一半有了可以判的形态。
;
; 读一个数：rdi 指向 UTF-16 码元，rcx 是可读的码元数（含分隔符）。
; 出：xmm0 = 值，rax = 用掉几个码元。
;
; 语法只有三种东西：十进制数字（可带一个小数点）、π（U+03C0）、e（ASCII 的 e）。
; 后两个是「乘以这个常量」—— 6π 是六乘圆周率，24e 是二十四乘底数。第一个既不是数字
; 也不是常量的码元（逗号、空格、行尾）就是数的结束。
;
; 小数部分先当整数攒起来，最后除以十的位数：一次除法，误差比逐位乘 0.1 小，
; 而且 30.4 这条路走下来正好是 30 + 4/10，不是三十次浮点乘加。
parse_decimal:
    push rbx
    push r8
    push r9
    push r10
    push r11
    push r12
    mov r10, rcx                    ; 上界挪个地方：下面 rcx 要用来放位权
    xor r8, r8                      ; 用掉几个码元
    xor r11, r11                    ; 整数部分（整数形式）
    xor r12, r12                    ; 小数部分（整数形式）
    xor r9, r9                      ; 小数位数
    xor rbx, rbx                    ; 读到过数字吗
.int_loop:
    cmp r8, r10
    jae .int_done
    movzx eax, word [rdi + r8 * 2]
    cmp ax, '0'
    jb .maybe_dot
    cmp ax, '9'
    ja .maybe_dot
    imul r11, r11, 10
    sub eax, '0'
    add r11, rax
    mov rbx, 1
    inc r8
    jmp .int_loop
.maybe_dot:
    cmp ax, '.'
    jne .int_done
    inc r8
.frac_loop:
    cmp r8, r10
    jae .int_done
    movzx eax, word [rdi + r8 * 2]
    cmp ax, '0'
    jb .int_done
    cmp ax, '9'
    ja .int_done
    imul r12, r12, 10
    sub eax, '0'
    add r12, rax
    inc r9
    mov rbx, 1
    inc r8
    jmp .frac_loop
.int_done:
    cvtsi2sd xmm0, r11
    test r9, r9
    jz .constants
    cmp r9, 9                       ; 表到十的九次方；再多就不认，按已有位数走
    ja .constants
    cvtsi2sd xmm1, r12
    lea rax, [pow10_tab]
    mov rcx, [rax + r9 * 8]
    cvtsi2sd xmm2, rcx
    divsd xmm1, xmm2                ; xmm1 = 小数部分 ÷ 十的位数
    addsd xmm0, xmm1                ; 再与整数部分相加，整数部分一直在 xmm0 里
.constants:
    cmp r8, r10
    jae .done
    movzx eax, word [rdi + r8 * 2]
    cmp ax, 0x03C0
    je .pi
    cmp ax, 'e'
    je .euler
    jmp .done
.pi:
    movsd xmm1, [const_pi]
    jmp .apply
.euler:
    movsd xmm1, [const_e]
.apply:
    test rbx, rbx
    jnz .multiply
    movsd xmm0, xmm1                ; 前面没有数字：这个常量本身就是这个数
    mov rbx, 1
    jmp .next
.multiply:
    mulsd xmm0, xmm1
.next:
    inc r8
    jmp .constants
.done:
    mov rax, r8
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbx
    ret

; 求 math.txt 里那一行。判据是两行读数：sum 与 average。
;
; 为什么分两行：一条判据同时压住十进制、常量、除法与小数打印，错了分不清是谁错。
; 和错而商对说明加法没问题、除法错了；和对而商错说明除法或个数错了。两行分得开。
run_math:
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r14d, [rax + 12]
    mov r8, fs_math_name
    mov r9, 8                       ; "math.txt"
    mov rsi, r14
    call fs_lookup
    test rax, rax
    jz math_missing
    mov rdi, r15
    call fs_load
    mov r14, rsi                    ; 四行的 UTF-16 码元
    mov r15, rbx
    shr r15, 1                      ; 字节数折成码元数
.line_loop:
.skip_ws:
    test r15, r15
    jz .all_done
    movzx eax, word [r14]
    cmp ax, ' '
    je .skip_one
    cmp ax, 10
    je .skip_one
    cmp ax, 13
    je .skip_one
    jmp .have_line
.skip_one:
    add r14, 2
    dec r15
    jmp .skip_ws
.have_line:
    xor r8, r8                      ; 这一行有多长
.len_loop:
    cmp r8, r15
    jae .len_done
    cmp word [r14 + r8 * 2], 10
    je .len_done
    inc r8
    jmp .len_loop
.len_done:
    test r8, r8
    jz .skip_line                   ; 空行不必分派，分派它只会得到一句 unknown
    call math_line
.skip_line:
    lea r14, [r14 + r8 * 2]         ; 先跳过这一行本身
    sub r15, r8
    test r15, r15
    jz .all_done                    ; 行占了剩余全部：没有换行可跳
    add r14, 2                      ; 再跳过换行那个码元
    dec r15
    jmp .line_loop
.all_done:
    ret

; 一行怎么读。design/MATH.txt 三节：冒号前是已知运算名就是具名运算，否则按表达式读。
; 而表达式那一边，左边是 y 还是 f(x) 还是 f x 都不影响 —— 括号与空格是给人看的。
; 所以这里的判据不是「算出了什么」，是「三种写法认出来一模一样」。算与画都还没有：
; 算要表达式求值（HMYR 的编译器那份活），画要一块能画点的界面。
; 入：r14 = 行首，r8 = 行长（码元数）。
math_line:
    push rbx
    push r8
    push r9
    push r10
    push r11
    push r12
    xor r9, r9
.find_eq:
    cmp r9, r8
    jae .not_curve
    cmp word [r14 + r9 * 2], '='
    je .is_curve
    inc r9
    jmp .find_eq
.is_curve:
    mov rsi, line_curve
    call puts64
    xor r10, r10
.name_loop:
    cmp r10, r9
    jae .name_done
    movzx eax, word [r14 + r10 * 2]
    call putc64                     ; 左边原样打，空格也打：f x 与 f(x) 要看得见差别
    inc r10
    jmp .name_loop
.name_done:
    mov rsi, line_curve_arrow
    call puts64
    lea r11, [r9 + 1]
.has_x:
    cmp r11, r8
    jae .no_x
    movzx eax, word [r14 + r11 * 2]
    cmp ax, 'x'
    je .yes_x
    cmp ax, 'X'
    je .yes_x
    inc r11
    jmp .has_x
.yes_x:
    mov rsi, line_curve_hasx
    call puts64
    jmp .curve_done
.no_x:
    mov rsi, line_curve_nox
    call puts64
.curve_done:
    call put_nl64
    jmp .done
.not_curve:
    cmp r8, 8
    jb math_unknown
    lea rsi, [math_op_average]
    xor r9, r9
.prefix:
    mov ax, [rsi + r9 * 2]
    cmp ax, [r14 + r9 * 2]
    jne math_unknown
    inc r9
    cmp r9, 8
    jb .prefix
    lea rdi, [r14 + 16]             ; 跳过 average: 那八个码元
    mov rcx, r8
    sub rcx, 8
    call math_average
.done:
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbx
    ret

; 具名运算的正文：逗号分隔的一串数。入 rdi = 首码元，rcx = 码元数。
math_average:
    push r14
    push r15
    push r12
    mov r14, rdi
    mov r15, rcx
    xorpd xmm3, xmm3                ; 和
    xor r12, r12                    ; 个数
.skip:
    test r15, r15
    jz .finish
    movzx eax, word [r14]
    cmp ax, ' '
    je .blank
    cmp ax, ','
    jne .number
.blank:
    add r14, 2
    dec r15
    jmp .skip
.number:
    mov rdi, r14
    mov rcx, r15
    call parse_decimal
    test rax, rax
    jz .finish                      ; 一个都读不动就不再往前：否则这一步原地打转
    addsd xmm3, xmm0
    inc r12
    lea r14, [r14 + rax * 2]
    sub r15, rax
    jmp .skip
.finish:
    test r12, r12
    jz .unknown
    movsd [math_sum], xmm3
    mov rsi, line_math_sum
    call puts64
    movsd xmm0, [math_sum]
    call put_f64
    call put_nl64
    mov rsi, line_math_avg
    call puts64
    movsd xmm0, [math_sum]
    cvtsi2sd xmm1, r12
    call div_f64
    call put_f64
    call put_nl64
    jmp .done
.unknown:
    mov rsi, line_math_unknown
    call puts64
.done:
    pop r12
    pop r15
    pop r14
    ret

math_unknown:
    mov rsi, line_math_unknown
    call puts64
    ret
math_missing:
    mov rsi, line_math_missing
    call puts64
    ret

; 给「除」这条操作码一个自己会红的判据。
;
; run_math 里的平均也走 div_f64，但它证明的是「平均值算得对」，不是「解释器认得
; 操作码 6」—— exec 那条分发表若漏了这一条，average 那一行照样是绿的。所以这里造
; 一段四条的迷你流：常量 π、常量 2、除、返回，交给 exec 跑。读数 1.570796327。
;
; 选 π 而不是随便两个数：常量的八字节位模式若读歪了，这里立刻看得出来。
run_div_test:
    push rbx
    push r12
    push r13
    mov r12, div_prog
    mov r13, 4
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    call scan_instrs
    xor rbx, rbx
    call exec
    pop r13
    pop r12
    pop rbx
    ret

run_div_report:
    mov r12, rax
    mov rbx, rdx
    mov rsi, line_div
    call puts64
    cmp r12, 1
    jne .bad
    movq xmm0, rbx
    call put_f64
    jmp put_nl64
.bad:
    mov rsi, line_bad_kind
    call puts64
    mov rax, r12
    call put_num64
    jmp put_nl64

run_ata_test:
    mov rax, 512
    call alloc64
    mov [ata_buf], rax            ; 缓冲区地址要留住：ata_read 会把 rax 用掉
    mov rdi, seed_lba             ; 种子在盘上的第一个扇区 —— 与 dap_lba 同源，不再各写一个数
    mov rsi, rax
    call ata_read
    jc ata_fail
    mov rsi, [ata_buf]
    mov rdi, 0x70000
    mov rcx, 512
    repe cmpsb
    jne ata_differ
    mov rsi, line_ata_same
    call puts64
    ret
ata_differ:
    ; rcx 是还没比的那几个，所以差在第 512 - rcx 个字节上。
    mov rax, 512
    sub rax, rcx
    mov rsi, line_ata_differ
    call puts64
    call put_num64
    call put_nl64
    ret
ata_fail:
    mov rsi, line_ata_fail
    call puts64
    ret

; ======================================================================
; 文件系统：第 1024 号扇区上的超级块，与它指的那个根目录
; ======================================================================
;
; 设计在 design/FS.txt。这一块只做到「读出一个名字」：
; 超级块的魔数与版本、根目录的扇区号、以及根目录里第一个条目的名字。
;
; 名字读得出来，路径才有意义 —— 而路径有意义，文件才算存在。
run_fs_test:
    mov rdi, 1024                   ; 超级块：引导与种子之后的第一千个扇区
    call fs_load
    mov [fs_buf], rsi
    cmp dword [rsi], 0x4F4E5559     ; "YUNO"
    jne fs_bad
    cmp word [rsi + 4], 0x5346      ; "FS"
    jne fs_bad
    movzx r14d, word [rsi + 6]      ; 版本
    mov r15d, [rsi + 12]            ; 根目录的第一个扇区
    mov rdi, r15
    call fs_load
    mov [fs_buf], rsi
    mov rsi, line_fs_ok
    call puts64
    mov rax, r14
    call put_num64
    mov rsi, line_fs_root
    call puts64
    mov rax, r15
    call put_num64
    mov r12, [fs_buf]
    movzx eax, word [r12]           ; 第一个条目的名字长度
    test eax, eax
    jz fs_empty
    mov r13, rax
    mov rsi, line_fs_first
    call puts64
    xor rbx, rbx
.name:
    cmp rbx, r13
    jae .name_done
    movzx eax, word [r12 + 2 + rbx * 2]
    call putc64                     ; 名字是 UTF-16 码元，这一版只取低字节
    inc rbx
    jmp .name
.name_done:
    jmp put_nl64
fs_empty:
    mov rsi, line_fs_empty
    call puts64
    ret
fs_bad:
    mov rsi, line_fs_bad
    call puts64
    ret
fs_fail:
    mov rsi, line_fs_fail
    call puts64
    ret

; ======================================================================
; 按路径打开一份文件
; ======================================================================
;
; 设计在 design/FS.txt 第三节。这一版只认 α 一块盘、只走一层目录 —— 两条限制都写成了
; 明确的声音（unknown drive / not found），而不是静悄悄给出一个空。
;
; 判据是文件内容本身：盘符认错、分隔跳错、名字比错、扇区算错，任何一环出错都读不到
; 「Yunooka filesystem ok」这二十二个字节。一个字符对不上就全对不上。
run_fs_open:
    mov rdi, fs_path
    movzx eax, word [rdi]
    cmp ax, 0x03B1                ; α
    jne fs_open_drive
    add rdi, 6                    ; 跳过 α : /
    xor rcx, rcx                  ; 名字多长：扫到 0 码元
.fs_count:
    cmp rcx, 64                   ; 上限：路径再长也不该长过 64 个码元。没有这一条，
    jae fs_open_miss              ; 一个找不到 0 的扫法会一直往前读，而「卡住」与「没有这个
    cmp word [rdi + rcx * 2], 0   ; 文件」在串口上是两种完全不同的结论
    je .fs_counted
    inc rcx
    jmp .fs_count
.fs_counted:
    mov r13, rcx                  ; 目标名字长度
    mov r14, rdi                  ; 目标名字
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    ; 32 位读。用 mov rdi, [rax + 12] 会把紧跟着的「数据起点」也装进高 32 位，
    ; 于是 fs_load 算出来的地址在几十 GB 之外 —— 而那个地址读出来是别的内存，
    ; 九次比较当然一次都过不去。同一个形状在这一版里出现第三次了：指令数、
    ; 状态字节、现在这个扇区号，都是 u32 被八字节读吃掉邻居。
    mov edi, [rax + 12]           ; 超级块说的根目录扇区
    call fs_load
    mov [fs_buf], rsi
.fs_entry:
    movzx eax, word [rsi]
    test eax, eax
    jz fs_open_miss               ; 名字长度为 0：名册到头了
    cmp rax, r13
    jne .fs_next
    xor rdx, rdx
.fs_cmp:
    cmp rdx, r13
    jae .fs_hit
    mov ax, [rsi + 2 + rdx * 2]
    cmp ax, [r14 + rdx * 2]
    jne .fs_next
    inc rdx
    jmp .fs_cmp
.fs_hit:
    movzx ecx, word [rsi]
    lea rdx, [rsi + 2 + rcx * 2]  ; 名字之后是类型 u8、起始 u32、长度 u32
    mov r15d, [rdx + 1]
    mov ebx, [rdx + 5]
    mov rdi, r15
    call fs_load
    mov [fs_buf], rsi
    mov rsi, line_fs_open
    call puts64
    mov rdi, r14                  ; 盘符是 UTF-16 的希腊字，八位串口打不出来 —— 打名字
    call put_utf16_ascii
    mov rsi, line_fs_arrow
    call puts64
    mov rsi, [fs_buf]
    mov rcx, rbx
.fs_put:
    test rcx, rcx
    jz .fs_put_done
    mov al, [rsi]
    push rsi
    push rcx
    call putc64
    pop rcx
    pop rsi
    inc rsi
    dec rcx
    jmp .fs_put
.fs_put_done:
    call put_nl64
    ret
.fs_next:
    movzx ecx, word [rsi]         ; 条目变长：2 + 2*名字 + 1 + 4 + 4
    lea rsi, [rsi + 11 + rcx * 2]
    jmp .fs_entry
fs_open_miss:
    mov rsi, line_fs_nofile
    call puts64
    ret
fs_open_drive:
    mov rsi, line_fs_nodrive
    call puts64
    ret
fs_open_read:
    mov rsi, line_fs_fail
    call puts64
    ret

; ======================================================================
; 多级目录：在一个目录里找名字，然后按段走下去
; ======================================================================
;
; 绝对路径是「从根往下走」的，所以多级目录并不需要「当前目录」那个状态 —— 每一层只要
; 知道「这一层是哪个扇区」，就够走下一步。这也是为什么这一块能先于进程做出来。
;
; 一叠套着的抽屉，每个抽屉里有一张纸写着下一个抽屉的扇区号。走两层就是拉两次抽屉。

; r8 = 名字起点，r9 = 名字长度，rsi = 目录扇区。
; 回来 rax = 1 找到 / 0 没有；找到时 r15 = 起始扇区、rbx = 字节长度、dl = 类型。
fs_lookup:
    mov rdi, rsi                  ; 入参是目录扇区，fs_load 要的是 rdi
    call fs_load
    mov [fs_buf], rsi
.entry:
    movzx eax, word [rsi]
    test eax, eax
    jz .miss                      ; 名字长度为 0：这一层到头了
    cmp rax, r9
    jne .next
    xor rdx, rdx
.cmp:
    cmp rdx, r9
    jae .hit
    mov ax, [rsi + 2 + rdx * 2]
    cmp ax, [r8 + rdx * 2]
    jne .next
    inc rdx
    jmp .cmp
.hit:
    mov [last_entry], rsi          ; 这一条在预读区里的起点 —— 改共享位要用它
    movzx ecx, word [rsi]
    lea rdx, [rsi + 2 + rcx * 2]
    movzx r10d, byte [rdx]        ; 类型
    mov r15d, [rdx + 1]
    mov ebx, [rdx + 5]
    mov rdx, r10
    mov rax, 1
    ret
.next:
    movzx ecx, word [rsi]
    lea rsi, [rsi + 11 + rcx * 2]
    jmp .entry
.miss:
    xor rax, rax
    ret

; 按路径逐段查找。rdi = UTF-16 路径，以 0 码元结尾，形如 α:/docs/sub/deep.txt。
;
; 路径语法在 design/FS.txt 三节：盘符 α 起、斜杠分隔、全绝对。这里只做一件 ——
; 从根目录起一段一段查下去。
;
; 为什么要有它：之前的两层是手写的，两个段名各占一个变量（fs_seg1、fs_seg2）。那证明的是
; 「目录里的条目能指向另一个目录」，不是「路径能被解析」—— 三层的写法在那种形状里要再加
; 一个变量，四层再加一个。按斜杠切段之后，深度只是循环转了几圈。
;
; 「当前在哪一层」是 r13 里的一个扇区号，不是全局的当前目录 —— 绝对路径不需要那东西，
; 而当前目录要等有进程、有「谁记得自己站在哪」的时候才谈得上。
;
; 出：rax = 1 找到（r15 = 扇区、rbx = 字节数），0 = 没找到。
fs_open_path:
    push r12
    push r13
    movzx eax, word [rdi]
    cmp ax, 0x03B1                 ; α = 主盘，预读在 0x40000、第 1024 扇区起
    je .alpha
    cmp ax, 0x03B2                 ; β = 第二块盘，预读在 0x60000、第 0 扇区起
    jne .miss
    mov qword [fs_base], 0x60000
    mov qword [fs_start], 0
    jmp .drive_ok
.alpha:
    mov qword [fs_base], 0x40000
    mov qword [fs_start], 1024
.drive_ok:
    add rdi, 2
    movzx eax, word [rdi]
    cmp ax, ':'
    jne .miss
    add rdi, 2
    push rdi
    mov rdi, [fs_start]            ; 超块就在这一段的第一个扇区
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r13d, [rax + 12]           ; 从根目录起
    pop rdi
.segment:
.skip_slash:
    movzx eax, word [rdi]
    cmp ax, '/'
    jne .have_start
    add rdi, 2
    jmp .skip_slash
.have_start:
    test ax, ax
    jz .miss                       ; 以斜杠收尾：那是一个目录，不是文件
    mov r12, rdi                   ; 段首
    xor rcx, rcx                   ; 段长
.count:
    movzx eax, word [rdi + rcx * 2]
    test ax, ax
    jz .at_end
    cmp ax, '/'
    je .at_slash
    inc rcx
    cmp rcx, 64
    ja .miss                       ; 一段长过 64 个码元：不像一个名字
    jmp .count
.at_slash:
    lea rax, [r12 + rcx * 2]       ; 下一轮的起点
    push rax
    mov r8, r12
    mov r9, rcx
    mov rsi, r13
    call fs_lookup
    mov r12, rax                   ; fs_lookup 的答案先收好，再取回起点
    pop rdi
    test r12, r12
    jz .miss
    mov r13, r15                   ; 这一段的扇区成为下一段的目录
    jmp .segment
.at_end:
    mov r8, r12
    mov r9, rcx
    mov rsi, r13
    call fs_lookup
    test rax, rax
    jz .miss
    ; 过边界。主盘是自家的盘，随便看；别的盘要过两关 —— 同一个家，而且这一条带了共享位。
    ;
    ; 这两件事分开查是有原因的：那个共享位在此之前只是一个能列出来的标记，没有任何
    ; 约束力。一块盘上的文件不管共不共享都读得到，「共享」就是一句宣言。加上这一道之后
    ; 它才是一个许可。
    call fs_gate
    test al, al
    jz .miss
    ; 把地址一起算出来交出去。
    ;
    ; 之前只交扇区号，而「这是哪一块盘的扇区」那件事在 .done 里被拨回了主盘 —— 调用者
    ; 自己再调 fs_load 时，拿 α 的起点去减 β 的扇区号，借位成巨大偏移，症状是 #PF。
    ; 这个坑踩过两次（run_fs_open4 与 run_gate_test），两次看起来都像别的问题。
    ; 所以地址在这里算：此刻 fs_base 与 fs_start 还是那块盘的。
    mov rdi, r15
    call fs_load
    mov [last_addr], rsi
    mov rax, 1
    jmp .done
.miss:
    xor eax, eax
.done:
    pop r13
    pop r12
    ; 拨回 α。调用者接下来多半还是用主盘，而「上一次查的是 β」这种状态留在变量里，
    ; 会让下一次 α 的读取落到第二块盘的地址上 —— 那种错很安静，读出来的是别人的字节。
    mov qword [fs_base], 0x40000
    mov qword [fs_start], 1024
    ret

; 过边界：当前盘（fs_start 指的）是不是自家的盘，以及那一条有没有共享位。
; rdl = fs_lookup 交回来的类型（含 0x80 共享位）。出 al = 1 允许 / 0 拒绝。
;
; 主盘直接放行：那是自己的盘，自家的东西不必自己给自己发许可。
fs_gate:
    ; 管理动作不走这道门。share 要先找到那条才能标记它，而它被标记之前又过不了门 ——
    ; 「要共享才能访问、要访问才能共享」是个闭环。所以门只管读取，由 gate_off 分开。
    cmp qword [gate_off], 0
    jne .yes
    cmp qword [fs_start], 1024
    je .yes
    push rdx
    ; fs_load 用的是「当前盘」的那两个数，所以读主盘的家要先把它们拨过去 ——
    ; 直接 fs_load(1024) 会在 β 上算出 0x60000 + 1024*512，那是 β 的第 1024 个扇区。
    push qword [fs_base]
    push qword [fs_start]
    mov qword [fs_base], 0x40000
    mov qword [fs_start], 1024
    mov rdi, 1024
    call fs_load
    mov eax, [rsi + 28]
    mov [gate_a], eax
    pop qword [fs_start]
    pop qword [fs_base]
    mov rdi, [fs_start]
    call fs_load
    mov eax, [rsi + 28]
    mov [gate_b], eax
    pop rdx
    mov eax, [gate_a]
    cmp eax, [gate_b]
    jne .no
    test dl, 0x80
    jz .no
.yes:
    mov al, 1
    ret
.no:
    xor al, al
    ret

; 家庭组的第四步：共享位要有约束力。
;
; 在此之前，β 上的文件不管共不共享都读得到 —— 那个位只是一个能列出来的标记，是一句
; 宣言，不是许可。这一条给它加上约束：别的盘上的东西，要同一个家、而且那一条带共享位。
;
; 三次读数，各自分得开不同的坏法：
;   家不同时读      → 必须被挡住（不然边界只是个装饰）
;   同一家、共享过  → 必须读得到（不然边界挡住了自家人）
;   同一家、没共享  → 必须被挡住（不然共享位只是个装饰）
; 第三行是这一组里最要紧的：一颗「只要同一家就放行」的实现，前两行都对。
run_gate_blocked:
    mov rdi, fs_path4
    call fs_open_path
    test rax, rax
    jnz .opened
    mov rsi, line_gate_blocked
    call puts64
    ret
.opened:
    mov rsi, line_gate_leak
    call puts64
    ret

run_gate_test:
    ; 同一家、共享过的那个：读得到
    mov rdi, fs_path4
    call fs_open_path
    test rax, rax
    jz .failed
    ; 地址由 fs_open_path 一起交出来了 —— 这段拨盘的代码原来在这里，因为只交扇区号时
    ; 调用者得自己知道「那是哪一块盘的扇区」。现在不必了，这也是那笔债还掉的样子。
    mov rsi, [last_addr]
    mov [fs_buf], rsi
    mov rsi, line_gate_shared
    call puts64
    mov rsi, [fs_buf]
    mov rcx, rbx
.put:
    test rcx, rcx
    jz .put_done
    mov al, [rsi]
    push rsi
    push rcx
    call putc64
    pop rcx
    pop rsi
    inc rsi
    dec rcx
    jmp .put
.put_done:
    call put_nl64
    ; 同一家、没共享的那个：必须被挡住
    mov rdi, fs_secret_path
    call fs_open_path
    test rax, rax
    jnz .leak
    mov rsi, line_gate_secret
    call puts64
    ret
.leak:
    mov rsi, line_gate_leak
    call puts64
    ret
.failed:
    mov rsi, line_gate_leak
    call puts64
    ret

run_fs_open2:
    mov rdi, fs_path2
    call fs_open_path
    test rax, rax
    jz fs_open_miss
    mov rsi, [last_addr]
    mov [fs_buf], rsi
    mov rsi, line_fs_open
    call puts64
    lea rdi, [fs_path2 + 6]        ; 跳过 α:/ 三个码元，只打路径那一段
    call put_utf16_ascii
    mov rsi, line_fs_arrow
    call puts64
    mov rsi, [fs_buf]
    mov rcx, rbx
.put:
    test rcx, rcx
    jz .put_done
    mov al, [rsi]
    push rsi
    push rcx
    call putc64
    pop rcx
    pop rsi
    inc rsi
    dec rcx
    jmp .put
.put_done:
    call put_nl64
    ret

; 三层：α:/docs/sub/deep.txt。深度到这里已经不靠新变量了 —— 与两层走的是同一个循环，
; 只是多转一圈。这一行才是「路径被解析」的判据；两层那一行在旧的写法下也能过。
run_fs_open3:
    mov rdi, fs_path3
    call fs_open_path
    test rax, rax
    jz fs_open_miss
    mov rsi, [last_addr]           ; 地址由 fs_open_path 算好：它知道那一条属于哪块盘
    mov [fs_buf], rsi
    mov rsi, line_fs_open
    call puts64
    lea rdi, [fs_path3 + 6]
    call put_utf16_ascii
    mov rsi, line_fs_arrow
    call puts64
    mov rsi, [fs_buf]
    mov rcx, rbx
.put:
    test rcx, rcx
    jz .put_done
    mov al, [rsi]
    push rsi
    push rcx
    call putc64
    pop rcx
    pop rsi
    inc rsi
    dec rcx
    jmp .put
.put_done:
    call put_nl64
    ret

; 第二块盘：另一块盘、另一个文件系统、同一个格式。盘符的意义就在这里 ——
; α:/hello.txt 与 β:/hello.txt 是两份不同的字节，而打开它们的是同一段代码。
run_fs_open4:
    mov rdi, fs_path4
    call fs_open_path
    test rax, rax
    jz fs_open_miss
    ; fs_open_path 返回前已经把基址拨回 α，而这一行要读的是 β 的文件 —— 所以自己再拨一次。
    ;
    ; 这一处踩过：拨回放在查找函数里，读文件却在调用者那儿，于是 fs_load(2) 用的是 α 的
    ; 起点 1024，sub 2, 1024 借位成一个巨大的偏移，地址飞出映射，结果是 #PF at 0xA1B4 ——
    ; 而不是「读错了内容」。一个状态什么时候失效，要由用完它的人决定，不是由产生它的人。
    mov qword [fs_base], 0x60000
    mov qword [fs_start], 0
    mov rdi, r15
    call fs_load
    mov [fs_buf], rsi
    mov qword [fs_base], 0x40000   ; 读完立刻拨回，别让后面的测试读错盘
    mov qword [fs_start], 1024
    mov rsi, line_fs_open
    call puts64
    lea rdi, [fs_path4 + 6]        ; 跳过 β:/ 三个码元（β 的低字节串口打不出来）
    call put_utf16_ascii
    mov rsi, line_fs_arrow
    call puts64
    mov rsi, [fs_buf]
    mov rcx, rbx
.put:
    test rcx, rcx
    jz .put_done
    mov al, [rsi]
    push rsi
    push rcx
    call putc64
    pop rcx
    pop rsi
    inc rsi
    dec rcx
    jmp .put
.put_done:
    call put_nl64
    ret

; ======================================================================
; 写一个文件：在根目录里追加一条，把数据拷进一个新扇区
; ======================================================================
;
; 这一版写的是「文件系统这一层的写」：算出一个空闲扇区、在目录里加一条、把字节拷进去。
; 它没有把扇区写回盘上 —— 数据落在预读区里，所以重启就没了。持久化是另一件（要 PIO 写），
; 单独记着，不混进这一条。
;
; 为什么先做这一半：空闲扇区的账、目录条目的形状、数据落点，这三样是「写」的语义；
; 而「有没有落到盘上」是 IO 那一层的性质。两件事混在一起做，出错时分不清是哪一层 ——
; 而分不清的那一次，通常会把「没落盘」当成「写错了」。
;
; rdi = 文件名（UTF-16，0 码元结尾）、rsi = 数据、rcx = 字节数。出 rax = 1 成功 / 0 失败。
; 从目录里删掉一条：把后面那一段往前挪，在新的末尾写零。
;
; rdi = 名字（UTF-16，以零码元结尾）、rsi = 目录扇区。回来 rax = 1 删掉 / 0 没有。
;
; 为什么不把名字长度置零：目录是一条链，条目一个接一个，靠「长度为零」收尾。把一个中间
; 条目的长度置零会把后面的整条链切断 —— 症状是「删掉一份之后，那一层里别的文件也不见了」，
; 而在 fs_lookup 那一侧看不出是谁动的。
;
; 也不做墓碑：墓碑要在每个遍历它的地方都被跳过，漏掉一处就多一个看不见的文件。挪一次
; 只在这里错，而错法的样子是「搬错了字节」，比「某处忘了过滤」容易看见。
;
; 这一块是全局的（不带 .op_ 前缀），所以它必须住在 exec 外面。上一版插在 .op_list 之前，
; 于是它后面所有 .op_* 都变成了它的局部标签，nasm 报 exec.op_index 未定义。
fs_delete:
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r12, rdi
    mov r13, rsi
    mov rdi, 1024
    call fs_load
    mov rbx, rsi
    mov rdi, r13
    call fs_load
    mov r9, rsi
    xor r14, r14
.dcount:
    cmp word [r12 + r14 * 2], 0
    je .dcounted
    inc r14
    jmp .dcount
.dcounted:
.dfind:
    movzx ecx, word [r9]
    test ecx, ecx
    jz .dmiss
    ; 输入的名字是裸串（以零码元结尾），不是长度前缀 —— 与 fs_write_file 一个约定。
    ; 上一版读 [r12] 当长度，于是拿 'i'（105）去比 note.txt 的 8，永远不等。
    cmp r14, rcx
    jne .dnext
    xor rdx, rdx
.dcmp:
    cmp rdx, rcx
    jae .dfound
    mov ax, [r9 + 2 + rdx * 2]
    cmp ax, [r12 + rdx * 2]
    jne .dnext
    inc rdx
    jmp .dcmp
.dnext:
    movzx eax, word [r9]
    lea r9, [r9 + 11 + rax * 2]
    jmp .dfind
.dfound:
    movzx eax, word [r9]
    lea r14, [rax * 2 + 11]        ; 这一条的字节数
    lea r15, [r9 + r14]            ; 下一条的起点，也就是要搬的源
    mov rsi, r15
.dend:
    movzx eax, word [rsi]
    test eax, eax
    jz .dsize
    lea rsi, [rsi + 11 + rax * 2]
    jmp .dend
.dsize:
    sub rsi, r15                   ; 要搬的字节数（含末尾那两个零码元）
    mov rcx, rsi
    mov rsi, r15
    mov rdi, r9
    cld
    rep movsb
    mov word [rdi], 0              ; 搬完的位置成了新的终止
    mov rax, 1
    jmp .ddone
.dmiss:
    xor eax, eax
.ddone:
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

fs_write_file:
    push r11
    push r12
    push r13
    push r14
    push r15
    push rbx
    mov r12, rdi                   ; 文件名
    mov r13, rsi                   ; 数据
    mov r14, rcx                   ; 字节数
    mov rdi, 1024
    call fs_load
    mov rbx, rsi                   ; 超级块
    ; 新扇区号 = 数据起 + (总数 - 数据起 - 空闲)
    mov eax, [rbx + 8]
    sub eax, [rbx + 20]
    sub eax, [rbx + 24]
    add eax, [rbx + 20]
    mov r15d, eax
    mov [last_write_sec], r15       ; 数据那一页：save 要把它写回盘
    ; 找根目录里的第一个空条目（名字长度为 0）
    ; 写到哪一层由 write_dir 说：0 是根目录，非零是某一个目录的扇区。
    ;
    ; 用全局而不是第三个参数，是因为现有每一个调用者都只写根目录 —— 让它们在调用点
    ; 各补一句 rdx = 0，是四次同样的改动，而漏掉一次就会写进一个垃圾地址。
    mov edi, [write_dir]
    test edi, edi
    jnz .dir_ok
    mov edi, [rbx + 12]
.dir_ok:
    mov [last_dir_sec], rdi         ; 目录那一页：同上
    mov eax, [rbx + 16]             ; 根目录占几个扇区 —— 落盘要把它们都写回
    mov [last_dir_pages], rax
    call fs_load
    mov r9, rsi
    ; 条目区的上界 = 目录自己那几页的末尾。
    ;
    ; 没有这一条的时候，根目录写满就沿着预读区往后写，而紧跟其后的是下一个目录的条目区。
    ; 症状不是「写不进去」，而是另一个目录里的文件凭空消失 —— docs 的 sub 被 new.txt 的
    ; 条目压掉，而 fs_lookup 只在连续内存里走，看不出那是一条谁都不该越过的边界。
    ;
    ; 上界从超块偏移 16 读，不写死：那个字段本来就是「根目录占几个扇区」。
    mov eax, [rbx + 16]
    shl eax, 9
    lea r11, [rsi + rax]
.find_free:
    movzx eax, word [r9]
    test eax, eax
    jz .have_slot
    ; 同名检查。这一段是新加的：在这个函数里它原先只找空槽，于是同名的第二次写会造出
    ; 第二条同名条目，而目录里两条都算数。一条「谁都写得上」的文件系统里，只读位只是
    ; stat 里的一列，不是一道门。
    xor rdx, rdx
.cmp_name:
    cmp rdx, rax
    jae .cmp_end
    mov cx, [r9 + 2 + rdx * 2]
    cmp cx, [r12 + rdx * 2]
    jne .not_same
    inc rdx
    jmp .cmp_name
.cmp_end:
    cmp word [r12 + rax * 2], 0    ; 输入的名字也要在这里结束，才算同名
    jne .not_same
    ; 同名。带只读位就拒绝 —— 系统保护的第一层，而在这一块砖之前它什么也没挡。
    lea rcx, [r9 + 2 + rax * 2]
    movzx edx, byte [rcx]
    test dl, 0x40
    jz .exists
    mov rsi, line_write_ro
    call puts64
    jmp .fail
.exists:
    ; 同名：覆盖。条目不新增，只改它指向哪儿、多大。
    ;
    ; 「同名也算成功」是一件事，「不新增第二条」是另一件事 —— 后者才是判据要的。
    ; 一个把覆盖当成新建的实现会让目录里出现两条同名，而 fs_lookup 取第一条，于是
    ; 写成功了、读到的还是旧的，而串口上看不出区别。区分它们的只有一个数：长度。
    ;
    ; rcx 在 .cmp_end 里已经算好，指着这一条的类型字节；rcx + 1 是扇区、rcx + 5 是字节数。
    ; 三项要在拷贝之前改 —— rep movsb 会把 rcx 用成计数器。
    ;
    ; 旧扇区不回收：这一版的数据分配是一个减法（下一个空扇区永远在最后），没有回收。
    ; 覆盖几次就浪费掉几个扇区，这是已知的账，不是漏掉的。
    mov rsi, line_write_over
    call puts64
    mov byte [rcx], 0              ; 类型：文件
    mov [rcx + 1], r15d            ; 新扇区
    mov [rcx + 5], r14d            ; 新字节数
    mov rdi, r15
    call fs_load
    mov rdi, rsi
    mov rsi, r13
    mov rcx, r14
    cld
    rep movsb
    dec dword [rbx + 24]
    mov rax, 1
    jmp .done
.not_same:
    movzx eax, word [r9]
    lea r9, [r9 + 11 + rax * 2]
    cmp r9, r11
    jae .fail                     ; 写到目录自己的页之外了：不再往后挤
    jmp .find_free
.have_slot:
    mov r10, r9
    xor rcx, rcx
.count_name:
    cmp word [r12 + rcx * 2], 0
    je .named
    inc rcx
    cmp rcx, 64
    ja .fail
    jmp .count_name
.named:
    mov [r10], cx
    lea rdi, [r10 + 2]
    xor rdx, rdx
.copy_name:
    cmp rdx, rcx
    jae .copied
    mov ax, [r12 + rdx * 2]
    mov [rdi + rdx * 2], ax
    inc rdx
    jmp .copy_name
.copied:
    lea rdi, [r10 + 2 + rcx * 2]
    mov byte [rdi], 0              ; 类型：文件
    mov [rdi + 1], r15d            ; 起始扇区
    mov [rdi + 5], r14d            ; 字节数
    ; 数据拷到新扇区
    mov rdi, r15
    call fs_load
    mov rdi, rsi
    mov rsi, r13
    mov rcx, r14
    cld                            ; rep 系列的搬运要看方向位，而不该假设别人留了 0
    rep movsb
    dec dword [rbx + 24]           ; 空闲数减一
    mov rax, 1
    jmp .done
.fail:
    xor eax, eax
.done:
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    ret

; ======================================================================
; 系统保护的第一层：只读位真的挡住写
; ======================================================================
;
; 目录条目的类型字节 bit 6 是只读位，从 Kohane 第四层起就在了 —— 而它在此之前什么也
; 没挡：fs_write_file 只找空槽新建，同名的第二次写会造出第二条同名条目，两条都被
; 算数。所以「只读」当时只是 stat 里的一列，不是一道门。
;
; 这一块补两件事：查重名（已有就不许再建一条），以及同名的条目带只读位时拒绝写。
; 两条走同一条失败路径，但报出来的话不同 —— 「这个名字有了」与「这个名字被保护了」
; 对要写的人是两条不一样的消息。
;
; 判据三条，第三条是为了让前两条有意义：
;   一、写一个新名字，成功；
;   二、把它标成只读之后再写，失败，而且报的是只读；
;   三、换一个名字再写，成功 —— 少了这条，「拒绝」可能只是「整个写坏了」，
;       而两种看起来完全一样。
run_guard_test:
    mov rdi, fs_guard_name
    mov rsi, fs_guard_data
    mov rcx, fs_guard_len
    call fs_write_file
    test rax, rax
    jz .lost
    mov rsi, line_guard_write
    call puts64
    mov rdi, fs_guard_path
    call fs_readonly
    test rax, rax
    jz .lost
    mov rsi, line_guard_ro
    call puts64
    mov rdi, fs_guard_name
    mov rsi, fs_guard_data
    mov rcx, fs_guard_len
    call fs_write_file
    test rax, rax
    jnz .not_blocked
    mov rsi, line_guard_refused
    call puts64
    mov rdi, fs_guard2_name
    mov rsi, fs_guard_data
    mov rcx, fs_guard_len
    call fs_write_file
    test rax, rax
    jz .lost
    mov rsi, line_guard_other
    call puts64
    ret
.not_blocked:
    mov rsi, line_guard_leaked
    call puts64
    ret
.lost:
    mov rsi, line_guard_fail
    call puts64
    ret

; FNV-1a 32 位。rdi = 数据，rcx = 字节数，出 eax。
;
; 为什么是它而不是 CRC32：一条异或、一条乘法，两条指令的量，不需要表。它不防碰撞，
; 而这一层要防的不是碰撞，是「文件被改过而没人知道」。
fnv1a:
    push rsi
    push rdx
    mov eax, 0x811C9DC5
    mov rsi, rdi
    xor rdx, rdx
.loop:
    cmp rdx, rcx
    jae .done
    movzx r10d, byte [rsi + rdx]
    xor eax, r10d
    imul eax, eax, 0x01000193
    inc rdx
    jmp .loop
.done:
    pop rdx
    pop rsi
    ret

; ======================================================================
; SHA-256
; ======================================================================
;
; 为什么它在这一块里：这一层要防的是「有人改了并把校验和也重算了」，所以哈希必须是
; 抗碰撞的那一种。FNV-1a 连碰撞都不防 —— 它为「一个字节变了就报」设计的，而那是另一
; 件事。S.M.Y.T. 那一侧对没有内嵌签名位置的格式用的也是 SHA-256 清单（design/SIGN.txt
; 第一节），所以这里用同一个函数，不是另立一套。
;
; rdi = 数据，rcx = 字节数。出 [sha_out] 的 32 字节，大端。
sha256:
    push rbx
    push rsi
    push rdi
    push r8
    push r9
    ; 方向标志要在这里清一次。下面两次 rep（stosd 清补齐区、movsb 拷剩下的字节）
    ; 都按 DF 走，而 DF 不是自己的：别人设过它，自己没清，症状是补齐区**反向**被填 ——
    ; 于是哈希完全不对，而「不对」这个症状与「算法写错」分不开。
    ; fs_write_file 里也踩过同一处。
    cld
    mov [sha_ptr], rdi
    mov [sha_len], rcx
    mov dword [sha_h + 0],  0x6a09e667
    mov dword [sha_h + 4],  0xbb67ae85
    mov dword [sha_h + 8],  0x3c6ef372
    mov dword [sha_h + 12], 0xa54ff53a
    mov dword [sha_h + 16], 0x510e527f
    mov dword [sha_h + 20], 0x9b05688c
    mov dword [sha_h + 24], 0x1f83d9ab
    mov dword [sha_h + 28], 0x5be0cd19
    xor r8, r8                     ; 已经处理了多少字节
.full:
    mov rax, [sha_len]
    sub rax, r8
    cmp rax, 64
    jb .tail
    mov rdi, [sha_ptr]
    add rdi, r8
    call sha256_block
    add r8, 64
    jmp .full
.tail:
    lea rdi, [sha_pad]
    xor eax, eax
    mov ecx, 32                    ; 128 字节 = 32 个 dword
    rep stosd
    mov rsi, [sha_ptr]
    add rsi, r8
    mov rcx, [sha_len]
    sub rcx, r8
    mov r9, rcx                    ; 剩下几个字节
    lea rdi, [sha_pad]
    rep movsb
    mov byte [sha_pad + r9], 0x80
    mov rax, [sha_len]
    shl rax, 3                     ; 总长按位算
    bswap rax                      ; 末尾那八字节是大端
    cmp r9, 56
    jb .one
    ; 剩下 56 到 63 字节：长度装不进同一块，所以要补两块
    mov [sha_pad + 120], rax
    lea rdi, [sha_pad]
    call sha256_block
    lea rdi, [sha_pad + 64]
    call sha256_block
    jmp .out
.one:
    mov [sha_pad + 56], rax
    lea rdi, [sha_pad]
    call sha256_block
.out:
    ; 加回初值这一步**不在这里**，这一点值得写清楚。
    ;
    ; SHA-256 的链是 H(i+1) = H(i) + rounds(H(i), block) —— 加的是**上一步的状态**，
    ; 而它每个块各做一次。只在最后加一次「初值」，对一个块的消息恰好等价（那一步的
    ; H(i) 就是初值），从两块起就不同了。这一处曾经就是这样错的：单块全对、两块全错，
    ; 而第二环的清单里三个文件都短于一块，所以那条判据从来没有走到过会错的地方。
    ;
    ; 现在那一次加法在 sha256_block 自己的尾部（对着 sha_h0），这里只剩输出。
    lea rsi, [sha_h]
    lea rdi, [sha_out]
    mov ecx, 8
.emit:
    mov eax, [rsi]
    bswap eax
    mov [rdi], eax
    add rsi, 4
    add rdi, 4
    dec ecx
    jnz .emit
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbx
    ret

; 一个 64 字节块。rdi = 块地址。
;
; 逻辑函数一律就地展开，不跳小函数：那一个小跳会把 rcx（轮次）用掉，而它是整个循环里
; 唯一不能丢的东西。踩过一次同类 —— puts64 里的 lodsb 改 al 而 al 是循环变量。
sha256_block:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    ; W[0..15]：从大端读进来
    xor ecx, ecx
.load:
    mov eax, [rdi + rcx * 4]
    bswap eax
    mov [sha_w + rcx * 4], eax
    inc ecx
    cmp ecx, 16
    jb .load
    ; W[16..63] = σ1(W[t-2]) + W[t-7] + σ0(W[t-15]) + W[t-16]
    mov ecx, 16
.expand:
    mov eax, [sha_w + rcx * 4 - 8]     ; W[t-2]
    mov ebx, eax
    ror eax, 17
    ror ebx, 19
    xor eax, ebx
    mov ebx, [sha_w + rcx * 4 - 8]
    shr ebx, 10
    xor eax, ebx                       ; σ1
    add eax, [sha_w + rcx * 4 - 28]    ; + W[t-7]
    mov ebx, [sha_w + rcx * 4 - 60]    ; W[t-15]
    mov edx, ebx
    ror ebx, 7
    ror edx, 18
    xor ebx, edx
    mov edx, [sha_w + rcx * 4 - 60]
    shr edx, 3
    xor ebx, edx                       ; σ0
    add eax, ebx
    add eax, [sha_w + rcx * 4 - 64]    ; + W[t-16]
    mov [sha_w + rcx * 4], eax
    inc ecx
    cmp ecx, 64
    jb .expand
    ; 这一块的初值先存下来，交给尾部那一次 feed-forward。放在这里而不是开头，是因为
    ; rep movsd 要吃 rdi，而 rdi 在整个 .load 里都是块地址 —— 到了这里它已经用完了。
    lea rsi, [sha_h]
    lea rdi, [sha_h0]
    mov ecx, 8
    rep movsd
    ; 六十四轮
    xor ecx, ecx
.round:
    ; T1 = h + Σ1(e) + Ch(e,f,g) + K[t] + W[t]
    mov eax, [sha_h + 16]              ; e
    mov ebx, eax
    ror eax, 6
    ror ebx, 11
    xor eax, ebx
    mov ebx, [sha_h + 16]
    mov edx, ebx
    ror ebx, 25
    xor eax, ebx                       ; Σ1(e)
    mov ebx, [sha_h + 16]
    and ebx, [sha_h + 20]              ; e & f
    mov edx, [sha_h + 16]
    not edx
    and edx, [sha_h + 24]              ; ~e & g
    xor ebx, edx                       ; Ch
    add eax, ebx
    add eax, [sha_h + 28]              ; + h
    add eax, [sha_k + rcx * 4]
    add eax, [sha_w + rcx * 4]
    mov r8d, eax                       ; T1
    ; T2 = Σ0(a) + Maj(a,b,c)
    mov eax, [sha_h + 0]
    mov ebx, eax
    ror eax, 2
    ror ebx, 13
    xor eax, ebx
    mov ebx, [sha_h + 0]
    mov edx, ebx
    ror ebx, 22
    xor eax, ebx                       ; Σ0(a)
    mov ebx, [sha_h + 0]
    and ebx, [sha_h + 4]
    mov edx, [sha_h + 0]
    and edx, [sha_h + 8]
    xor ebx, edx
    mov edx, [sha_h + 4]
    and edx, [sha_h + 8]
    xor ebx, edx                       ; Maj
    add eax, ebx
    mov r9d, eax                       ; T2
    ; 移位。x86 没有内存到内存的 mov，所以一律经由 eax —— 而 T1/T2 已经在 r8d/r9d 里，
    ; 所以这两个寄存器在这一段里不能碰。
    mov eax, [sha_h + 24]
    mov [sha_h + 28], eax              ; h = g
    mov eax, [sha_h + 20]
    mov [sha_h + 24], eax              ; g = f
    mov eax, [sha_h + 16]
    mov [sha_h + 20], eax              ; f = e
    mov eax, [sha_h + 12]
    add eax, r8d
    mov [sha_h + 16], eax              ; e = d + T1
    mov eax, [sha_h + 8]
    mov [sha_h + 12], eax              ; d = c
    mov eax, [sha_h + 4]
    mov [sha_h + 8], eax               ; c = b
    mov eax, [sha_h + 0]
    mov [sha_h + 4], eax               ; b = a
    mov eax, r8d
    add eax, r9d
    mov [sha_h + 0], eax               ; a = T1 + T2
    inc ecx
    cmp ecx, 64
    jb .round
    ; feed-forward：H(i+1) = H(i) + rounds(H(i), block)，而 H(i) 就是刚才存下的 sha_h0。
    ; 每个块各做一次 —— 只在最后做一次的话，单块的消息恰好等价，两块起就全错，
    ; 而那种错法与「压缩函数写错」在串口上分不开。
    mov eax, [sha_h0 + 0]
    add [sha_h + 0], eax
    mov eax, [sha_h0 + 4]
    add [sha_h + 4], eax
    mov eax, [sha_h0 + 8]
    add [sha_h + 8], eax
    mov eax, [sha_h0 + 12]
    add [sha_h + 12], eax
    mov eax, [sha_h0 + 16]
    add [sha_h + 16], eax
    mov eax, [sha_h0 + 20]
    add [sha_h + 20], eax
    mov eax, [sha_h0 + 24]
    add [sha_h + 24], eax
    mov eax, [sha_h0 + 28]
    add [sha_h + 28], eax
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ======================================================================
; SHA-512
; ======================================================================
;
; 为什么它是另一份实现而不是那一份的参数化：Ed25519 的消息哈希是 SHA-512（RFC 8032
; 第 5.1 节），第二环用的是 SHA-256。两者的字长、轮数、常量表、补齐的长度字段全不
; 一样，合成一份的代价是每个地方都多一个「这一版是哪一个」的参数，而它的错法仍然是
; 同一个症状「哈希不对」—— 那时反而多一层分不清。两份各配一个判据，错了立刻分得出。
;
; 与 SHA-256 那一份的三处实差，写在这里免得对着两段代码找：
;   一、字是 64 位，所以轮函数里那些 ror 的移位量不同（Σ0 28/34/39、Σ1 14/18/41、
;      σ0 1/8/7、σ1 19/61/6 —— 注意不能沿用 32 位那一套）。
;   二、块是 128 字节，W 有 80 项而不是 64。
;   三、补齐末尾是 128 位长度字段（16 字节），只是这一台机器上的消息长度远小于 2^64
;      位，所以高 8 字节永远是零，只有低 8 字节要写。
;
; rdi = 数据，rcx = 字节数。出 [sha512_out] 的 64 字节，大端。
sha512:
    push rbx
    push rsi
    push rdi
    push r8
    push r9
    cld
    mov [sha512_ptr], rdi
    mov [sha512_len], rcx
    mov rax, 0x6a09e667f3bcc908
    mov [sha512_h + 0], rax
    mov rax, 0xbb67ae8584caa73b
    mov [sha512_h + 8], rax
    mov rax, 0x3c6ef372fe94f82b
    mov [sha512_h + 16], rax
    mov rax, 0xa54ff53a5f1d36f1
    mov [sha512_h + 24], rax
    mov rax, 0x510e527fade682d1
    mov [sha512_h + 32], rax
    mov rax, 0x9b05688c2b3e6c1f
    mov [sha512_h + 40], rax
    mov rax, 0x1f83d9abfb41bd6b
    mov [sha512_h + 48], rax
    mov rax, 0x5be0cd19137e2179
    mov [sha512_h + 56], rax
    xor r8, r8                     ; 已经处理了多少字节
.full:
    mov rax, [sha512_len]
    sub rax, r8
    cmp rax, 128
    jb .tail
    mov rdi, [sha512_ptr]
    add rdi, r8
    call sha512_block
    add r8, 128
    jmp .full
.tail:
    lea rdi, [sha512_pad]
    xor eax, eax
    mov ecx, 32                    ; 256 字节 = 32 个 qword
    rep stosq
    mov rsi, [sha512_ptr]
    add rsi, r8
    mov rcx, [sha512_len]
    sub rcx, r8
    mov r9, rcx                    ; 剩下几个字节
    lea rdi, [sha512_pad]
    rep movsb
    mov byte [sha512_pad + r9], 0x80
    mov rax, [sha512_len]
    shl rax, 3                     ; 总长按位算
    bswap rax
    cmp r9, 112
    jb .one
    ; 剩下 112 到 127 字节：长度装不进同一块，所以要补两块。
    ;
    ; 那个 248 不是 240。SHA-512 的长度字段是 128 位（16 字节），落在块内偏移
    ; 112 到 127；这一台机器上的消息长度远小于 2^64 位，所以高 8 字节恒为零、只有低
    ; 8 字节要写 —— 而低 8 字节的位置是 120，不是 112。写成 112 的症状很整齐：空消息
    ; 的长度是 0，写哪都一样，于是只有 len=0 对，其余五个长度全错，看起来像搬运错。
    mov [sha512_pad + 248], rax
    lea rdi, [sha512_pad]
    call sha512_block
    lea rdi, [sha512_pad + 128]
    call sha512_block
    jmp .out
.one:
    mov [sha512_pad + 120], rax
    lea rdi, [sha512_pad]
    call sha512_block
.out:
    ; 加回初值那一次加法**在 sha512_block 的尾部**，每个块各做一次，加的是那个块开始
    ; 时的状态。这里只剩输出 —— 写成「只在最后加一次初值」的话，单块的消息恰好等价，
    ; 两块起就全错，而 SHA-256 那一份正是这样错了一整轮。
    lea rsi, [sha512_h]
    lea rdi, [sha512_out]
    mov ecx, 8
.emit:
    mov rax, [rsi]
    bswap rax
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz .emit
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbx
    ret

; 一个 128 字节块。rdi = 块地址。
;
; 与 SHA-256 那一份同一个取舍：逻辑函数就地展开，不跳小函数 —— 那一个小跳会把 rcx
; （轮次）用掉，而它是整个循环里唯一不能丢的东西。
sha512_block:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    ; W[0..15]：从大端读进来
    xor ecx, ecx
.load:
    mov rax, [rdi + rcx * 8]
    bswap rax
    mov [sha512_w + rcx * 8], rax
    inc ecx
    cmp ecx, 16
    jb .load
    ; W[16..79] = σ1(W[t-2]) + W[t-7] + σ0(W[t-15]) + W[t-16]
    mov ecx, 16
.expand:
    mov rax, [sha512_w + rcx * 8 - 16]   ; W[t-2]
    mov rbx, rax
    ror rax, 19
    ror rbx, 61
    xor rax, rbx
    mov rbx, [sha512_w + rcx * 8 - 16]
    shr rbx, 6
    xor rax, rbx                         ; σ1
    add rax, [sha512_w + rcx * 8 - 56]   ; + W[t-7]
    mov rbx, [sha512_w + rcx * 8 - 120]  ; W[t-15]
    mov rdx, rbx
    ror rbx, 1
    ror rdx, 8
    xor rbx, rdx
    mov rdx, [sha512_w + rcx * 8 - 120]
    shr rdx, 7
    xor rbx, rdx                         ; σ0
    add rax, rbx
    add rax, [sha512_w + rcx * 8 - 128]  ; + W[t-16]
    mov [sha512_w + rcx * 8], rax
    inc ecx
    cmp ecx, 80
    jb .expand
    ; 这一块的初值先存下来，交给尾部那一次 feed-forward。放在这里是因为 rep movsq
    ; 要吃 rdi，而 rdi 在整个 .load 里都是块地址 —— 到这里它已经用完了。
    lea rsi, [sha512_h]
    lea rdi, [sha512_h0]
    mov ecx, 8
    rep movsq
    ; 八十轮
    xor ecx, ecx
.round:
    ; T1 = h + Σ1(e) + Ch(e,f,g) + K[t] + W[t]
    mov rax, [sha512_h + 32]             ; e
    mov rbx, rax
    ror rax, 14
    ror rbx, 18
    xor rax, rbx
    mov rbx, [sha512_h + 32]
    ror rbx, 41
    xor rax, rbx                         ; Σ1(e)
    mov rbx, [sha512_h + 32]
    and rbx, [sha512_h + 40]             ; e & f
    mov rdx, [sha512_h + 32]
    not rdx
    and rdx, [sha512_h + 48]             ; ~e & g
    xor rbx, rdx                         ; Ch
    add rax, rbx
    add rax, [sha512_h + 56]             ; + h
    add rax, [sha512_k + rcx * 8]
    add rax, [sha512_w + rcx * 8]
    mov r8, rax                          ; T1
    ; T2 = Σ0(a) + Maj(a,b,c)
    mov rax, [sha512_h + 0]
    mov rbx, rax
    ror rax, 28
    ror rbx, 34
    xor rax, rbx
    mov rbx, [sha512_h + 0]
    ror rbx, 39
    xor rax, rbx                         ; Σ0(a)
    mov rbx, [sha512_h + 0]
    and rbx, [sha512_h + 8]
    mov rdx, [sha512_h + 0]
    and rdx, [sha512_h + 16]
    xor rbx, rdx
    mov rdx, [sha512_h + 8]
    and rdx, [sha512_h + 16]
    xor rbx, rdx                         ; Maj
    add rax, rbx
    mov r9, rax                          ; T2
    ; 移位。x86 没有内存到内存的 mov，所以一律经由 rax —— 而 T1/T2 在 r8/r9 里，
    ; 这两个寄存器在这一段里不能碰。
    mov rax, [sha512_h + 48]
    mov [sha512_h + 56], rax             ; h = g
    mov rax, [sha512_h + 40]
    mov [sha512_h + 48], rax             ; g = f
    mov rax, [sha512_h + 32]
    mov [sha512_h + 40], rax             ; f = e
    mov rax, [sha512_h + 24]
    add rax, r8
    mov [sha512_h + 32], rax             ; e = d + T1
    mov rax, [sha512_h + 16]
    mov [sha512_h + 24], rax             ; d = c
    mov rax, [sha512_h + 8]
    mov [sha512_h + 16], rax             ; c = b
    mov rax, [sha512_h + 0]
    mov [sha512_h + 8], rax              ; b = a
    mov rax, r8
    add rax, r9
    mov [sha512_h + 0], rax              ; a = T1 + T2
    inc ecx
    cmp ecx, 80
    jb .round
    ; feed-forward：H(i+1) = H(i) + rounds(H(i), block)，H(i) 就是刚才存下的 sha512_h0。
    ; 每个块各做一次 —— 「只在最后加一次」对单块的消息恰好等价，两块起就全错。
    mov rax, [sha512_h0 + 0]
    add [sha512_h + 0], rax
    mov rax, [sha512_h0 + 8]
    add [sha512_h + 8], rax
    mov rax, [sha512_h0 + 16]
    add [sha512_h + 16], rax
    mov rax, [sha512_h0 + 24]
    add [sha512_h + 24], rax
    mov rax, [sha512_h0 + 32]
    add [sha512_h + 32], rax
    mov rax, [sha512_h0 + 40]
    add [sha512_h + 40], rax
    mov rax, [sha512_h0 + 48]
    add [sha512_h + 48], rax
    mov rax, [sha512_h0 + 56]
    add [sha512_h + 56], rax
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rdi = 字节串，rcx = 字节数。每字节两个十六进制字符（大写）。
;
; 判据用得上它：一个哈希对不对，只能与另一个地方算出来的同一个哈希比 —— 而那个地方
; 是主机上的 node。打十进制太短、打 base64 太绕，十六进制是唯一能一眼对照的形状。
put_hex_bytes:
    push rsi
    push rdi
    push rcx
.put:
    test rcx, rcx
    jz .done
    movzx eax, byte [rdi]
    push rax
    shr eax, 4
    call put_hex_digit
    pop rax
    and eax, 0x0F
    call put_hex_digit
    inc rdi
    dec rcx
    jmp .put
.done:
    pop rcx
    pop rdi
    pop rsi
    ret
put_hex_digit:
    cmp al, 10
    jb .num
    add al, 'A' - 10
    jmp putc64
.num:
    add al, '0'
    jmp putc64

; ======================================================================
; 系统保护的第二层：核心清单与校验和
; ======================================================================
;
; 第一层（只读位）在盘上、跟着文件走；这一层在系统里 —— 换一块盘插过来，清单还在。
; 清单是盘上的一个文件 core.bin，二进制：u32 项数，然后每项 u8 名字长、名字 ASCII、
; u32 FNV-1a。二进制而不是文本，是因为解析十六进制 ASCII 是白多做一步。
;
; 判据两条，而第二条是这一层的全部价值：
;   一、不改盘时，三项全部对上；
;   二、把盘上 hello.txt 的首字节翻一位（build --break），而清单仍按原内容算 ——
;      校验必须红，并且点出是哪一个名字。
; 少了第二条，一个「永远报 ok」的实现也能过第一条。
run_core_test:
    mov rdi, fs_core_path
    call fs_open_path
    test rax, rax
    jz .nomanifest
    mov rsi, [last_addr]
    mov eax, [rsi]                 ; 项数
    mov [core_left], rax
    add rsi, 4
    mov [core_ptr], rsi
    mov qword [core_bad], 0
    mov qword [core_n], 0
.one:
    cmp qword [core_left], 0
    je .report
    mov rsi, [core_ptr]
    movzx ecx, byte [rsi]          ; 名字长（ASCII 字节数）
    mov [core_namelen], rcx
    inc rsi
    ; 拼路径：α:/ 三个码元，然后名字逐字节扩成码元
    lea rdi, [core_path]
    mov word [rdi], 0x03B1
    mov word [rdi + 2], 0x003A
    mov word [rdi + 4], 0x002F
    add rdi, 6
    xor rdx, rdx
.copy:
    cmp rdx, [core_namelen]
    jae .copied
    movzx eax, byte [rsi + rdx]
    mov [rdi + rdx * 2], ax
    inc rdx
    jmp .copy
.copied:
    mov word [rdi + rdx * 2], 0
    ; 清单项的 hash 在名字之后，而游标要在这里一次推到位 ——
    ; 下面那个 fs_open_path 会把 last_addr 覆盖掉，拿它当游标就丢了位置。
    lea rax, [rsi + rdx]
    mov eax, [rax]
    mov [core_hash], rax
    lea rax, [rsi + rdx + 4]
    mov [core_ptr], rax
    dec qword [core_left]
    lea rdi, [core_path]
    call fs_open_path
    test rax, rax
    jz .missing
    mov rdi, [last_addr]
    mov rcx, rbx
    call fnv1a
    cmp eax, dword [core_hash]
    jne .mismatch
    inc qword [core_n]
    jmp .one
.mismatch:
    inc qword [core_bad]
    mov rsi, line_core_bad
    call puts64
    lea rdi, [core_path + 6]       ; 跳过 α:/ 三个码元
    call put_utf16_ascii
    call put_nl64
    jmp .one
.missing:
    inc qword [core_bad]
    mov rsi, line_core_missing
    call puts64
    lea rdi, [core_path + 6]
    call put_utf16_ascii
    call put_nl64
    jmp .one
.report:
    mov rsi, line_core_ok
    call puts64
    mov rax, [core_n]
    call put_num64
    mov al, ' '
    call putc64
    mov rax, [core_bad]
    call put_num64
    call put_nl64
    ; 有缺先试着自己修，修不了才摆补完界面。
    ;
    ; 顺序本身就是判据：能修的那一趟不该看见那个界面。它回答的是「现在修不了」，
    ; 而一台能自己修好的机器不该被问那个问题。
    cmp qword [core_bad], 0
    je .clean
    call run_repair_patch
    cmp qword [core_bad], 0
    je .repaired
    call run_repair_screen
    jmp .clean
.repaired:
    ; 修好了，重新数一遍再报一次。
    ;
    ; 上面那一行说的是修补**之前**的状态（缺一条），而判据要的是现在的状态。两行都
    ; 留在串口上，读的人才看得出来「修之前是几条、修之后是几条」—— 只报后一行的话，
    ; 「本来就全对」与「修好了」在串口上长得一样。
    mov rsi, line_core_ok
    call puts64
    mov rax, [core_n]
    call put_num64
    mov al, ' '
    call putc64
    mov rax, [core_bad]
    call put_num64
    call put_nl64
.clean:
    ret
.nomanifest:
    mov rsi, line_core_nocore
    call puts64
    ret

; ======================================================================
; 补丁包：按名字找一项
; ======================================================================
;
; 形状（YUNOPAT，从信箱盘第 1 个扇区起）：魔数八字节、u32 项数；然后每项
; u16 名字长（码元数）、名字 UTF-16、u32 字节数、内容。项与项之间不补齐 ——
; 补位是给「按下标取数组」的实现省事的，而这里从头到尾是顺读。
;
; 为什么按名字找、不按清单的顺序对：补丁只该带「真的缺了的那几条」，而清单的顺序与
; 补丁的顺序不该被绑在一起。绑了之后清单里加一项就会让补丁那一份错位，而错位的症状
; 是「补丁里有它，写进去的却是别人的字节」—— 那是把一份好的东西悄悄换成坏的。
;
; rdi = 要找的名字（UTF-16，0 码元结尾）。出 rax = 1 找到 / 0 没有。
;    找到时 [pat_data] 是内容地址、[pat_len] 是字节数。
patch_find:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, 0x5020C               ; 第一个项：0x50200 + 8（魔数）+ 4（项数）
    mov r14d, [0x50200 + 8]        ; 项数
.one:
    test r14, r14
    jz .miss
    cmp r13, 0x50800               ; 读进来的上界。越界就当没有 —— 补丁写到读进来之后再
    jae .miss                      ; 的那些字节是别的什么，不是这一份补丁的项
    movzx r15d, word [r13]         ; 这一项的名字长
    lea rbx, [r13 + 2]             ; 名字起点
    xor rdx, rdx
.cmp:
    cmp rdx, r15
    jae .tail
    mov ax, [rbx + rdx * 2]
    cmp ax, [r12 + rdx * 2]
    jne .next
    inc rdx
    jmp .cmp
.tail:
    cmp word [r12 + r15 * 2], 0    ; 要找的名字也要在同一处结束，才算同名
    jne .next
    lea rax, [rbx + r15 * 2]
    mov ecx, [rax]                 ; 字节数
    mov [pat_len], rcx
    add rax, 4
    mov [pat_data], rax
    mov rax, 1
    jmp .done
.next:
    lea r13, [rbx + r15 * 2]
    mov eax, [r13]                 ; 跳过这一项的内容
    lea r13, [r13 + 4 + rax]
    dec r14
    jmp .one
.miss:
    xor eax, eax
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ======================================================================
; 修补：从补丁包把缺的那几条搬回来
; ======================================================================
;
; 位置很要紧：这一步在「查到有缺」之后、在补完界面之前。也就是说 —— 能修的时候
; 不该看见补完界面。那个界面是「修不了」的地方，不是每次启动都路过的地方。
; 放在这里，两条判据就自然分开了：有补丁的那一趟没有 event=guard.entry，
; 没有补丁的那一趟有。
;
; 三道门，每一道都必要：
;   一、补丁里要有这一条（按名字找）。没有就跳过 —— 一条补丁修一条，不猜。
;   二、补丁给的那份字节算出的哈希要与清单里记的一致。这是整块砖的门：补丁包不是
;       「随便什么字节都能写进去」，它只能把文件恢复成清单记的那一份。少了它，
;       这条通道就成了「谁写得了信箱盘，谁就改得动核心文件」。
;   三、写完再从盘上读回来重算一次。读不到或对不上都不算修好 —— 报 fixed 而不报
;       verified，就是把「写了」当成了「写对了」，而那正是这一层要防的东西。
;
; 进的时候 [core_bad] 非零，出来的时候它可能变成零 —— 那是「修好了」唯一的凭据。
run_repair_patch:
    mov rdi, 0x50200
    mov rsi, pat_magic
    mov rcx, 8
    call bytes_eq
    jc .nopatch                    ; 魔数不对 = 这一趟没带补丁。不是错，只是修不了
    ; 清单重新读一遍。run_core_test 的游标已经走到头了，复用它会读到空清单，
    ; 于是「一条都没缺」—— 那正好是这一层最怕的那种假绿。
    mov rdi, fs_core_path
    call fs_open_path
    test rax, rax
    jz .nopatch
    mov rsi, [last_addr]
    mov eax, [rsi]
    mov [core_left], rax
    add rsi, 4
    mov [core_ptr], rsi
    mov qword [rep_fixed], 0
    mov qword [rep_verified], 0
    mov qword [rep_refused], 0
.one:
    cmp qword [core_left], 0
    je .report
    mov rsi, [core_ptr]
    movzx ecx, byte [rsi]          ; 名字长（ASCII 字节数）
    mov [core_namelen], rcx
    inc rsi
    lea rdi, [core_path]
    mov word [rdi], 0x03B1
    mov word [rdi + 2], 0x003A
    mov word [rdi + 4], 0x002F
    add rdi, 6
    xor rdx, rdx
.copy:
    cmp rdx, [core_namelen]
    jae .copied
    movzx eax, byte [rsi + rdx]
    mov [rdi + rdx * 2], ax
    inc rdx
    jmp .copy
.copied:
    mov word [rdi + rdx * 2], 0
    ; 游标一次推到位：下面那次 fs_open_path 会把 last_addr 覆盖掉。
    lea rax, [rsi + rdx]
    mov eax, [rax]
    mov [core_hash], rax
    lea rax, [rsi + rdx + 4]
    mov [core_ptr], rax
    dec qword [core_left]
    ; 这一项现在好不好？好就跳过 —— 补丁不覆盖好的那一份。
    lea rdi, [core_path]
    call fs_open_path
    test rax, rax
    jz .try
    mov rdi, [last_addr]
    mov rcx, rbx
    call fnv1a
    cmp eax, dword [core_hash]
    je .one
.try:
    lea rdi, [core_path + 6]       ; 跳过 α:/ 三个码元：名字部分
    call patch_find
    test rax, rax
    jz .one                        ; 补丁里没有这一条：修不了，留给补完界面说
    ; 第二道门：补丁给的字节与清单要一致。不一致就拒绝，并且说得出是哪一个名字。
    mov rdi, [pat_data]
    mov rcx, [pat_len]
    call fnv1a
    cmp eax, dword [core_hash]
    jne .refuse
    lea rdi, [core_path + 6]
    mov rsi, [pat_data]
    mov rcx, [pat_len]
    call fs_write_file
    test rax, rax
    jz .one                        ; 写不进去（同名的带只读位，或目录满了）
    ; 第三道门：从盘上读回来再算一次。它与 run_core_test 走同一条路
    ; （fs_open_path + fnv1a），所以证的是「现在这一份与清单一致」，
    ; 而不是「我刚拷进去的东西我记得是对的」。
    lea rdi, [core_path]
    call fs_open_path
    test rax, rax
    jz .one
    mov rdi, [last_addr]
    mov rcx, rbx
    call fnv1a
    cmp eax, dword [core_hash]
    jne .one
    inc qword [rep_verified]
    inc qword [rep_fixed]
    dec qword [core_bad]           ; 这一条不再是「缺的」
    inc qword [core_n]
    jmp .one
.refuse:
    inc qword [rep_refused]
    mov rsi, line_repair_refused
    call puts64
    lea rdi, [core_path + 6]
    call put_utf16_ascii
    call put_nl64
    jmp .one
.report:
    mov rsi, line_repair_fixed
    call puts64
    mov rax, [rep_fixed]
    call put_num64
    mov rsi, line_repair_verified
    call puts64
    mov rax, [rep_verified]
    call put_num64
    mov rsi, line_repair_refused_n
    call puts64
    mov rax, [rep_refused]
    call put_num64
    call put_nl64
    ret
.nopatch:
    mov rsi, line_repair_nopatch
    call puts64
    ret

; ======================================================================
; OnlySign 的第二环：SHA-256 清单
; ======================================================================
;
; 设计在 design/SIGN.txt。它回答的问题与 run_core_test 不同：那一条说「文件与清单是否
; 一致」，这一条说「清单自己有没有被动过」。
;
; 它唯一的理由是这个场景：有人改了盘上的 hello.txt，**并且**把 core.bin 里那一条的
; FNV-1a 也重算对了。run_core_test 看到的是它自己那份清单，于是它报 3 0 —— 绿的。
; 而这一条按 sign.bin 里那份 SHA-256 比，红，并且点出名字。
; build 的 --forge 造的正是这个处境，而它是这一条唯一的验红手段。
;
; 三条读数分开：ok（逐项一致）、bad（点出名字）、nosign（盘上没有 sign.bin）。
; 第三条不是「验过了」，是「没东西可验」—— 那两件事在串口上必须不一样，否则一台
; 没有清单的机器与一台清单全对的机器长得一样。
run_sign_test:
    mov rdi, fs_sign_path
    call fs_open_path
    test rax, rax
    jz .nosign
    mov rdi, [last_addr]
    mov rsi, sign_magic
    mov rcx, 8
    call bytes_eq
    jc .nomagic
    mov rsi, [last_addr]
    mov eax, [rsi + 12]            ; 项数
    mov [sign_left], rax
    mov qword [sign_n], 0
    mov qword [sign_bad], 0
    mov qword [sign_dbg], 0
    add rsi, 16                    ; 第一项
    mov [sign_ptr], rsi
.one:
    cmp qword [sign_left], 0
    je .report
    mov rsi, [sign_ptr]
    movzx ecx, byte [rsi]          ; 名字长（ASCII 字节数）
    mov [sign_namelen], rcx
    inc rsi
    ; 拼路径 α:/名字。这一段的游标要一次推到位：下面 fs_open_path 会覆盖 last_addr。
    lea rdi, [sign_path]
    mov word [rdi], 0x03B1
    mov word [rdi + 2], 0x003A
    mov word [rdi + 4], 0x002F
    add rdi, 6
    xor rdx, rdx
.copy:
    cmp rdx, [sign_namelen]
    jae .copied
    movzx eax, byte [rsi + rdx]
    mov [rdi + rdx * 2], ax
    inc rdx
    jmp .copy
.copied:
    mov word [rdi + rdx * 2], 0
    lea rax, [rsi + rdx]
    mov [sign_hash_ptr], rax       ; 32 字节 SHA-256 就在名字之后
    lea rax, [rsi + rdx + 32]
    mov [sign_ptr], rax
    dec qword [sign_left]
    ; 算盘上那份的 SHA-256，与清单里的比
    lea rdi, [sign_path]
    call fs_open_path
    test rax, rax
    jz .missing
    mov rdi, [last_addr]
    mov [sign_filelen], rbx        ; 长度先存下来：下面几个打印都会把 rbx 用掉
    mov rcx, rbx
    call sha256
    ; 每一项都打一行：名字、长度、摘要的前八个字节。
    ;
    ; 为什么不是只打第一项（原来就是这样）：清单里前三项都短于 64 字节，于是那段打印
    ; 一直在给「一块」的路径作证，而「两块」从来没有被打出来过。一个只在短输入上被看过
    ; 的哈希，看着是绿的。八字节足够与主机对，又比整份摘要短一半。
    mov rsi, line_sign_item
    call puts64
    lea rdi, [sign_path + 6]
    call put_utf16_ascii
    mov rsi, line_sign_len
    call puts64
    mov rax, [sign_filelen]
    call put_num64
    mov rsi, line_sign_sha8
    call puts64
    lea rdi, [sha_out]
    mov rcx, 8
    call put_hex_bytes
    call put_nl64
.nodb:
    lea rdi, [sha_out]
    mov rsi, [sign_hash_ptr]
    mov rcx, 32
    call bytes_eq
    jc .mismatch
    inc qword [sign_n]
    jmp .one
.mismatch:
    inc qword [sign_bad]
    mov rsi, line_sign_bad
    call puts64
    lea rdi, [sign_path + 6]
    call put_utf16_ascii
    call put_nl64
    jmp .one
.missing:
    inc qword [sign_bad]
    mov rsi, line_sign_bad
    call puts64
    lea rdi, [sign_path + 6]
    call put_utf16_ascii
    call put_nl64
    jmp .one
.report:
    cmp qword [sign_bad], 0
    je .clean
    ; 名字已经由 bad 那几行点过了，这里只报坏几条 —— 「哪一条」与「几条」是两件事。
    mov rsi, line_sign_bad_n
    call puts64
    mov rax, [sign_bad]
    call put_num64
    call put_nl64
    ret
.clean:
    mov rsi, line_sign_ok
    call puts64
    mov rax, [sign_n]
    call put_num64
    call put_nl64
    ret
.nomagic:
    mov rsi, line_sign_nomagic
    call puts64
    ret
.nosign:
    mov rsi, line_sign_nosign
    call puts64
    ret

; ======================================================================
; 第三环：sign.bin 自己也被签过
; ======================================================================
;
; 前两环都在「盘上有一份清单」这个层面：core.bin 说文件与清单是否一致，sign.bin 说
; 清单自己有没有被动过。而 sign.bin 本身也会被一起重算 —— 下决心的人可以把两份一起
; 改对。第三环挡的是这一手：auth.bin 里是对 sign.bin 内容的 Ed25519 签名。
;
; 公钥为什么不放盘上：放上去的话，改盘的人可以把公钥与签名一起换掉，而这一环就退化
; 成第二环。公钥内嵌在第二段里，要伪造就必须改第二段 —— 而第二段是从引导扇区读进来
; 的，那一路上没有清单可改。
;
; 两条判据缺一不可：
;   一、正常那一趟必须通过 —— 否则这一环只是把一切判死；
;   二、签名被改一位的那一趟必须红（build 的 --authbreak）—— 否则一个「永远通过」
;      的实现也是绿的，而它与真正的验签在正常那一趟上完全一样。
run_onlysign3_test:
    lea rdi, [sig_pk]
    lea rsi, [onlysign_pubkey]
    mov ecx, 8
    cld
    rep movsd

    mov rdi, fs_auth_path
    call fs_open_path
    test rax, rax
    jz .noauth
    mov rcx, rbx
    cmp rcx, 64
    jne .badsig
    mov rsi, [last_addr]
    lea rdi, [sig_sig]
    cld
    rep movsb

    mov rdi, fs_sign_path
    call fs_open_path
    test rax, rax
    jz .nolist
    mov [sig_msglen], rbx
    mov rsi, [last_addr]
    lea rdi, [sig_msg]
    mov rcx, rbx
    cld
    rep movsb

    call pt_verify
    test rax, rax
    jz .bad
    mov rsi, line_onlysign3_ok
    call puts64
    ret
.bad:
    ; where 是验签自己报的「走到第几步」。它在正常那一趟没有意义，而在红的那一趟
    ; 是唯一的线索 —— 没有它，一个「签名不对」可以是链上任何一层的意思。
    mov rsi, line_onlysign3_bad
    call puts64
    mov rax, [sig_where]
    call put_num64
    call put_nl64
    ret
.noauth:
    ; 缺件也进补完界面。
    ;
    ; 在那之前，这一环在缺 auth.bin 时只打一行 noauth 就过去了 —— 而补完界面回答的正是
    ; 「现在修不了，缺什么」，auth.bin 缺了是那个问题的一种。让它进同一个界面，缺件的
    ; 清单就只剩一处（core_bad），而不是「核心三条一处、签名一条另一处」。
    ;
    ; 这里直接写 core_bad 而不是去问 core.bin：补完界面只用那个数报「缺几条」，而
    ; core.bin 那一趟已经在前面跑过、已经打过它自己的读数了。改这个数不会让串口上
    ; 「几条」变成假话 —— 它是这一环自己的计数，而这一环缺的是一条。
    mov qword [core_bad], 1
    call run_repair_screen
    mov rsi, line_onlysign3_noauth
    call puts64
    ret
.badsig:
    mov rsi, line_onlysign3_badsig
    call puts64
    ret
.nolist:
    mov rsi, line_onlysign3_nolist
    call puts64
    ret

; ======================================================================
; SHA-512 的判据
; ======================================================================
;
; 为什么它要在验签之前有自己的判据：验签的最后一步是「让两个哈希相等」，而其中一个是
; SHA-512 算的。哈希本身错了，验签就报「签名不对」—— 与「签名真的不对」在串口上
; 一模一样，而后者是这一层要报的那件事。所以这一块的判据不是「验签通过」，是「与主机
; 上 node 算的同一个值逐字符相同」：串口打出来，run.mjs 拿同样的字节自己算一遍去对。
;
; 为什么六个长度而不是一个：补齐是这一块里唯一分岔的地方，而它分成四种处境 ——
; 余下不足 112 字节（一块就够）、正好 112 到 127 字节（要补两块）、正好一整块、
; 以及空消息。只打一个长度最多碰到其中一种，剩下三种坏了也看不见。
run_sha512_test:
    ; 判据用的字节串：第 i 字节 = i & 0xFF。内容不取盘上任何文件 —— 这一条要验的是
    ; 这个函数，把「盘读得对不对」混进来，两边一起错的时候就分不出是谁错。
    lea rdi, [sha512_bt]
    xor ecx, ecx
.fill:
    mov eax, ecx
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, 256
    jb .fill
    xor rsi, rsi
.next:
    mov rcx, [sha512_lens + rsi * 8]
    cmp rcx, -1                    ; 结束标记
    je .done
    push rsi
    push rcx
    lea rdi, [sha512_bt]
    call sha512
    mov rsi, line_sha512
    call puts64
    mov rax, [rsp]                 ; 栈顶是刚压进去的长度
    call put_num64
    mov rsi, line_sha512_hex
    call puts64
    lea rdi, [sha512_out]
    mov rcx, 64
    call put_hex_bytes
    call put_nl64
    pop rcx
    pop rsi
    inc rsi
    jmp .next
.done:
    ret

; ======================================================================
; 补完界面的骨架
; ======================================================================
;
; 它只做三件事，而三件事各自有判据：
;   一、屏幕上画出来 —— 与正常启动的画面不同，而判据读的是两个位置的颜色，
;      不是「看起来像」。
;   二、串口说清缺几条 —— 一行结构化的，形状固定（event= 开头、键值对、顺序固定）。
;      这一行是 design/GUARD.txt 第六节那条「新写的事件行用固定形状」的第一个样本：
;      旧的散文（guard core 2 1）不动，因为判据已经与它绑在一起了。
;   三、说明从哪来 —— repair=mailbox。这一版的修补通道是信箱盘（一块裸盘，主机写、
;      客人机读），不是网络；内置下载器排在 browser 那一条之后。
;
; 为什么先做骨架：补完这件事的难点不在「怎么修」，在「知道要修什么」—— 而后者正是
; 核心清单加校验和那一块已经做掉的东西。骨架把「知道了」与「说得出」接上；
; 真正去修（从信箱盘搬进来、重算、再校验一次）是下一块砖。
run_repair_screen:
    ; 屏幕清成暗青，而正常启动的桌面底色不是它 —— 一个像素就能分出两种处境。
    xor edi, edi
    xor esi, esi
    mov rdx, 320
    mov rcx, 200
    mov r8b, 0x0B
    call fill_rect
    ; 居中的窗口：边框、标题栏、内容区。三个原语都是 Kohane 第二层就有的，
    ; 而它们的判据也已经立过（读回四个位置的颜色）。
    mov rdi, 40
    mov rsi, 40
    mov rdx, 240
    mov rcx, 120
    mov r8b, 0x2F
    call draw_rect
    mov rdi, 41
    mov rsi, 41
    mov rdx, 238
    mov rcx, 14
    mov r8b, 0x1C
    call fill_rect
    mov rdi, 41
    mov rsi, 56
    mov rdx, 238
    mov rcx, 103
    mov r8b, 0x0F
    call fill_rect
    ; 串口那一行。缺几条与修补通道在同一个事件里，因为它们回答的是同一个问题：
    ; 「这台机器现在能不能自己修好，靠什么修」。
    mov rsi, line_repair_entry
    call puts64
    mov rax, [core_bad]
    call put_num64
    mov rsi, line_repair_where
    call puts64
    ret

; 写一次再读回来。判据是读到的内容 —— 「写了」这件事没有别的观测点。
run_fs_write:
    mov rdi, fs_write_name
    mov rsi, fs_write_data
    mov rcx, fs_write_len
    call fs_write_file
    test rax, rax
    jz fs_write_failed
    mov rdi, fs_write_path
    call fs_open_path
    test rax, rax
    jz fs_write_lost
    mov rsi, [last_addr]
    mov [fs_buf], rsi              ; 先存：下一句要拿 rsi 去打提示词
    mov rsi, line_fs_write
    call puts64
    mov rsi, [fs_buf]
    mov rcx, rbx
.put:
    test rcx, rcx
    jz .put_done
    mov al, [rsi]
    push rsi
    push rcx
    call putc64
    pop rcx
    pop rsi
    inc rsi
    dec rcx
    jmp .put
.put_done:
    call put_nl64
    ret
fs_write_failed:
    mov rsi, line_fs_write_fail
    call puts64
    ret
fs_write_lost:
    mov rsi, line_fs_write_lost
    call puts64
    ret

; ======================================================================
; 域算术 mod 2^255-19：第三环的地基
; ======================================================================
;
; 为什么这一层要有自己的判据，先于任何曲线代码：验签的最后一句话是「这两个点是不是
; 同一个点」，而点运算是域上的加、减、乘、平方堆出来的。乘法错一个肢体，验签就报
; 「签名不对」—— 与「签名真的是假的」在串口上一个样，而后者正是第三环要报的那件事。
; 一层一层都得先自己站稳，才轮到上面那层开始搭。
;
; 表示法：一个域元素是 8 个 32 位肢体，小端，每个肢体一个 dd。没有冗余位、没有延迟
; 约简 —— 每回乘法之后立刻归约成唯一表示。选它不是因为快，而是因为「每个中间量都
; 只有一个写法」：固件打出来的十六进制与主机 BigInt 打出来的可以逐字符比。带冗余
; 表示的实现里同一个数有好几种写法，对拍就从「比一比」变成「先解释再比」。
;
; 约简的全部依据只有一条：p = 2^255 - 19，所以 2^256 = 2 * 2^255 = 38 (mod p)。
; 一个 512 位的积 N 写成 L + H * 2^256，就等价于 L + 38 * H。折两次之后必然小于
; 2^256，再做一两次条件减 p 就落进 [0, p)。

; ----------------------------------------------------------------------
; fp_mul：fp_a × fp_b → fp_prod，16 个肢体，未约简。
;
; 内层是教科书式的「行扫描」：外层固定 a 的一个肢体，内层走 b 的八个肢体，进位在
; 同一条链上。每一格最多收 8 个 32x32 的积，加上进位，总和卡在 2^64 之内（最坏是
; (2^32-1)^2 + 2*(2^32-1) = 2^64 - 1，正好不溢出），所以一个 64 位寄存器就够装。
; ----------------------------------------------------------------------
fp_mul:
    push rdi
    push r8
    push r9
    push r10
    push r11

    lea rdi, [fp_prod]
    xor eax, eax
    mov ecx, 16
    cld
    rep stosd                       ; 积的十六格先清零

    xor r9d, r9d                    ; i
.outer:
    cmp r9d, 8
    jae .outer_done
    xor r11, r11                    ; 这一行的进位
    xor r10d, r10d                  ; j
.inner:
    cmp r10d, 8
    jae .inner_done
    mov eax, [fp_a + r9 * 4]
    mul dword [fp_b + r10 * 4]      ; edx:eax = a[i] * b[j]
    shl rdx, 32
    or  rax, rdx                    ; rax = 完整的 64 位积
    lea r8, [r9 + r10]
    mov ecx, [fp_prod + r8 * 4]
    add rax, rcx                    ; 加这一格已有的部分和
    add rax, r11                    ; 加上一位来的进位
    mov [fp_prod + r8 * 4], eax
    shr rax, 32
    mov r11, rax
    inc r10d
    jmp .inner
.inner_done:
    lea r8, [r9 + 8]
    mov [fp_prod + r8 * 4], r11d    ; 这一行最后一次进位落到下一格
    inc r9d
    jmp .outer
.outer_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    ret

; ----------------------------------------------------------------------
; fp_copy：rdi 目的，rsi 源，八格。
fp_copy:
    push rcx
    push rsi
    push rdi
    mov ecx, 8
    cld
    rep movsd
    pop rdi
    pop rsi
    pop rcx
    ret

; ----------------------------------------------------------------------
; fp_add：fp_out = fp_a + fp_b mod p
;
; 进位靠 CF 传，所以循环里不许碰 CF：mov、adc、inc、dec、jnz 都不碰它。这条不是
; 装饰 —— fp_condsub 那条链上原本有一个 cmp，它把 CF 盖掉，五个向量照旧对、一个错。
;
; 两个都小于 p 的数相加小于 2p，而 2p = 2^256 - 38 还没越过 2^256，所以八格的加法
; 不会产生第九格的进位。这一点决定了这里不必处理溢出的高位，只须条件减一次。
fp_add:
    push rcx
    push rdx
    push r8
    clc
    xor ecx, ecx
    mov r8d, 8
.loop:
    mov eax, [fp_a + rcx * 4]
    adc eax, [fp_b + rcx * 4]
    mov [fp_out + rcx * 4], eax
    inc ecx
    dec r8d
    jnz .loop
    lea rdi, [fp_out]
    call fp_condsub
    test rax, rax
    jz .out
    call fp_condsub                 ; 和小于 2p，所以第二次一定不减；留着是为了不依赖那句推理
.out:
    pop r8
    pop rdx
    pop rcx
    ret

; ----------------------------------------------------------------------
; fp_sub：fp_out = fp_a - fp_b mod p
;
; a 大于等于 b 就直接减。a 小于 b 时第一次减法留下借位，八格里装的是 a - b + 2^256；
; 再加 p 就把它折回 a - b + p，而加 p 自己在第九格产生的那一份溢出正好抵掉借位 ——
; 所以结果落在 [0, p)，不必再条件减。
fp_sub:
    push rcx
    push rdx
    push r8
    clc
    xor ecx, ecx
    mov r8d, 8
.loop:
    mov eax, [fp_a + rcx * 4]
    sbb eax, [fp_b + rcx * 4]
    mov [fp_out + rcx * 4], eax
    inc ecx
    dec r8d
    jnz .loop
    jnc .out                        ; 没有借位，a 本来就不小于 b
    clc
    xor ecx, ecx
    mov r8d, 8
.addp:
    mov eax, [fp_out + rcx * 4]
    adc eax, [fp_p + rcx * 4]
    mov [fp_out + rcx * 4], eax
    inc ecx
    dec r8d
    jnz .addp
.out:
    pop r8
    pop rdx
    pop rcx
    ret

; ----------------------------------------------------------------------
; fp_condsub：rdi 指的八格若大于等于 p 就减掉 p。出 rax = 1 表示减了。
;
; 从最高肢体往下比，找到第一个不同的肢体就定了大小 —— 与手算多位数比大小一样。
; ----------------------------------------------------------------------
fp_condsub:
    push rdi
    push rcx
    push rdx
    push r8
    mov ecx, 7
.cmp:
    mov eax, [rdi + rcx * 4]
    mov edx, [fp_p + rcx * 4]
    cmp eax, edx
    ja  .sub
    jb  .nosub
    dec ecx
    jns .cmp
.sub:
    ; 减法链靠 CF 传借位，所以循环里一个字都不许碰 CF。
    ;
    ; 这里原来写的是 inc ecx / cmp ecx, 8 / jb —— 而 cmp 会覆盖 CF：ecx 小于 8 时它
    ; 恒设 CF=1，于是除第一位以外每一位都白借一个。症状极隐蔽：(p-1)^2 约简之后是
    ; 2^255-18，减 p 该得 1，被白借之后变成一个大于等于 p 的数，于是又被减一次，
    ; 落到 0x14 ... 7FFFFFFF。六组向量里只有这一组需要连续借位，也只红了这一组。
    ; 而 inc 与 dec 都不动 CF，所以计数改用倒数。
    clc
    xor ecx, ecx
    mov r8d, 8
.subloop:
    mov eax, [rdi + rcx * 4]
    sbb eax, [fp_p + rcx * 4]
    mov [rdi + rcx * 4], eax
    inc ecx
    dec r8d
    jnz .subloop
    mov eax, 1
    jmp .out
.nosub:
    xor eax, eax
.out:
    pop r8
    pop rdx
    pop rcx
    pop rdi
    ret

; ----------------------------------------------------------------------
; fp_reduce：fp_prod（16 格）→ fp_out（8 格，落进 [0, p)）
;
; 折两轮。第一轮把高 256 位乘 38 加进低 256 位；那一轮自己会产生一个溢出（至多几百），
; 第二轮把它再乘 38 折回来。第二轮之后剩下的溢出小到不会让任何一格再进位，所以第三
; 轮只是把那个小数加到最低格上，用一条短的进位传播收尾。
; ----------------------------------------------------------------------
fp_reduce:
    push rdi
    push rcx
    push rdx
    push r8
    push r9
    push r11
    push r12

    xor r11, r11
    xor r9d, r9d
.round1:
    mov edx, 38
    mov eax, [fp_prod + 32 + r9 * 4]
    mul edx                         ; edx:eax = 38 * prod[8+i]
    shl rdx, 32
    or  rax, rdx
    mov ecx, [fp_prod + r9 * 4]
    add rax, rcx
    add rax, r11
    mov [fp_out + r9 * 4], eax
    shr rax, 32
    mov r11, rax
    inc r9d
    cmp r9d, 8
    jb .round1

    imul r12, r11, 38               ; 第一轮的溢出，乘 38 之后只剩一个很小的数
    xor r11, r11
    xor r9d, r9d
.round2:
    mov rax, r12
    xor r12, r12                    ; 只有第一次带值，之后是零
    mov ecx, [fp_out + r9 * 4]
    add rax, rcx
    add rax, r11
    mov [fp_out + r9 * 4], eax
    shr rax, 32
    mov r11, rax
    inc r9d
    cmp r9d, 8
    jb .round2

    test r11, r11                   ; 第二轮的溢出
    jz  .cond
    imul rax, r11, 38
    xor r9d, r9d
.round3:
    test rax, rax
    jz  .cond
    mov ecx, [fp_out + r9 * 4]
    add rax, rcx
    mov [fp_out + r9 * 4], eax
    shr rax, 32
    inc r9d
    cmp r9d, 8
    jb .round3

.cond:
    lea rdi, [fp_out]
    call fp_condsub
    test rax, rax
    jz .done
    call fp_condsub                 ; 最多两次：折完之后一定小于 2^256，而 2p 才越过它
.done:
    pop r12
    pop r11
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rdi
    ret

; ----------------------------------------------------------------------
; 域算术的判据
;
; 输出一组一行：左边是固件算的完整 32 字节。run.mjs 拿同样的输入用 BigInt 自己算
; 一遍，两份逐字符比。比的是完整的 32 字节而不是前八个 —— 约简出错时动的往往是高位，
; 而前八个字节在低端，正好看不见。
;
; 六组向量各压一种处境：乘一（最平静的）、乘小整数（看不出约简）、p-1 的平方（输入
; 最大而结果最小，(p-1)^2 = 1）、p-1 乘二、两个都大于 p 的数（专门压「输入不必先
; 约简」这一条）、以及基点的 x 乘 y（真实会走到的数）。
; ----------------------------------------------------------------------
fp_mulmod:
    call fp_mul
    call fp_reduce
    ret

run_fp_test:
    mov qword [fp_vec_i], 0
.loop:
    mov rax, [fp_vec_i]
    cmp rax, 6
    jae .report
    shl rax, 6                      ; 每组 64 字节
    lea rdx, [fp_vecs]
    add rdx, rax

    lea rdi, [fp_a]
    mov rsi, rdx
    mov ecx, 8
    cld
    rep movsd                       ; a
    lea rdi, [fp_b]
    mov ecx, 8
    cld
    rep movsd                       ; b，rsi 已经跟着前进了 32 字节

    call fp_mulmod

    mov rsi, line_fp_val
    call puts64
    lea rdi, [fp_out]
    mov rcx, 32
    call put_hex_bytes
    call put_nl64

    inc qword [fp_vec_i]
    jmp .loop
.report:
    mov rsi, line_fp_ok
    call puts64
    ret

; ----------------------------------------------------------------------
; 域加减的判据
;
; 六组，前三组加法、后三组减法。每一组都压一条边：
;
;   二加三          最平静的那一组，能过的实现很多
;   (p-1) 加二      和越过 p 一个 2，条件减必须减掉一次
;   (p-1) 加自己    和是 2p-2，离 2p 只差 38，也就是离「八格装不下」只差一步
;   二减三          借位路径：结果是 p-1，而中间量一度是 2^256-1
;   (p-1) 减自己    借位与条件减都不该发生，结果是零
;   零减一          最纯粹的借位：被减数整个是零，每一位都要往下借
;
; 中间那两条各管一件事：加法那一侧管「和越过 p」，减法那一侧管「不够减要加 p」。
; 少一条，另一条就有一半的路从来没人走过 —— 与 SHA-2 那个多块缺陷是同一个形状。
; ----------------------------------------------------------------------
run_fp2_test:
    mov qword [fp2_i], 0
.loop:
    mov rax, [fp2_i]
    cmp rax, 6
    jae .report
    shl rax, 6
    lea rdx, [fp2_vecs]
    add rdx, rax

    lea rdi, [fp_a]
    mov rsi, rdx
    mov ecx, 8
    cld
    rep movsd                       ; a
    lea rdi, [fp_b]
    mov ecx, 8
    cld
    rep movsd                       ; b

    cmp qword [fp2_i], 3
    jb .do_add
    call fp_sub
    mov rsi, line_fp2_sub
    jmp .show
.do_add:
    call fp_add
    mov rsi, line_fp2_add
.show:
    call puts64
    lea rdi, [fp_out]
    mov rcx, 32
    call put_hex_bytes
    call put_nl64

    inc qword [fp2_i]
    jmp .loop
.report:
    mov rsi, line_fp2_ok
    call puts64
    ret

; ======================================================================
; 点运算：扩展坐标上的加与双
; ======================================================================
;
; 坐标是 (X, Y, Z, T)，代表仿射点 (X/Z, Y/Z)，而 T = X*Y/Z。用扩展坐标而不是仿射，
; 是因为仿射的加法和倍点都要一次模逆，而模逆是 p-2 次方，比一次乘法贵三个数量级；
; 扩展坐标把除法推迟到最后一刻 —— 验签全程只在编码那一步做一次逆。
;
; 点加用统一公式（add-2008-hwcd-3 那一族），点倍用 dbl-2008-hwcd。两个公式给出的
; 投影表示不同：同一个点可以是 (X,Y,Z,T) 也可以是 (kX,kY,kZ,kT)，而这两套公式选的
; k 不一样。所以「两个点是不是同一个点」不能比坐标，要比交叉积（X1*Z2 == X2*Z1 且
; Y1*Z2 == Y2*Z1）—— 这一件事由主机那边做，因为四份坐标是它拿到的。

; FPOP 目的, 左, 右, 函数 —— 「左 操作 右，存进 目的」写成一行。
;
; 第四个参数是乘法时必须写 fp_mulmod，不能写 fp_mul。fp_mul 只把 512 位的积写进
; fp_prod，而 FPOP 拷出去的是 fp_out：用 fp_mul 的话拷到的是上一次运算留在 fp_out
; 里的那个值，于是乘法那一步静默地什么都没做，链上每一步都在拿上一步的结果当自己
; 算出来的。
;
; 这个错法的形状很难看。域乘法自己的六组判据用的是 fp_mulmod（乘完再约简），所以
; 它一直是绿的；加减那两步用的是 fp_add / fp_sub，它们直接写 fp_out，所以也是绿的；
; 只有点运算错，而它错成的样子是四份坐标全部相同 —— 因为它们拿到的是同一个旧值。
; 从「四格一样」倒推回「乘法没写 fp_out」花了很久，而从这个宏的定义到第一次跑，
; 中间没有任何一步会抱怨。
;
; 点加十二步、点倍十五步，每一步都是同一件事：两个操作数拷进 fp_a / fp_b、调一个域
; 函数、把 fp_out 拷出来。显式写出来是每步六条指令、二十来段几乎一样的代码，而复制
; 粘贴出来的错不会报错 —— 它只会算出一个别的点，然后在验签那一步报「签名不对」。
%macro FPOP 4
    lea rdi, [fp_a]
    lea rsi, [%2]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [%3]
    call fp_copy
    call %4
    lea rdi, [%1]
    lea rsi, [fp_out]
    call fp_copy
%endmacro

; pt_copy：rdi 目的，rsi 源，一个点三十格。
pt_copy:
    push rcx
    push rsi
    push rdi
    mov ecx, 32
    cld
    rep movsd
    pop rdi
    pop rsi
    pop rcx
    ret

; ----------------------------------------------------------------------
; pt_add：pt_a + pt_b → pt_o
;
;   A = (Y1-X1)*(Y2-X2)      E = B-A      X3 = E*F
;   B = (Y1+X1)*(Y2+X2)      F = D-C      Y3 = G*H
;   C = T1*2d*T2             G = D+C      T3 = E*H
;   D = 2*Z1*Z2              H = B+A      Z3 = F*G
;
; T 那一格不是从 x*y 算出来的，是 E*H —— 正是这一点让整条链不必做除法。
; ----------------------------------------------------------------------
pt_add:
    FPOP pt_t0, pt_a+32, pt_a, fp_sub
    FPOP pt_t1, pt_b+32, pt_b, fp_sub
    FPOP pt_t2, pt_t0, pt_t1, fp_mulmod      ; A

    FPOP pt_t0, pt_a+32, pt_a, fp_add
    FPOP pt_t1, pt_b+32, pt_b, fp_add
    FPOP pt_t3, pt_t0, pt_t1, fp_mulmod      ; B

    FPOP pt_t0, pt_a+96, fp_d2, fp_mulmod
    FPOP pt_t4, pt_t0, pt_b+96, fp_mulmod    ; C

    FPOP pt_t0, pt_a+64, pt_b+64, fp_mulmod
    FPOP pt_t5, pt_t0, pt_t0, fp_add      ; D

    FPOP pt_t6, pt_t3, pt_t2, fp_sub      ; E
    FPOP pt_t7, pt_t5, pt_t4, fp_sub      ; F
    FPOP pt_t8, pt_t5, pt_t4, fp_add      ; G
    FPOP pt_t9, pt_t3, pt_t2, fp_add      ; H

    FPOP pt_o, pt_t6, pt_t7, fp_mulmod
    FPOP pt_o+32, pt_t8, pt_t9, fp_mulmod
    FPOP pt_o+96, pt_t6, pt_t9, fp_mulmod
    FPOP pt_o+64, pt_t7, pt_t8, fp_mulmod
    ret

; ----------------------------------------------------------------------
; pt_double：2 * pt_a → pt_o
;
;   A = X1^2                 G = D+B      X3 = E*F
;   B = Y1^2                 F = G-C      Y3 = G*H
;   C = 2*Z1^2               H = D-B      T3 = E*H
;   D = -A                   E = (X1+Y1)^2 - A - B    Z3 = F*G
;
; E 那一条不写成 2*X1*Y1，而是 (X1+Y1)^2 - A - B：省一次乘法，而且这个写法只用平方
; 与加减。它也是这一层最容易写错的一步 —— 展开少减掉一项，结果会是一个不在曲线上的
; 点，而曲线不会当场抱怨。
; ----------------------------------------------------------------------
pt_double:
    FPOP pt_t0, pt_a, pt_a, fp_mulmod        ; A
    FPOP pt_t1, pt_a+32, pt_a+32, fp_mulmod  ; B
    FPOP pt_t2, pt_a+64, pt_a+64, fp_mulmod
    FPOP pt_t2, pt_t2, pt_t2, fp_add      ; C

    FPOP pt_t3, fp_zero, pt_t0, fp_sub    ; D = -A

    FPOP pt_t4, pt_a, pt_a+32, fp_add
    FPOP pt_t4, pt_t4, pt_t4, fp_mulmod
    FPOP pt_t4, pt_t4, pt_t0, fp_sub
    FPOP pt_t4, pt_t4, pt_t1, fp_sub      ; E

    FPOP pt_t5, pt_t3, pt_t1, fp_add      ; G
    FPOP pt_t6, pt_t5, pt_t2, fp_sub      ; F
    FPOP pt_t7, pt_t3, pt_t1, fp_sub      ; H

    FPOP pt_o, pt_t4, pt_t6, fp_mulmod
    FPOP pt_o+32, pt_t5, pt_t7, fp_mulmod
    FPOP pt_o+96, pt_t4, pt_t7, fp_mulmod
    FPOP pt_o+64, pt_t6, pt_t5, fp_mulmod
    ret

; ----------------------------------------------------------------------
; pt_show：rsi 标签，rdi 点。打一行四个坐标，各三十二字节连写。
;
; 一次打满一百二十八字节而不是一个一个打：主机那边按每六十四个十六进制字符切一格，
; 切法与打印格式是同一件事。这里原来写的是三十二 —— 那正好是一格，于是四份坐标只露
; 了一份，而主机那条判据要的是四份，两边一条也没对上。
pt_show:
    push rdi
    call puts64
    pop rdi
    mov rcx, 128
    call put_hex_bytes
    call put_nl64
    ret

; fp_show：rsi 标签，rdi 一个域元素。点加算错时用来把中间量摊开。
;
; 它现在又有调用者了（验签那边要看约简之后的 k），而当初留着它的理由正是「下一次
; 不必再写一遍」—— 只是上次清理的时候连标签一起删了，函数体做了半天孤儿。
fp_show:
    push rdi
    call puts64
    pop rdi
    mov rcx, 32
    call put_hex_bytes
    call put_nl64
    ret

; ----------------------------------------------------------------------
; 点运算的判据
;
; 五组读数，三条判据，全部由主机那边判 —— 它拿到四份坐标，自己做交叉积比较。
;
;   add-bb       B + B
;   dbl-b        2B                      与 add-bb 必须是同一个点
;   dbl2-b       2*(2B)                  与 add-4b 必须是同一个点
;   add-4b       (2B) + (2B)
;   add-ident    B + O                   O 是单位元 (0,1,1,0)，必须还是 B
;
; 为什么是交叉积而不是坐标相减：点加与点倍选的投影比例 k 不同，同一个点在这两条路
; 上会得到不同的 (X,Y,Z,T)。比坐标会把一个正确的实现判成错的。
;
; 为什么这三条不是重复：add-bb 与 dbl-b 比的是「两个公式是不是同一个群运算」；dbl2-b
; 与 add-4b 比的是「群运算能不能叠」；add-ident 比的是「单位元真的是单位元」。三条
; 各自能单独红 —— 而三条一起绿，才说明这不是一组凑出来的数。
; ----------------------------------------------------------------------
run_pt_test:
    ; add-bb：B + B
    lea rdi, [pt_a]
    lea rsi, [pt_base]
    call pt_copy
    lea rdi, [pt_b]
    lea rsi, [pt_base]
    call pt_copy
    ; 先把喂进去的两个点打出来。点加算错的时候，第一件要分的事是「输入错了」还是
    ; 「公式错了」—— 而这两件事在只看得见输出的时候长得一样。pti 前缀是刻意的：
    ; 主机那条判据只认 pt 开头的五行，这两行不参与判分。
    mov rsi, line_pt_in_a
    lea rdi, [pt_a]
    call pt_show
    mov rsi, line_pt_in_b
    lea rdi, [pt_b]
    call pt_show
    call pt_add
    mov rsi, line_pt_addbb
    lea rdi, [pt_o]
    call pt_show
    lea rdi, [pt_o2]
    lea rsi, [pt_o]
    call pt_copy                       ; 2B 收起来，后面还要用

    ; dbl-b：2B
    lea rdi, [pt_a]
    lea rsi, [pt_base]
    call pt_copy
    call pt_double
    mov rsi, line_pt_dblb
    lea rdi, [pt_o]
    call pt_show

    ; dbl2-b：2*(2B)
    lea rdi, [pt_a]
    lea rsi, [pt_o2]
    call pt_copy
    call pt_double
    mov rsi, line_pt_dbl2
    lea rdi, [pt_o]
    call pt_show
    lea rdi, [pt_o3]
    lea rsi, [pt_o]
    call pt_copy

    ; add-4b：(2B) + (2B)
    lea rdi, [pt_a]
    lea rsi, [pt_o2]
    call pt_copy
    lea rdi, [pt_b]
    lea rsi, [pt_o2]
    call pt_copy
    call pt_add
    mov rsi, line_pt_add4
    lea rdi, [pt_o]
    call pt_show

    ; add-ident：B + O
    lea rdi, [pt_a]
    lea rsi, [pt_base]
    call pt_copy
    lea rdi, [pt_b]
    lea rsi, [pt_ident]
    call pt_copy
    call pt_add
    mov rsi, line_pt_addid
    lea rdi, [pt_o]
    call pt_show

    mov rsi, line_pt_ok
    call puts64
    ret

; ======================================================================
; 标量乘：双倍-加
; ======================================================================
;
; 从最低位往上走：acc 置单位元、base 置 P，每一位若是一就把 base 加进 acc，然后 base
; 翻倍、标量右移一位，直到标量变成零。这是最笨的一种，每轮一次加倍加半次加法。
;
; 选它不是因为快 —— 定窗口能快一倍多 —— 而是因为它只有两个动作，而这两个动作各自
; 已经单独站住过。第三环走到这里，能复用的东西比能省的时间值钱。
;
; 标量是就地右移的，进来的那一份会被改掉。判据每组重新设一次，所以不要紧；而验签
; 那边 S 与 k 各用一次，本来也各算各的。

; 标量是不是零。置零的时候循环一次也不跑，acc 停在单位元上 —— 这是零在群里的定义，
; 也是唯一一组「循环没跑」的判据。
pt_scalar_zero:
    xor eax, eax
    mov ecx, 7
.chk:
    or eax, [pt_scalar + rcx * 4]
    dec ecx
    jns .chk
    ret

; pt_mul：pt_scalar × pt_a → pt_o
pt_mul:
    lea rdi, [pt_acc]
    lea rsi, [pt_ident]
    call pt_copy
    lea rdi, [pt_bse]
    lea rsi, [pt_a]
    call pt_copy
.loop:
    call pt_scalar_zero
    test rax, rax
    jz .done                        ; 标量已经是零，循环走完
    test byte [pt_scalar], 1
    jz .no_add
    lea rdi, [pt_a]
    lea rsi, [pt_acc]
    call pt_copy
    lea rdi, [pt_b]
    lea rsi, [pt_bse]
    call pt_copy
    call pt_add
    lea rdi, [pt_acc]
    lea rsi, [pt_o]
    call pt_copy
.no_add:
    lea rdi, [pt_a]
    lea rsi, [pt_bse]
    call pt_copy
    call pt_double
    lea rdi, [pt_bse]
    lea rsi, [pt_o]
    call pt_copy
    ; 标量右移一位。rcr 靠 CF 把上一格的末位移下来，所以这条链与减法链一样，中间
    ; 不许有任何碰 CF 的指令 —— mov 与 dec 都不碰，这是它们在这里的用处。
    clc
    mov ecx, 7
.shr:
    mov eax, [pt_scalar + rcx * 4]
    rcr eax, 1
    mov [pt_scalar + rcx * 4], eax
    dec ecx
    jns .shr
    jmp .loop
.done:
    lea rdi, [pt_o]
    lea rsi, [pt_acc]
    call pt_copy
    ret

; ----------------------------------------------------------------------
; 标量乘的判据
;
; 四组读数，三条交叉积，全部与前面已经站住的东西比：
;
;   mul-1    1P          与基点同点 —— 循环跑了一次，加号没进，加倍也没改到值
;   mul-2    2P          与 dbl-b 同点 —— 标量乘里的加倍与点倍子程序是一回事
;   mul-3    3P          与 add-3b 同点 —— 标量乘里的加法与点加子程序是一回事
;   add-3b   (2B) + B    用 pt_add 直接算出来的 3P
;
; 为什么这四条不是重复：mul-1 压的是「标量右移与循环终止」；mul-2 压的是加倍那一条；
; mul-3 同时压加倍与加法，而且是两者交替发生的那一组（位模式 11）。只测 mul-2 的话，
; 一个「加号永远不进」的实现照样绿。
;
; 标量为零的那一组不在这里 —— 它需要与单位元比，而单位元的 (0,1,1,0) 在交叉积下会
; 与一个全零的点也被判成同点（X 那一项两边都是零）。主机那边给「同点」加了 Z 不为零
; 这一条，所以零不会被误判成绿；但一组只能证明「循环没跑」的读数不值得占一个向量位，
; 它已经在 pt_mul 的注释里写清楚了。
; ----------------------------------------------------------------------
run_pt_mul_test:
    lea rdi, [pt_scalar]
    lea rsi, [pt_k1]
    call fp_copy
    lea rdi, [pt_a]
    lea rsi, [pt_base]
    call pt_copy
    call pt_mul
    mov rsi, line_pt_mul1
    lea rdi, [pt_o]
    call pt_show

    lea rdi, [pt_scalar]
    lea rsi, [pt_k2]
    call fp_copy
    lea rdi, [pt_a]
    lea rsi, [pt_base]
    call pt_copy
    call pt_mul
    mov rsi, line_pt_mul2
    lea rdi, [pt_o]
    call pt_show

    lea rdi, [pt_scalar]
    lea rsi, [pt_k3]
    call fp_copy
    lea rdi, [pt_a]
    lea rsi, [pt_base]
    call pt_copy
    call pt_mul
    mov rsi, line_pt_mul3
    lea rdi, [pt_o]
    call pt_show

    ; add-3b：用点加直接算 (2B) + B。pt_o2 是 run_pt_test 存下的 2B。
    lea rdi, [pt_a]
    lea rsi, [pt_o2]
    call pt_copy
    lea rdi, [pt_b]
    lea rsi, [pt_base]
    call pt_copy
    call pt_add
    mov rsi, line_pt_add3b
    lea rdi, [pt_o]
    call pt_show

    ; 这里不再打 event=ptmul ok。同一个函数上面已经把四组读数打出去了，而判据读的是
    ; 那些读数 —— 一个「ok」既不能替换它们，也不能在它们错的时候变红。打了没人读的
    ; 行与挂了永不触发的判据是同一种病：出事的时候都保持沉默。
    ret

; ======================================================================
; 模逆与压缩点的编码
; ======================================================================
;
; 模逆用费马小定理：a^(p-2)。p 是素数，所以 a * a^(p-2) = a^(p-1) = 1。
;
; 这条路的代价是 255 次平方加若干次乘法，比一次乘法贵两个数量级 —— 而整条验签链只在
; 编码时用一次。为它写一个扩展欧几里得是省了时间，却多了一整段只有一种用法的代码；
; 而这一层的判据现在只有四条读数，不值得为省那点时间多一处会错的地方。
;
; 指数是常量（p-2），所以写成数据段里的八格，逐位读。最高位是第 254 位。
;
; 注意：这支例程会覆盖 fp_a / fp_b / fp_out，编码那一段也是。调用顺序上它们是串的，
; 不会相互踩到 —— 但如果将来有人在中间插一段用 fp_* 的代码，这里会静默地算错。

; 第 i 位（i 存在 fp_inv_i）是不是一。出 rax = 0 或 1。
;
; 位的来源是 fp_exp_ptr 指的那八格 —— 所以逆与开方共用同一套循环，只差一个指针。
fp_inv_bit:
    mov rax, [fp_inv_i]
    mov rcx, rax
    shr rax, 5                      ; 落在第几格
    and ecx, 31                     ; 格内第几位
    mov rdx, [fp_exp_ptr]
    mov edx, [rdx + rax * 4]
    shr edx, cl
    and edx, 1
    mov eax, edx
    ret

; fp_inv：rdi = 目标，rsi = 源。源^(p-2)，也就是逆。
; fp_pow：rdi = 目标，rsi = 底，rdx = 指数（八格的地址）。底^exp。
;
; 两者共用一个核心。开方要的指数是 (p+3)/8，与逆只差一个指针 —— 而这段循环有 255 轮，
; 是最不该写两遍的东西。从第 254 位往下走：高位的零只会多做几次平方，不改变结果，
; 所以两个指数都不必各自记着自己的位长。
fp_inv:
    lea rax, [fp_im1]
    mov [fp_exp_ptr], rax
    jmp fp_pow_core
fp_pow:
    mov [fp_exp_ptr], rdx
fp_pow_core:
    push rdi
    push rsi
    lea rdi, [fp_inv_a]
    call fp_copy
    lea rdi, [fp_inv_r]
    lea rsi, [fp_one]
    call fp_copy
    mov qword [fp_inv_i], 254
.loop:
    lea rdi, [fp_a]
    lea rsi, [fp_inv_r]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [fp_inv_r]
    call fp_copy
    call fp_mulmod
    lea rdi, [fp_inv_r]
    lea rsi, [fp_out]
    call fp_copy
    call fp_inv_bit
    test rax, rax
    jz .skip
    lea rdi, [fp_a]
    lea rsi, [fp_inv_r]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [fp_inv_a]
    call fp_copy
    call fp_mulmod
    lea rdi, [fp_inv_r]
    lea rsi, [fp_out]
    call fp_copy
.skip:
    dec qword [fp_inv_i]
    cmp qword [fp_inv_i], 0
    jge .loop
    pop rsi
    pop rdi
    lea rsi, [fp_inv_r]
    call fp_copy
    ret

; ----------------------------------------------------------------------
; pt_encode：rdi = 三十二字节输出，rsi = 点
;
; 压缩点的形状：y 的三十二字节小端，最高位放 x 的最低位。x 本身不存 —— 它由曲线方程
; 与那个符号位唯一确定，而这就是「压缩」的意思。
;
; 所以编码只做一件事：把投影坐标除回仿射（一次模逆），取 y，再看 x 的奇偶。解码那边
; 才是难的一半 —— 它要从 y 解出 x，而那要一次开方。
; ----------------------------------------------------------------------
pt_encode:
    mov [pt_src], rsi
    mov [pt_dst], rdi
    lea rdi, [fp_inv_t]
    mov rax, [pt_src]
    lea rsi, [rax + 64]             ; Z
    call fp_inv

    lea rdi, [fp_a]
    mov rax, [pt_src]
    lea rsi, [rax + 32]             ; Y
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [fp_inv_t]
    call fp_copy
    call fp_mulmod
    mov rdi, [pt_dst]
    lea rsi, [fp_out]
    call fp_copy                    ; y 的三十二字节就位

    lea rdi, [fp_a]
    mov rax, [pt_src]
    lea rsi, [rax]                  ; X
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [fp_inv_t]
    call fp_copy
    call fp_mulmod
    mov al, byte [fp_out]
    and eax, 1
    shl eax, 7
    mov rdi, [pt_dst]
    or byte [rdi + 31], al
    ret

; fp_lt_p：rdi 指的八格若严格小于 p 就出 1。
fp_lt_p:
    mov ecx, 7
.cmp:
    mov eax, [rdi + rcx * 4]
    mov edx, [fp_p + rcx * 4]
    cmp eax, edx
    jb .yes
    ja .no
    dec ecx
    jns .cmp
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; fp_eq：rdi 与 rsi 两个八格若逐格相同就出 1。
fp_eq:
    xor ecx, ecx
.chk:
    mov eax, [rdi + rcx * 4]
    cmp eax, [rsi + rcx * 4]
    jne .no
    inc ecx
    cmp ecx, 8
    jb .chk
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; fp_is_zero：rdi 指的八格若全零就出 1。
fp_is_zero:
    xor ecx, ecx
.chk:
    mov eax, [rdi + rcx * 4]
    test eax, eax
    jnz .no
    inc ecx
    cmp ecx, 8
    jb .chk
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; ----------------------------------------------------------------------
; pt_decode：rdi = 点（输出），rsi = 三十二字节。出 rax = 1 成功 / 0 拒绝。
;
; 从 y 把 x 解出来，靠的是曲线方程：-x² + y² = 1 + d x² y²，整理一下
;
;     x² = (y² - 1) / (d y² + 1)
;
; 也就是一次除法（一次逆）。剩下的是一次开方 —— p ≡ 5 (mod 8)，所以平方根可以用
; 幂 a^((p+3)/8) 求，而它给出的是「平方根乘以 ±1 或者 ±sqrt(-1)」里的某一个。所以
; 算完之后必须验：把那一次方再平方回去，若不等于 x²，就乘 sqrt(-1) 再验一次；两次
; 都不等于，说明这个 y 落不到曲线上，拒绝。
;
; 这里的「验」不是防御性编程，是算法的一半：那个指数给的不是唯一的根，而是某族的
; 一个代表。少了这一步，任何 y 都会被解出一个看起来像点的东西。
;
; 拒绝的三种情形：y 不小于 p（不是一个域元素）、y 不在曲线上、x 为零而符号位是一
; （RFC 8032 明确把这一种算作不合法，否则单位元有两种写法）。
; ----------------------------------------------------------------------
pt_decode:
    mov [pt_dst], rdi
    mov [pt_src], rsi

    lea rdi, [pt_bytes]
    mov rsi, [pt_src]
    mov ecx, 8
    cld
    rep movsd
    movzx eax, byte [pt_bytes + 31]
    shr eax, 7
    mov [pt_sign], rax
    and byte [pt_bytes + 31], 0x7F

    lea rdi, [pt_y]
    lea rsi, [pt_bytes]
    mov ecx, 8
    cld
    rep movsd

    lea rdi, [pt_y]
    call fp_lt_p
    test rax, rax
    jz .fail

    ; y2 = y*y
    lea rdi, [fp_a]
    lea rsi, [pt_y]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [pt_y]
    call fp_copy
    call fp_mulmod
    lea rdi, [pt_y2]
    lea rsi, [fp_out]
    call fp_copy

    ; u = y2 - 1
    lea rdi, [fp_a]
    lea rsi, [pt_y2]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [fp_one]
    call fp_copy
    call fp_sub
    lea rdi, [pt_u]
    lea rsi, [fp_out]
    call fp_copy

    ; v = d*y2 + 1
    lea rdi, [fp_a]
    lea rsi, [fp_d]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [pt_y2]
    call fp_copy
    call fp_mulmod
    lea rdi, [fp_a]
    lea rsi, [fp_out]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [fp_one]
    call fp_copy
    call fp_add
    lea rdi, [pt_v]
    lea rsi, [fp_out]
    call fp_copy

    ; x2 = u * inv(v)
    lea rdi, [fp_inv_t]
    lea rsi, [pt_v]
    call fp_inv
    lea rdi, [fp_a]
    lea rsi, [pt_u]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [fp_inv_t]
    call fp_copy
    call fp_mulmod
    lea rdi, [pt_x2]
    lea rsi, [fp_out]
    call fp_copy

    ; x = x2^((p+3)/8)
    lea rdi, [pt_x]
    lea rsi, [pt_x2]
    lea rdx, [fp_sqexp]
    call fp_pow

    lea rdi, [pt_x]
    lea rsi, [pt_x2]
    call pt_decode_checksq
    test rax, rax
    jnz .x_ok

    ; 乘 sqrt(-1) 再验一次
    lea rdi, [fp_a]
    lea rsi, [pt_x]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [fp_sqrtm1]
    call fp_copy
    call fp_mulmod
    lea rdi, [pt_x]
    lea rsi, [fp_out]
    call fp_copy
    lea rdi, [pt_x]
    lea rsi, [pt_x2]
    call pt_decode_checksq
    test rax, rax
    jz .fail

.x_ok:
    movzx eax, byte [pt_x]
    and eax, 1
    cmp rax, [pt_sign]
    je .sign_ok
    lea rdi, [fp_a]
    lea rsi, [fp_zero]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [pt_x]
    call fp_copy
    call fp_sub
    lea rdi, [pt_x]
    lea rsi, [fp_out]
    call fp_copy
.sign_ok:
    lea rdi, [pt_x]
    call fp_is_zero
    test rax, rax
    jz .ok
    cmp qword [pt_sign], 0
    jne .fail

.ok:
    mov rdi, [pt_dst]
    lea rsi, [pt_x]
    call fp_copy
    mov rdi, [pt_dst]
    add rdi, 32
    lea rsi, [pt_y]
    call fp_copy
    mov rdi, [pt_dst]
    add rdi, 64
    lea rsi, [fp_one]
    call fp_copy
    lea rdi, [fp_a]
    lea rsi, [pt_x]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [pt_y]
    call fp_copy
    call fp_mulmod
    mov rdi, [pt_dst]
    add rdi, 96
    lea rsi, [fp_out]
    call fp_copy
    mov eax, 1
    ret
.fail:
    xor eax, eax
    ret

; pt_decode 的中间一步：rdi 那一格平方之后等不等于 rsi。出 1 表示相等。
;
; 两个参数都从栈上读（不 pop 再 push），因为中间那几次调用会把寄存器用光。
pt_decode_checksq:
    push rdi
    push rsi
    lea rdi, [fp_a]
    mov rsi, [rsp + 8]              ; 第一个参数
    call fp_copy
    lea rdi, [fp_b]
    mov rsi, [rsp + 8]
    call fp_copy
    call fp_mulmod
    lea rdi, [fp_out]
    mov rsi, [rsp]                  ; 第二个参数
    call fp_eq
    pop rsi
    pop rdi
    ret

; ----------------------------------------------------------------------
; 解码的判据：往返
;
; 对 1、2、3、5 四个倍数各做一次「算出来 → 编码 → 解码」，然后把编码前与解码后的
; 四份坐标都打出来。主机那边成对比较：同一个 k 的两组必须是同一个点。
;
; 为什么往返是这一层唯一说得清的判据：编码与解码互为逆，而它们各自都不需要知道
; 「正确的坐标是什么」—— 只要两个方向一致，往返就闭合。这比拿一个写死的期望值去比
; 结实得多，因为写死的期望值只覆盖那一个点。
;
; 1、2、3 覆盖的是符号位为零那一半（它们的 x 都是偶数），5 覆盖另一半。上一轮的教训：
; 少了 5，符号位那一位改坏了也不红。
;
; 另外一组是坏输入：y = 2 落不到曲线上，解码必须拒绝。没有这一组，一个「任何输入都
; 接受」的实现会与正确的实现看起来一模一样 —— 因为它在四个正确的输入上全对。
; ----------------------------------------------------------------------
run_pt_dec_test:
    mov qword [ptd_i], 0
.loop:
    mov rax, [ptd_i]
    cmp rax, 4
    jae .bad
    shl rax, 5
    lea rdx, [pt_dec_ks]
    add rdx, rax
    lea rdi, [pt_scalar]
    mov rsi, rdx
    call fp_copy

    lea rdi, [pt_a]
    lea rsi, [pt_base]
    call pt_copy
    call pt_mul
    mov rsi, line_ptd_before
    lea rdi, [pt_o]
    call pt_show

    lea rdi, [pt_enc]
    lea rsi, [pt_o]
    call pt_encode
    lea rdi, [pt_o]
    lea rsi, [pt_enc]
    call pt_decode
    test rax, rax
    jz .reject
    mov rsi, line_ptd_after
    lea rdi, [pt_o]
    call pt_show

    inc qword [ptd_i]
    jmp .loop

.bad:
    lea rdi, [pt_o]
    lea rsi, [pt_bad]
    call pt_decode
    mov rsi, line_ptd_bad
    call puts64
    call put_num64
    call put_nl64
    ; 同上：四组往返读数已经打出去了。
    ret
.reject:
    ; 这一支不再打 event=ptdec reject。
    ;
    ; 上面 .bad 那一支打的 ptd bad N 已经把「坏输入被拒」说完了，而 run.mjs 读的正是
    ; 那一行（ptrBad 要求它是 0）。再打一行 reject，是一句没人读的重复宣告 —— 而它
    ; 还会让 tools/audit.mjs 报「这个 event 没人读」，那正是它该报的。
    ret

; ======================================================================
; 验签本体
; ======================================================================
;
; RFC 8032 的那一条式子：给定公钥 A、消息 M、签名 (R, S)，
;
;   一、S 必须小于 L（群的阶）—— 不小于就不是一个标量，直接拒；
;   二、把 A 与 R 从压缩点解出来（两个都解不出来也直接拒）；
;   三、k = SHA-512(R || A || M)，按小端当整数，再对 L 取模；
;   四、[S]B 与 R + [k]A 必须是同一个点。
;
; 这四步下面每一层都单独有判据：解码、标量乘、点加、域算术，各自与主机对过。所以
; 这一段代码本身只需要「串得对」—— 它不应该再是第一个发现下层有问题的地方。
;
; S 小于 L 那一条不是形式主义：Ed25519 的签名里 S 是模 L 的，一个不检查的实现会接受
; 同一签名的 S+L、S+2L …… 而这些是不同字节串的「同一个签名」。放松这一条，签名的
; 字节串就不再唯一。

; k_lt_l：rdi 指的八格若严格小于 L 就出 1。
k_lt_l:
    mov ecx, 7
.cmp:
    mov eax, [rdi + rcx * 4]
    mov edx, [k_l + rcx * 4]
    cmp eax, edx
    jb .yes
    ja .no
    dec ecx
    jns .cmp
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; ----------------------------------------------------------------------
; modl_reduce：k_n（16 格，512 位小端）→ k_rem（前八格，落在 [0, L)）
;
; 用的是二进制长除法：从最高位往下走，每一步把 rem 左移一位、把当前位塞进最低位，
; 然后看 rem 是否已经够减 L。五百一十二轮，每轮三十来条指令。
;
; 为什么不用 Barrett 之类：那个要预先算一个 512 位的倒数常量，而它的正确性又依赖一次
; 多精度乘法 —— 也就是说，为了省这五百轮，要多出两处会错的地方。这一段只在验签时
; 跑一次，慢一倍不要紧。
;
; 左移链靠 CF 串位，所以与减法链同一个规矩：中间不许碰 CF。cmp 碰，dec 不碰。
; ----------------------------------------------------------------------
modl_reduce:
    push rdi
    push rcx
    push rdx
    push r8
    push r9
    lea rdi, [k_rem]
    xor eax, eax
    mov ecx, 9
    cld
    rep stosd
    mov qword [k_bit], 511
.loop:
    ; 取 N 的第 i 位
    mov rax, [k_bit]
    mov rcx, rax
    shr rax, 5
    and ecx, 31
    mov edx, [k_n + rax * 4]
    shr edx, cl
    and edx, 1
    mov r8d, edx

    ; rem <<= 1（九格，从低到高）
    clc
    xor ecx, ecx
    mov r9d, 9
.shift:
    mov eax, [k_rem + rcx * 4]
    rcl eax, 1
    mov [k_rem + rcx * 4], eax
    inc ecx
    dec r9d
    jnz .shift
    or [k_rem], r8d                 ; 把这一位放进最低位

    ; rem >= L ？
    mov ecx, 8
.cmp:
    mov eax, [k_rem + rcx * 4]
    mov edx, [k_l + rcx * 4]
    cmp eax, edx
    ja .sub
    jb .nosub
    dec ecx
    jns .cmp
.sub:
    clc
    xor ecx, ecx
    mov r9d, 9
.dosub:
    mov eax, [k_rem + rcx * 4]
    sbb eax, [k_l + rcx * 4]
    mov [k_rem + rcx * 4], eax
    inc ecx
    dec r9d
    jnz .dosub
.nosub:
    dec qword [k_bit]
    cmp qword [k_bit], 0
    jge .loop

    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rdi
    ret

; ----------------------------------------------------------------------
; pt_verify：用 sig_pk（三十二字节）、sig_sig（六十四字节）、sig_msg 与 sig_msglen。
; 出 rax = 1 通过 / 0 不通过。
; ----------------------------------------------------------------------
pt_verify:
    mov qword [sig_where], 0
    ; 一、S < L
    lea rdi, [sig_sig + 32]
    call k_lt_l
    test rax, rax
    jz .no
    mov qword [sig_where], 1

    ; 二、解码 A 与 R
    lea rdi, [pt_A]
    lea rsi, [sig_pk]
    call pt_decode
    test rax, rax
    jz .no
    mov qword [sig_where], 2
    lea rdi, [pt_R]
    lea rsi, [sig_sig]
    call pt_decode
    test rax, rax
    jz .no
    mov qword [sig_where], 3

    ; 三、k = SHA-512(R || A || M) mod L
    ;
    ; 拼接用的是 sig_cat，不是 sig_buf —— 后者是第二环规则扫描的缓冲区，名字先到先得。
    ; 撞名字的时候 nasm 报的是「重复定义」，而不是「你引用错了那个」，这一点算是运气。
    lea rdi, [sig_cat]
    lea rsi, [sig_sig]
    mov ecx, 8
    cld
    rep movsd
    lea rdi, [sig_cat + 32]
    lea rsi, [sig_pk]
    mov ecx, 8
    cld
    rep movsd
    lea rdi, [sig_cat + 64]
    lea rsi, [sig_msg]
    mov rcx, [sig_msglen]
    cld
    rep movsb

    lea rdi, [sig_cat]
    mov rcx, [sig_msglen]
    add rcx, 64
    call sha512

    ; sha512_out 的六十四字节直接就是「按小端解释」要的顺序。
    ;
    ; 标准的哈希输出把最高有效字节放在最前面，而 RFC 8032 说的是把这个摘要「当作小端
    ; 整数」—— 第一个字节就是最低位。所以原样拷过去即可。这里原先多反序了一次，等于
    ; 解释成大端；而那个错法极难找：摘要本身对（hs 那一行与主机逐字节相同）、约简本身
    ; 也对（四个小用例全过），错的只是喂给约简的那份字节的方向。串口上看到的是「k 不对」
    ; 而两边都自证清白。
    lea rdi, [k_n]
    lea rsi, [sha512_out]
    mov ecx, 16
    cld
    rep movsd
    call modl_reduce
    mov qword [sig_where], 4

    ; 四、[S]B 与 R + [k]A
    lea rdi, [pt_scalar]
    lea rsi, [sig_sig + 32]
    call fp_copy
    lea rdi, [pt_a]
    lea rsi, [pt_base]
    call pt_copy
    call pt_mul
    lea rdi, [pt_SB]
    lea rsi, [pt_o]
    call pt_copy

    lea rdi, [pt_scalar]
    lea rsi, [k_rem]
    call fp_copy
    lea rdi, [pt_a]
    lea rsi, [pt_A]
    call pt_copy
    call pt_mul

    lea rdi, [pt_a]
    lea rsi, [pt_R]
    call pt_copy
    lea rdi, [pt_b]
    lea rsi, [pt_o]
    call pt_copy
    call pt_add

    ; 交叉积比较：X1*Z2 与 X2*Z1
    lea rdi, [fp_a]
    lea rsi, [pt_SB]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [pt_o + 64]
    call fp_copy
    call fp_mulmod
    lea rdi, [pt_c1]
    lea rsi, [fp_out]
    call fp_copy

    lea rdi, [fp_a]
    lea rsi, [pt_o]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [pt_SB + 64]
    call fp_copy
    call fp_mulmod
    lea rdi, [pt_c2]
    lea rsi, [fp_out]
    call fp_copy

    lea rdi, [pt_c1]
    lea rsi, [pt_c2]
    call fp_eq
    test rax, rax
    jz .no
    mov qword [sig_where], 5

    ; Y 那一对
    lea rdi, [fp_a]
    lea rsi, [pt_SB + 32]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [pt_o + 64]
    call fp_copy
    call fp_mulmod
    lea rdi, [pt_c1]
    lea rsi, [fp_out]
    call fp_copy

    lea rdi, [fp_a]
    lea rsi, [pt_o + 32]
    call fp_copy
    lea rdi, [fp_b]
    lea rsi, [pt_SB + 64]
    call fp_copy
    call fp_mulmod
    lea rdi, [pt_c2]
    lea rsi, [fp_out]
    call fp_copy

    lea rdi, [pt_c1]
    lea rsi, [pt_c2]
    call fp_eq
    test rax, rax
    jz .no
    mov qword [sig_where], 6

    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; ----------------------------------------------------------------------
; 验签的判据：RFC 8032 的三组向量，每组验两次
;
;   ok   原样的签名必须通过
;   bad  把签名的第一个字节翻一位，必须不通过
;
; 两条缺一不可。只验 ok 的话，一个永远返回 1 的实现全绿；只验 bad 的话，一个永远返回
; 0 的实现全绿。而这两组向量是 RFC 里给的，不是自己造的 —— 自造向量只能证明「它与
; 自己一致」，证明不了「它与标准一致」。
;
; 三组的消息长度是 0、1、2，覆盖了 SHA-512 那条链的最短几种输入。长消息的多块路径
; 已经由 SHA-512 自己的六行判据压过了（其中四个在两块以上），所以这里不重复。
; ----------------------------------------------------------------------
run_pt_verify_test:
    ; 先单独问一次约简：它是验签里唯一还没有自己的判据的一步，而它的输入输出都短，
    ; 四个用例就够定位。零与一压的是「不动」；L 与 L+1 压的是「恰好减一次」与
    ; 「刚越过就该减」。
    lea rdi, [k_n]
    xor eax, eax
    mov ecx, 16
    cld
    rep stosd
    call modl_reduce
    mov rsi, line_modl
    call puts64
    xor eax, eax
    call put_num64
    mov rsi, line_colon
    call puts64
    lea rdi, [k_rem]
    mov rcx, 32
    call put_hex_bytes
    call put_nl64

    mov dword [k_n], 1
    call modl_reduce
    mov rsi, line_modl
    call puts64
    mov eax, 1
    call put_num64
    mov rsi, line_colon
    call puts64
    lea rdi, [k_rem]
    mov rcx, 32
    call put_hex_bytes
    call put_nl64

    lea rdi, [k_n]
    xor eax, eax
    mov ecx, 16
    cld
    rep stosd
    lea rdi, [k_n]
    lea rsi, [k_l]
    mov ecx, 8
    cld
    rep movsd
    call modl_reduce
    mov rsi, line_modl
    call puts64
    mov eax, 2
    call put_num64
    mov rsi, line_colon
    call puts64
    lea rdi, [k_rem]
    mov rcx, 32
    call put_hex_bytes
    call put_nl64

    mov dword [k_n], 1
    call modl_reduce
    mov rsi, line_modl
    call puts64
    mov eax, 3
    call put_num64
    mov rsi, line_colon
    call puts64
    lea rdi, [k_rem]
    mov rcx, 32
    call put_hex_bytes
    call put_nl64

    mov qword [vt_i], 0
.loop:
    mov rax, [vt_i]
    cmp rax, 3
    jae .done

    lea rdx, [vt_pks]
    mov rsi, [rdx + rax * 8]
    lea rdi, [sig_pk]
    mov ecx, 8
    cld
    rep movsd

    mov rax, [vt_i]
    lea rdx, [vt_sigs]
    mov rsi, [rdx + rax * 8]
    lea rdi, [sig_sig]
    mov ecx, 16
    cld
    rep movsd

    mov rax, [vt_i]
    lea rdx, [vt_msgs]
    mov rsi, [rdx + rax * 8]
    lea rdi, [sig_msg]
    lea rdx, [vt_lens]
    mov rcx, [rdx + rax * 8]
    mov [sig_msglen], rcx
    cld
    rep movsb

    call pt_verify
    mov [sig_res], rax
    mov rax, [sig_where]
    mov [sig_w1], rax

    xor byte [sig_sig], 0x01
    call pt_verify
    mov [sig_res2], rax
    mov rax, [sig_where]
    mov [sig_w2], rax
    xor byte [sig_sig], 0x01

    mov rsi, line_sig_res
    call puts64
    mov rax, [vt_i]
    inc rax
    call put_num64
    mov rsi, line_sig_ok
    call puts64
    mov rax, [sig_res]
    call put_num64
    mov rsi, line_sig_bad
    call puts64
    mov rax, [sig_res2]
    call put_num64
    mov rsi, line_sig_where
    call puts64
    mov rax, [sig_w1]
    call put_num64
    call put_nl64

    inc qword [vt_i]
    jmp .loop
.done:
    mov rsi, line_sig_done
    call puts64
    ret

; ----------------------------------------------------------------------
; 编码的判据
;
; 四组：基点、2B、3B、4B 各编码一次。基点的编码是 RFC 8032 给的那一串常量（5866 打头，
; 后面一路 66），所以它连主机都不用 —— 而另外三组要与主机算的逐字节比。
;
; 为什么编码值得单独有判据：它一次压住四件事 —— 模逆对不对、乘法对不对、y 的字节序对
; 不对、符号位取的是 x 还是 y 的最低位。四件事里任何一件错，32 字节里都会有一位不对，
; 而这一层是验签链上唯一输出到「外面」的地方：验签比的是两个点的编码，编码错了，
; 前面每一层再对也白搭。
; ----------------------------------------------------------------------
run_pt_enc_test:
    lea rdi, [pt_enc]
    lea rsi, [pt_base]
    call pt_encode
    mov rsi, line_pte_b
    call puts64
    lea rdi, [pt_enc]
    mov rcx, 32
    call put_hex_bytes
    call put_nl64

    lea rdi, [pt_enc]
    lea rsi, [pt_o2]
    call pt_encode
    mov rsi, line_pte_2b
    call puts64
    lea rdi, [pt_enc]
    mov rcx, 32
    call put_hex_bytes
    call put_nl64

    ; 3B：run_pt_mul_test 最后一组把 add-3b 的坐标留在 pt_o 里
    lea rdi, [pt_enc]
    lea rsi, [pt_o]
    call pt_encode
    mov rsi, line_pte_3b
    call puts64
    lea rdi, [pt_enc]
    mov rcx, 32
    call put_hex_bytes
    call put_nl64

    lea rdi, [pt_enc]
    lea rsi, [pt_o3]
    call pt_encode
    mov rsi, line_pte_4b
    call puts64
    lea rdi, [pt_enc]
    mov rcx, 32
    call put_hex_bytes
    call put_nl64

    ; 5B：唯一一组 x 为奇数的读数。
    ;
    ; 前四组（B、2B、3B、4B）的 x 全是偶数，所以符号位那一位全程是零 —— 把 shl 7 改成
    ; shl 6，四组编码一个字节都不变，判据照旧绿。这不是判据写错了，是它的覆盖少了一半：
    ; 压缩点的最高位，那个唯一不来自 y 的位，从来没有被走到过。
    ;
    ; 找一个奇数 x 的倍数不是为了凑数。五组里两组覆盖 0、三组覆盖 1，那一位才真的
    ; 被问过；而验签那边 R 与 A 的符号位是随机的，一半的概率会用到它。
    lea rdi, [pt_scalar]
    lea rsi, [pt_k5]
    call fp_copy
    lea rdi, [pt_a]
    lea rsi, [pt_base]
    call pt_copy
    call pt_mul
    mov rsi, line_ptm_mul5
    lea rdi, [pt_o]
    call pt_show
    lea rdi, [pt_enc]
    lea rsi, [pt_o]
    call pt_encode
    mov rsi, line_pte_5b
    call puts64
    lea rdi, [pt_enc]
    mov rcx, 32
    call put_hex_bytes
    call put_nl64

    ; 同上：五组编码读数已经打出去了，ok 那一行是多余的。
    ret

; ======================================================================
; 家庭组的第一步：共享是目录条目上的一个位
; ======================================================================
;
; 设计在 design/HOMEGROUP.txt。Windows 的家庭组拆开来是五个部件，而其中三件依赖网络
; 与「第二台机器」—— 这两样这台机器都还没有。所以这里先做那两件不需要网络的：
; 「边界」与「共享」。
;
; 共享做成了条目类型上的一个位（0x80），而不是一张单独的共享表。理由是它没有第二份
; 真相：表要跟目录同步，而同步总有一个人先动 —— 那个间隙里两边会不一致。位上则只有
; 一份数据，改它就是改目录。
;
; 代价是类型那一个字节现在有三个含义：低六位是文件还是目录，bit 7 是共享，bit 6 是只读。
; 这种挤在一起的字段要靠约定守住，所以下面凡是用类型的地方都先 and 0x3F。
; 只读位进来之前掩码是 0x7F —— 加一个位就要把每一处掩码都收窄一格，而漏掉的那一处不会
; 报错：它只会把一个只读的目录算成别的值，症状与只读这件事看起来毫无关系。
;
; rdi = 路径（UTF-16，0 码元结尾）。出 rax = 1 成功 / 0 没找到。
fs_share:
    push rdi
    mov qword [gate_off], 1        ; 标记是管理动作，不走读取那道门
    call fs_open_path
    mov qword [gate_off], 0
    pop rdi
    test rax, rax
    jz .miss
    mov rax, [last_entry]
    test rax, rax
    jz .miss
    movzx ecx, word [rax]
    lea rdx, [rax + 2 + rcx * 2]   ; 名字之后就是类型
    or byte [rdx], 0x80
    mov rax, 1
    ret
.miss:
    xor eax, eax
    ret

; 列出根目录里带共享位的条目。名字与类型都打出来 —— 只有名字的话，一个被标记的目录
; 与一个被标记的文件在清单里长得一样。
; 在当前这块盘上列共享。调用者先设好 fs_base 与 fs_start —— 它不知道该列哪一块盘，
; 也不该知道；「列哪一块」是调用者的事。
list_shares_here:
    push rbx
    ; 不打 「shares 」前缀：列哪一块盘、要不要先说家 ID，是调用者的事。
    mov rdi, [fs_start]
    call fs_load
    mov rbx, rsi
    mov edi, [rbx + 12]
    call fs_load
    mov [shares_ptr], rsi
.entry:
    mov r12, [shares_ptr]
    movzx ecx, word [r12]
    test ecx, ecx
    jz .done
    lea r9, [r12 + 2 + rcx * 2]    ; 类型在名字之后
    movzx r10d, byte [r9]
    test r10b, 0x80
    jz .next
    push r10
    mov rdi, r12
    add rdi, 2
    call put_utf16_n               ; rcx 已经是名字长度
    pop r10
    and r10b, 0x3F                  ; 共享是 bit 7、只读是 bit 6，所以类型只剩低六位
    cmp r10b, 1
    je .as_dir
    mov rsi, line_share_file
    call puts64
    jmp .next
.as_dir:
    mov rsi, line_share_dir
    call puts64
.next:
    ; 指针与长度都从内存里再取一遍：put_utf16_n 与 puts64 会占用它们碰到的寄存器，
    ; 把循环变量托付给任何一个寄存器，都会在「打了点什么」之后丢掉位置。
    mov rax, [shares_ptr]
    movzx ecx, word [rax]
    lea rax, [rax + 11 + rcx * 2]
    mov [shares_ptr], rax
    jmp .entry
.done:
    call put_nl64
    pop rbx
    ret

; 主盘上列共享：先说一句、设好主盘的那两个数，再交给上面那一段。
run_shares:
    mov rsi, line_shares
    call puts64
    mov qword [fs_base], 0x40000
    mov qword [fs_start], 1024
    jmp list_shares_here

; ======================================================================
; 列另一块盘上的共享 —— 共享与边界第一次见面
; ======================================================================
;
; 到这一步之前，「共享」是目录条目上的一个位，「边界」是超块里的一个数，两件东西各在
; 各的位置，从没见过面。这里让它们见：先比家 ID，同一家才列，不同一家一条都不列。
;
; 判据因此分得开两件事：「列出来了」与「被挡住了」。而挡住的判据必须是那一行 not family，
; 不能只是「没有条目」—— 一块盘上本来就可能一条共享都没有，那种空与这种空看起来一样。
;
; rdi = 盘符（UTF-16，0 码元结尾）。出 rax = 1 列了 / 0 不是一家人。
fs_shares_at:
    push r12
    push rbx
    mov rbx, rdi                   ; 盘符先存：fs_load 会改 rdi
    mov rdi, 1024
    call fs_load
    mov r12d, [rsi + 28]           ; 主盘的家
    movzx eax, word [rbx]
    cmp ax, 0x03B1
    je .alpha
    mov qword [fs_base], 0x60000
    mov qword [fs_start], 0
    jmp .set
.alpha:
    mov qword [fs_base], 0x40000
    mov qword [fs_start], 1024
.set:
    mov rdi, [fs_start]
    call fs_load
    mov r13d, [rsi + 28]           ; 那块盘的家
    mov rsi, line_shares
    call puts64
    mov rax, r13
    call put_hex64
    mov al, ' '
    call putc64
    cmp r12d, r13d
    jne .stranger
    call list_shares_here          ; 同一家：列它
    mov rax, 1
    jmp .back
.stranger:
    mov rsi, line_not_family
    call puts64
    xor eax, eax
.back:
    mov qword [fs_base], 0x40000
    mov qword [fs_start], 1024
    pop rbx
    pop r12
    ret

; 三步：先标记 β 上的一个文件、再列 β 的共享（这时还不是一家人，该被挡住）、
; 然后加入、再列一次（这时该看得见）。
;
; 第三步与第四步之间只发生了一件事：家 ID 被写过去了。所以两次读数的差别只能来自那里。
run_homeshare_test:
    ; 先列一次：家不同，该被挡住
    mov rdi, fs_beta_drive
    call fs_shares_at
    call run_join_test
    ; 标记放在加入之后：share 要走 fs_open_path，而它现在有门 ——
    ; 在加入之前标记一块外人的盘，门会把这条管理动作也挡住。
    mov rdi, fs_share_beta
    call fs_share
    mov rdi, fs_beta_drive
    call fs_shares_at
    ret

; 第一条走完再走一遍，看会不会多出一条 —— 标记不是追加，这一点要能看出差别：
; 一个「往清单里加一条」的实现，走两遍就会出现两个 docs。
run_share_test:
    mov rsi, line_share_first
    call puts64
    mov rdi, fs_share_path
    call fs_share
    test rax, rax
    jz .failed
    call run_shares
    mov rsi, line_share_again
    call puts64
    mov rdi, fs_share_path
    call fs_share
    call run_shares
    ret
.failed:
    mov rsi, line_share_failed
    call puts64
    ret

; ======================================================================
; PCI 枚举：先证明「有一块网卡」
; ======================================================================
;
; 家庭组要跨机器，跨机器要网络，而网络要一块网卡。可是「有网卡」与「能发一个包」
; 之间隔着一整个协议栈，所以第一步就要选一件不需要协议的事 —— 那就是 PCI 配置空间里
; 那两个数：vendor 与 device。
;
; 它们由硬件自己给出，不由我们解释。读对了它们，就说明「这块网卡在这台机器上、而这条
; 总线读得通」；读不对，往后所有网络的事都会在别处找原因。
;
; 访问方式只有两个端口：0xCF8 写地址（bit 31 置一表示使能），0xCFC 读数据。
; rdi = bus<<16 | dev<<11 | func<<8 | offset，出 eax。
pci_read:
    mov eax, edi
    or eax, 0x80000000
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    ret

; 写配置空间里那一个 dword。rdi 与 pci_read 同形，esi = 要写的值。
;
; 为什么需要写：设备的 MMIO 那一片要先由 PCI 命令寄存器的 Memory Space 位（bit 1）
; 打开，它才会响应访问。不开的时候读回来的是总线上别的东西 —— 而「读出了数」会让
; 这件事看起来像「设备在工作」，这是这一台机器上最会骗人的一种失败。
pci_write:
    mov eax, edi
    or eax, 0x80000000
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    mov eax, esi
    out dx, eax
    ret

; 扫 0 号总线上的 32 个设备槽，凡是有 vendor 的都报出来。
;
; 只扫 0 号总线、只扫 func 0：这台机器的设备都在那里，而多扫两级要把「怎么认多功能的
; 设备」也写进来 —— 那一层对「有没有网卡」这个问题没有帮助。
run_pci_scan:
    xor r12, r12                   ; 设备号 0..31
.dev:
    mov rdi, r12
    shl rdi, 11
    call pci_read
    cmp ax, 0xFFFF
    je .next
    mov r13d, eax                  ; vendor | device<<16
    mov rsi, line_pci
    call puts64
    mov rax, r12
    call put_num64
    mov al, ' '
    call putc64
    mov rax, r13
    call put_hex64
    call put_nl64
.next:
    inc r12
    cmp r12, 32
    jb .dev
    ret

; 把一个物理地址所在的那个 2 MB 页映进页表（身份映射）。rdi = 物理地址，出 rax = 同一地址。
;
; 为什么需要它：页表只映了前 1 GB，而 AHCI 的 ABAR 是 0xF0804000 —— 分页开着的时候，
; 一条普通的读就会 #PF。而 #PF 在这里看起来像「那一片不存在」，与「那个控制器没有寄存器」
; 分不开，所以先把它变成普通内存，再去判断别的事。
;
; 四级分页的三层已经有了：PML4 在 0x1000、PDPT 在 0x2000、PD 在 0x1000。这里补的是
; 「PDPT 的某一项还没有 PD」那一格 —— 前 1 GB 用的恰好是 PDPT[0]，而 0xF0804000 落在
; PDPT[3]，那一项是零。所以第一次来的时候要现造一个全零的 PD 页。
;
; 池从 0x4000 起：页表占 0x1000 到 0x4000，0x4000 往上到 0x7E00（第二段被加载的地方）
; 是空的。一页一个 PD，够用很久。
map_page_2m:
    push r12
    push r13
    push r14
    mov r14, rdi                   ; 入参保在 r14 里。这一条路上 rdi 会被改成 PD 页的地址
                                   ; （下面 rep stosq 要用它），于是末尾那句「返回 rdi」
                                   ; 交出去的是 PD 页 —— 而调用者拿它当设备寄存器读。
                                   ;
                                   ; 这个 bug 藏了很久，因为它只在**第一次**映射某一个
                                   ; 4 GB 区段时显形（那一格还没有 PD）；第二次走复用分支、
                                   ; rdi 不被改，返回值就对了。于是「设备寄存器读得出值」
                                   ; 与「读到的是页表页」在同一段代码里同时成立。
                                   ; AHCI 那一整章的所有怪读数（CAP 0x18920F、写 CAP 读回
                                   ; 自己、三个芯片组同值）全部来自这里。
    mov r12, rdi
    shr r12, 30
    and r12, 0x1FF                 ; PDPT 索引（bits 38:30）
    mov r13, rdi
    shr r13, 21
    and r13, 0x1FF                 ; PD 索引（bits 29:21）
    mov rax, [0x2000 + r12 * 8]
    test al, 1
    jnz .have_pd
    ; 这一格还没有 PD：分配一页，清干净，再挂上去。
    ;
    ; 不用固定地址，因为 0x4000 到 0x7E00 那一段不是空的：0x1000 到 0x4000 是页表、
    ; **0x5000 到 0x6000 是 IDT**（256 项，每项 16 字节）、0x7E00 起是第二段自己。
    ; 第一版把池写成「从 0x4000 起，每次加 0x1000」，于是第二次调用（对照实验那一次）
    ; 取到 0x5000，rep stosq 把 IDT 整整一页清成了零 —— 而症状离这件事很远：
    ; 「异常」那一条红，ud2 找不到处理者。一个池的起点写错，坏的是三个调用之后的事。
    ;
    ; alloc64 只保证 16 字节，而 PD 页要 4 KB 对齐，所以取整到 4096。
    mov rax, 8192
    call alloc64
    add rax, 4095
    and rax, -4096
    push rax
    mov rdi, rax
    xor eax, eax
    mov ecx, 512
    cld                            ; rep 系列的清零要看方向位。这一页是页表，
                                   ; 填反了就是「映射上了而内容全是垃圾」
    rep stosq                      ; 512 个 qword = 4 KB
    pop rax
    or rax, 3                      ; present + writable
    mov [0x2000 + r12 * 8], rax
.have_pd:
    mov rax, [0x2000 + r12 * 8]
    and rax, -4096                 ; PD 的物理地址（低 12 位是标志位）
    mov rdx, r14                   ; 用保住的那份入参，不是 rdi —— 新建 PD 页那一支里
                                   ; rdi 已经被改成 PD 页的地址了，而这一句如果照旧取 rdi，
                                   ; 写进 PD 的就是「堆的地址」，于是那一段虚拟地址会映到
                                   ; 堆上：读设备寄存器读到的是内存，而写入读回自己。
    and rdx, 0xFFE00000            ; 2 MB 对齐
    or rdx, 0x83                   ; present + writable + large page
    mov [rax + r13 * 8], rdx
    mov rax, r14
    pop r14
    pop r13
    pop r12
    ret

; ======================================================================
%if 0
; AHCI 那两个探测已经判死，而那一章的读数后来被证明是假的 —— 代码留着（%if 0 关掉，不进二进制），
; 因为引导扇区一次 int 0x13 不能跨 64 KB，而第二段从 0x7E00 起最多 64 个扇区。
; map_page_2m 与 pci_write 是通用的，它们不在这一段里。
; AHCI：先看见那条不是 0x1F* 的通道
; ======================================================================
;
; 盘健康的五个探测都在 IDE 那条路上回一页零，所以下一步不是再试一次，是换一条路。
; 换之前要先看见那条路存在：一个 AHCI 控制器，它的寄存器在 MMIO 那一片（ABAR 指的
; 那一段），不在 0x1F0 到 0x1F7 这几个端口上。
;
; 这一块只做两件事：找到它、报出它的 ABAR。不碰盘、不发命令。
; 为什么切在这里：ABAR 的地址要先看得见，才知道后面能不能走 —— 如果它落在恒等映射的
; 那一 GB 之外，那就要先把一个任意物理地址映进页表，而那是另一块砖，不该混在这一块里猜。
;
; PCI 配置空间 offset 0x08 的高 24 位是 class/subclass/prog-if。
; SATA/AHCI 是 0x010601：class 01 大容量存储、subclass 06 SATA、prog-if 01 AHCI。
; 比 class 而不比 vendor/device：VBox 的 AHCI 是 8086:2829，换一台机器就不一样，
; 而 class code 跟的是规范。
run_ahci_probe:
    xor r12, r12                   ; 设备号
.dev:
    cmp r12, 32
    jae .none
    xor r15, r15                   ; 功能号
.func:
    cmp r15, 8
    jae .next_dev
    mov edi, r12d
    shl edi, 11
    mov eax, r15d
    shl eax, 8
    or edi, eax
    mov [pci_devbase], rdi         ; dev 与 func 都记住：后面每一次读配置空间都要用
    or edi, 0x08
    call pci_read
    mov r13d, eax
    shr r13d, 8
    cmp r13d, 0x010601
    je .found
    inc r15
    jmp .func
.next_dev:
    inc r12
    jmp .dev
.found:
    ; 先把 PCI 命令寄存器的 Memory Space（bit 1）与 Bus Master（bit 2）置上。
    ; 这一步在规范里是「设备能不能被访问」的开关，而不是优化 —— 不置的时候 MMIO
    ; 那一片读回来的是总线上的别的东西，而它会有结构、会变、写入还能读回来，
    ; 于是看起来像一个活着的控制器。这一条假设是照着已经读到的三个怪现象立的：
    ; PxSIG 是零、PxIS 写 0xFFFFFFFF 就读回 0xFFFFFFFF、CAP 两次不同。
    mov edi, [pci_devbase]
    or edi, 0x04
    call pci_read
    mov [pci_cmd_before], rax
    mov esi, eax
    or esi, 6
    mov edi, [pci_devbase]
    or edi, 0x04
    call pci_write
    mov edi, [pci_devbase]
    or edi, 0x04
    call pci_read
    mov [pci_cmd], rax
    mov rsi, line_ahci_pcicmd
    call puts64
    mov rax, [pci_cmd_before]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [pci_cmd]
    call put_hex64
    call put_nl64
    mov edi, [pci_devbase]
    or edi, 0x24                   ; BAR5：AHCI 的 ABAR
    call pci_read
    and eax, 0xFFFFFFF0            ; 低四位是标志位，ABAR 按 4 KB 对齐
    mov [ahci_abar], rax
    mov rsi, line_ahci_found
    call puts64
    mov rax, r12
    call put_num64
    mov al, '.'
    call putc64
    mov rax, r15
    call put_num64
    mov al, ' '
    call putc64
    mov rax, [ahci_abar]
    call put_hex64
    call put_nl64
    ; 映上去，再读 CAP 与 PI。读了它们，才说明那一片真的能当内存用 ——
    ; 「BAR 报了一个数」与「那个数指的地址读得通」是两件事。
    mov rdi, [ahci_abar]
    call map_page_2m
    mov r13, rax
    mov eax, [r13]                 ; CAP：能力位
    mov [ahci_cap], rax
    ; CAP 是只读寄存器。往它写一个显眼的值再读回来 —— 真的 CAP 不会变，
    ; 而一段普通内存会变成那个值。这是分辨「那一片是真的设备寄存器」与
    ; 「那一片只是被映射上的一段内存」最便宜的一步，而它决定后面所有读数的可信度。
    mov dword [r13], 0xDEADBEEF
    mov eax, [r13]
    mov [ahci_cap_after], rax
    mov rsi, line_ahci_ro
    call puts64
    mov rax, [ahci_cap]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [ahci_cap_after]
    call put_hex64
    call put_nl64
    ; VS（偏移 0x10）：AHCI 1.0 的版本寄存器是 0x00010000。它是「那一片是不是真的
    ; AHCI 寄存器组」最硬的一条 —— 比 CAP 硬，因为 CAP 有些实现不保护写入，
    ; 而 VS 不会有第二个值。写到 CAP 上那一次实验因此只能算半个证据。
    mov eax, [r13 + 0x10]
    mov [ahci_sig], rax
    mov rsi, line_ahci_regs
    call puts64
    mov rax, [ahci_sig]
    call put_hex64
    call put_nl64
    mov eax, [r13]                 ; 写完之后再取一次，后面的读数用这一个
    ; 对照实验：映一个肯定没有设备的物理地址（1.25 GB，RAM 只有 32 MB），读它。
    ; 如果那里读出来与 ABAR 那一片是同一个 0x18920F，那 0x18920F 就不是「控制器的
    ; 能力位」，而是「不存在的物理地址上的固定返回值」—— 而那样的话，ABAR 那几次
    ; 读数全部作废，包括「CAP 读得出」这件事。一个读数没有对照，就只是一个数。
    mov rdi, 0x50000000
    call map_page_2m
    mov r13, rax
    mov eax, [r13]
    mov [ahci_ghc_before], rax
    mov rsi, line_ahci_ctl
    call puts64
    mov rax, [ahci_ghc_before]
    call put_hex64
    call put_nl64
    mov r13, [ahci_abar]
    ; GHC.AE（bit 31）：AHCI 规范要求驱动先把这一位置上，MMIO 那一片才算启用。
    ; 置之前读 PI 得到的是一个零 —— 而那个零有两种解释：「一个 port 都没接东西」
    ; 与「控制器还没被启用」，两种在串口上一模一样。
    mov eax, [r13 + 4]
    mov [ahci_ghc_before], rax
    or eax, 0x80000000
    mov [r13 + 4], eax
    mov eax, [r13 + 4]
    mov [ahci_ghc], rax
    mov eax, [r13 + 0x0C]          ; PI：哪些 port 上接了东西，一位一个 port
    mov [ahci_pi], rax
    ; PxSSTS：port 0 的状态。低四位是设备检测（三表示有设备且通信已建立），
    ; 它比 PI 更细 —— PI 说「这个 port 属于这个控制器」，SSTS 说「这里真的有东西」。
    mov eax, [r13 + 0x100 + 0x28]
    mov [ahci_ssts], rax
    mov rsi, line_ahci_cap
    call puts64
    mov rax, [ahci_cap]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [ahci_pi]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [ahci_ssts]
    call put_hex64
    call put_nl64
    ; 启用的前后各一个 GHC：AE 真的写进去了才叫启用
    mov rsi, line_ahci_ghc
    call puts64
    mov rax, [ahci_ghc_before]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [ahci_ghc]
    call put_hex64
    call put_nl64
    ret
.none:
    mov rsi, line_ahci_none
    call puts64
    ret

; ======================================================================
; AHCI 的第一条命令：IDENTIFY DEVICE
; ======================================================================
;
; 盘健康那五个探测在 IDE 那条路上全回一页零。AHCI 这一侧现在已经证明三件事：控制器在
; 13 号槽、ABAR 是 0xF0804000、那一片映射好之后 CAP 与 GHC 都读得出来（置 AE 位能写进去
; 再读回来）。剩下的就是「发一条命令，让盘自己说话」。
;
; PI 与 PxSSTS 报出来都是零，而 VBox 的日志说 port 0 上有一块盘
; （AHCI: LUN#0: disk, total number of sectors 2048）。这两件事不矛盾：VBox 在驱动
; 初始化之前不填 PI。所以这一块不按 PI 枚举 port —— 直接对 port 0 做初始化，而它到底
; 有没有东西，由 PxSIG 与 IDENTIFY 的成败回答。
;
; 四个缓冲区，其中三个有对齐要求（规范定的，不是偏好）：
;   命令列表 1 KB，1024 字节对齐；FIS 接收区 256 字节；命令表 128 字节。
; alloc64 只保证 16 字节，所以分配之后自己往上取整 —— 取整，而不是希望它刚好对齐。
run_ahci_identify:
    mov rax, 2048
    call alloc64
    add rax, 1023
    and rax, -1024                 ; 命令列表要 1024 字节对齐，而 alloc64 只保证 16
    mov [ahci_cmdlist], rax
    mov rdi, rax
    mov rcx, 1024
    xor eax, eax
    rep stosb
    mov rax, 512
    call alloc64
    add rax, 255
    and rax, -256
    mov [ahci_fis], rax
    mov rdi, rax
    mov rcx, 256
    xor eax, eax
    rep stosb
    mov rax, 512
    call alloc64
    add rax, 127
    and rax, -128
    mov [ahci_cmdtbl], rax
    mov rdi, rax
    mov rcx, 512
    xor eax, eax
    rep stosb
    mov rax, 512
    call alloc64
    mov [ahci_idbuf], rax
    mov rdi, rax
    mov rcx, 512
    xor eax, eax
    rep stosb
    ; BOHC（偏移 0x28）是 BIOS 与 OS 的交接闸：BOS（bit 0）是「BIOS 还占着」的标志。
    ; 规范说驱动初始化时若 BOS 是 1，就置 OOS（bit 1）等 BOS 清零；BIOS 不放手的话
    ; 可以置 BOH（bit 31）强制拿走。这一台机器上 VBox 的 BIOS 确实通过 AHCI 访问过盘
    ; （日志里 AHCI 0-P#0: 0x800 sectors），而它未必做了交接 —— 那会让控制器对 OS
    ; 这一侧半锁着，症状正是「通用寄存器读得出、port 一片零」。
    mov r13, [ahci_abar]
    mov eax, [r13 + 0x28]
    mov [ahci_bohc], rax
    test eax, 1
    jz .bohc_done
    or eax, 2
    mov [r13 + 0x28], eax
    mov rcx, 20000000
.bohc_wait:
    mov eax, [r13 + 0x28]
    test eax, 1
    jz .bohc_done
    dec rcx
    jnz .bohc_wait
    ; 还没放手：强制拿走
    mov eax, [r13 + 0x28]
    or eax, 0x80000000
    mov [r13 + 0x28], eax
.bohc_done:
    mov eax, [r13 + 0x28]
    mov [ahci_bohc2], rax
    mov rsi, line_ahci_bohc
    call puts64
    mov rax, [ahci_bohc]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [ahci_bohc2]
    call put_hex64
    call put_nl64
    ; 只置 AE，不发起 HBA reset。
    ;
    ; 规范里 AE 之后要一次 HR 才算切到 AHCI 模式，而这一台机器上 HR 写进去之后
    ; 一直不清零：写之前 GHC 是 0x80008E00（HR=0），写之后是 0x80000001（HR=1），
    ; 而它再也不回来了。而 HR 期间访问 port 寄存器是非法的 —— 于是 PI 与整片 port 区
    ; 读出来都是零。这一条把之前几轮的读数解释干净了：「控制器说没有设备」与
    ; 「控制器还在复位里」在串口上一模一样。
    ;
    ; 所以这一版不发 HR：它需要更长的等待，或者根本不该由这一层发起（BIOS 已经做过
    ; 一次，VBox 的日志里是 Reset the HBA）。这件事记在 design/AHCI.txt 里。
    mov r13, [ahci_abar]
    mov eax, [r13 + 4]
    or eax, 0x80000000
    mov [r13 + 4], eax
    mov eax, [r13 + 4]
    mov [ahci_ghc], rax
    mov eax, [r13 + 0x0C]
    mov [ahci_pi], rax
    mov rsi, line_ahci_pi2
    call puts64
    mov rax, [ahci_pi]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [ahci_ghc]
    call put_hex64
    call put_nl64
    ; 六个 BAR 全报一遍。AHCI 规范把 ABAR 放在 BAR5，而 VS 读成零说明那一片
    ; 不是 AHCI 的寄存器组 —— 那就先把「VBox 把这个控制器放在哪些 BAR 上」看清楚，
    ; 再谈偏移。一次六个数比继续猜便宜。
    mov qword [ahci_cap], 0
.bar_loop:
    mov rax, [ahci_cap]
    cmp rax, 6
    jae .bar_done
    mov edi, [pci_devbase]
    add edi, 0x10
    lea eax, [rax * 4]
    add edi, eax
    call pci_read
    mov [ahci_tfd], rax
    mov rsi, line_ahci_bar
    call puts64
    mov rax, [ahci_tfd]
    call put_hex64
    call put_nl64
    inc qword [ahci_cap]
    jmp .bar_loop
.bar_done:
    ; port 0 的寄存器从 ABAR + 0x100 起
    mov r13, [ahci_abar]
    add r13, 0x100
    mov [ahci_port], r13
    ; 先停：清 ST，再等 CR 真的落下 —— 控制器跑着的时候改 CLB 是未定义行为
    mov eax, [r13 + 0x18]
    and eax, -2
    mov [r13 + 0x18], eax
.wait_cr:
    mov eax, [r13 + 0x18]
    test eax, 0x8000
    jnz .wait_cr
    ; 四个基址：命令列表与 FIS 接收区。高 32 位都写零 —— 缓冲区都在 4 MB 起，
    ; 物理地址不到 4 GB，所以高位真的没有东西可写。
    mov rax, [ahci_cmdlist]
    mov [r13 + 0x00], eax
    mov dword [r13 + 0x04], 0
    mov rax, [ahci_fis]
    mov [r13 + 0x08], eax
    mov dword [r13 + 0x0C], 0
    ; FIS 接收使能，再让命令处理跑起来。分两次写：规范要求 FRE 先于 ST。
    ; SUD（bit 1，spin-up device）也要置：规范说硬盘要先转起来，命令才谈得上。
    mov eax, [r13 + 0x18]
    or eax, 0x12
    mov [r13 + 0x18], eax
    mov eax, [r13 + 0x18]
    or eax, 1
    mov [r13 + 0x18], eax
    ; COMRESET。VBox 的日志说得很清楚：BIOS 通过 AHCI 认出了 port 0 上的盘
    ; （AHCI 0-P#0: 0x800 sectors），随后自己 Reset the HBA —— 于是 port 的状态归零，
    ; 而 SSTS 与 PxSIG 都读成零。真实驱动在这种时候要主动把 PHY 重跑一遍：
    ; PxSCTL 的 DET（bits 3:0）写 1，等它自己回 0，再看 PxSSTS 的 DET 是否变成 3。
    ; 「控制器说没设备」与「PHY 还没握手」在读数上一模一样，区别只在于有没有重跑过。
    mov eax, [r13 + 0x2C]
    and eax, 0xFFFFFFF0
    or eax, 1
    mov [r13 + 0x2C], eax
    mov rcx, 10000000
.com_wait:
    mov eax, [r13 + 0x2C]
    and eax, 0xF
    jz .com_done
    dec rcx
    jnz .com_wait
.com_done:
    mov rcx, 100000000
.det_wait:
    mov eax, [r13 + 0x28]
    and eax, 0xF
    cmp eax, 3
    je .det_ok
    dec rcx
    jnz .det_wait
.det_ok:
    ; 置 ST 之后再读一次这两样：probe 那一次是在 ST 之前读的，那时 SSTS 是零
    ; 只说明「控制器还没开始处理这一条 port」，与「这条线没东西」不是一回事。
    mov eax, [r13 + 0x24]
    mov [ahci_sig], rax
    mov eax, [r13 + 0x28]
    mov [ahci_ssts], rax
    ; PxSIG：ATA 盘应当是 0x101。它不是零，就说明这个 port 后面真的有东西，
    ; 而这一读数与 PI 那个零不冲突 —— 一个说「控制器认领了哪些 port」，
    ; 一个说「这一条线上握手了没有」。
    mov eax, [r13 + 0x24]
    mov [ahci_sig], rax
    ; 六个 port 的 PxSSTS 一次报完：DET 那四位是设备检测。
    ; 「port 0 是空的」与「所有 port 都是空的」是两件事 —— 后者说明这块盘在
    ; 控制器眼里不存在，那问题就在配置那一侧，而不在我的初始化顺序上。
    mov rsi, line_ahci_ports
    call puts64
    mov qword [ahci_cap], 0
.all_loop:
    mov rax, [ahci_cap]
    cmp rax, 6
    jae .all_done
    shl rax, 7                     ; 0x80 一个 port
    mov r13, [ahci_abar]
    add r13, 0x100
    add r13, rax
    mov eax, [r13 + 0x28]
    mov [ahci_tfd], rax
    mov rax, [ahci_tfd]
    call put_hex64
    mov al, ' '
    call putc64
    inc qword [ahci_cap]
    jmp .all_loop
.all_done:
    call put_nl64
    mov r13, [ahci_port]
    ; 命令头（32 字节一条）：CFL 是 5 个 dword 的 FIS，一条 PRDT 表项
    mov rbx, [ahci_cmdlist]
    mov dword [rbx + 0], 5
    mov dword [rbx + 4], 1
    mov rax, [ahci_cmdtbl]
    mov [rbx + 8], eax
    mov dword [rbx + 12], 0
    ; 命令表：CFIS 在偏移 0，PRDT 在偏移 0x80
    mov rbx, [ahci_cmdtbl]
    mov byte [rbx + 0], 0x27       ; H2D Register FIS
    mov byte [rbx + 1], 0x80       ; C = 1：这一条是命令，不是控制
    mov byte [rbx + 2], 0xEC       ; IDENTIFY DEVICE
    mov rax, [ahci_idbuf]
    mov [rbx + 0x80], eax          ; PRDT 的数据基址
    mov dword [rbx + 0x84], 0
    mov dword [rbx + 0x8C], 511    ; DBC = 512 - 1，少一才是字节数
    ; 发命令：先清 PxIS，再置 PxCI 的槽 0
    mov r13, [ahci_port]
    mov dword [r13 + 0x10], 0xFFFFFFFF
    mov dword [r13 + 0x38], 1
    mov rcx, 50000000
.wait:
    mov eax, [r13 + 0x38]
    test eax, 1
    jz .issued
    dec rcx
    jnz .wait
    ; 超时也要留下证据。「命令没完成」有四种样子，而四种要改的地方完全不同：
    ;   PxCMD 的 ST 位没置上 —— 写没生效（或者控制器不接受这一次写）
    ;   PxIS 报了某一位 —— 命令被拒，理由写在状态里
    ;   PxTFD 的 ERR 位 —— 命令执行了而盘回了错
    ;   三个都是零而 CI 仍是一 —— 命令根本没被取走，问题在命令列表或命令表那一侧
    mov rsi, line_ahci_timeout
    call puts64
    mov eax, [r13 + 0x18]
    mov [ahci_pxcmd], rax
    mov eax, [r13 + 0x10]
    mov [ahci_pxis], rax
    mov eax, [r13 + 0x20]
    mov [ahci_tfd], rax
    mov rsi, line_ahci_stuck
    call puts64
    mov rax, [ahci_sig]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [ahci_pxcmd]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [ahci_pxis]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [ahci_tfd]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [ahci_ssts]
    call put_hex64
    call put_nl64
    ret
.issued:
    mov eax, [r13 + 0x20]          ; PxTFD：bit 0 是 ERR、bit 6 是 DRDY
    mov [ahci_tfd], rax
    mov rsi, line_ahci_sig
    call puts64
    mov rax, [ahci_sig]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [ahci_tfd]
    call put_hex64
    call put_nl64
    ; 型号在 IDENTIFY 的 word 27 到 46，每个 word 是大端（高字节在前）——
    ; 而这一台是小端机，所以两个字节要换一下位置，否则打出来是倒着的。
    mov rsi, [ahci_idbuf]
    add rsi, 54                    ; 27 * 2
    lea rdi, [ahci_model]
    mov rcx, 20
.model_loop:
    mov ax, [rsi]
    xchg al, ah
    mov [rdi], al
    inc rdi
    mov [rdi], ah
    inc rdi
    add rsi, 2
    dec rcx
    jnz .model_loop
    mov byte [rdi], 0
    mov rsi, line_ahci_model
    call puts64
    lea rsi, [ahci_model]
    call puts64
    jmp put_nl64

; ======================================================================
%endif
; NVMe：AHCI 的 port 侧在这台机器上不通，换一条
; ======================================================================
;
; AHCI 那条路走到了同一处：控制器的通用寄存器是真的（CAP 读得出，而映一个肯定
; 没有设备的地址读不到同一个值 —— 那个对照实验是必要的，没有它「读得出值」什么也
; 说明不了），而**六个 port 的 PxSSTS 全是零**。VBox 的 AHCI 对 OS 这一侧报告
; 「没有任何设备」，而 BIOS 通过它访问过盘。所以那是配置与实现之间的事，
; 不是我这边初始化的顺序 —— 六条排除都写在 design/AHCI.txt 里。
;
; NVMe 是另一条：它没有 IDE 兼容模式那一段历史，寄存器全在 BAR0 的 MMIO 里，
; 而版本寄存器 VS 是必需的（1.0 是 0x00010000）。所以「那一片是不是真的控制器」
; 用 VS 一个数就答得出来，不必再绕 CAP 怎么写。
;
; class code 是 0x010802：class 01、subclass 08（非易失存储）、prog-if 02（NVMe）。
run_nvme_probe:
    xor r12, r12
.dev:
    cmp r12, 32
    jae .none
    xor r15, r15
.func:
    cmp r15, 8
    jae .next_dev
    mov edi, r12d
    shl edi, 11
    mov eax, r15d
    shl eax, 8
    or edi, eax
    mov [pci_devbase], rdi
    or edi, 0x08
    call pci_read
    mov r13d, eax
    shr r13d, 8
    cmp r13d, 0x010802
    je .found
    inc r15
    jmp .func
.next_dev:
    inc r12
    jmp .dev
.found:
    ; PCI 命令寄存器的 Memory Space 与 Bus Master。这一次不是「顺手」——
    ; 没有 Bus Master，控制器取不到提交队列里的命令（DMA 被禁），而 CSTS 照样会
    ; 报 RDY=1：于是「控制器就绪」与「命令能跑」看起来是同一件事，而实际差着一整条
    ; DMA 通道。AHCI 那个设备我置过，NVMe 是另一个设备，得单独置。
    ; 实测的形状：CC 的 EN 起了、CSTS 的 RDY 起了、两个队列基址读回也都是我写的值，
    ; 而写门铃之后 SQ 的 head 一动不动 —— 那就是「命令没被取走」，而原因不在队列。
    mov edi, [pci_devbase]
    or edi, 0x04
    call pci_read
    mov [nvme_pcicmd_before], rax
    mov esi, eax
    or esi, 6
    mov edi, [pci_devbase]
    or edi, 0x04
    call pci_write
    mov edi, [pci_devbase]
    or edi, 0x04
    call pci_read
    mov [nvme_pcicmd], rax
    mov rsi, line_nvme_pcicmd
    call puts64
    mov rax, [nvme_pcicmd_before]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [nvme_pcicmd]
    call put_hex64
    call put_nl64
    ; BAR0 是 64 位的：低半在 0x10、高半在 0x14。高半不移上去的话，
    ; 落在 4 GB 之外的 BAR 会被读成一个低地址，而那看起来像「设备在低处」。
    mov edi, [pci_devbase]
    or edi, 0x10
    call pci_read
    and eax, 0xFFFFFFF0
    mov [nvme_bar], rax
    mov edi, [pci_devbase]
    or edi, 0x14
    call pci_read
    shl rax, 32
    or [nvme_bar], rax
    mov rsi, line_nvme_found
    call puts64
    mov rax, r12
    call put_num64
    mov al, '.'
    call putc64
    mov rax, r15
    call put_num64
    mov al, ' '
    call putc64
    mov rax, [nvme_bar]
    call put_hex64
    call put_nl64
    mov rdi, [nvme_bar]
    call map_page_2m
    mov r13, rax
    ; 诊断：PDPT[3] 那一项（0x2000 + 3*8）与 map_page_2m 交回的地址。
    ; 「映射上了而读不到」有两种样子：项没写进去（PDPT[3] 是零或者没有 present 位），
    ; 或者项写了而 PD 那一格不对。这两个数能把它们分开。
    mov rax, [0x2018]
    mov [nvme_vs], rax
    mov rax, r13
    mov [nvme_cap], rax
    mov rsi, line_nvme_map
    call puts64
    mov rax, [nvme_vs]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [nvme_cap]
    call put_hex64
    call put_nl64
    mov eax, [r13 + 8]             ; VS：版本
    mov [nvme_vs], rax
    mov eax, [r13]                 ; CAP 低半：MQES 在 bits 15:0
    mov [nvme_cap], rax
    mov rsi, line_nvme_regs
    call puts64
    mov rax, [nvme_vs]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [nvme_cap]
    call put_hex64
    call put_nl64
    ret
.none:
    mov rsi, line_nvme_none
    call puts64
    ret

; ======================================================================
; NVMe 的第一条命令：Get Log Page 拿 SMART / Health
; ======================================================================
;
; 为什么这一条比 IDENTIFY 更值：Get Log Page（opcode 0x02，LID 0x02）一页里就有
; Composite Temperature、Available Spare、Percentage Used、Media Errors、
; Data Units Read/Written —— 盘健康要的那五样全在，而它不需要先过「盘认不认得这组
; 命令」那一道门。所以这条路的第一条命令就是它，而不是 IDENTIFY。
;
; 初始化五步（规范 3.1.1 的顺序）：
;   一、CC.EN 清零，等 CSTS.RDY 落下 —— 控制器跑着的时候改队列基址是未定义行为
;   二、AQA 写队列深度（我们只要 4 项，一条命令一次）
;   三、ASQ / ACQ 写 64 位物理地址，两块都要页对齐
;   四、CC 置 EN、IOSQES=6、IOCQES=4（提交项 64 字节、完成项 16 字节）
;   五、等 CSTS.RDY 起来
;
; 三块内存都从堆里分、取整到 4 KB。不用固定地址：0x1000 到 0x7E00 那一段已经满了
; （页表、IDT、第二段自己），而 AHCI 那一块刚刚为这件事付过一次学费 ——
; 池子起点写错，清掉的是 IDT。
run_nvme_health:
    mov rax, 8192
    call alloc64
    add rax, 4095
    and rax, -4096
    mov [nvme_asq], rax
    mov rdi, rax
    mov rcx, 4096
    xor eax, eax
    rep stosb
    mov rax, 8192
    call alloc64
    add rax, 4095
    and rax, -4096
    mov [nvme_acq], rax
    mov rdi, rax
    mov rcx, 4096
    xor eax, eax
    rep stosb
    mov rax, 8192
    call alloc64
    add rax, 4095
    and rax, -4096
    mov [nvme_log], rax
    mov rdi, rax
    mov rcx, 4096
    xor eax, eax
    rep stosb
    mov rax, 8192
    call alloc64
    add rax, 4095
    and rax, -4096
    mov [nvme_ns], rax
    mov rdi, rax
    mov rcx, 4096
    xor eax, eax
    rep stosb
    mov r13, [nvme_bar]
    ; 一、停
    mov eax, [r13 + 0x14]
    and eax, -2
    mov [r13 + 0x14], eax
    mov rcx, 20000000
.w0:
    mov eax, [r13 + 0x1C]
    test eax, 1
    jz .stop
    dec rcx
    jnz .w0
.stop:
    ; 二、队列深度：两边都是 4 项，所以字段写 3
    mov dword [r13 + 0x24], 0x00030003
    ; 三、两个基址（64 位，缓冲区在 4 MB 起，所以高位真的是零）
    mov rax, [nvme_asq]
    mov [r13 + 0x28], rax
    mov rax, [nvme_acq]
    mov [r13 + 0x30], rax
    ; 四、CC：EN | IOSQES=6 | IOCQES=4
    mov eax, 6
    shl eax, 16
    mov edx, 4
    shl edx, 20
    or eax, edx
    or eax, 1
    mov [r13 + 0x14], eax
    ; 五、等 RDY
    mov rcx, 20000000
.w1:
    mov eax, [r13 + 0x1C]
    test eax, 1
    jnz .ready
    dec rcx
    jnz .w1
    mov rsi, line_nvme_noen
    call puts64
    ret
.ready:
    ; 诊断：CC、CSTS、以及两个队列基址读回来是不是我写进去的。
    ; 「命令不完成」有四种样子，而这四个数能把它们分开：
    ;   CC 的 EN 没置上 —— 写没生效；
    ;   CSTS 的 RDY 没起来 —— 控制器没就绪（上面那一关已经挡住这一种）；
    ;   两个基址读回来不对 —— 寄存器没接受那两个地址；
    ;   三个都对而队列不动 —— 问题在命令项或门铃那一侧。
    mov eax, [r13 + 0x14]
    mov [nvme_cw], rax
    mov eax, [r13 + 0x1C]
    mov [nvme_spare], rax
    mov eax, [r13 + 0x28]
    mov [nvme_used], rax
    mov eax, [r13 + 0x30]
    mov [nvme_media], rax
    mov rsi, line_nvme_diag
    call puts64
    mov rax, [nvme_cw]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [nvme_spare]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [nvme_used]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [nvme_media]
    call put_hex64
    call put_nl64
    ; 命令项 64 字节：opcode 在 byte 0，NSID 在 dword 1，PRP1 在 qword 3，
    ; CDW10 在 0x28。
    ;
    ; 这一条是 Identify Controller（opcode 0x06，CDW10 的 CNS 写 1）。
    ; 先要的为什么不是 SMART / Health：那一条也跑通了（status 是 0，命令成功），
    ; 而 VBox 的 NVMe 返回的那一页全是零 —— 它没有真的温度与寿命可报。
    ; 而 Identify Controller 的 offset 24 那 40 个字节是型号，是盘自己报的，
    ; 也是 Kohane 第五层那条判据的原话：「型号那几个字符是盘自己报的，
    ; 不是代码里写死的」。所以这一条更值得先钉住。
    mov rbx, [nvme_asq]
    mov dword [rbx + 0x00], 0x06
    mov dword [rbx + 0x04], 0
    mov rax, [nvme_log]
    mov [rbx + 0x18], rax
    mov dword [rbx + 0x28], 1
    ; 门铃：SQ0 的 tail 走到 1
    mov dword [r13 + 0x1000], 1
    ; 完成项 16 字节，最后那个 word 的 bit 0 是 phase —— 从零翻成一就是「完成了」
    mov rbx, [nvme_acq]
    mov rcx, 50000000
.wcq:
    mov eax, [rbx + 0x0E]
    test eax, 1
    jnz .got
    dec rcx
    jnz .wcq
    ; 超时也要留下证据。「命令不完成」的两种样子在这里分得开：
    ;   SQ 的 head doorbell 还是零 —— 控制器没把命令取走（门铃或队列深度那一侧）；
    ;   head 走了一 —— 命令被取走了，而完成项没写回来（PRP 或 status 那一侧）。
    ; CQ 的第一项也打出来：phase 没翻，但里面的 CID 与 status 已经写着内容，
    ; 说明写回来过、只是我认的方式不对，那也是另一种解释。
    mov rsi, line_nvme_stuck
    call puts64
    mov eax, [r13 + 0x1004]
    mov [nvme_status], rax
    mov rax, [nvme_status]
    call put_hex64
    mov al, ' '
    call putc64
    mov rbx, [nvme_acq]
    mov eax, [rbx + 0x0C]
    mov [nvme_status], rax
    mov rax, [nvme_status]
    call put_hex64
    mov al, ' '
    call putc64
    mov eax, [rbx + 0x0E]
    mov [nvme_status], rax
    mov rax, [nvme_status]
    call put_hex64
    call put_nl64
    mov rsi, line_nvme_timeout
    call puts64
    ret
.got:
    ; 完成项的 status 在 bits 15:1，非零就是命令回了错
    mov eax, [rbx + 0x0E]
    mov [nvme_status], rax
    ; Identify Controller 的布局：offset 4 是序列号（20 字节），
    ; offset 24 是型号（40 字节）。两个都是定长、尾部用空格补齐。
    ; 拷出来之后自己修剪尾部 —— 不修剪的话，串口上那一行会带着一串看不见的空白，
    ; 而判据要从这一行里认型号。
    cld
    mov rbx, [nvme_log]
    lea rsi, [rbx + 24]
    lea rdi, [nvme_model]
    mov rcx, 40
.cm:
    lodsb
    stosb
    dec rcx
    jnz .cm
    mov byte [rdi], 0
    lea rdi, [nvme_model + 40]
.trim:
    dec rdi
    cmp rdi, nvme_model
    jb .trim_done
    cmp byte [rdi], ' '
    jne .trim_done
    mov byte [rdi], 0
    jmp .trim
.trim_done:
    mov rsi, line_nvme_model
    call puts64
    lea rsi, [nvme_model]
    call puts64
    call put_nl64
    ; 序列号也报一下：它是另一段独立的位置，而两段都对才说明这一页真的是盘给的
    mov rbx, [nvme_log]
    lea rsi, [rbx + 4]
    lea rdi, [nvme_serial]
    mov rcx, 20
.cs:
    lodsb
    stosb
    dec rcx
    jnz .cs
    mov byte [rdi], 0
    lea rdi, [nvme_serial + 20]
.s_trim:
    dec rdi
    cmp rdi, nvme_serial
    jb .s_done
    cmp byte [rdi], ' '
    jne .s_done
    mov byte [rdi], 0
    jmp .s_trim
.s_done:
    mov rsi, line_nvme_serial
    call puts64
    lea rsi, [nvme_serial]
    call puts64
    call put_nl64
    ; 第二条命令：Identify Namespace（同一条 opcode，NSID 写 1、CNS 写 0）。
    ;
    ; 为什么它比「再读一遍控制器」值：这一页 offset 0 那八个字节是这个命名空间有多少个
    ; 逻辑块，而那是**盘自己报的容量**。判据那一侧知道造盘时给的是 2 MB，所以两个数
    ; 一对上，就说明这一页真的从盘里读进来了 —— 而那是一个「打印固定字符串」的实现
    ; 交不出来的东西。
    mov rbx, [nvme_asq]
    lea rbx, [rbx + 64]            ; 槽 1：第一条命令用掉了槽 0
    mov dword [rbx + 0x00], 0x06
    mov dword [rbx + 0x04], 1
    mov rax, [nvme_ns]
    mov [rbx + 0x18], rax
    mov dword [rbx + 0x28], 0      ; CDW10 的 CNS 写 0 = Identify Namespace
    mov dword [r13 + 0x1000], 2    ; SQ 的 tail 走到 2
    ; 完成项在 ACQ 的第二项。phase 仍然是 1 —— 同一轮里不翻，
    ; 翻是在「队列绕回」的时候，而我们只要两条命令。
    mov rbx, [nvme_acq]
    lea rbx, [rbx + 16]
    mov rcx, 50000000
.wnq:
    mov eax, [rbx + 0x0E]
    test eax, 1
    jnz .ns_got
    dec rcx
    jnz .wnq
    mov rsi, line_nvme_nstimeout
    call puts64
    ret
.ns_got:
    mov rbx, [nvme_ns]
    mov rax, [rbx + 0]             ; NSZE：逻辑块数
    mov [nvme_nsze], rax
    ; LBA 大小：offset 26 的低四位是 FLBAS（用了哪一种格式），
    ; 格式表从 offset 128 起、每项 4 字节，而 LBADS 在格式项的 byte 2。
    movzx eax, byte [rbx + 26]
    and eax, 0x0F
    shl eax, 2
    add rax, 128
    add rax, rbx
    movzx eax, byte [rax + 2]
    mov [nvme_lbads], rax
    mov rsi, line_nvme_ns
    call puts64
    mov rax, [nvme_nsze]
    call put_num64
    mov al, ' '
    call putc64
    mov rax, [nvme_lbads]
    call put_num64
    call put_nl64

    ; 第三条命令：Get Log Page 拿 SMART / Health（opcode 0x02，LID 0x02）。
    ;
    ; 这一条以前被整段拿掉过，理由是「命令成功而返回一页零」。但那一版的读法没有留在
    ; 代码里，所以那个结论没有东西支撑它 —— 而「全零」有两种可能：盘真的不报，或者
    ; CDW10 的 NUMD 写错了。NUMD 是「要几个 dword，减一」，而这一页是 512 字节 =
    ; 128 个 dword，所以它该是 127。写小了不会报错，只会让盘少写几个字节，剩下的
    ; 就是缓冲区里原本的零 —— 而症状与「盘不报」一模一样。
    ;
    ; 所以这一段把 NUMD 写对、把前 32 字节打出来。全零与不全零都在串口上，判据那一侧
    ; 只需要认「有没有那一行」，以及「非零的话温度像不像一个温度」。
    mov rbx, [nvme_asq]
    lea rbx, [rbx + 128]           ; 槽 2：前两条用掉了 0 与 1
    mov dword [rbx + 0x00], 0x02
    mov dword [rbx + 0x04], 0xFFFFFFFF   ; NSID：控制器级日志
    mov rax, [nvme_log]
    mov [rbx + 0x18], rax
    mov dword [rbx + 0x28], 0x007F0002   ; CDW10：LID=2、NUMDL=127
    mov dword [rbx + 0x2C], 0            ; CDW11：NUMDU=0
    mov dword [r13 + 0x1000], 3          ; SQ 的 tail 走到 3

    mov rbx, [nvme_acq]
    lea rbx, [rbx + 32]
    mov rcx, 50000000
.wnsm:
    mov eax, [rbx + 0x0E]
    test eax, 1
    jnz .sm_got
    dec rcx
    jnz .wnsm
    mov rsi, line_nvme_smtimeout
    call puts64
    ret
.sm_got:
    ; 先把完成项的 status 打出来。它是「命令被拒」与「命令号称成功却没写数据」这两种
    ; 处境的唯一分界 —— 而缓冲区里有旧数据的时候，这两种在串口上看起来一样。
    mov eax, [rbx + 0x0E]
    shr eax, 1
    and eax, 0x7FFF
    mov [nvme_status], rax
    mov rsi, line_nvme_smstat
    call puts64
    mov rax, [nvme_status]
    call put_num64
    call put_nl64

    mov rsi, line_nvme_smart
    call puts64
    mov rbx, [nvme_log]
    mov rdi, rbx
    mov rcx, 32
    call put_hex_bytes
    call put_nl64

    ; 温度在 offset 1 与 2，小端、单位开尔文。全零的时候它就是零 —— 而零不是一个
    ; 温度，所以这一行「零」应当被读成「盘不报」，不是「零度」。
    mov rsi, line_nvme_temp
    call puts64
    movzx eax, byte [rbx + 1]
    movzx edx, byte [rbx + 2]
    shl edx, 8
    or eax, edx
    mov [nvme_temp], rax
    call put_num64
    call put_nl64

    ; 一行汇总：能读到的报出来，读不到的明说读不到。
    ;
    ; 这一行是这一层现在的最终形状。VBox 这三次尝试（IDE 的 IDENTIFY、AHCI、NVMe 的
    ; SMART 页）都到不了「温度与寿命」，所以健康的五样里只有型号、序列号、容量是真的。
    ;
    ; 温度那一格写 n/a 而不是零，也不是那个 61056。理由在这一层最要紧：**一个准确的
    ; 「我不知道」比一个假的零度好**，因为读这一行的人（或者下游）会把零当成一个可用的
    ; 数。61056 更糟 —— 它是个数，看起来像读数。
    ;
    ; 判定用范围而不是「是不是零」：一块真报 SMART 的盘温度在 273 到 350 开尔文之间，
    ; 而 VBox 那个由型号字节拼出来的值落在几万。范围之外一律 n/a。
    mov rsi, line_dh
    call puts64
    lea rsi, [nvme_model]
    call puts64
    mov al, ' '
    call putc64
    lea rsi, [nvme_serial]
    call puts64
    mov al, ' '
    call putc64
    mov rax, [nvme_nsze]
    call put_num64
    mov al, ' '
    call putc64
    mov rax, [nvme_temp]
    cmp rax, 200
    jb .dh_na
    cmp rax, 500
    ja .dh_na
    call put_num64
    jmp .dh_done
.dh_na:
    mov rsi, line_dh_na
    call puts64
.dh_done:
    call put_nl64
    ret

; ======================================================================
; 家庭组的第二步：边界是一个可以比较的数
; ======================================================================
;
; 设计在 design/HOMEGROUP.txt 三节：边界是超块里的一个 u32，不是一段密码。
; 理由是密码在没有网络身份的地方没法验证，而两个数可以比较。
;
; 这一块只做比较本身：读主盘的家、读第二块盘的家、比一比、说出来。共享清单还不会
; 因为「不是一家人」而拒绝什么 —— 那要有「列某块盘的共享」这个动作才谈得上，而它现在
; 还没有。先把「比较发生过」变成一行能读的读数，是这一步的全部。
;
; 主盘与 β 的家故意不同（build 与 run.mjs 各写一个数）。同号的话，「比较过」与
; 「根本没比较」在串口上完全一样 —— 而那是这一条最该分得开的两件事。
run_home_test:
    mov rdi, 1024
    call fs_load
    mov eax, [rsi + 28]
    mov r12d, eax
    mov rsi, line_home
    call puts64
    mov rax, r12
    call put_hex64
    call put_nl64
    jmp betahome_report
.differ:
    mov rsi, line_not_family
    call puts64
    ret

; 读第二块盘的家、与主盘比、说出来。两处都调它，因为「比较」这件事只该有一份 ——
; 而两处的结果不同（一次 not family、一次 family），那正是判据要看的东西。
betahome_report:
    mov rdi, 1024
    call fs_load
    mov r12d, [rsi + 28]
    mov qword [fs_base], 0x60000
    mov qword [fs_start], 0
    xor edi, edi
    call fs_load
    mov r13d, [rsi + 28]
    mov qword [fs_base], 0x40000
    mov qword [fs_start], 1024
    mov rsi, line_home_beta
    call puts64
    mov rax, r13
    call put_hex64
    mov al, ' '
    call putc64
    cmp r12d, r13d
    jne run_home_test.differ
    mov rsi, line_family
    call puts64
    ret

; 加入：把主盘的家写进第二块盘。
;
; 这一步的意义不在写那两个字节，而在「家 ID 从构建期的事实变成运行时的动作」——
; 在此之前，一块盘属不属于这个家由 build 决定；在此之后，它由一条命令决定。
;
; 判据是同一个比较的结论翻过来：上一块刚说 not family，这里说 family。同一段代码、
; 同一个读法，只有盘上的数变了 —— 这比「又打印了一次 family」结实得多。
run_join_test:
    mov rdi, 1024
    call fs_load
    mov r12d, [rsi + 28]
    mov qword [fs_base], 0x60000
    mov qword [fs_start], 0
    xor edi, edi
    call fs_load
    mov [rsi + 28], r12d
    mov qword [fs_base], 0x40000
    mov qword [fs_start], 1024
    jmp betahome_report


; ======================================================================
; 像素层：帧缓冲能写能读
; ======================================================================
;
; system-software 那一份里五件事的共同标准是「它的哪一部分必须在还没有操作系统的机器上
; 就存在」。像素层是唯一一件不需要进程的：它只是一块可写可读的内存，写进去的东西最后
; 变成光。所以它先做。
;
; 判据分两层。串口那一行证明「帧缓冲能写能读」—— 写一个已知字节、读回来比。它证明不了
; 「屏幕上真的有」，所以第二层是截图：那是人（和 read_image）看的证据，不作自动判据 ——
; 而这一层不能作判据的原因是这台机器 headless，屏幕上有没有东西，串口说不了话。
;
; 0x13 的布局：320 字节一行，200 行，0xA0000 起。所以「第 y 行第 x 列」是 0xA0000 + y*320 + x。
run_pixel_test:
    mov rdi, 0xA0000
    mov byte [rdi], 0x2F           ; 左上角一个像素
    mov byte [rdi + 320 * 100 + 160], 0x1C   ; 正中一个像素
    movzx eax, byte [rdi]
    mov r12d, eax
    movzx eax, byte [rdi + 320 * 100 + 160]
    mov r13d, eax
    mov rsi, line_pixel
    call puts64
    mov rax, r12
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, r13
    call put_hex64
    call put_nl64
    ret

; 画一条线：从 (r12, r13) 到 (r14, r15)，颜色在 dl。
;
; 整数 Bresenham。为什么用它而不是「按 x 采样、算 y」：采样法要么每步一次除法，
; 要么漏掉陡的地方 —— 而一条斜率大于 1 的线会断成点。Bresenham 只用加、减、比，
; 每步恰好落一个像素，且不需要浮点：这条路径上没有 f64 的事。
;
; 布局：0x13 是 320 字节一行，所以一个点是 0xA0000 + y*320 + x。
draw_line:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    mov r8b, dl                    ; 颜色：r8 的高位要留着算别的，所以只在写的时候用 r8b
    ; dx = |x1 - x0|, sx = 方向
    mov rbx, r14
    sub rbx, r12
    mov r9, 1
    test rbx, rbx
    jns .dx_ok
    neg rbx
    mov r9, -1
.dx_ok:
    mov rbp, r15
    sub rbp, r13
    mov r10, 1
    test rbp, rbp
    jns .dy_ok
    neg rbp
    mov r10, -1
.dy_ok:
    mov r11, rbx
    sub r11, rbp                   ; err = dx - dy
.loop:
    ; 画 (r12, r13)
    mov rax, r13
    imul rax, rax, 320
    add rax, r12
    mov rdi, 0xA0000
    add rdi, rax
    mov [rdi], r8b
    cmp r12, r14
    jne .step
    cmp r13, r15
    je .done
.step:
    mov rax, r11
    add rax, rax                   ; e2 = 2*err
    mov rcx, rbp
    neg rcx
    cmp rax, rcx
    jle .maybe_y
    sub r11, rbp
    add r12, r9
.maybe_y:
    cmp rax, rbx
    jge .loop
    add r11, rbx
    add r13, r10
    jmp .loop
.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; 画一条对角线，然后读回线上的两个点。
;
; 判据不靠眼睛：读回的字节说明「这条线上真的有像素」。截图那一层仍然留给人 ——
; 一条一像素宽的对角线在缩放的截图里本来就淡，让它承担自动判据是把脆弱当成了严谨。
; 读一个像素。rdi = x，rsi = y，返回 rax（调色板索引，零扩展 —— 高位要干净，
; 因为调用者会拿整只 rax 去打十六进制）。
read_pixel:
    push rbx
    mov rax, rsi
    imul rax, rax, 320
    add rax, rdi
    mov rbx, 0xA0000
    add rbx, rax
    movzx eax, byte [rbx]
    pop rbx
    ret

; 把一块 8x8 抹成某个颜色。入参：rdi = x，rsi = y，dl = 颜色。
;
; 为什么要单独一段，而不是「画一份全零的位图」：位图里的 0 表示「这个像素不写」，
; 所以全零位图画完什么也没发生 —— 那正是这里第一版的做法，而它让下面「该暗」那一点
; 读到了前面测试留在屏幕上的 0x0F。用「画」来实现「擦」在单色位图上不成立，因为
; 「不写」与「写背景色」是两件事，而位图表达的是前者。
clear_block:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    mov r8b, dl                    ; 颜色挪到 r8，因为 rdx 马上要当地址用
    xor rcx, rcx                   ; 行 0..7
.row:
    cmp rcx, 8
    jae .done
    xor rbx, rbx                   ; 列 0..7
.col:
    cmp rbx, 8
    jae .next_row
    mov rax, rcx
    add rax, rsi                   ; y + 行
    imul rax, rax, 320
    add rax, rdi                   ; x
    add rax, rbx                   ; + 列
    mov rdx, 0xA0000
    add rdx, rax
    mov [rdx], r8b
    inc rbx
    jmp .col
.next_row:
    inc rcx
    jmp .row
.done:
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; 清屏：把六万四千个字节写成给定颜色（320 x 200）。入参：dl = 颜色。
;
; 为什么单独一段而不是循环调 clear_block：整屏是一千个八乘八的块，每块都要算一次
; 地址，而这里地址是连着的 —— 一个指针走到底就完了，省下九万多次乘加。
;
; 为什么不用 rep stosb：它要 rdi / rcx / al 三样同时就位，而且小段上的启动开销随处理器
; 不同。这一版要的是「一定能跑、数得清」，六万四千次循环在这个尺度上没有区别。
clear_screen:
    push rax
    push rcx
    push rdi
    mov rdi, 0xA0000
    mov rcx, 64000
    mov al, dl
.loop:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .loop
    pop rdi
    pop rcx
    pop rax
    ret

; 清屏：先画一点东西，把整屏写成 0x05，再读回来。
;
; 判据读四个点，前三个都落在刚才画过、而且本来是亮的位置上：H 顶边的左右两端
; （0x81 的两个 1，也就是 (10,10) 与 (17,10)），以及它下面一行的左端 (10,11)。
; 第四点是 (0,0)，那里从没画过。四个都该是 05 —— 前三个证明清屏盖住了画过的地方，
; 第四个证明它不是只改那几个像素。
;
; 第二点最早写的是 (11,10)，而那是个**空**位（0x81 的中间六个比特都是 0）。验红时
; 它读出的 00 与「清屏了」在串口上一模一样，于是那个点等于是白读的 —— 一点也没在测。
; 一个判据点必须落在「本该非零」的地方，否则它证明不了任何事。
;
; 为什么这一格值得单独判：屏幕上有过像素、线、框、字，而「把它们擦掉」从来没有过。
; 没有清屏就没有「一帧」—— 两次画的东西叠在一起，谁也分不开谁是谁。
run_clear_test:
    mov rdi, 10
    mov rsi, 10
    lea rdx, [font_H]
    mov r8b, 0x2F
    call draw_glyph

    mov dl, 0x05
    call clear_screen

    mov rsi, line_clear
    call puts64
    mov rdi, 10
    mov rsi, 10
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 17
    mov rsi, 10
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 10
    mov rsi, 11
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    xor rdi, rdi
    xor rsi, rsi
    call read_pixel
    call put_hex64
    jmp put_nl64

; 屏幕上写一个字母，判据读四个像素。
;
; 为什么到这一轮才做：屏幕上有过像素、线、框、矩形与整窗，但从没出现过一个字母。
; 而「窗口那一层」若不能写字就不算窗口 —— 一份界面最先要能说人话。
;
; 判据的形状：把 H 铺在 (100, 60)，读四个点。
;   (100,60) 与 (107,60) 该亮 —— H 的两竖，左端与右端各一个
;   (101,60) 该暗 —— 两竖之间
;   (100,64) 该亮 —— 中间那一横的左端
; 四个点合起来证明三件事：位图读对了、列的方向没反（左端在左）、行也走对了。只读一个点
; 亮不亮证明不了方向 —— 一个把最高位当成最右位的实现也能让某个点亮起来，而它写出来的
; 字是镜像的。
;
; 先把这一小块抹成零：前面几条测试在同一片屏幕上画过线，而「暗」这个断言只有在背景
; 确实为零时才有意义。抹的方式是画一份全零的位图 —— 复用同一个函数，不另写一段清屏。
run_glyph_test:
    mov rdi, 100
    mov rsi, 60
    xor dl, dl                     ; 抹成 0
    call clear_block

    mov rdi, 100
    mov rsi, 60
    lea rdx, [font_H]
    mov r8b, 0x2F
    call draw_glyph

    mov rsi, line_glyph
    call puts64
    mov rdi, 100
    mov rsi, 60
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 107
    mov rsi, 60
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 101
    mov rsi, 60
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 100
    mov rsi, 64
    call read_pixel
    call put_hex64
    jmp put_nl64

; 一行字：两个数字，以及它们之间的字距。
;
; 判据读四个点，各说一件事：
;   (100,80) 暗 —— 0 的顶边从第二位起，所以最左一列是空的
;   (102,80) 亮 —— 0 顶边的右段
;   (101,84) 亮 —— 0 的左竖
;   (111,80) 亮 —— 1 顶边的第四个字节位
;   (110,80) 暗 —— 它左边一位，1 的顶边那里是空的
; 前三点验字模，后两点一起把字距钉住，而它们必须成对：111 在字距偏大时变暗（同一像素
; 落到 1 顶边更左的空位上），110 在字距偏小时变亮（同一像素落到 1 顶边最左那个亮位上）。
; 只读一个点只能测出一侧的偏差 —— 第一版就只读了 111，而字距改成七时它照样亮。
run_text_test:
    mov rdi, 100
    mov rsi, 80
    xor dl, dl
    call clear_block
    mov rdi, 108
    mov rsi, 80
    xor dl, dl
    call clear_block

    mov rdi, 100
    mov rsi, 80
    lea rdx, [str_01]
    mov r8b, 0x2F
    call draw_text

    mov rsi, line_text
    call puts64
    mov rdi, 100
    mov rsi, 80
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 102
    mov rsi, 80
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 101
    mov rsi, 84
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 111
    mov rsi, 80
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 110
    mov rsi, 80
    call read_pixel
    call put_hex64
    jmp put_nl64

; 字母表：写两个大写字母，读四个点。
;
; 挑 H 与 O 是因为它们顶边的形状不同 —— H 是 0x66（亮位在中间偏两端），O 是 0x3C
; （亮位在正中）。而四个点都落在「亮位与空位的交界」上，不是亮的中间：
;   (10,20) 是 H 顶边最左列，0x66 的 bit7 是 0，该暗
;   (11,20) 是它右边一位，bit6 是 1，该亮
;   (18,20) 是 O 顶边最左列，0x3C 的 bit7 是 0，该暗
;   (20,20) 是 O 起点右边第二位，bit5 是 1，该亮
; 期望 00 2F 2F 00。若字母表按错的基址算（比如代码按 0x30 起而表按 0x41 排），这四个点
; 会一起落到别的字上，读出来的不会是这个形状。
run_upper_test:
    mov rdi, 10
    mov rsi, 20
    xor dl, dl
    call clear_block
    mov rdi, 18
    mov rsi, 20
    xor dl, dl
    call clear_block

    mov rdi, 10
    mov rsi, 20
    lea rdx, [str_HO]
    mov r8b, 0x2F
    call draw_text

    mov rsi, line_upper
    call puts64
    mov rdi, 10
    mov rsi, 20
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 11
    mov rsi, 20
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 18
    mov rsi, 20
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 20
    mov rsi, 20
    call read_pixel
    call put_hex64
    jmp put_nl64

; 多行文本：换行与行距。
;
; 判据读四个点：
;   (10,20) 是 H 顶边最左列，该暗
;   (11,20) 是它右边一位，该亮
;   (12,30) 是第二行 0 顶边的中段，该亮 —— 它落在 (10, 20 + 10) 上，证明换行真的发生了
;   (12,37) 是第二行那个 0 的最后一行（行 7 也是 0x3C），该亮 —— 而它只在行距为十时
;     才落在这个字里面：行距改成八，第二行在 y=28，y=37 已经在字外面，读出来是零
; 所以前三点验「换行发生了」，第四点验「行距是十而不是八」。只读第二行顶部的话，
; 行距八与十都会被读到字，那一点就白算了。
run_lines_test:
    mov rdi, 10
    mov rsi, 20
    xor dl, dl
    call clear_block
    mov rdi, 10
    mov rsi, 30
    xor dl, dl
    call clear_block

    mov rdi, 10
    mov rsi, 20
    lea rdx, [str_h0]
    mov r8b, 0x2F
    call draw_lines

    mov rsi, line_lines
    call puts64
    mov rdi, 10
    mov rsi, 20
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 11
    mov rsi, 20
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 12
    mov rsi, 30
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 12
    mov rsi, 37
    call read_pixel
    call put_hex64
    jmp put_nl64

; 小写：字体只有大写，所以这一条验的是「折叠发生在绘制层」。
;
; 判据写 "ab"，读三个点：
;   (10,40) 是 A 顶边最左列，0x18 的 bit7 是 0，该暗
;   (13,40) 是 A 顶边的 bit4，该亮 —— 而它只有在 a 被折成 A 之后才会亮：没折叠的话
;     这个字符被当成未知字符跳过，整格是空的
;   (19,40) 是第二个字符（b 折成 B）顶边的 bit6，B 的顶边是 0x7C，该亮
; 所以两点「亮」各自守着一个小写字母，而它们之间隔着八像素 —— 字距也顺带被问到。
run_lower_test:
    mov rdi, 10
    mov rsi, 40
    xor dl, dl
    call clear_block
    mov rdi, 18
    mov rsi, 40
    xor dl, dl
    call clear_block

    mov rdi, 10
    mov rsi, 40
    lea rdx, [str_ab]
    mov r8b, 0x2F
    call draw_text

    mov rsi, line_lower
    call puts64
    mov rdi, 10
    mov rsi, 40
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 13
    mov rsi, 40
    call read_pixel
    call put_hex64
    mov rsi, line_space
    call puts64
    mov rdi, 19
    mov rsi, 40
    call read_pixel
    call put_hex64
    jmp put_nl64

run_line_test:
    mov r12, 0
    mov r13, 0
    mov r14, 319
    mov r15, 199
    mov dl, 0x2F
    call draw_line
    mov rdi, 0xA0000
    movzx eax, byte [rdi]          ; (0,0)
    mov r12d, eax
    movzx eax, byte [rdi + 100 * 320 + 160]   ; 对角线在 x=160 附近落在 y≈100
    mov r13d, eax
    mov rsi, line_line
    call puts64
    mov rax, r12
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, r13
    call put_hex64
    call put_nl64
    ret

; ======================================================================
; 会算数：把「1+1=x」算出来
; ======================================================================
;
; 这是 math-console 里最早被点名的一件，而它一直是空的 —— 因为 MATH.txt 写着
; 「表达式求值属于 HMYR 编译器」。那句话对，但它说的是「完整的表达式」；而用户要的第一件事
; 是两三个数的四则运算，那不需要编译器，只需要一个会看两级的读法。
;
; 这一版只认两级：乘除先、加减后。不做括号，也不做递归 —— 括号要递归，而递归要压 xmm 栈，
; 那会把这一段变成本文件里最难读的地方；而「1+1」与「2*3+4」不碰括号。
;
; 输入是 UTF-16（键盘那一路已经转好），rdi 前进到解析停下的地方；值在 xmm0。
calc_expr:
    call calc_term
    movsd xmm4, xmm0               ; 这一级的和
.loop:
    movzx eax, word [rdi]
    cmp ax, '+'
    je .plus
    cmp ax, '-'
    je .minus
.done:
    movsd xmm0, xmm4
    ret
.plus:
    add rdi, 2
    call calc_term
    addsd xmm4, xmm0
    jmp .loop
.minus:
    add rdi, 2
    call calc_term
    subsd xmm4, xmm0
    jmp .loop

; 乘除那一级。xmm5 是这一级的积，xmm6 暂存右操作数。
calc_term:
    call calc_factor
    movsd xmm5, xmm0
.loop:
    movzx eax, word [rdi]
    cmp ax, '*'
    je .mul
    cmp ax, '/'
    je .div
.done:
    movsd xmm0, xmm5
    ret
.mul:
    add rdi, 2
    call calc_factor
    mulsd xmm5, xmm0
    jmp .loop
.div:
    add rdi, 2
    call calc_factor
    movsd xmm6, xmm0
    movsd xmm0, xmm5
    movsd xmm1, xmm6
    call div_f64
    movsd xmm5, xmm0
    jmp .loop

; 一个数。负号当一元运算符处理，因为「-3+5」在录入时不该被当成错误。
calc_factor:
    movzx eax, word [rdi]
    cmp ax, '-'
    jne .number
    add rdi, 2
    call calc_factor
    movsd xmm1, [const_signmask]   ; 取负：与 0x8000… 异或
    xorpd xmm0, xmm1
    ret
.number:
    ; 变量 x。绘图这件事的全部要求就在这里 —— 一个求值器只要认一个变量，
    ; 就能对 320 个不同的 x 求 320 次值，而每一次都是一条曲线的采样点。
    ;
    ; 为什么变量表只有一格：这一版只画 y = f(x)，而 f 里除了 x 没有别的自由变量。
    ; 等到要画参数方程（x = f(t), y = g(t)）时才需要第二格，那时加，不是现在。
    movzx eax, word [rdi]
    cmp ax, 'x'
    jne .digits
    movsd xmm0, [var_x]
    add rdi, 2
    ret
.digits:
    mov rcx, 32                    ; 上限：一个数在这一版里不会长过 32 个码元
    call parse_decimal
    lea rdi, [rdi + rax * 2]
    ret

; 会算数的那一行：收一行、算、打出来。
;
; 「1+1=x」与「1+1」两种写法都认：等号右边是这一行的结果叫什么，没有等号就直接打值。
; 用户的原话是「输入 1+1=x 并回车（确认）的时候能够输出 x=2」，所以等号左边的算法与
; 右边的名字是这一件事的两半，而名字那半只是打印时加一句，不影响求值。
;
; 求值本身只到两级（乘除、加减），见 calc_expr 的注释。这一版不算括号、不算幂、
; 不算函数 —— 那些都要递归或符号表，而它们都不是「1+1=x」需要的。
run_calc_live:
    mov rsi, line_calc_ready
    call puts64
    call read_line_keys
    test rax, rax
    jz .timeout
    ; 键盘给的是 ASCII 字节，而 parse_decimal 读的是码元。
    lea rdi, [line_buf]
    lea rsi, [line_buf16]
    mov rcx, [line_len]
    xor rdx, rdx
.conv:
    cmp rdx, rcx
    jae .converted
    movzx eax, byte [rdi + rdx]
    mov [rsi + rdx * 2], ax
    inc rdx
    jmp .conv
.converted:
    mov word [line_buf16 + rcx * 2], 0
    ; 找等号：找到就把表达式截断在那里，右边留作名字
    lea r12, [line_buf16]
    xor rdx, rdx
.find_eq:
    cmp rdx, rcx
    jae .no_eq
    cmp word [line_buf16 + rdx * 2], '='
    je .has_eq
    inc rdx
    jmp .find_eq
.has_eq:
    mov word [line_buf16 + rdx * 2], 0
    lea r13, [line_buf16 + rdx * 2 + 2]   ; 名字，可能空
    jmp .calc
.no_eq:
    xor r13d, r13d                 ; 没有名字
.calc:
    lea rdi, [line_buf16]
    call calc_expr
    movsd [calc_value], xmm0
    mov rsi, r13
    test rsi, rsi
    jz .no_name
    call puts64                    ; 名字
    mov al, '='
    call putc64
    jmp .print
.no_name:
    mov rsi, line_calc_arrow
    call puts64
.print:
    movsd xmm0, [calc_value]
    call put_f64
    call put_nl64
    ret
.timeout:
    mov rsi, line_calc_timeout
    call puts64
    ret

; ======================================================================
; 签名匹配：Nanodesu 与 Torikago 的第一件事
; ======================================================================
;
; 设计在 design/SIGNATURE.txt。本机有四件现成的素材（ClamAV 1.5.4 与它 108 MB 的库、
; YARA 4.5.5、YARA-X 1.21.0、Torikago），而它们的库是 .cvd/.cld —— 压缩包，读不了；
; 能直接进来的是文本形态的签名。
;
; 所以第一批素材用 EICAR：一段公开的、专为测杀毒软件而造的字符串。它不是恶意代码，
; 而是一段打印得出来、命不命中当场看得见的串。用它当素材的理由不是简单，是合法且可核对 ——
; 不需要从任何一个病毒库里搬真东西进这台机器。
;
; 「训练」这个词在这里要读准：ClamAV 的库是签名，YARA 的规则是文本，两者都是数据加匹配，
; 不是梯度下降。所以这一层做的是「照着签名的形状比字节」，做对了之后换成谁的库都只是换数据。
;
; 这一版只做一条规则、一个固定串、子串搜索（不是固定偏移）：ClamAV 的 ndb 允许用 * 表示
; 任意偏移，那是通配而不是数值，而通配是下一条的事。
;
; rdi = 内容，rcx = 长度。出 rax = 1 命中。
scan_eicar:
    mov r8, eicar_len
    cmp rcx, r8
    jb .no
    sub rcx, r8                    ; 最后一个还放得下的起点
    xor r9, r9
.outer:
    cmp r9, rcx
    ja .no
    xor r10, r10
.inner:
    cmp r10, r8
    jae .yes
    mov r11, r9
    add r11, r10                   ; 不能直接 inc r9：失配时要回到起点加一
    mov al, [rdi + r11]
    cmp al, [eicar_sig + r10]
    jne .next
    inc r10
    jmp .inner
.next:
    inc r9
    jmp .outer
.yes:
    mov rax, 1
    ret
.no:
    xor eax, eax
    ret

; 把一个 ASCII 十六进制串解成字节。rdi = 串，rcx = 字符数。出 rax = 字节数，写进 sig_buf。
;
; 为什么规则要放盘上、而不继续写死在代码里：eicar_sig 那个常量证明的是「子串搜索能认出这 68
; 字节」，而它一个字都不证明「规则是数据」。换掉盘上那个文件、不改一行代码、行为跟着变 ——
; 那才是这个断言的证明方式，而这条路径就是为它存在的。
parse_hex:
    xor r8, r8                     ; 输出字节数
    xor r9, r9                     ; 输入字符索引
.loop:
    lea rax, [r9 + 1]
    cmp rax, rcx
    jae .done
    movzx eax, byte [rdi + r9]
    call hex_val
    shl al, 4
    mov dl, al
    add r9, 1
    movzx eax, byte [rdi + r9]
    call hex_val
    or dl, al
    mov [sig_buf + r8], dl
    add r8, 1
    add r9, 1
    jmp .loop
.done:
    mov rax, r8
    ret

; 一个字符的十六进制值。入 al，出 al。不是十六进制字符时给 0 —— 而 0 会让那条规则扫不到东西，
; 响声是「没命中」而不是「崩了」，这个取舍是有意的：一条坏规则不该让整台机器停下。
hex_val:
    cmp al, '0'
    jb .bad
    cmp al, '9'
    jbe .digit
    cmp al, 'A'
    jb .bad
    cmp al, 'F'
    ja .bad
    sub al, 'A' - 10
    ret
.digit:
    sub al, '0'
    ret
.bad:
    xor al, al
    ret

; 拿盘上的规则扫两个文件。
;
; 规则文件的形状：一行 `名字:十六进制`，冒号前是名字、后是签名。真的 ClamAV .ndb 还有
; 「目标类型」与「偏移」两栏（偏移可写 * 表示任意位置），这一版先只认两栏 —— 但形状按它来，
; 所以往后加那两栏是扩这一行，不是推翻它。
run_rules_test:
    mov rdi, fs_rules_path
    call fs_open_path
    test rax, rax
    jz .no_rules
    mov rdi, [last_addr]
    mov rcx, rbx                   ; 规则文件的长度
    ; 找冒号：它把名字与签名分开
    xor r9, r9
.find_colon:
    cmp r9, rcx
    jae .no_rules
    cmp byte [rdi + r9], ':'
    je .have_colon
    inc r9
    jmp .find_colon
.have_colon:
    add r9, 1                      ; 跳过冒号，r9 现在是签名的起点
    lea rdi, [rdi + r9]
    mov rcx, rcx
    sub rcx, r9                    ; 签名的字符数
    ; 到行尾为止（规则文件可能有多行，这一版只认第一行）
    xor r10, r10
.trim:
    cmp r10, rcx
    jae .parsed
    cmp byte [rdi + r10], 10
    je .cut
    cmp byte [rdi + r10], 13
    je .cut
    inc r10
    jmp .trim
.cut:
    mov rcx, r10
.parsed:
    call parse_hex
    mov [sig_len], rax
    test rax, rax
    jz .no_rules
    ; 扫两个文件
    mov rdi, fs_eicar_path
    call fs_open_path
    test rax, rax
    jz .no_rules
    mov rdi, [last_addr]
    mov rcx, rbx
    call scan_sig
    test rax, rax
    jz .missed
    mov rsi, line_rules_found
    call puts64
    jmp .second
.missed:
    mov rsi, line_rules_missed
    call puts64
.second:
    mov rdi, fs_clean_path
    call fs_open_path
    test rax, rax
    jz .no_rules
    mov rdi, [last_addr]
    mov rcx, rbx
    call scan_sig
    test rax, rax
    jnz .false_pos
    mov rsi, line_rules_clean
    call puts64
    ret
.false_pos:
    mov rsi, line_rules_false
    call puts64
    ret
.no_rules:
    mov rsi, line_rules_none
    call puts64
    ret

; 多行规则：拿盘上整个规则文件扫一个文件，报出命中的每一条名字。
;
; 这一层与「一行规则」那层的区别不是数量，是**名字**。一行规则只要能说「命中」就够，
; 而一个规则库必须说「是哪一条命中」—— 否则五十条规则命中了一条，你只知道有事发生。
;
; 三行里两行是假的（never、also），它们证明的不是「没命中」，是「命中不是随手报的」：
; 一个见到什么都报的实现会把两个名字一起报出来，而正确的实现只报 eicar。
run_rules_multi:
    mov rdi, fs_rules_path
    call fs_open_path
    test rax, rax
    jz .no_rules
    mov rax, [last_addr]
    mov [rules_ptr], rax
    mov [rules_left], rbx
    mov rsi, line_rules_head_e
    call puts64
    mov rdi, fs_eicar_path
    call scan_file_with_rules
    call put_nl64
    mov rsi, line_rules_head_c
    call puts64
    mov rdi, fs_clean_path
    call scan_file_with_rules
    call put_nl64
    ret
.no_rules:
    mov rsi, line_rules_none
    call puts64
    ret

; 用一个文件跑完整个规则库。rdi = 文件路径。命中的名字打出来，空格分隔；一个都没有就打 none。
scan_file_with_rules:
    push r14
    push r15
    push r13
    call fs_open_path
    test rax, rax
    jz .missing
    mov rax, [last_addr]
    mov [data_ptr], rax
    mov [data_len], rbx
    mov r14, [rules_ptr]
    mov r15, [rules_left]
    xor r13d, r13d                 ; 命中个数
.line:
    test r15, r15
    jz .done
    xor r9, r9
.find_eol:
    cmp r9, r15
    jae .have_eol
    cmp byte [r14 + r9], 10
    je .have_eol
    inc r9
    jmp .find_eol
.have_eol:
    xor r10, r10
.find_colon:
    cmp r10, r9
    jae .next_line
    cmp byte [r14 + r10], ':'
    je .got_colon
    inc r10
    jmp .find_colon
.got_colon:
    mov r11, r10
    cmp r11, 31
    jbe .name_ok
    mov r11, 31
.name_ok:
    xor rax, rax
.copy_name:
    cmp rax, r11
    jae .name_done
    mov dl, [r14 + rax]
    mov [rule_name + rax], dl
    inc rax
    jmp .copy_name
.name_done:
    mov byte [rule_name + rax], 0
    mov rdi, r14
    add rdi, r10
    add rdi, 1
    mov rcx, r9
    sub rcx, r10
    sub rcx, 1
    call parse_hex
    mov [sig_len], rax
    test rax, rax
    jz .next_line
    mov rdi, [data_ptr]
    mov rcx, [data_len]
    call scan_sig
    test rax, rax
    jz .next_line
    test r13, r13
    jz .no_space
    mov al, ' '
    call putc64
.no_space:
    lea rsi, [rule_name]
    call puts64
    inc r13
.next_line:
    lea r14, [r14 + r9]
    sub r15, r9
    test r15, r15
    jz .done
    cmp byte [r14], 10
    jne .done
    add r14, 1
    sub r15, 1
    jmp .line
.done:
    test r13, r13
    jnz .out
    mov rsi, line_rule_none
    call puts64
.out:
    pop r13
    pop r15
    pop r14
    ret
.missing:
    mov rsi, line_rule_none
    call puts64
    pop r13
    pop r15
    pop r14
    ret

; 用 sig_buf 里那条规则扫一段字节。rdi = 内容，rcx = 长度。出 rax = 1 命中。
scan_sig:
    mov r8, [sig_len]
    cmp rcx, r8
    jb .no
    sub rcx, r8
    xor r9, r9
.outer:
    cmp r9, rcx
    ja .no
    xor r10, r10
.inner:
    cmp r10, r8
    jae .yes
    mov r11, r9
    add r11, r10
    mov al, [rdi + r11]
    cmp al, [sig_buf + r10]
    jne .next
    inc r10
    jmp .inner
.next:
    inc r9
    jmp .outer
.yes:
    mov rax, 1
    ret
.no:
    xor eax, eax
    ret

; 扫两个文件：一个含那个串、一个不含。两条判据都要 —— 一个永远报 FOUND 的实现过第一条，
; 一个永远报 clean 的过第二条，只有两条一起才分得开口。
run_scan_test:
    mov rdi, fs_eicar_path
    call fs_open_path
    test rax, rax
    jz .no_eicar
    mov rdi, [last_addr]
    mov rcx, rbx
    call scan_eicar
    test rax, rax
    jz .missed
    mov rsi, line_scan_found
    call puts64
    jmp .clean_one
.missed:
    mov rsi, line_scan_missed
    call puts64
.clean_one:
    mov rdi, fs_clean_path
    call fs_open_path
    test rax, rax
    jz .no_clean
    mov rdi, [last_addr]
    mov rcx, rbx
    call scan_eicar
    test rax, rax
    jnz .false_pos
    mov rsi, line_scan_clean
    call puts64
    ret
.false_pos:
    mov rsi, line_scan_false
    call puts64
    ret
.no_eicar:
    mov rsi, line_scan_nofile
    call puts64
    ret
.no_clean:
    mov rsi, line_scan_nofile
    call puts64
    ret

; ======================================================================
; 把一条曲线画出来
; ======================================================================
;
; 这是 math-console 里最后一块砖：像素层、画线、求值三件都已经有了，缺的是把数学坐标
; 变成屏幕坐标那一步。
;
; 坐标变换放在这一侧、不放在 HMYR 那一侧，理由是一条边界：HMYR 那一侧不知道屏幕有多少
; 像素，也不该知道 —— 它的表达式说的是 x 与 y 的关系，而「x = 0 落在第 0 列、y = 0 落在
; 第 100 行」是这一台机器的屏幕的事。把屏幕尺寸写进语言里，换一块分辨率就要求表达式跟着变。
;
; 约定：屏幕 x = 数学 x（0 到 319），屏幕 y = 100 - 数学 y（因为屏幕的 y 往下长）。
; 这一版没有缩放也没有平移参数，所以 f 的值域要自己落在 -100 到 100 之间 —— 超出界外的点
; 被裁掉，而不是被压到边上（压到边上会让一条抛物线的两端看起来像贴了一条直线）。
plot_curve:
    mov qword [prev_x], -1         ; 还没有上一个点
    xor r12, r12                   ; 数学 x：0 到 319
.loop_x:
    cmp r12, 320
    jae .done
    cvtsi2sd xmm0, r12
    movsd [var_x], xmm0
    lea rdi, [plot_expr]
    call calc_expr
    movsd xmm2, [const_100]
    subsd xmm2, xmm0               ; 屏幕 y = 100 - f(x)
    cvttsd2si r13, xmm2
    test r13, r13
    js .next                       ; 裁掉界外：负的行号没有意义
    cmp r13, 200
    jae .next
    mov [cur_x], r12
    mov [cur_y], r13
    ; 打一个点，再与上一个点连线 —— 只打点的话，斜率大的地方会断成虚线，
    ; 而那正是「按列采样」本身的形状，不是屏幕的问题。
    mov rax, r13
    imul rax, rax, 320
    add rax, r12
    mov rdi, 0xA0000
    add rdi, rax
    mov byte [rdi], 0x2F
    cmp qword [prev_x], -1
    je .first
    mov r12, [prev_x]
    mov r13, [prev_y]
    mov r14, [cur_x]
    mov r15, [cur_y]
    mov dl, 0x2F
    call draw_line
    mov r12, [cur_x]
    mov r13, [cur_y]
.first:
    mov [prev_x], r12
    mov [prev_y], r13
.next:
    inc r12
    jmp .loop_x
.done:
    ret

; 从盘上读一行表达式、画出来、读回两个已知位置的点。
;
; 判据不靠眼睛：f(0) = 0 所以 (0,100) 该有点，f(160) = 25.6 所以 (160,74) 该有点。
; 这两个位置由那条表达式自己算出来，不是挑了两个看起来对的坐标。
run_plot_test:
    mov rdi, fs_plot_path
    call fs_open_path
    test rax, rax
    jz .no_expr
    ; 表达式拷进 plot_expr：它是 UTF-16 且 0 结尾，而盘上那一行只有换行结尾。
    mov rsi, [last_addr]
    lea rdi, [plot_expr]
    mov rcx, rbx
    xor rdx, rdx
.copy:
    cmp rdx, rcx
    jae .copied
    cmp rdx, 120                   ; 留一格给结尾的 0
    jae .copied
    mov ax, [rsi + rdx * 2]
    cmp ax, 10
    je .copied
    cmp ax, 13
    je .copied
    mov [rdi + rdx * 2], ax
    inc rdx
    jmp .copy
.copied:
    mov word [rdi + rdx * 2], 0
    call plot_curve
    mov rdi, 0xA0000
    movzx eax, byte [rdi + 100 * 320]          ; f(0) = 0 落在 (0, 100)
    mov r12d, eax
    movzx eax, byte [rdi + 74 * 320 + 160]     ; f(160) = 25.6 落在 (160, 74)
    mov r13d, eax
    mov rsi, line_plot
    call puts64
    mov rax, r12
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, r13
    call put_hex64
    call put_nl64
    ret
.no_expr:
    mov rsi, line_plot_none
    call puts64
    ret

; 写一个扇区。rdi = LBA，rsi = 512 字节的源。进位清表示写成。
;
; 它是 ata_read 的镜像：同一组端口、同一个 LBA 拆分、同一套等 BSY 与 DRQ 的循环，
; 只有两处不同 —— 命令是 0x30 而不是 0x20，而数据的方向是 out 而不是 in。连重试策略也照抄，
; 因为写与读走的是同一条时序，而读那边已经证明「一次不成再试两次」够用。
;
; 写完还要等一次 BSY：写完最后一个 word 时命令并没有结束，它在盘上真正落下之前一直忙。
; 不等这一下就断电（或者立刻读回来），读到的可能是别的东西 —— 而那种错看起来像「写丢了」，
; 实际上是「没等它写完」。
ata_write:
    push rsi
    push rdi
    mov r11, 3
.try:
    mov dx, 0x1F7
    in al, dx
    cmp al, 0xFF
    je .retry
    mov r10, 200000
.busy:
    mov dx, 0x1F7
    in al, dx
    cmp al, 0xFF
    je .retry
    test al, 0x80
    jz .idle
    dec r10
    jnz .busy
    jmp .retry
.idle:
    mov rdi, [rsp]
    mov rax, rdi
    shr rax, 24
    and al, 0x0F
    or al, 0xE0
    mov dx, 0x1F6
    out dx, al
    mov dx, 0x1F2
    mov al, 1
    out dx, al
    mov rax, rdi
    mov dx, 0x1F3
    out dx, al
    mov rax, rdi
    shr rax, 8
    mov dx, 0x1F4
    out dx, al
    mov rax, rdi
    shr rax, 16
    mov dx, 0x1F5
    out dx, al
    mov dx, 0x1F7
    mov al, 0x30                   ; 写扇区
    out dx, al
    mov r10, 200000
.wait:
    mov dx, 0x1F7
    in al, dx
    test al, 0x80
    jnz .wait_dec
    test al, 0x08                  ; DRQ：盘在等数据
    jnz .ready
.wait_dec:
    dec r10
    jnz .wait
    jmp .retry
.ready:
    mov rsi, [rsp + 8]
    mov dx, 0x1F0
    mov rcx, 256
.out:
    mov ax, [rsi]
    out dx, ax
    add rsi, 2
    dec rcx
    jnz .out
    mov r10, 200000
.flush:
    mov dx, 0x1F7
    in al, dx
    test al, 0x80
    jz .done
    dec r10
    jnz .flush
    jmp .retry
.done:
    pop rdi
    pop rsi
    clc
    ret
.retry:
    dec r11
    jnz .try
    pop rdi
    pop rsi
    stc
    ret

; 落盘：写一个扇区、再读回来比。
;
; 判据只能是「读回来一样」—— 因为写的对象与读的对象是同一块盘，而中间没有别的东西可以相信。
; 真正更强的判据要跨两次启动（写一次、重启、再读），那一条留给 run.mjs 的两趟。
;
; 为什么写 60000 号扇区：文件系统只占到 1040 左右，60000 在那个范围之外，写它不会碰坏任何文件。
; 挑一个「碰不到别人」的位置，是为了让这一条的失败只可能出在写本身。
run_persist_test:
    ; 先读 60000 号扇区，看它现在是什么。这一步是整条判据的枢纽：
    ;   - 全新盘上它是零（build 从没写过那里），所以第一次启动走「写一次」
    ;   - 写过之后它是 0x2A，所以第二次启动走「只读」而不写
    ; 用盘上留下的字节区分两次启动，而不是靠命令行参数或第三个文件 —— 因为「盘上有什么」
    ; 正是这一条要证明的东西，拿它当依据不是循环，那就是这件事本身。
    mov rdi, 60000
    lea rsi, [persist_buf2]
    call ata_read
    jc .fail
    lea rsi, [persist_buf2]
    mov rcx, 512
    mov al, [rsi]
    cmp al, 0x2A
    jne .fresh
.scan:
    test rcx, rcx
    jz .survived
    cmp byte [rsi], al
    jne .fresh
    inc rsi
    dec rcx
    jmp .scan
.survived:
    ; 第二次启动：上一次写下的 512 个 0x2A 还在盘上，一个字节都没变
    mov rsi, line_persist_survived
    call puts64
    ret
.fresh:
    lea rdi, [persist_buf]
    mov rcx, 512
    mov al, 0x2A
    rep stosb
    mov rdi, 60000
    lea rsi, [persist_buf]
    call ata_write
    jc .fail
    mov rdi, 60000
    lea rsi, [persist_buf2]
    call ata_read
    jc .fail
    lea rsi, [persist_buf]
    lea rdi, [persist_buf2]
    mov rcx, 512
.cmp:
    test rcx, rcx
    jz .ok
    mov al, [rsi]
    cmp al, [rdi]
    jne .diff
    inc rsi
    inc rdi
    dec rcx
    jmp .cmp
.ok:
    mov rsi, line_persist_ok
    call puts64
    ret
.diff:
    mov rsi, line_persist_diff
    call puts64
    ret
.fail:
    mov rsi, line_persist_fail
    call puts64
    ret

; 问盘：「你是谁」。rdi = 512 字节缓冲。进位清表示答了。
;
; IDENTIFY DEVICE 是 0xEC，回来的 256 个 word 里有型号、序列号、以及一堆能力位。
; 它是 disk-health 的第一块砖，理由不在温度也不在通电时间：这两样都要先知道盘认不认得
; 这组命令。先问「你在不在」，再问「你累不累」。
;
; 它比读写简单一档：没有 LBA 要拆、没有扇区数要设，只有一个 DEV 位要放对。
ata_identify:
    push rsi
    push rdi
    mov r11, 3
.try:
    mov dx, 0x1F7
    in al, dx
    cmp al, 0xFF
    je .retry
    mov r10, 200000
.busy:
    mov dx, 0x1F7
    in al, dx
    cmp al, 0xFF
    je .retry
    test al, 0x80
    jz .idle
    dec r10
    jnz .busy
    jmp .retry
.idle:
    ; 等 DRDY 起来，并在每次读状态之后补 400ns。
    ;
    ; 这两件是 ATA 规范里明写的，而第一版都没做：第一版只查 BSY 就往下走，于是可能在
    ; 「盘还没就绪」的时候把命令送进去。读 0x3F6（alt status）四次是那个 400ns 的常用近似 ——
    ; 它读的是同一组寄存器，但不会清中断，所以可以随便读。
    ;
    ; 读回来一页零这件事，先怀疑这两处，再怀疑盘 —— 因为「盘不答」是一个代价很大的结论，
    ; 它会让一条目标被挂起来；而这两处是可以改的。
    mov r10, 200000
.drdy:
    mov dx, 0x3F6
    in al, dx
    in al, dx
    in al, dx
    in al, dx
    mov dx, 0x1F7
    in al, dx
    test al, 0x80
    jnz .drdy_dec
    test al, 0x40                  ; DRDY
    jnz .drdy_ok
.drdy_dec:
    dec r10
    jnz .drdy
    jmp .retry
.drdy_ok:
    mov dx, 0x1F6
    mov al, 0xE0                   ; 主盘、LBA 模式
    out dx, al
    mov dx, 0x1F7
    mov al, 0xEC
    out dx, al
    mov r10, 200000
.wait:
    mov dx, 0x1F7
    in al, dx
    test al, 0x80
    jnz .wait_dec
    test al, 0x08
    jnz .ready
.wait_dec:
    dec r10
    jnz .wait
    jmp .retry
.ready:
    mov rdi, [rsp + 8]
    mov dx, 0x1F0
    mov rcx, 256
.in:
    in ax, dx
    mov [rdi], ax
    add rdi, 2
    dec rcx
    jnz .in
    pop rdi
    pop rsi
    clc
    ret
.retry:
    dec r11
    jnz .try
    pop rdi
    pop rsi
    stc
    ret

; SMART READ DATA：0xB0 加子命令 0xD0。
;
; 它是 disk-health 这一侧最后一条不经过 IDENTIFY 的路，所以先试它 —— 而「先试便宜的」
; 这一条在上一次已经证明过：为了 IDENTIFY 被挂起，代价是以后每次有人想问盘都得读一遍那段。
;
; 回来也是 512 字节，而结构与 IDENTIFY 不同：头两个字节是版本、然后 30 条属性、每条 12 字节。
; 温度、通电时间、重映射扇区都在那 30 条里。这一版只证明「它答了」—— 判据是头一个字节不是零，
; 因为一页零正是 IDENTIFY 失败时的样子，而这一条最该分得开的正是「答了但内容不同」与「没答」。
ata_smart:
    push rsi
    push rdi
    mov r11, 3
.try:
    mov dx, 0x1F6
    mov al, 0xE0
    out dx, al
    mov dx, 0x1F1
    mov al, 0xD0                   ; SMART READ DATA
    out dx, al
    mov dx, 0x1F2
    xor al, al
    out dx, al
    mov dx, 0x1F3
    out dx, al
    mov dx, 0x1F4
    out dx, al
    mov dx, 0x1F5
    out dx, al
    mov dx, 0x1F7
    mov al, 0xB0
    out dx, al
    mov r10, 200000
.wait:
    mov dx, 0x1F7
    in al, dx
    test al, 0x80
    jnz .wait_dec
    test al, 0x08
    jnz .ready
.wait_dec:
    dec r10
    jnz .wait
    jmp .retry
.ready:
    mov rdi, [rsp + 8]
    mov dx, 0x1F0
    mov rcx, 256
.in:
    in ax, dx
    mov [rdi], ax
    add rdi, 2
    dec rcx
    jnz .in
    pop rdi
    pop rsi
    clc
    ret
.retry:
    dec r11
    jnz .try
    pop rdi
    pop rsi
    stc
    ret

; SMART 这一条：报头一个字节与第一个属性登记表的第一个字节。
;
; 两个数都要，因为「答了」与「答的是 SMART」是两件事：一页零能过前者，过不了后者。
run_smart_test:
    mov rdi, smart_buf
    call ata_smart
    jc .fail
    mov rsi, line_smart
    call puts64
    mov rdi, smart_buf
    movzx eax, byte [rdi]
    mov r12d, eax
    movzx eax, byte [rdi + 2]
    mov r13d, eax
    mov rax, r12
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, r13
    call put_hex64
    call put_nl64
    ret
.fail:
    mov rsi, line_smart_fail
    call puts64
    ret

; 盘的健康：先问出型号。
;
; 型号在 word 27 到 46，而每个 word 里两个字符是反的（ATA 的高字节在前，小端存进来就成
; 了反的）。所以打印要成对交换 —— 不交换的话 VBOX HARDDISK 会打成 VOBX AHDRISKD 这种
; 东西，而它看起来像「读错了」，实际只是没换字节序。
run_health_test:
    mov rdi, health_buf
    call ata_identify
    jc .fail
    mov rsi, line_health
    call puts64
    lea rsi, [health_buf + 54]     ; word 27 = 偏移 54
    mov rcx, 12                    ; 十二对，够看出是哪个型号
.print:
    test rcx, rcx
    jz .done
    mov al, [rsi + 1]              ; 高字节在前
    push rsi
    push rcx
    call putc64
    pop rcx
    pop rsi
    mov al, [rsi]
    push rsi
    push rcx
    call putc64
    pop rcx
    pop rsi
    add rsi, 2
    dec rcx
    jmp .print
.done:
    call put_nl64
    ret
.fail:
    mov rsi, line_health_fail
    call puts64
    ret

; ======================================================================
; KID：把盘上的名字建成一张能反复查的表
; ======================================================================
;
; system-software 那五件里，这一件是唯一不需要任何新前提的 —— 它要的东西全在：
; 文件系统、目录条目、以及 fs_lookup 里那段走条目的代码。
;
; 但它不是「再找一遍」。区别有三处，而判据必须压住这三处：
;   一、建一次、查多次 —— fs_lookup 每查一次都从头走目录。
;   二、能按序号列 —— 「第三条叫什么」这件事，走目录的函数给不出来。
;   三、建的时候要数出有几个 —— 那是「索引存在过」的证据，也是「最后一条没漏」的证据。
;
; 所以判据是三条：条目数、按名字查到扇区、查不存在的名字返回空。少第一条的话，
; 一颗「其实什么也没建、每次都现找」的实现也能过后两条。
;
; 表放在内存里，16 条封顶：这一版盘上只有九个名字，而 16 是「装得下」与「能数出来」的交点。
index_build:
    mov qword [index_n], 0
    ; 从超块取根目录扇区 —— 与 run_shares 那一段同一个走法，而那一处抄错过一次
    mov rdi, 1024
    call fs_load
    mov rbx, rsi
    mov edi, [rbx + 12]
    call fs_load
    mov r8, rsi                    ; 目录项游标
    xor r9, r9
.loop:
    cmp r9, index_cap              ; 表容量。它的值与盘上名字数的关系由 build 核对。
    jae .done
    movzx rax, word [r8]
    test rax, rax                  ; 名字长度 0：目录到头了
    jz .done
    mov rcx, rax
    ; 名字存成 ASCII（低字节）：这一版的名字都是 ASCII，而比两串字节比两串码元少一半活
    lea rdi, [index_buf]
    mov rax, r9
    imul rax, rax, 40              ; 每条 40 字节：32 名字 + 4 扇区
    add rdi, rax
    xor r10, r10
.copy_name:
    cmp r10, rcx
    jae .name_done
    cmp r10, 31
    jae .name_done
    mov al, [r8 + 2 + r10 * 2]
    mov [rdi + r10], al
    inc r10
    jmp .copy_name
.name_done:
    mov byte [rdi + r10], 0
    lea rax, [r8 + 2 + rcx * 2 + 1]   ; 类型之后是起始扇区
    mov eax, [rax]
    mov [rdi + 32], eax
    inc r9
    lea r8, [r8 + 2 + rcx * 2 + 9]    ; 2 + 名字 + 1 类型 + 4 起 + 4 长
    jmp .loop
.done:
    mov [index_n], r9
    ret

; 按名字查。rdi = ASCII 名字（0 结尾）。出 rax = 扇区，0 表示没有。
index_find:
    xor r9, r9
.entry:
    cmp r9, [index_n]
    jae .miss
    mov rax, r9
    imul rax, rax, 40
    lea rsi, [index_buf]
    add rsi, rax
    xor r10, r10
.cmp:
    mov al, [rdi + r10]
    mov dl, [rsi + r10]
    cmp al, dl
    jne .next
    test al, al
    jz .hit
    inc r10
    cmp r10, 32
    jb .cmp
.hit:
    mov eax, [rsi + 32]
    ret
.next:
    inc r9
    jmp .entry
.miss:
    xor eax, eax
    ret

; 三条判据：条目数、按名字查到扇区、查不存在的名字返回空。
run_index_test:
    call index_build
    mov rsi, line_index_count
    call puts64
    mov rax, [index_n]
    call put_hex64
    call put_nl64
    lea rdi, [name_hello]
    call index_find
    mov r12, rax
    mov rsi, line_index_hello
    call puts64
    mov rax, r12
    call put_hex64
    call put_nl64
    lea rdi, [name_nosuch]
    call index_find
    mov r13, rax
    mov rsi, line_index_miss
    call puts64
    mov rax, r13
    call put_hex64
    call put_nl64
    ret

; ======================================================================
; 窗口：一个矩形边框，一块填充
; ======================================================================
;
; 用户要的 Kohane 是「此电脑」，按文件资源管理器的样子做。而资源管理器在屏幕上首先是一个
; 矩形：边框、标题栏、左边导航栏、右边内容区。所以这一块砖不是界面，是**能把界面画出来的
; 那两个原语** —— 不先有它们，谈布局没有意义。
;
; 为什么参数走内存：draw_line 自己要用 r12 到 r15（那是它的四个端点），所以四次调用之间
; 没有寄存器可以托付 x、y、w、h、颜色。这一份文件里「寄存器被吃掉」的教训已经有五条了，
; 这一条是同一族 —— 只是这次吃寄存器的是画线。
; 把一份 8x8 位图铺到帧缓冲。
;
; 入参：rdi = 屏幕 x，rsi = 屏幕 y，rdx = 八个字节的位图（每字节一行，最高位在左边），
;       r8b = 颜色。
;
; 为什么是 8x8 单色：帧缓冲是每像素一字节的调色板索引（320x200），所以一个字符就是
; 「六十四次写或不写」。每行一字节、最高位对齐左边，比存六十四个字节省八倍，而「第几
; 行第几列」这个关系在移位里是明摆着的 —— 左移 r11 位之后，原来第 (7-r11) 位到了最高位。
;
; 全部寄存器都保存：调用者是 exec，它用 r12 指指令流、r13 数指令数，而这两个不在这里的
; 保存名单里 —— 也正因如此这一段不碰它们。draw_line 不保存 r12 到 r15（那是它的入参），
; 所以调用它之前要自己存，而这一段只碰通用寄存器。
draw_glyph:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r10
    push r11
    xor r9, r9                     ; 行 0..7
.row:
    cmp r9, 8
    jae .done
    movzx r10, byte [rdx + r9]     ; 这一行的八个位
    xor r11, r11                   ; 列 0..7
.col:
    cmp r11, 8
    jae .next_row
    mov rcx, r11                   ; 移位量要在 cl 里
    mov rax, r10
    shl rax, cl                    ; 把第 (7-列) 位顶到最高位
    test rax, 0x80
    jz .skip
    ; 裁剪：只在矩形内写。规则是「左闭右开」—— x 落在 [clip_x0, clip_x1) 才算在里面。
    ; 右开是为了让相邻两块窗口共用一条边而不重叠：前一块的 x1 就是后一块的 x0。
    ;
    ; 裁剪关着的时候这一段的代价只是两条 cmp，而它挡住的是「一个窗口的字画到隔壁窗口
    ; 身上」—— 那种错在屏幕上看得出，在串口上看不出。
    cmp qword [clip_on], 0
    je .write_ok
    mov rax, rdi
    add rax, r11                   ; 屏幕 x
    cmp rax, [clip_x0]
    jb .skip
    cmp rax, [clip_x1]
    jae .skip
    mov rcx, rsi
    add rcx, r9                    ; 屏幕 y
    cmp rcx, [clip_y0]
    jb .skip
    cmp rcx, [clip_y1]
    jae .skip
.write_ok:
    mov rax, r9
    add rax, rsi                   ; y + 行
    imul rax, rax, 320
    add rax, rdi                   ; x
    add rax, r11                   ; + 列
    mov rbx, 0xA0000
    add rbx, rax
    mov [rbx], r8b
.skip:
    inc r11
    jmp .col
.next_row:
    inc r9
    jmp .row
.done:
    pop r11
    pop r10
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; 把一行字铺到帧缓冲。入参：rdi = x，rsi = y，rdx = 以 0 结尾的字符串，r8b = 颜色。
;
; 这一版支持数字 0 到 9 与大写字母 A 到 Z，各一张表。别的字符被**跳过**而不是画成一个
; 方块 —— 因为「画不出来」与「画错了」在屏幕上长得一样，而在判据里必须分得开。要扩字符集
; 就是加字模，机制不动。
;
; 字距是八像素：字模本身八宽，所以相邻两个字符之间没有空隙。加空隙要改这个增量，而
; 那是排版的事，等有排版再说 —— 现在只有一个数，判据能量它。
;
; 全部寄存器都保存：调用者是 exec，它用 r12 指指令流、r13 数指令数。
; 画一个字符。rdi = x，rsi = y，ax = 码元，r8b = 颜色。
; 认不出的字符什么也不画 —— 「画不出来」与「画错了」在判据里要分得开。
;
; 入参是 16 位码元而不是 8 位字节：包里的串是 UTF-16（u16 长度 + 码元），而固件里那
; 几条测试用的是 8 位串。让这一层吃码元，两条路就共用同一份绘制 —— 字符集、字距、
; 未知字符的处理三样都只有一份。
;
; 这一段是从 draw_text 里抽出来的：多行文本要按字符画（换行处得重新起头），而「把一行
; 串从头画到尾」只是它的一个上层。数字与字母各有一张表，入口先分派再看表 —— 一张连续表
; 要从 0x30 铺到 0x5A，中间那七个标点得占着位置填空白，而空白在判据里与「这个字符不
; 存在」分不开。
;
; 开头那句 movzx 不能省：入参只有 ax，rax 的高位是调用者留下的，而下面的 sub rax 会用
; 到整只寄存器。
draw_one:
    push rax
    push r10
    movzx eax, ax
    ; 小写折成大写：这一版字体只有大写 26 个。折在这一层是它该做的事 —— 一个只有大写的
    ; 字体把 a 画成 A；若留给每个调用者自己转，就变成每处调用都要记得转，而漏掉的那一处
    ; 只会画出一片空白，不会报错。
    cmp ax, 'a'
    jb .case_done
    cmp ax, 'z'
    ja .case_done
    sub ax, 0x20
.case_done:
    cmp ax, '0'
    jb .out
    cmp ax, '9'
    jbe .digit
    cmp ax, 'A'
    jb .out
    cmp ax, 'Z'
    ja .out
    sub rax, 'A'
    shl rax, 3
    lea r10, [font_letters]
    add r10, rax
    jmp .draw
.digit:
    sub rax, '0'
    shl rax, 3
    lea r10, [font_digits]
    add r10, rax
.draw:
    mov rdx, r10
    call draw_glyph
.out:
    pop r10
    pop rax
    ret

draw_text:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    mov r9, rdi                    ; 当前这一格的 x
.loop:
    movzx rax, byte [rdx]
    test rax, rax
    jz .done
    mov rdi, r9
    push rdx                       ; rdx 在下面被当作字符传下去，所以先存串指针
    call draw_one
    pop rdx
    add r9, 8                      ; 字距：与字模宽度相同，所以无空隙
    inc rdx
    jmp .loop
.done:
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; 把一段话铺到屏幕上。rdi = x，rsi = y，rdx = 以 0 结尾的串，r8b = 颜色。
; 换行用 0x0A，行距十像素（字高八加两行空）。
;
; 为什么换行不并进 draw_text：它的入参只有一个 x，它不知道「下一行从哪里重新起头」——
; 那是调用者的事。分成两层之后 draw_text 保持「一行」的语义，draw_lines 管换行与行距。
;
; 行首 x 存在 r9 里、当前 x 在 r11 里、当前 y 在 r10 里。三个都要跨调用活着，所以都用
; 不参与传参的寄存器；r10 在 draw_one 内部被保存过，r9 与 r11 两边都不碰。
draw_lines:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r10
    push r11
    mov r9, rdi                    ; 每一行重新起头的 x
    mov r10, rsi                   ; 当前 y
    mov r11, rdi                   ; 当前 x
.loop:
    movzx rax, byte [rdx]
    test rax, rax
    jz .done
    cmp rax, 10
    je .newline
    mov rdi, r11
    mov rsi, r10
    push rdx
    call draw_one
    pop rdx
    add r11, 8
    inc rdx
    jmp .loop
.newline:
    mov r11, r9                    ; 回到行首
    add r10, 10                    ; 行距：字高八，空两行
    inc rdx
    jmp .loop
.done:
    pop r11
    pop r10
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; 把包里那种串铺到屏幕上：rdx = 指针（u16 长度 + UTF-16 码元），rdi = x，rsi = y，
; r8b = 颜色。
;
; 与 draw_text 的差别只有「字符从哪里来」：那个吃以 0 结尾的 8 位串（固件自己的测试用），
; 这个吃包里的带长度前缀的 UTF-16。画的部分是同一个 draw_one，所以字符集、字距、未知字符
; 的处理三样都只有一份。
;
; 换行认 0x0A，行距十像素 —— 与 draw_lines 同一套约定，因为这两条路最后都落到 draw_one，
; 而「一段话长什么样」不该因为串的来源不同而不同。
;
; 三个状态量：rbx 是行首 x（换行时回到这里），r9 是当前 x，r10 是当前 y。用 rbx 而不是
; 再找一个不参与传参的寄存器，是因为 draw_one 一路下去不会碰它（draw_glyph 自己会保存
; rbx）。r11 是串指针，rcx 是剩余码元数。
draw_utf16:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r10
    push r11
    mov rbx, rdi                   ; 行首 x
    mov r9, rdi                    ; 当前 x
    mov r10, rsi                   ; 当前 y
    mov r11, rdx                   ; 串指针
    movzx ecx, word [r11]          ; 码元数
    add r11, 2
.loop:
    test ecx, ecx
    jz .done
    movzx eax, word [r11]
    cmp ax, 10
    je .newline
    mov rdi, r9
    mov rsi, r10
    push rcx                       ; draw_one 会碰 rax 与 r10（保存过），而 rcx/r11 是状态
    push r11
    call draw_one
    pop r11
    pop rcx
    add r9, 8
    add r11, 2
    dec ecx
    jmp .loop
.newline:
    mov r9, rbx                    ; 回到行首
    add r10, 10                    ; 行距：字高八，空两行
    add r11, 2
    dec ecx
    jmp .loop
.done:
    pop r11
    pop r10
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

draw_rect:
    mov [rect_x], rdi
    mov [rect_y], rsi
    mov [rect_w], rdx
    mov [rect_h], rcx
    mov [rect_c], r8b
    ; 上边
    mov r12, [rect_x]
    mov r13, [rect_y]
    mov r14, [rect_x]
    add r14, [rect_w]
    dec r14
    mov r15, [rect_y]
    mov dl, [rect_c]
    call draw_line
    ; 下边
    mov r12, [rect_x]
    mov r13, [rect_y]
    add r13, [rect_h]
    dec r13
    mov r14, r12
    add r14, [rect_w]
    dec r14
    mov r15, r13
    mov dl, [rect_c]
    call draw_line
    ; 左边
    mov r12, [rect_x]
    mov r13, [rect_y]
    mov r14, r12
    mov r15, r13
    add r15, [rect_h]
    dec r15
    mov dl, [rect_c]
    call draw_line
    ; 右边
    mov r12, [rect_x]
    add r12, [rect_w]
    dec r12
    mov r13, [rect_y]
    mov r14, r12
    mov r15, r13
    add r15, [rect_h]
    dec r15
    mov dl, [rect_c]
    call draw_line
    ret

; 填充一个矩形。rdi x, rsi y, rdx w, rcx h, r8b 颜色。
fill_rect:
    mov [rect_x], rdi
    mov [rect_y], rsi
    mov [rect_w], rdx
    mov [rect_h], rcx
    mov [rect_c], r8b
    xor r9, r9
.row:
    cmp r9, [rect_h]
    jae .done
    xor r10, r10
.col:
    cmp r10, [rect_w]
    jae .next_row
    mov rax, [rect_y]
    add rax, r9
    imul rax, rax, 320
    add rax, [rect_x]
    add rax, r10
    mov rdi, 0xA0000
    add rdi, rax
    mov al, [rect_c]
    mov [rdi], al
    inc r10
    jmp .col
.next_row:
    inc r9
    jmp .row
.done:
    ret

; 此电脑那个窗口的骨架：清屏、边框、标题栏、左边导航栏、内容区。
;
; 判据读回四个位置的颜色。四行都要 —— 一颗「只清屏不画」的实现过不了前三行，
; 一颗「整屏填满」的实现过不了最后一行。
run_explorer_test:
    xor edi, edi
    xor esi, esi
    mov rdx, 320
    mov rcx, 200
    xor r8d, r8d
    call fill_rect
    mov rdi, 8
    mov rsi, 8
    mov rdx, 304
    mov rcx, 184
    mov r8b, 0x2F
    call draw_rect
    mov rdi, 9
    mov rsi, 9
    mov rdx, 302
    mov rcx, 12
    mov r8b, 0x1C
    call fill_rect
    mov rdi, 9
    mov rsi, 22
    mov rdx, 76
    mov rcx, 169
    mov r8b, 0x28
    call fill_rect
    mov rdi, 86
    mov rsi, 22
    mov rdx, 225
    mov rcx, 169
    mov r8b, 0x0F
    call fill_rect
    mov rdi, 0xA0000
    movzx eax, byte [rdi + 8 * 320 + 8]
    mov r12d, eax
    movzx eax, byte [rdi + 14 * 320 + 100]
    mov r13d, eax
    movzx eax, byte [rdi + 100 * 320 + 40]
    mov r14d, eax
    movzx eax, byte [rdi + 100 * 320 + 200]
    mov r15d, eax
    mov rsi, line_explorer
    call puts64
    mov rax, r12
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, r13
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, r14
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, r15
    call put_hex64
    call put_nl64
    ret

; ======================================================================
; Kohane 第三层：进一个盘，把根目录的条目一条一条列出来
; ======================================================================
;
; 这一层的价值不在「能打印」，在**它列出了哪几列**：名字、类型、字节数、共享位。
; 四列少任何一列，都有一类实现能蒙过判据 ——
;   · 少了类型列，docs（目录、0 字节）与一个空文件在表里长得一样；
;   · 少了字节数列，一个只念名字的实现照样能列出全部条目；
;   · 少了共享位列，「共享过」与「没共享」在表上分不开。
;
; 所以判据让两块盘各列一次，而**两块盘上都有一个叫 hello.txt 的**：主盘那份 8 字节、
; 不带共享位；β 那份 23 字节、带共享位。两张表因此一眼分得开 —— 一个「只列主盘、
; 再把结果抄一遍」的实现交不出 β 那两行。这也是「同名不同物」那件事第一次在屏幕上现身。
;
; 时机也有用：这一段排在 run_share_test 与 run_homeshare_test 之后，那两段各自标记过
; 一个共享位。所以这里读到的那几个 1 不是代码里写死的，是前面真的改过的。
;
; 形状：目录条目在预读区里就是内存，所以这一层不需要任何新前提 —— 不读盘、不算偏移。
;
; 每行自带盘符字母（La / Lb），所以判据不必先切段落再数：一行是什么、属于哪一块盘，
; 都写在行首了。
;
; rdi = 盘符（UTF-16，0 码元结尾），esi = 行首那个字母。出 rax = 列了几条。
fs_list_disk:
    push r12
    push r13
    push rbx
    mov rbx, rdi                   ; 盘符先存：fs_load 会用 rdi 算地址
    mov eax, esi
    mov [list_tag], al
    movzx eax, word [rbx]
    cmp ax, 0x03B1
    je .alpha
    cmp ax, 0x03B2
    jne .miss
    mov qword [fs_base], 0x60000
    mov qword [fs_start], 0
    jmp .set
.alpha:
    mov qword [fs_base], 0x40000
    mov qword [fs_start], 1024
.set:
    mov rdi, [fs_start]
    call fs_load
    mov edi, [rsi + 12]            ; 超块第 12 字节：根目录扇区。
                                   ; 这里必须是 32 位读 —— 写成 64 位就会把紧跟着的
                                   ; root span 一起读进来，扇区号变成 0x0000000100000401，
                                   ; 而 fs_load 算出巨大偏移，症状是 #PF at 0xBA52。
    call fs_load
    mov [list_ptr], rsi
    mov qword [list_n], 0
.entry:
    mov r12, [list_ptr]
    movzx eax, word [r12]
    test eax, eax                  ; 名字长度 0：走到头了
    jz .done
    mov [list_namelen], rax
    lea r9, [r12 + 2 + rax * 2]    ; 名字之后：类型 u8、起扇区 u32、字节长 u32
    movzx r10d, byte [r9]
    mov [list_type], r10
    mov eax, [r9 + 5]
    mov [list_size], rax
    ; 行首：L、盘符字母、一个空格
    mov al, 'L'
    call putc64
    mov al, [list_tag]
    call putc64
    mov al, ' '
    call putc64
    ; 名字
    mov rdi, [list_ptr]
    add rdi, 2
    mov rcx, [list_namelen]
    call put_utf16_n
    mov al, ' '
    call putc64
    ; 类型：目录打 d，其余打 f
    mov rdx, [list_type]
    and edx, 0x3F
    mov al, 'f'
    cmp rdx, 1
    jne .type_out
    mov al, 'd'
.type_out:
    call putc64
    mov al, ' '
    call putc64
    ; 字节数
    mov rax, [list_size]
    call put_num64
    mov al, ' '
    call putc64
    ; 共享位。与类型同位，所以上面那一手 and 0x7F 是必须的 ——
    ; 少了它，一个被共享的目录会打出一个既不是 d 也不是 f 的字节。
    mov rax, [list_type]
    and eax, 0x80
    jz .plain
    mov al, '1'
    jmp .share_out
.plain:
    mov al, '0'
.share_out:
    call putc64
    call put_nl64
    ; 下一条。位置与长度都从内存里重取一遍：这一份文件里「打印函数吃掉循环变量」
    ; 已经有过五条教训，而这一处一次要跨四个打印函数。
    mov rax, [list_namelen]
    lea rdx, [rax * 2 + 11]
    add rdx, [list_ptr]
    mov [list_ptr], rdx
    inc qword [list_n]
    jmp .entry
.done:
    mov rax, [list_n]
    ; 拨回 α。调用者接下来多半还用主盘，而「上一次查的是 β」留在变量里，
    ; 会让下一次 α 的读取落到第二块盘的地址上 —— 那种错很安静。
    mov qword [fs_base], 0x40000
    mov qword [fs_start], 1024
    pop rbx
    pop r12
    pop r13
    ret
.miss:
    mov rsi, line_list_miss
    call puts64
    mov qword [fs_base], 0x40000
    mov qword [fs_start], 1024
    xor eax, eax
    pop rbx
    pop r12
    pop r13
    ret

; 打一行「这一盘列了几条」。行首字母取自 list_tag —— 就是刚列的那一块盘的那个字母，
; 所以这一行不必再被告知是 α 还是 β。
put_list_count:
    mov rsi, line_list_count
    call puts64
    mov al, [list_tag]
    call putc64
    mov al, ' '
    call putc64
    mov rax, [list_count]
    call put_num64
    jmp put_nl64

; 两块盘各列一次，各报一次数。数落在 list_count 里再打，是因为 put_num64 与 puts64
; 都不保证保住寄存器，而 r12 里那个数要跨过两个打印函数。
run_kohane_list_test:
    mov rdi, fs_alpha_drive
    mov esi, 'a'
    call fs_list_disk
    mov [list_count], rax
    call put_list_count
    mov rdi, fs_beta_drive
    mov esi, 'b'
    call fs_list_disk
    mov [list_count], rax
    call put_list_count
    ret

; ======================================================================
; Kohane 第四层：一个文件的详情
; ======================================================================
;
; 六列：名字、起始扇区、字节数、类型、共享位、只读位。
;
; 这一层真正值钱的不是「六列都打得出来」，是**交叉验证**：那个起始扇区要走两条完全
; 不同的路各算一遍 ——
;   一条是目录：fs_open_path 按斜杠逐段查找，落在 last_entry 指向的那一条上；
;   一条是索引：index_build 先把整张表建好，再按名字查。
; 两条路算出同一个数，才说明这个字段在两边是同一个意思。同一条路自己算两遍，
; 什么也证明不了 —— 那正是这一层与「再多打一列」的区别。
;
; 只读位是这一层新开的一个位。目录条目的类型字节原先只用掉 bit 7（共享），现在 bit 6
; 是只读。所以**凡是用类型的地方，掩码都要跟着收窄**，从 0x7F 到 0x3F。漏一处，症状是
; 「标记只读之后那个目录就不是目录了」—— 与只读这件事看起来毫无关系。
;
; 判据四条：
;   一、hello.txt 的起始扇区与索引那一行相同（两条独立路径，客人机自己比）；
;   二、docs 是 d、0 字节、共享位 1（它在前面的 run_share_test 里被标记过）；
;   三、hello.txt 标记之前共享位 0、只读位 0；
;   四、标记之后只读位变 1 而共享位仍是 0 —— 两个位各管各的，不互相串。

; 把一个文件的只读位标上。与 fs_share 同族：只改条目上的一个位，不往任何清单里加一项。
; rdi = 路径。出 rax = 1 标了 / 0 没找到。
fs_readonly:
    push rdi
    mov qword [gate_off], 1        ; 标记是管理动作，不走读取那道门
    call fs_open_path
    mov qword [gate_off], 0
    pop rdi
    test rax, rax
    jz .miss
    mov rax, [last_entry]
    test rax, rax
    jz .miss
    movzx ecx, word [rax]
    lea rdx, [rax + 2 + rcx * 2]   ; 名字之后就是类型
    or byte [rdx], 0x40
    mov rax, 1
    ret
.miss:
    xor eax, eax
    ret

; 取一个条目的六列，放进那几个变量。rdi = 路径。出 rax = 1 取到了 / 0 没找到。
fs_stat_path:
    mov qword [gate_off], 1        ; 统计也是管理动作：看一个没共享的文件不该被门挡住
    call fs_open_path
    mov qword [gate_off], 0
    test rax, rax
    jz .miss
    mov rax, [last_entry]
    test rax, rax
    jz .miss
    mov [stat_entry], rax
    movzx eax, word [rax]
    mov [stat_namelen], rax
    lea r9, [rax * 2 + 2]          ; 2 字节名字长度 + 名字的码元
    add r9, [stat_entry]           ; 类型字节的位置
    movzx r10d, byte [r9]
    mov [stat_type], r10
    mov eax, [r9 + 1]              ; 起始扇区 u32
    mov [stat_start], rax
    mov eax, [r9 + 5]              ; 字节长 u32
    mov [stat_size], rax
    mov rax, 1
    ret
.miss:
    xor eax, eax
    ret

; 把那六列打成一行。名字从条目里读，与层三同一个走法。
print_stat_line:
    mov rsi, line_stat_head
    call puts64
    mov rdi, [stat_entry]
    add rdi, 2
    mov rcx, [stat_namelen]
    call put_utf16_n
    mov rsi, line_fs_arrow
    call puts64
    mov rax, [stat_start]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [stat_size]
    call put_num64
    mov al, ' '
    call putc64
    ; 类型：掩码是 0x3F 而不是 0x7F —— 只读位进来之后，两位都要让开
    mov rdx, [stat_type]
    and edx, 0x3F
    mov al, 'f'
    cmp rdx, 1
    jne .type_out
    mov al, 'd'
.type_out:
    call putc64
    mov al, ' '
    call putc64
    ; 共享位
    mov rax, [stat_type]
    and eax, 0x80
    jz .s_plain
    mov al, '1'
    jmp .s_out
.s_plain:
    mov al, '0'
.s_out:
    call putc64
    mov al, ' '
    call putc64
    ; 只读位
    mov rax, [stat_type]
    and eax, 0x40
    jz .r_plain
    mov al, '1'
    jmp .r_out
.r_plain:
    mov al, '0'
.r_out:
    call putc64
    jmp put_nl64

; 三次 stat 加一次交叉核对。
;
; 三次的顺序有意义：hello.txt（标记前）、docs、hello.txt（标记后）。第一与第三行只差
; 一件事 —— 中间那次 fs_readonly 改了 bit 6。所以两行的差别只能来自那里，而共享位那一列
; 必须两行一样（否则说明 or 0x40 顺手把 0x80 也带上了，或者掩码写错）。
run_kohane_stat_test:
    mov rdi, fs_hello_path
    call fs_stat_path
    test rax, rax
    jz .miss
    call print_stat_line
    mov rdi, fs_docs_path
    call fs_stat_path
    test rax, rax
    jz .miss
    call print_stat_line
    mov rdi, fs_hello_path
    call fs_readonly
    mov rdi, fs_hello_path
    call fs_stat_path
    test rax, rax
    jz .miss
    call print_stat_line
    ; 第四次：把一个**目录**标成只读。这一行是掩码那件事唯一的判据 ——
    ; 只读位在类型字节的 bit 6，而「是不是目录」的掩码从 0x7F 收窄到 0x3F 之后，
    ; 一个被标了只读的目录必须仍然是 d。漏改一处掩码，这一行就会把 docs 打成 f，
    ; 而这件事与只读看起来毫无关系。
    mov rdi, fs_docs_path
    call fs_readonly
    mov rdi, fs_docs_path
    call fs_stat_path
    test rax, rax
    jz .miss
    call print_stat_line
    ; 交叉核对：目录那条与索引那条，各算一遍。
    ;
    ; 这里要把 hello.txt 再 stat 一次：上面最后一次 stat 是 docs，stat_start 已经是
    ; docs 的扇区了，而索引查的是 hello.txt —— 拿两个不同名字的扇区去比，结论只会是
    ; differ，而那不是「两条路不一致」，是「比了两个不同的东西」。
    mov rdi, fs_hello_path
    call fs_stat_path
    test rax, rax
    jz .miss
    call index_build
    lea rdi, [name_hello]
    call index_find
    mov [stat_index], rax
    mov rsi, line_stat_cross
    call puts64
    mov rax, [stat_start]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [stat_index]
    call put_hex64
    mov al, ' '
    call putc64
    mov rax, [stat_start]
    cmp rax, [stat_index]
    jne .differ
    mov rsi, line_stat_same
    call puts64
    jmp .tail
.differ:
    mov rsi, line_stat_differ
    call puts64
.tail:
    jmp put_nl64
.miss:
    mov rsi, line_stat_miss
    call puts64
    ret

; ======================================================================
; 认一个文件是什么：看它的头几个字节，不看它的名字
; ======================================================================
;
; 这是 Kohane 第六层的砖。它值钱的地方不在「能认出文本与包」，而在**它不看名字**：
; 盘上有一个叫 fake.txt 的文件，内容是 prog.hmtn —— 而它必须被认成包。
;
; 「按扩展名猜」的实现会把三条判据的头一条与第三条都做对（因为那两个名字本来就是对的），
; 只在第二条上翻车 —— 而一条只有两条判据的测试分不出它来。所以这一层要三条。
;
; rdi = 内容，rcx = 长度。出 rax = 1 文本、2 包、0 不认得。
identify:
    cmp rcx, 5
    jb .unknown
    ; 包：魔数 HMYRB
    cmp byte [rdi], 'H'
    jne .text_check
    cmp byte [rdi + 1], 'M'
    jne .text_check
    cmp byte [rdi + 2], 'Y'
    jne .text_check
    cmp byte [rdi + 3], 'R'
    jne .text_check
    cmp byte [rdi + 4], 'B'
    jne .text_check
    mov rax, 2
    ret
.text_check:
    ; 别的系统的可执行与包：五个头，都在前 64 个字节内。
    ;
    ; 判断顺序有讲究。MZ 只有两个字节，最容易撞上（一个以字母 MZ 开头的文本文件就是），
    ; 所以它不单独成立 —— 真正的 PE 定义是「MZ，而 offset 0x3C 那个 u32 指着 PE\0\0」。
    ; 判据要的是那个定义，不是它的缩写。
    cmp word [rdi], 0x5A4D         ; 'M' 'Z'
    jne .try_elf
    cmp rcx, 64
    jb .try_elf
    mov eax, [rdi + 0x3C]          ; e_lfanew：PE 头在文件里的偏移
    cmp eax, 0x10000000
    jae .try_elf                   ; 荒谬的偏移，不可能是 PE
    add rax, 4
    cmp rax, rcx
    jae .try_elf
    cmp dword [rdi + rax - 4], 0x00004550   ; 'P' 'E' 0 0
    jne .try_elf
    mov rax, 3
    ret
.try_elf:
    cmp dword [rdi], 0x464C457F    ; 7F 'E' 'L' 'F'
    jne .try_macho
    mov rax, 4
    ret
.try_macho:
    mov eax, [rdi]
    ; Mach-O 的魔数有四种写法（32 位与 64 位，各自两种字节序）。
    ; 只认前两种的话，一台大端机器上编译出来的东西会被认成不认得。
    cmp eax, 0xFEEDFACF
    je .macho
    cmp eax, 0xFEEDFACE
    je .macho
    cmp eax, 0xCFFAEDFE
    je .macho
    cmp eax, 0xCEFAEDFE
    je .macho
    jmp .try_zip
.macho:
    mov rax, 5
    ret
.try_zip:
    ; PK 03 04 是 zip 的头。APK 也是 zip，而「这个 zip 是不是 APK」要往里翻
    ; AndroidManifest.xml —— 那超过「看头几个字节」这一层的约定，所以这里答 zip。
    ; 一个答不出来的问题，比一个猜出来的答案好。
    cmp dword [rdi], 0x04034B50    ; 'P' 'K' 03 04
    jne .try_dex
    mov rax, 6
    ret
.try_dex:
    cmp dword [rdi], 0x0A786564    ; 'd' 'e' 'x' '\n'
    jne .try_gzip
    mov rax, 7
    ret
; 下面七个是「别的系统的东西」里最常撞上的那几种。它们与上面五个同一个约定：能从头上
; 答出来的才答。所以「这个 zip 是不是 APK」仍然不答 —— 那要往里翻 AndroidManifest.xml，
; 而一个答不出来的问题比一个猜出来的答案好。
.try_gzip:
    cmp word [rdi], 0x8B1F         ; 1F 8B
    jne .try_7z
    cmp byte [rdi + 2], 8          ; 压缩方法：8 是 deflate，几乎只有它
    jne .try_7z
    mov rax, 8
    ret
.try_7z:
    cmp dword [rdi], 0xAFBC7A37    ; 37 7A BC AF
    jne .try_rar
    cmp word [rdi + 4], 0x1C27     ; 27 1C
    jne .try_rar
    mov rax, 9
    ret
.try_rar:
    cmp dword [rdi], 0x21726152    ; 'R' 'a' 'r' '!'
    jne .try_pdf
    cmp word [rdi + 4], 0x071A     ; 1A 07
    jne .try_pdf
    mov rax, 10
    ret
.try_pdf:
    cmp dword [rdi], 0x46445025    ; '%' 'P' 'D' 'F'
    jne .try_png
    mov rax, 11
    ret
.try_png:
    cmp rcx, 8
    jb .try_jpeg
    cmp dword [rdi], 0x474E5089    ; 89 'P' 'N' 'G'
    jne .try_jpeg
    cmp dword [rdi + 4], 0x0A1A0A0D ; 0D 0A 1A 0A
    jne .try_jpeg
    mov rax, 12
    ret
.try_jpeg:
    cmp word [rdi], 0xD8FF         ; FF D8
    jne .try_sqlite
    cmp byte [rdi + 2], 0xFF       ; 第三个字节也是 FF：标记段的起点
    jne .try_sqlite
    mov rax, 13
    ret
.try_sqlite:
    cmp rcx, 16
    jb .try_text
    cmp dword [rdi], 0x694C5153    ; 'S' 'Q' 'L' 'i'
    jne .try_hmgk
    cmp dword [rdi + 4], 0x66206574 ; 't' 'e' ' ' 'f'
    jne .try_hmgk
    cmp dword [rdi + 8], 0x616D726F ; 'o' 'r' 'm' 'a'
    jne .try_hmgk
    cmp dword [rdi + 12], 0x00332074 ; 't' ' ' '3' 0
    jne .try_hmgk
    mov rax, 14
    ret
.try_hmgk:
    ; hmgk（ひめがく）：KID 的音乐输出文件。规范与字节布局在 design/HMGK.txt。
    ;
    ; 它是这张表里第一个本机自己的格式 —— 前面十四种都是别人的。而它进这张表的理由
    ; 与那十四种一样：前四个字节是魔数，按字节比，不看扩展名。
    cmp rcx, 20
    jb .try_text
    cmp dword [rdi], 0x4B474D48    ; 'H' 'M' 'G' 'K'
    jne .try_text
    mov rax, 15
    ret
.try_text:
    ; 文本：头 32 个字节里没有不可打印的东西（换行、回车、制表除外）
    mov r8, rcx
    cmp r8, 32
    jbe .scan
    mov r8, 32
.scan:
    xor r9, r9
.loop:
    cmp r9, r8
    jae .text
    mov al, [rdi + r9]
    cmp al, 32
    jb .control
    cmp al, 126
    ja .unknown
    jmp .next
.control:
    cmp al, 10
    je .next
    cmp al, 13
    je .next
    cmp al, 9
    je .next
    jmp .unknown
.next:
    inc r9
    jmp .loop
.text:
    mov rax, 1
    ret
.unknown:
    xor eax, eax
    ret

; 三条判据。第二条（fake.txt）是「看内容不看名字」那一刀。
run_identify_test:
    mov rsi, line_ident_head
    call puts64
    ; hello.txt：真是文本
    mov rdi, fs_hello_path
    call fs_open_path
    test rax, rax
    jz .miss
    mov rdi, [last_addr]
    mov rcx, rbx
    call identify
    call put_ident_kind
    ; prog.hmtn：真是包
    mov rdi, fs_prog_path
    call fs_open_path
    test rax, rax
    jz .miss
    mov rdi, [last_addr]
    mov rcx, rbx
    call identify
    call put_ident_kind
    ; fake.txt：名字是文本、内容是包 —— 而它必须被认成包
    mov rdi, fs_fake_path
    call fs_open_path
    test rax, rax
    jz .miss
    mov rdi, [last_addr]
    mov rcx, rbx
    call identify
    call put_ident_kind
    ; 别的系统的五种头。样本的名字一律是 .bin —— 后缀与内容无关，而这一条在 fake.txt
    ; 上已经验过一次；这里是同一个道理换个方向：判据要看的是头，不是后缀。
    mov rdi, fs_pe_path
    call fs_open_path
    test rax, rax
    jz .miss
    mov rdi, [last_addr]
    mov rcx, rbx
    call identify
    call put_ident_kind
    mov rdi, fs_elf_path
    call fs_open_path
    test rax, rax
    jz .miss
    mov rdi, [last_addr]
    mov rcx, rbx
    call identify
    call put_ident_kind
    mov rdi, fs_macho_path
    call fs_open_path
    test rax, rax
    jz .miss
    mov rdi, [last_addr]
    mov rcx, rbx
    call identify
    call put_ident_kind
    mov rdi, fs_zip_path
    call fs_open_path
    test rax, rax
    jz .miss
    mov rdi, [last_addr]
    mov rcx, rbx
    call identify
    call put_ident_kind
    mov rdi, fs_dex_path
    call fs_open_path
    test rax, rax
    jz .miss
    mov rdi, [last_addr]
    mov rcx, rbx
    call identify
    call put_ident_kind
    ; 另外七种：直接给头，不经文件系统。
    ;
    ; identify 吃的是「一串字节加一个长度」，所以它不需要文件系统 —— 而根目录只有
    ; 512 字节，十八条已经用掉四百八十多，再放七个样本就溢出（症状是 build 在偏移
    ; 511 处抛 RangeError）。判据要的是「给一个头，它答那个名字」，不关心那个头是从
    ; 盘上读来的还是从数据段里指过来的。
    lea rdi, [samp_gzip]
    mov rcx, 64
    call identify
    call put_ident_kind
    lea rdi, [samp_7z]
    mov rcx, 64
    call identify
    call put_ident_kind
    lea rdi, [samp_rar]
    mov rcx, 64
    call identify
    call put_ident_kind
    lea rdi, [samp_pdf]
    mov rcx, 64
    call identify
    call put_ident_kind
    lea rdi, [samp_png]
    mov rcx, 64
    call identify
    call put_ident_kind
    lea rdi, [samp_jpeg]
    mov rcx, 64
    call identify
    call put_ident_kind
    lea rdi, [samp_sqlite]
    mov rcx, 64
    call identify
    call put_ident_kind
    ; 第十六格：本机自己的格式。样本按 design/HMGK.txt 的布局造 —— 魔数、版本、
    ; 压缩格式与级别、事件流长度、三张表的项数。识别只看前四个字节，而整份样本
    ; 按真实布局写，是为了让「一份 hmgk 长什么样」在这里也有个可读的样子。
    lea rdi, [samp_hmgk]
    mov rcx, 64
    call identify
    call put_ident_kind
    call put_nl64
    ret
.miss:
    mov rsi, line_ident_miss
    call puts64
    ret

; hmgk 的头：按布局把四个字段读出来。
;
; 这一条与上面那一格问的不是同一件事。上面认只需要头四个字节 —— 魔数对了就答 hmgk，
; 而这一条要按偏移走完整个头、读出四个数，所以「魔数对」在这里只是前提，不是答案。
;
; 挑这四个字段的理由：
;   版本在偏移 4、结构段在偏移 8、pattern 数在偏移 22、BPM 在偏移 28 —— 后三个都不在
;   头四个字节里，读错了位置只会得到别的数；而 pattern 数夹在两串 u16 之间，最容易
;   数错一格。
; 判据是三个写死在样本里的数（BPM 120500、结构段 40、pattern 3）加上版本 1。它们只有
; 按布局算偏移才报得出来：从「恰好非零」里凑不出 120500 这样的值。
;
; 寄存器：rbx 存样本地址，put_num64 自己 push/pop 它，puts64 不碰它，所以全程安全。
run_hmgk_test:
    lea rbx, [samp_hmgk]
    mov rsi, line_hmgk_v
    call puts64
    movzx eax, word [rbx + 4]      ; 版本
    call put_num64
    mov rsi, line_hmgk_bpm
    call puts64
    mov eax, [rbx + 28]            ; BPM × 1000
    call put_num64
    mov rsi, line_hmgk_struct
    call puts64
    mov eax, [rbx + 8]             ; 结构段字节数
    call put_num64
    mov rsi, line_hmgk_pattern
    call puts64
    movzx eax, word [rbx + 22]     ; pattern 数
    call put_num64
    jmp put_nl64

; 在一段字节里找四字节魔数。
;
; 为什么要这个函数：identify 只看头上那几个字节，而那套约定在「一份文件被嵌进另一个
; 程序」之后就不成立了 —— 那时 hmgk 的魔数出现在任意位置。认出这种形态只有一条路：扫。
;
; 入参 rdi 起点、rcx 长度、eax 要找的 dword。返回 rax = 偏移，找不到给 -1。
; 上界是 rcx - 4：最后一个合法起点要能读满四个字节，否则会读出边界外。
; r8 与 r9 是这段的循环变量，不保存 —— 调用者不能指望它们。
scan_magic:
    cmp rcx, 4
    jb .none
    mov r8, rcx
    sub r8, 4
    xor r9, r9
.loop:
    cmp r9, r8
    ja .none
    cmp dword [rdi + r9], eax
    je .found
    inc r9
    jmp .loop
.found:
    mov rax, r9
    ret
.none:
    mov rax, -1
    ret

; 嵌入形态：一个 PE 头后面跟着一份 hmgk。
;
; 判据要两样东西，缺一不算：主类型答 pe（说明外面那层先被认出来了），并且扫出来的偏移
; 正好是 256（说明里面那份 hmgk 确实在它该在的地方）。只答一样不够 —— 只答 pe 的实现
; 根本不知道里面有东西，只答 hmgk 的实现则把外面那层漏了。
;
; 256 这个数不是挑的：样本按那个偏移造，而扫描要从 0 一路走到 255 才撞上它，所以「扫到
; 了」这件事本身包含了「前面那 255 个字节都不是魔数」。
;
; 顺序上有个坑值得记：puts64 会 clobber rax（lodsb 改 al），所以前缀必须先打、类型码必须
; 后取。反过来写会打出上一格留下的数字，而那种错看起来像「identify 算错了」。
run_hmgk_embed_test:
    mov rsi, line_embed_main
    call puts64
    lea rdi, [samp_embed]
    mov rcx, samp_embed_len
    call identify
    call put_ident_kind

    mov rsi, line_embed_inner
    call puts64
    lea rdi, [samp_embed]
    mov rcx, samp_embed_len
    mov eax, 0x4B474D48            ; 'H' 'M' 'G' 'K'
    call scan_magic
    cmp rax, -1
    je .none
    call put_num64
    jmp put_nl64
.none:
    mov rsi, line_embed_missing
    call puts64
    jmp put_nl64

; 把一个类型码打成名字，接在后面。
;
; 名字用短的：这一行要在一行里挤八个结果，而判据要能一眼看出哪一格不对。
put_ident_kind:
    cmp rax, 1
    je .text
    cmp rax, 2
    je .pkg
    cmp rax, 3
    je .pe
    cmp rax, 4
    je .elf
    cmp rax, 5
    je .macho
    cmp rax, 6
    je .zip
    cmp rax, 7
    je .dex
    cmp rax, 8
    je .gzip
    cmp rax, 9
    je .sevenz
    cmp rax, 10
    je .rar
    cmp rax, 11
    je .pdf
    cmp rax, 12
    je .png
    cmp rax, 13
    je .jpeg
    cmp rax, 14
    je .sqlite
    cmp rax, 15
    je .hmgk
    mov rsi, line_kind_none
    jmp .out
.text:
    mov rsi, line_kind_text
    jmp .out
.pkg:
    mov rsi, line_kind_pkg
    jmp .out
.pe:
    mov rsi, line_kind_pe
    jmp .out
.elf:
    mov rsi, line_kind_elf
    jmp .out
.macho:
    mov rsi, line_kind_macho
    jmp .out
.zip:
    mov rsi, line_kind_zip
    jmp .out
.dex:
    mov rsi, line_kind_dex
    jmp .out
.gzip:
    mov rsi, line_kind_gzip
    jmp .out
.sevenz:
    mov rsi, line_kind_7z
    jmp .out
.rar:
    mov rsi, line_kind_rar
    jmp .out
.pdf:
    mov rsi, line_kind_pdf
    jmp .out
.png:
    mov rsi, line_kind_png
    jmp .out
.jpeg:
    mov rsi, line_kind_jpeg
    jmp .out
.hmgk:
    mov rsi, line_kind_hmgk
    jmp .out
.sqlite:
    mov rsi, line_kind_sqlite
.out:
    call puts64
    mov al, ' '
    call putc64
    ret

; 打一串 UTF-16 码元，只取低字节。这一版的名字都是 ASCII，够用；非 ASCII 的名字会
; 在这里变成别的字节，而那是「打印」这一层的限制，不是名字本身的。
put_utf16_ascii:
.one:
    movzx eax, word [rdi]
    test eax, eax
    jz .out
    push rdi
    call putc64
    pop rdi
    add rdi, 2
    jmp .one
.out:
    ret

; rdi = 码元串，rcx = 码元数。只打这些，不看零码元。
;
; 为什么另起一个：目录条目里的名字之后紧跟类型 u8 与起始扇区 u32，那几个字节
; 不是码元。用「打到零码元」那种写法，类型是 0 而扇区号是 0x403 时，读到的
; 下一个「码元」是 0x0300 —— 不是零，于是多打出几个看不见的字节。
put_utf16_n:
.l:
    test rcx, rcx
    jz .out
    movzx eax, word [rdi]
    push rdi
    push rcx
    call putc64
    pop rcx
    pop rdi
    add rdi, 2
    dec rcx
    jmp .l
.out:
    ret

; 跑两次符位：参数真时它应当交出 2147483648，参数假时交出 0。
; 这两次跑的是同一段指令、同一个入口，只差栈上那一个值 —— 所以它们同时验了
; 「跳转真的按条件走」与「两条路都走到了」。
run_fn116_twice:
    mov qword [test_arg], 1
    call run_fn116
    ; 这里不能夹任何打印：puts64 用 lodsb，会把 rax 的低字节改掉，而 rax 正是
    ; 刚跑出来的种类。第一次跑就栽在这上面 —— 返回值在报告之前被一行诊断毁了，
    ; 症状是「第一个结果是空、第二个对」，看起来像求值器只对了一半。
    call fn116_report
    mov qword [test_arg], 0
    call run_fn116
    call fn116_report
    ret

fn116_report:
    mov r12, rax                    ; 种类
    mov rbx, rdx                    ; 内容
    mov rsi, line_fn116
    call puts64
    cmp r12, 1                      ; 数
    jne .bad
    ; 数的内容是一份 f64 的位模式，不是整数 —— 直接交给 put_num64 会打出一个
    ; 十几位的天文数字（2147483648 的位模式是 4746794007248502784）。
    ; 这一版只需要非负整数，所以取指数与尾数把它还原成整数就够。
    mov rax, rbx
    call f64_to_int
    call put_num64
    jmp put_nl64
.bad:
    mov rsi, line_bad_kind
    call puts64
    mov rax, r12
    call put_num64
    call put_nl64

; rax（f64 位模式）→ rax（整数）。只处理非负、整数、且小于 2^63 的情况 ——
; 这一块要验的两个值都在这范围里。别的值会给出一个凑合的结果，而不是崩溃，
; 因为这是显示层的一步，不该替求值层做判断。
f64_to_int:
    mov rdx, rax
    shr rdx, 52
    and edx, 0x7FF                  ; 指数
    jz .zero                        ; 指数为零就是零（这一版不处理非规格化）
    sub edx, 1023
    js .zero
    mov r9, rax
    mov r10, 0x000FFFFFFFFFFFFF
    and r9, r10                     ; 尾数低 52 位
    bts r9, 52                      ; 补上隐含的那个 1
    mov ecx, edx
    sub ecx, 52                     ; 要移的位数
    jz .done
    js .shr
    shl r9, cl
    jmp .done
.shr:
    neg ecx
    shr r9, cl
.done:
    mov rax, r9
    ret
.zero:
    xor eax, eax
    ret
run_fn116:
    ; 符位 的指令流在种子偏移 43920（0xAB90），11 条指令 —— 那是用 node 走一遍函数表
    ; 算出来的确定位置。这里不走遍历：Map 会把重名折成一个，所以「第几个函数」在
    ; 两侧不是同一个数（这一侧按文件顺序数，node 那边给的是 121），而这一块只需要
    ; 一个确定的字节位置，不需要一个可能对不上的序号。
    mov rsi, 0x70000 + 43920
    mov r12, rsi
    mov r13, 11
    ; 参数进帧 0 的槽 0。「取」读的是槽区，不是运算栈 —— 所以这里直接写槽，
    ; 而不是压一次栈让两边「对得上」。上一版两条路都写一遍，那正是隐患：
    ; 一旦它们不同步，读到的参数与算出来的参数就是两个值。
    mov qword [stack_top], 32
    mov qword [frame_sp], 0
    mov rax, 1                      ; 数
    mov [stack_kinds], rax
    mov rax, [test_arg]
    mov [stack_vals], rax
    call exec
    ret
.none:
    xor rax, rax
    xor rdx, rdx
    ret

; 按立即数形状跳过一条指令剩余的部分。形状编号沿用 src/code-file.mjs 的十种，
; 这里只用到八种能算出长度的（tuple 与 value 里的元组/记录走不到，遇到就停）。
;   0 none  1 u16  2 u32  3 name  4 store  5 record  6 call  7 value  8 tuple
skip_imm:
    cmp al, 0
    je .done
    cmp al, 1
    je .u16
    cmp al, 2
    je .u32
    cmp al, 3
    je .name
    cmp al, 4
    je .store
    cmp al, 5
    je .record
    cmp al, 6
    je .call
    cmp al, 7
    je .value
    ; 8 tuple：一个 u16 长度，后面跟的是槽号不是数据，所以只跳过长度
    add rsi, 2
    ret
.u16:
    add rsi, 2
    ret
.u32:
    add rsi, 4
    ret
.name:
    movzx eax, word [rsi]
    lea rsi, [rsi + 2 + rax * 2]
    ret
.store:
    add rsi, 3                     ; u16 槽号 + u8 是否声明
    ret
.record:
    movzx ecx, word [rsi]
    add rsi, 2
.rec_loop:
    test ecx, ecx
    jz .done
    movzx eax, word [rsi]
    lea rsi, [rsi + 2 + rax * 2]
    dec ecx
    jmp .rec_loop
.call:
    movzx eax, word [rsi]          ; 名字在前
    lea rsi, [rsi + 2 + rax * 2]
    add rsi, 2                     ; 再跟一个 u16
    ret
.value:
    movzx eax, byte [rsi]          ; 值编码的首字节就是种类
    inc rsi
    test eax, eax
    jz .done                       ; 0 空
    cmp eax, 1
    je .v_num
    cmp eax, 2
    je .v_str
    cmp eax, 3
    je .v_bool
    ; 4 元组 / 5 记录：这一块不展开，遇到就停 —— 第一个函数的四条指令用不到它们
    ret
.v_num:
    add rsi, 8                     ; f64
    ret
.v_str:
    movzx eax, word [rsi]
    lea rsi, [rsi + 2 + rax * 2]
    ret
.v_bool:
    add rsi, 1
.done:
    ret

; 把 rax 里的地址打成一整行：前缀、十六位十六进制、换行。
show_alloc:
    push rax
    mov rsi, line_alloc
    call puts64
    pop rax
    push rax
    call put_hex64
    call put_nl64
    pop rax
    ret

; bump 分配：游标从 heap_next 起往上走，返回移走之前的位置。
; 按 16 字节对齐 —— 那够大多数结构用，而对齐要从第一个分配器就有，
; 不然后面每个调用点都得自己补一次。
alloc64:
    add rax, 15
    and rax, -16
    mov rdx, [heap_next]
    add [heap_next], rax
    mov rax, rdx
    ret

; 打印 rax 的十六位十六进制（大写）。用 rol 从最高四位开始取 —— 十六个字符正好是
; 一个 64 位地址的宽度，前面补零比省略更能看出对齐。
put_hex64:
    push rax
    push rcx
    push rdx
    mov rcx, 16
.loop:
    rol rax, 4
    mov edx, eax
    and edx, 0x0F
    cmp edx, 10
    jb .digit
    add edx, 'A' - 10
    jmp .emit
.digit:
    add edx, '0'
.emit:
    ; 这里必须把 rax 存一下：putc64 吃的是 al，而 al 就是 rax 的低字节 ——
    ; 不保存的话，下一次 rol 会在一份被改过的值上转，十六个字符里只有第一个是对的。
    ; 症状是地址看起来「总差那么几个」，而不是完全错，很容易被当成对齐算错了。
    push rax
    mov al, dl
    call putc64
    pop rax
    dec rcx
    jnz .loop
    pop rdx
    pop rcx
    pop rax
    ret

put_nl64:
    push rax
    mov al, 13
    call putc64
    mov al, 10
    call putc64
    pop rax
    ret

puts64:
    lodsb
    test al, al
    jz .done
    call putc64
    jmp puts64
.done:
    ret
putc64:
    push rax
    push rdx
    mov ah, al
    mov dx, 0x3FD
.wait:
    in al, dx
    test al, 0x20
    jz .wait
    mov al, ah
    mov dx, 0x3F8
    out dx, al
    pop rdx
    pop rax
    ret

; ======================================================================
; 四、数据（不分位宽，谁都在段 0 里按偏移取）
; ======================================================================
[bits 16]
drive: db 0
; 信箱那几样。mbox_save 存主盘号，因为 int 0x13 的盘号要从 [drive] 里取，而读信箱时
; 得临时把它换成 0x81 —— 读坏了不能连主盘一起不认。
mbox_save: db 0
mbox_carry: db 0
mbox_magic: db "YUNOMBX", 0
; 运行时轮询用的缓冲：一次 ata_read 读进来 512 字节。
;
; 它不与 0x50000 那一块共用。那一块是启动时实模式读进来的快照，而这一块每次都是新读的。
; 两者分开，才分得清「启动时那一份」与「刚才盘上那一份」—— 而这一格要的正是后者：
; 一条只在启动时读的通道，与一条运行时还能读到新东西的通道，是两件不同的事。
mbox_buf: times 512 db 0
; 上一次见到的序列号。0 表示还没记过基准 —— 第一次轮询只记基准，不报新，
; 否则启动时那份快照会被当成一条刚到的输入。
mbox_serial0: dq 0
; 队头：下一次读哪个扇区。消费一条就前进一格 —— 队列因此能放不止一条消息，
; 而「一条消息只被读一次」不再靠序列号，靠队头。
;
; 从 4 起：第 0 到第 3 是启动时读的那四个。测试可以把队头摆到别处（一个没有 YUNOMBX
; 的扇区就是「这一趟别从盘上送东西」），于是「哪一趟由谁来送」变成一件可以安排的事，
; 而不是靠谁先等谁先得。
mbox_head: dq 4
seed_magic: db "HMYRB"

; Disk Address Packet，16 字节。每次调用前重设 count 与 off/seg —— int 0x13 会把
; count 改成实际读到的扇区数，也会把 lba 推进到下一批的位置。
dap:
    db 0x10
    db 0
dap_count:
    dw 64
dap_off:
    dw 0x8000
dap_seg:
    dw 0x0000
dap_lba:
    dd 9
    dd 0

; GDT：空描述符、32 位代码段、数据段、64 位代码段。
;
; 这里必须有**两个**代码段描述符，这是实测踩出来的：一开始只有一个 L=1 的代码段，
; 于是刚置完 CR0.PE 就拿它远跳 —— 而 L=1 的段在还没打开 EFER.LME 时是未定义的，
; CPU 不是报错而是挂住，串口停在远跳之前那一个观测字节上，看不出原因。
; 所以：进保护模式用 0x08（D=1, L=0），进长模式用 0x18（D=0, L=1）。
align 8
gdt:
    dq 0x0000000000000000         ; 0x00 空
    dq 0x00CF9A000000FFFF         ; 0x08 32 位代码：G=1, D=1, L=0
    dq 0x00CF92000000FFFF         ; 0x10 数据：G=1, D=1
    dq 0x00AF9A000000FFFF         ; 0x18 64 位代码：G=1, D=0, L=1
gdt_end:
gdt_desc:
    dw gdt_end - gdt - 1
    dd gdt

line2:     db "Yunooka: stage2 ok", 13, 10, 0
line3ok:   db "Yunooka: seed ok ", 0
line3bad:  db "Yunooka: seed bad", 13, 10, 0
line3fail: db "Yunooka: seed unreadable", 13, 10, 0
line4:     db "Yunooka: protected mode ok", 13, 10, 0
line5:     db "Yunooka: long mode ok", 13, 10, 0
line_alloc: db "Yunooka: alloc ", 0
line_heap_ok: db "Yunooka: heap ok", 13, 10, 0
line_heap_bad: db "Yunooka: heap bad", 13, 10, 0
line_clock_head: db "Yunooka: clock ticks=", 0
line_clock_rate: db "Yunooka: clock rate=", 0
clock_cal_t0: dq 0
clock_a: dq 0
clock_start: dq 0
line_wait_timeout: db "Yunooka: wait timeout ", 0
line_drain: db "Yunooka: drain ", 0
clock_deadline: dq 0
clock_nextpoll: dq 0
wait_budget: dq wait_ticks
line_seed_hdr: db "Yunooka: seed v", 0
line_seed_mid: db " ", 0
line_fn: db "Yunooka: fn ", 0
line_fn_params: db " params ", 0
line_fn_mid: db " slots ", 0
line_fn_instrs: db " instrs ", 0
line_op: db "Yunooka: op ", 0
line_nl:   db 13, 10, 0

; 操作码 → 立即数形状，按号排（0 到 33），与 src/code-file.mjs 的立即数形状表一致。
; 形状编号：0 none · 1 u16 · 2 u32 · 3 name · 4 store · 5 record · 6 call ·
;          7 value · 8 tuple
; 这张表是走完指令流的前提：不知道一条指令占多少字节，就只能读第一条。
imm_shape:
    db 0, 1, 0, 6, 6, 7, 0, 0, 3, 0, 3, 0, 0, 2, 2, 2, 2, 2, 0, 1
    db 0, 0, 0, 0, 0, 0, 0, 5, 0, 4, 0, 1, 6, 3
    db 1                     ; 34：本侧自己的「存」，HMYR 的表里没有这一条
    db 1, 1                  ; 35 全域取、36 全域存：本侧自己的，HMYR 里也没有

line_letters: db "Yunooka: letters -> ", 0
line_op_bad: db "Yunooka: scan op ", 0
line_fn_dbg: db "Yunooka: fn at ", 0
line_skip_dbg: db "Yunooka: skip at ", 0
line_scan_dbg: db "Yunooka: scan at ", 0
dbg_rsi: dq 0
dbg_len: dq 0
dbg_a: dq 0
dbg_b: dq 0
dbg_c: dq 0
line_measure: db "Yunooka: shape ", 0
line_string: db "string ", 0
line_number: db "number", 13, 10, 0
line_bool: db "bool", 13, 10, 0
line_empty: db "empty", 13, 10, 0
line_unknown_kind: db "?", 13, 10, 0

; 只有一格的栈。letters 从入口到第一个「返回」只压过一次，所以一格够用；
; 不够用的时候会以「结果不对」的形式露出来，那时再加深度也不迟。
align 8
stack_kind: dq 0
stack_val: dq 0
; 桥的返回值暂存。它与上面那两格不是一回事：那两格是「只有一格的栈」，而这两格只是内层
; exec 停下时的一个快照 —— 取走就作废，下一次桥接会重新写。
rp_kind: dq 0
rp_val: dq 0
; 两个参数的桥还要多存一对：栈顶是第二个实参，先弹出来的那个得先放下，等第一个弹出来才能
; 按「槽 0 是第一个实参」写回去。这一对就是那半步的落脚处。
rp_kb: dq 0
rp_b: dq 0

; 解释器的那几样：值栈、帧、以及每条指令的字节偏移。
;
; 值栈分两段用。0 到 31 是槽区：一帧占八格，槽 0 到 7 放参数与局部量；32 往上是
; 运算区，push_val 从那里往上走。分成两段是因为「取」读的是槽，而槽不能随运算栈的
; 高低漂移 —— 一压一弹之间，槽的位置必须不动。
;
; 帧深四。这个深度是照着非尾调用挑的：in_set 的递归形参里有个下标、每轮加一，十轮
; 就要十帧，而那条递归是尾调用，所以真正常用的路不吃帧；四帧留给「调完还要接着算」
; 的那种。
align 8
stack_kinds: times 48 dq 0
stack_vals:  times 48 dq 0
stack_top:   dq 32
frame_sp:      dq 0
frame_pc:      times 4 dq 0
frame_instr:   times 4 dq 0
frame_count:   times 4 dq 0
frame_slotbase: times 4 dq 0
instr_offsets: times 64 dq 0
test_arg: dq 1
ata_buf: dq 0
; 这一趟 ata_read 读哪一块盘：0 是主盘，0x10 是从盘（信箱盘）。
;
; 它平时是 0 —— 文件系统那一整套读的都是主盘，而它们是这条通道的绝大多数调用者。
; 只有 mbox_poll 在读之前把它置成 0x10、读完置回，所以「哪块盘」这件事只在一处出现。
ata_dev: db 0
fs_buf: dq 0
; 当前这个盘符对应哪一块盘：预读区的基址，与那一段从哪个扇区起。
; 默认是 α（主盘）。fs_open_path 认盘符之后会把它们改成 β 的，用完拨回来。
fs_base: dq 0x40000
fs_start: dq 1024
; fs_lookup 命中的那一条在预读区里的地址。改共享位要用它 —— 而 lookup 本来就找到了
; 那一条，只是以前没把位置留下来。
last_entry: dq 0
; 最后一条被打开的路径的「数据在哪儿」。fs_open_path 算好它 —— 因为只有它知道
; 那一条属于哪一块盘，而调用者知道的时候已经太晚了。
last_addr: dq 0
; 列共享时用的游标：循环变量放内存，不托付给任何寄存器。
shares_ptr: dq 0
; 过边界时要同时拿着两边的家 ID，而中间那两次 fs_load 会吃掉寄存器 —— 放内存。
gate_a: dd 0
gate_b: dd 0
; 非零时门放行。只有标记这种管理动作会打开它，读取一律走门。
gate_off: dq 0
; calc_live 求出来的那个值：打印分几支，而 xmm 会在打印里被用掉。
calc_value: dq 0
; 从盘上那条规则解出来的签名，以及它的字节数。
sig_buf: times 256 db 0
sig_len: dq 0
; 多行规则那一层用的游标与名字。规则库遍历与文件遍历各自要一个指针，
; 寄存器不够用，而这类「被打印函数吃掉」的教训在这份文件里已经有四条了。
rules_ptr: dq 0
rules_left: dq 0
data_ptr: dq 0
data_len: dq 0
rule_name: times 32 db 0
; 绘图那一层要的几个数：当前 x、两次求值的结果、上一个屏幕点。
; 而它们必须是内存变量 —— draw_line 自己要用 r12 到 r15，与绘图循环抢的正是同一组寄存器。
var_x: dq 0
plot_y: dq 0
cur_x: dq 0
cur_y: dq 0
prev_x: dq 0
prev_y: dq 0

line_fn116: db "Yunooka: fn116 -> ", 0
line_call: db "Yunooka: call -> ", 0
line_byname: db "Yunooka: byname -> ", 0
line_byname_first: db "Yunooka: byname first -> ", 0
line_byname_missing: db "Yunooka: byname missing after ", 0

; 「块长」两个字的 UTF-16 码元。按名字找函数时，名字是拿这份字节去比，
; 而不是拿一个编译期算出来的偏移 —— 偏移只在种子不变时才对，名字才属于语言。
name_kuaichang: dw 0x5757, 0x957F
name_is_digit: dw 0x0069, 0x0073, 0x005F, 0x0064, 0x0069, 0x0067, 0x0069, 0x0074
fs_myon_name: dw 0x006D, 0x0079, 0x006F, 0x006E, 0x002E, 0x0068, 0x006D, 0x0074, 0x006E
myon_dbg_a: dq 0
myon_dbg_b: dq 0
myon_dbg_c: dq 0
; slurp 拼出来的路径（α:/ + 参数）与它交出去的串。
slurp_path: times 520 dw 0
slurp_dbg: dq 0
line_slurp_miss: db "Yunooka: slurp miss at ", 0
slurp_buf: times 520 db 0
; save 内置用的两块缓冲：名字（去掉长度前缀、以零码元收尾）与内容（码元压成字节）。
save_buf: times 512 db 0
save_name: times 132 dw 0
save_len: dq 0
last_write_sec: dq 0
last_dir_sec: dq 0
last_dir_pages: dq 0
; fs_write_file 写到哪一层：0 是根目录，非零是某一个目录的扇区。
write_dir: dq 0
list_dir: dq 0
; 包写出来的那一份，用完整路径再查一次。
fs_save_path: dw 0x03B1, 0x003A, 0x002F, 0x0064, 0x006F, 0x0063, 0x0073, 0x002F, 0x0069, 0x006E, 0x006E, 0x0065, 0x0072, 0x002E, 0x0074, 0x0078, 0x0074, 0
name_savetest: dw 0x0073, 0x0061, 0x0076, 0x0065, 0x0074, 0x0065, 0x0073, 0x0074
name_listtest: dw 0x006C, 0x0069, 0x0073, 0x0074, 0x0074, 0x0065, 0x0073, 0x0074
name_removetest: dw 0x0072, 0x0065, 0x006D, 0x006F, 0x0076, 0x0065, 0x0074, 0x0065, 0x0073, 0x0074
line_prog_remove: db "Yunooka: prog remove -> ", 0
line_prog_remove_bad: db "Yunooka: prog remove missing", 13, 10, 0
fs_docs_name: dw 0x0064, 0x006F, 0x0063, 0x0073
fs_late_name: dw 0x006C, 0x0061, 0x0074, 0x0065, 0x002E, 0x0074, 0x0078, 0x0074, 0
fs_late_data: db 'x', 'y'
late_probe: dq 0
late_probe_sec: dq 0
fs_late_path: dw 0x03B1, 0x003A, 0x002F, 0x0064, 0x006F, 0x0063, 0x0073, 0x002F, 0x006C, 0x0061, 0x0074, 0x0065, 0x002E, 0x0074, 0x0078, 0x0074, 0
line_late_ok: db "Yunooka: dirfull docs ok ", 0
line_late_blocked: db "Yunooka: dirfull docs blocked", 13, 10, 0
line_late_lost: db "Yunooka: dirfull docs lost", 13, 10, 0
line_prog_list: db "Yunooka: prog list -> ", 0
line_prog_list_bad: db "Yunooka: prog list missing", 13, 10, 0
line_save_survived: db "Yunooka: save survived docs/inner.txt ", 0
line_save_ok: db "Yunooka: save docs/inner.txt ", 0
line_save_lost: db "Yunooka: save docs/inner.txt lost", 13, 10, 0
line_save_missing: db "Yunooka: save missing", 13, 10, 0
dirfull_ok: dq 0
dirfull_no: dq 0
fs_full_name: times 8 dw 0
fs_full_data: db 'x'
line_full_ok: db "Yunooka: dirfull wrote ", 0
line_full_mid: db " refused ", 0
line_full_eaten: db "Yunooka: dirfull ate docs", 13, 10, 0
fs_myon_path: dw 0x03B1, 0x003A, 0x002F, 0x0064, 0x006F, 0x0063, 0x0073, 0x002F, 0x006D, 0x0079, 0x006F, 0x006E, 0x002E, 0x0068, 0x006D, 0x0074, 0x006E, 0
name_echo: dw 0x0065, 0x0063, 0x0068, 0x006F

; ---- 内置表 ------------------------------------------------------------
;
; 表项三样：名字长度、名字指针、处理者。长度为零结束。
;
; 换成表之前的形状是一条跳转链 —— 每加一个内置都要回头改上一个的失败出口。那个错
; 在一轮里犯了两次（readline 与 border 都因此没被试到），症状都是 unknown builtin，
; 而那看起来像名字写错。表之后加一个内置就是加下面三行。
;
; 处理者用全名（exec.op_len 之类）引用：它们是 exec 的局部标签，而这里在数据段。
bi_name_len: dw 0x006C, 0x0065, 0x006E
bi_name_write: dw 0x0077, 0x0072, 0x0069, 0x0074, 0x0065
bi_name_readline: dw 0x0072, 0x0065, 0x0061, 0x0064, 0x006C, 0x0069, 0x006E, 0x0065
bi_name_border: dw 0x0062, 0x006F, 0x0072, 0x0064, 0x0065, 0x0072
bi_name_runpkg: dw 0x0072, 0x0075, 0x006E, 0x0070, 0x006B, 0x0067
bi_name_runpkg1: dw 0x0072, 0x0075, 0x006E, 0x0070, 0x006B, 0x0067, 0x0031
bi_name_runpkg2: dw 0x0072, 0x0075, 0x006E, 0x0070, 0x006B, 0x0067, 0x0032
bi_name_runpkg3: dw 0x0072, 0x0075, 0x006E, 0x0070, 0x006B, 0x0067, 0x0033
bi_name_runpkg4: dw 0x0072, 0x0075, 0x006E, 0x0070, 0x006B, 0x0067, 0x0034
bi_name_rect: dw 0x0072, 0x0065, 0x0063, 0x0074
bi_name_text: dw 0x0074, 0x0065, 0x0078, 0x0074
bi_name_clip: dw 0x0063, 0x006C, 0x0069, 0x0070
clip_on: dq 0
clip_x0: dq 0
clip_y0: dq 0
clip_x1: dq 0
clip_y1: dq 0
; 全域区：三十二格，帧外的名字。它与值栈上的槽是两回事 —— 槽随帧生死，这几格不随。
;
; 十六格的时候这一层够用：位置、尺寸、选择子、标志，用掉大半。而「两个窗口」要两组位置加
; 两组尺寸，十六格立刻见底。扩到三十二不是留余量 —— 是下一件事需要它。
global_kinds: times 32 dq 0
global_vals:  times 32 dq 0
; 登记表：四格，0 表示空位，非零就是一个登记过的源 id。
;
; 它是这一层的第一份清单，而它现在只回答一个问题：这个源 id 在不在里面。四格是容量下界，
; 不是一个设计数字 —— 这一格只登记一个源、送两个源。0 当空位是安全的：源 id 从 1 数起，
; 而 0 在事件行里会让判据读不出源。
src_registry: times 4 dq 0
; 绑定表：与登记表同下标，0 是空位，非零是那个源绑着的操作员 id。
;
; 分开放而不是合成一张，是因为它们回答两个不同的问题：登记回答「这个源存在吗」，绑定回答
; 「它属于谁」。合成一张表也跑得动，但那样「登记过」与「有主人」就再也分不开了，而这一层
; 的第三条判据问的正是这两件事之间的那个差。
src_bind: times 4 dq 0
; 工程表：四格。id 是工程的身份，state 是它的状态 —— 0 空位、1 失活、2 信任。
;
; 三态而不是两态，是因为「没见过」与「见过而失活」是两件事，而这一格的判据要问的正是
; 它们之间的差：一个从未见过的工程第一次撞门，报的是「不在清单里」；撞过一次之后，
; 它留下一条失活的记录，下一次报的是「失活」。两态的话，那两行会合成一行。
proj_id: times 4 dq 0
proj_state: times 4 dq 0
; 名字列：与签名表同下标。名字是一个编号 —— 这一层只需要比较两个名字是否相同，
; 不需要它的字节；真名进来的时候这一列会换成指向名字的指针，而查找仍然走签名。
;
; 这一列存在的唯一理由，是让「同名」这个事实可核对：判据要读到两个不同的签名带着
; 同一个名字，才证明那两行是伪装与被识破，而不是两个无关的工程。
proj_name: times 4 dq 0
bi_name_slurp: dw 0x0073, 0x006C, 0x0075, 0x0072, 0x0070
bi_name_save: dw 0x0073, 0x0061, 0x0076, 0x0065
bi_name_list: dw 0x006C, 0x0069, 0x0073, 0x0074
bi_name_remove: dw 0x0072, 0x0065, 0x006D, 0x006F, 0x0076, 0x0065
builtin_table:
    dq 3
    dq bi_name_len
    dq exec.op_len
    dq 5
    dq bi_name_write
    dq exec.op_write
    dq 8
    dq bi_name_readline
    dq exec.op_readline
    dq 6
    dq bi_name_border
    dq exec.op_border
    dq 6
    dq bi_name_runpkg
    dq exec.op_runpkg
    dq 7
    dq bi_name_runpkg1
    dq exec.op_runpkg1
    dq 7
    dq bi_name_runpkg2
    dq exec.op_runpkg2
    dq 7
    dq bi_name_runpkg3
    dq exec.op_runpkg3
    dq 7
    dq bi_name_runpkg4
    dq exec.op_runpkg4
    dq 4
    dq bi_name_rect
    dq exec.op_rect
    dq 4
    dq bi_name_text
    dq exec.op_text
    dq 4
    dq bi_name_clip
    dq exec.op_clip
    dq 5
    dq bi_name_slurp
    dq exec.op_slurp
    dq 4
    dq bi_name_save
    dq exec.op_save
    dq 4
    dq bi_name_list
    dq exec.op_list
    dq 6
    dq bi_name_remove
    dq exec.op_remove
    dq 0
    dq 0
    dq 0

; 两个单字符串，形状与种子里的一样：u16 长度在前，码元在后。「索引」交出来的
; 也是这个形状 —— 所以这两份既是参数，也是「索引」的对照物。
char7: dw 1, 0x0037
chara: dw 1, 0x0061
line_unknown_builtin: db "Yunooka: unknown builtin", 13, 10, 0
line_isdigit7: db "Yunooka: is_digit('7') -> ", 0
line_isdigita: db "Yunooka: is_digit('a') -> ", 0
line_true: db "true", 13, 10, 0
line_false: db "false", 13, 10, 0
line_isdigit_missing: db "Yunooka: is_digit missing", 13, 10, 0
line_exec_none: db "Yunooka: exec ran out at ", 0
line_miss_fn: db "Yunooka: no such function", 13, 10, 0
line_miss_frame: db "Yunooka: frames exhausted", 13, 10, 0
line_notail: db "Yunooka: notail pc ", 0
line_ata_same: db "Yunooka: ata same 512", 13, 10, 0
line_ata_differ: db "Yunooka: ata differ at ", 0
line_ata_fail: db "Yunooka: ata read failed", 13, 10, 0
line_fs_ok: db "Yunooka: fs ok v", 0
line_fs_root: db " root ", 0
line_fs_first: db " first ", 0
line_fs_empty: db "Yunooka: fs root empty", 13, 10, 0
line_fs_bad: db "Yunooka: fs bad magic", 13, 10, 0
line_fs_fail: db "Yunooka: fs read failed", 13, 10, 0
line_fs_preread: db "Yunooka: fs preread failed", 13, 10, 0
line_mbox_ok: db "Yunooka: mailbox ok", 13, 10, 0
line_mbox_bad: db "Yunooka: mailbox bad", 13, 10, 0
line_mbox_fail: db "Yunooka: no mailbox", 13, 10, 0
line_mbox_ready: db "Yunooka: mbox ready", 13, 10, 0
line_mbox_base: db "Yunooka: mbox base=", 0
line_mbox_new: db "Yunooka: mbox new=", 0
line_mbox_readfail: db "Yunooka: mbox read failed", 13, 10, 0
; 同级那四行：两趟各一行读数，加上两次握手。
line_same_ready: db "Yunooka: same ready", 13, 10, 0
line_same_again: db "Yunooka: same again", 13, 10, 0
line_same_a: db "Yunooka: same a ", 0
line_same_b: db "Yunooka: same b ", 0
line_same_g: db "Yunooka: same g ", 0
line_same_nopkg: db "Yunooka: same nopkg", 13, 10, 0
line_fs2_fail: db "Yunooka: beta preread failed", 13, 10, 0
line_idt_ok: db "Yunooka: idt ok", 13, 10, 0
line_exception: db "Yunooka: exception ", 0
line_exception_at: db " at ", 0
line_trap_before: db "Yunooka: trap test", 13, 10, 0
; 这一行永远打不出来。留着它是因为「处理器没有返回」这件事需要一个名字 —— 否则
; 判据只能靠「后面没有输出」这种否定式，而否定式分不清「没返回」与「还没跑到」。
line_trap_after: db "Yunooka: handler returned", 13, 10, 0

; IDT 的伪描述符，lidt 要的是「limit + base」，64 位下共 10 字节。
; limit 4095 = 256 项乘 16 字节再减一。
align 8
idt_desc:
    dw 4095
    dq 0x5000
line_serial_got: db "Yunooka: echo ", 0
line_serial_none: db "Yunooka: no input", 13, 10, 0
line_key: db "Yunooka: key ", 0
line_key_none: db "Yunooka: no key", 13, 10, 0
line_key_ready: db "Yunooka: key ready", 13, 10, 0
line_shell_ready: db "Yunooka: shell ready", 13, 10, 0
line_shell_timeout: db "Yunooka: no line", 13, 10, 0
line_repl_ready: db "Yunooka: repl ready", 13, 10, 0
line_repl_live_prompt: db "Yunooka: repl-live> ", 0
line_repl_live_unk: db "Yunooka: no such name", 13, 10, 0
line_repl_live_to: db "Yunooka: no line", 13, 10, 0
; 不带换行的 true / false：print_value 不打换行，由调用者收尾，所以不能借用带换行那份。
line_true_flat: db "true", 0
line_false_flat: db "false", 0
; 盘上那个程序包与它里面的入口。
fs_prog_name: dw 0x0070, 0x0072, 0x006F, 0x0067, 0x002E, 0x0068, 0x006D, 0x0074, 0x006E, 0
name_main: dw 0x006D, 0x0061, 0x0069, 0x006E
name_sum: dw 0x0073, 0x0075, 0x006D
name_win: dw 0x0077, 0x0069, 0x006E
name_textline: dw 0x0074, 0x0065, 0x0078, 0x0074, 0x006C, 0x0069, 0x006E, 0x0065
name_echo2text: dw 0x0065, 0x0063, 0x0068, 0x006F, 0x0032, 0x0074, 0x0065, 0x0078, 0x0074
name_titlewin: dw 0x0074, 0x0069, 0x0074, 0x006C, 0x0065, 0x0077, 0x0069, 0x006E
name_redraw: dw 0x0072, 0x0065, 0x0064, 0x0072, 0x0061, 0x0077
line_progredraw: db "Yunooka: progredraw ", 0
line_progredraw_bad: db "Yunooka: progredraw missing", 0
name_shiftwin: dw 0x0073, 0x0068, 0x0069, 0x0066, 0x0074, 0x0077, 0x0069, 0x006E
line_progshift: db "Yunooka: progshift ", 0
line_progshift_bad: db "Yunooka: progshift missing", 0
name_clipped: dw 0x0063, 0x006C, 0x0069, 0x0070, 0x0070, 0x0065, 0x0064
name_showfile: dw 0x0073, 0x0068, 0x006F, 0x0077, 0x0066, 0x0069, 0x006C, 0x0065
name_slotwrite: dw 0x0073, 0x006C, 0x006F, 0x0074, 0x0077, 0x0072, 0x0069, 0x0074, 0x0065
name_loopthree: dw 0x006C, 0x006F, 0x006F, 0x0070, 0x0074, 0x0068, 0x0072, 0x0065, 0x0065
name_globalset: dw 0x0067, 0x006C, 0x006F, 0x0062, 0x0061, 0x006C, 0x0073, 0x0065, 0x0074
name_globalget: dw 0x0067, 0x006C, 0x006F, 0x0062, 0x0061, 0x006C, 0x0067, 0x0065, 0x0074
name_resetpos: dw 0x0072, 0x0065, 0x0073, 0x0065, 0x0074, 0x0070, 0x006F, 0x0073
name_mark: dw 0x006D, 0x0061, 0x0072, 0x006B
name_right60: dw 0x0072, 0x0069, 0x0067, 0x0068, 0x0074, 0x0036, 0x0030
name_erase: dw 0x0065, 0x0072, 0x0061, 0x0073, 0x0065
line_progframe: db "Yunooka: progfrm ", 0
line_progframe_bad: db "Yunooka: progfrm missing", 0
name_retitle: dw 0x0072, 0x0065, 0x0074, 0x0069, 0x0074, 0x006C, 0x0065
line_progretitle: db "Yunooka: progretitle ", 0
line_progretitle_bad: db "Yunooka: progretitle missing", 0
name_bridge: dw 0x0062, 0x0072, 0x0069, 0x0064, 0x0067, 0x0065
line_progbridge: db "Yunooka: progbridge ", 0
line_progbridge_bad: db "Yunooka: progbridge missing", 0
name_bridge1: dw 0x0062, 0x0072, 0x0069, 0x0064, 0x0067, 0x0065, 0x0031
name_bump: dw 0x0062, 0x0075, 0x006D, 0x0070
line_progbump: db "Yunooka: progbump ", 0
line_progbump_bad: db "Yunooka: progbump missing", 0
name_bridge2: dw 0x0062, 0x0072, 0x0069, 0x0064, 0x0067, 0x0065, 0x0032
name_sum2: dw 0x0073, 0x0075, 0x006D, 0x0032
line_progsum: db "Yunooka: progsum ", 0
line_progsum_bad: db "Yunooka: progsum missing", 0
name_bridge3: dw 0x0062, 0x0072, 0x0069, 0x0064, 0x0067, 0x0065, 0x0033
name_sub2: dw 0x0073, 0x0075, 0x0062, 0x0032
line_progsub: db "Yunooka: progsub ", 0
line_progsub_bad: db "Yunooka: progsub missing", 0
name_bridge4: dw 0x0062, 0x0072, 0x0069, 0x0064, 0x0067, 0x0065, 0x0034
name_drawat: dw 0x0064, 0x0072, 0x0061, 0x0077, 0x0061, 0x0074
line_progdraw: db "Yunooka: progdraw ", 0
line_progdraw_bad: db "Yunooka: progdraw missing", 0
line_progsize: db "Yunooka: progsize ", 0
line_progsize_bad: db "Yunooka: progsize missing", 0
name_highslot: dw 0x0068, 0x0069, 0x0067, 0x0068, 0x0073, 0x006C, 0x006F, 0x0074
line_proghigh: db "Yunooka: proghigh ", 0
line_proghigh_bad: db "Yunooka: proghigh missing", 0
name_redraw2: dw 0x0072, 0x0065, 0x0064, 0x0072, 0x0061, 0x0077, 0x0032
line_progtwo: db "Yunooka: progtwo ", 0
line_progtwo_bad: db "Yunooka: progtwo missing", 0
name_keymove: dw 0x006B, 0x0065, 0x0079, 0x006D, 0x006F, 0x0076, 0x0065
line_progmove: db "Yunooka: progmove ", 0
line_progmove_bad: db "Yunooka: progmove missing", 0
line_move_ready: db "Yunooka: move ready", 13, 10, 0
line_move_again: db "Yunooka: move again", 13, 10, 0
line_event_ready: db "Yunooka: event ready", 13, 10, 0
line_event_head: db "Yunooka: event src=", 0
; 拒绝行：源 id 与理由各自一格。理由做成字段而不是散文，因为这一层后面还要区分
; 「未绑定」与「工程失活」—— 三种拒绝的修法各不相同，串口上分不开就等于没分。
line_input_head: db "Yunooka: input src=", 0
line_input_reason: db " rejected=", 0
line_input_unregistered: db "unregistered", 13, 10, 0
line_input_unbound: db "unbound", 13, 10, 0
line_unbound_ready: db "Yunooka: unbound ready", 13, 10, 0
; 工程那一层：一行一个工程的判决。四种结局各是一个词，而「失活」与「不在清单里」必须
; 是两个词 —— 修法不同，串口上分不开就等于没分。
line_proj_head: db "Yunooka: project ", 0
line_proj_what: db " ", 0
line_proj_untrusted: db "untrusted", 13, 10, 0
line_proj_inactive: db "inactive", 13, 10, 0
line_proj_trusted: db "trusted", 13, 10, 0
line_proj_accepted: db "accepted src=", 0
; 伪装那一行：签名、名字、判决。它走自己的行首，因为它是「一次对照」的结果 ——
; 两行成对读才有意义，而 project 那一行说的是单个工程的状态。
line_disguise_head: db "Yunooka: disguise sig=", 0
line_disguise_name: db " name=", 0
line_disguise_what: db " ", 0
; 注册那两行：成功与失败各一句，而失败那一句**不带「缺了哪一项」**。
; 这不是省字：两种不同的缺项必须给出同一行，否则一个试错的人可以逐项收敛，
; 而「不说明缺什么」正是这一条判据要测的东西。
line_register_ok: db "Yunooka: register ok", 13, 10, 0
line_register_denied: db "Yunooka: register denied", 13, 10, 0
; 不锁定那两行：它走自己的行首，因为它测的是「两次失败之后」这一条时间线，而不是
; 一份材料的结果。合成一套行首会让两条判据按位置切同一股串口流，而那最容易错位。
line_nolock_ok: db "Yunooka: nolock ok", 13, 10, 0
line_nolock_denied: db "Yunooka: nolock denied", 13, 10, 0
line_reject_ready: db "Yunooka: reject ready", 13, 10, 0
line_reject_again: db "Yunooka: reject again", 13, 10, 0
line_event_kind: db " kind=key payload=", 0
line_event_target: db " target=", 0
line_progdrag: db "Yunooka: progdrg ", 0
line_progdrag_bad: db "Yunooka: progdrg missing", 0
line_progglobal: db "Yunooka: progglobal ", 0
line_progglobal_bad: db "Yunooka: progglobal missing", 0
line_progloop: db "Yunooka: progloop ", 0
line_progloop_bad: db "Yunooka: progloop missing", 0
line_progset: db "Yunooka: progset ", 0
line_progset_bad: db "Yunooka: progset missing", 0
line_progfile: db "Yunooka: progfile ", 0
line_progfile_bad: db "Yunooka: progfile missing", 0
line_progclip: db "Yunooka: progclip ", 0
line_progclip_bad: db "Yunooka: progclip missing", 0
line_progtitle: db "Yunooka: progtitle ", 0
line_progtitle_bad: db "Yunooka: progtitle missing", 0
line_progecho: db "Yunooka: progecho ", 0
line_progecho_bad: db "Yunooka: progecho missing", 0
line_progtext: db "Yunooka: progtext ", 0
line_progtext_bad: db "Yunooka: progtext missing", 0
name_filesize: dw 0x0066, 0x0069, 0x006C, 0x0065, 0x0073, 0x0069, 0x007A, 0x0065
line_size: db "Yunooka: prog size -> ", 0
line_size_bad: db "Yunooka: prog size missing", 13, 10, 0
line_win_px: db "Yunooka: win px ", 0
line_win_bad: db "Yunooka: win missing", 13, 10, 0
line_prog_sum: db "Yunooka: prog sum -> ", 0
line_prog_sum_bad: db "Yunooka: prog sum missing", 13, 10, 0
line_prog: db "Yunooka: prog main -> ", 0
line_prog_missing: db "Yunooka: no prog.hmtn", 13, 10, 0
line_myon_done: db "Yunooka: event=myon write ok", 13, 10, 0
line_myon_px: db "Yunooka: myon px ", 0
line_myon_missing: db "Yunooka: no myon.hmtn", 13, 10, 0
line_myon_bad: db "Yunooka: myon bad magic", 13, 10, 0
line_myon_nofn: db "Yunooka: myon no echo", 13, 10, 0
line_myon2_ok: db "Yunooka: event=myon2 ok", 13, 10, 0
line_myon2_missing: db "Yunooka: no docs/myon.hmtn", 13, 10, 0
line_myon2_dbg: db "Yunooka: myon2 dbg ", 0
line_myon2_hex: db "Yunooka: myon2 hex ", 0
line_myon2_bad: db "Yunooka: myon2 bad magic", 13, 10, 0
line_myon2_nofn: db "Yunooka: myon2 no echo", 13, 10, 0
line_prog_bad: db "Yunooka: prog bad magic", 13, 10, 0
line_prog_nomain: db "Yunooka: prog has no main", 13, 10, 0

; 扫描码集 1 → ASCII。索引就是扫描码，值是字符，0 表示「这个键不产字」。
;
; 为什么是集 1 而不是集 2：实测说了算。VirtualBox 的 BIOS 日志写着 keyboard 用 scan set 2，
; 而 controlvm keyboardputscancode 送什么码 guest 就收到什么码（原样穿透）；可
; controlvm keyboardputstring 送的是集 1 —— 用集 2 的表去读它，回显会是 c3：0x21 被当成 c、
; 0x26 被当成 3。两条路只有一条能对上，于是选那个能一次送一整行的。
;
; 集 1 的放开码是「按下码或上 0x80」，所以 128 以上的码一律跳过 —— 这一版不需要知道
; 哪个键放开了。
;
; 只填用得上的那些：二十六个字母、0 到 9、空格、回车、退格。其余留 0 不是偷懒 ——
; 一张「部分认识」的表比一张猜出来的表诚实，遇到不认识的键就当没按过，而不是打出
; 一个形状对、意思错的字符。
align 8
keymap:
    db 0,0,"1","2","3","4","5","6", "7","8","9","0","-","=",0,0     ; 00-0F
    db "q","w","e","r","t","y","u","i", "o","p",0,0,13,0,"a","s" ; 10-1F
    db "d","f","g","h","j","k","l",0, 0,0,0,0,"z","x","c","v"    ; 20-2F
    db "b","n","m",0,0,0,0,0, 0," ",0,0,0,0,0,0                  ; 30-3F
    db 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0                          ; 40-4F
    db 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0                          ; 50-5F
    db 0,0,0,0,0,0,8,0, 0,0,0,0,0,0,0,0                          ; 60-6F
    db 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0                          ; 70-7F

; 键盘那一行的缓冲。64 字节够一条命令；超出的部分丢掉而不是截断成另一条命令 ——
; 一条被悄悄截断的命令会在后面以「unknown command」的样子出现，而那不是真正的原因。
align 8
line_buf: times 64 db 0
line_len: dq 0
; 同一个名字的 UTF-16 版本：键盘给的是 ASCII 字节，而种子里存的是码元。
line_buf16: times 128 db 0
; Shift 有没有按着。表里只有小写与不用 Shift 的字符，所以它只用来把 = 变成 +。
shift_state: db 0
; 当前在扫哪一个包。种子的地址是 0x70000，而盘上读进来的包住在预读区里 ——
; find_fn_by_name 靠这个变量就知道该从哪儿开始，不必写两份查找器。
pkg_base: dq 0x70000
line_fs_open: db "Yunooka: open ", 0
line_fs_arrow: db " -> ", 0
line_fs_nofile: db "Yunooka: not found", 13, 10, 0
line_fs_nodrive: db "Yunooka: unknown drive", 13, 10, 0

; 要打开的那条路径。以 0 码元结尾，这样算长度不必另存一个数 —— 而是把长度交给
; 路径自己写清楚。α : / h e l l o . t x t
fs_path: dw 0x03B1, 0x003A, 0x002F, 0x0068, 0x0065, 0x006C, 0x006C
         dw 0x006F, 0x002E, 0x0074, 0x0078, 0x0074, 0

; 两条段名与整条路径。段名是给 fs_lookup 用的（它不知道路径，只认一个名字），
; 整条路径留着给以后的切分器 —— 这一版先手动喂两段，因为两段就是全部。
fs_path2: dw 0x03B1, 0x003A, 0x002F, 0x0064, 0x006F, 0x0063, 0x0073, 0x002F
          dw 0x006E, 0x006F, 0x0074, 0x0065, 0x002E, 0x0074, 0x0078, 0x0074, 0
fs_seg1: dw 0x0064, 0x006F, 0x0063, 0x0073, 0
fs_seg2: dw 0x006E, 0x006F, 0x0074, 0x0065, 0x002E, 0x0074, 0x0078, 0x0074, 0
; 三层那一条：α:/docs/sub/deep.txt。fs_open_path 用的就是这个 —— 它按斜杠切段，
; 所以这一行与两层那一行走的是同一段代码。
fs_path3: dw 0x03B1, 0x003A, 0x002F, 0x0064, 0x006F, 0x0063, 0x0073, 0x002F
          dw 0x0073, 0x0075, 0x0062, 0x002F, 0x0064, 0x0065, 0x0065, 0x0070
          dw 0x002E, 0x0074, 0x0078, 0x0074, 0
; 第二块盘上的同一个名字：β:/hello.txt。盘符不同、盘不同、内容也不同，
; 而打开它的是同一段 fs_open_path。
fs_path4: dw 0x03B2, 0x003A, 0x002F, 0x0068, 0x0065, 0x006C, 0x006C, 0x006F
          dw 0x002E, 0x0074, 0x0078, 0x0074, 0
; 写的判据：造一个不存在的名字，写一段只有这里才有的字节，再按路径打开它。
fs_write_name: dw 0x006E, 0x0065, 0x0077, 0x002E, 0x0074, 0x0078, 0x0074, 0   ; "new.txt"
fs_write_path: dw 0x03B1, 0x003A, 0x002F, 0x006E, 0x0065, 0x0077, 0x002E
               dw 0x0074, 0x0078, 0x0074, 0                                  ; α:/new.txt
fs_write_data: db "Yunooka wrote this", 10
fs_write_len: equ $ - fs_write_data
line_fs_write: db "Yunooka: wrote -> ", 0
line_fs_write_fail: db "Yunooka: write failed", 13, 10, 0
line_fs_write_lost: db "Yunooka: wrote but lost", 13, 10, 0
; 系统保护那一块。名字是 UTF-16（目录里的名字），而两个拒绝的理由要分开报。
fs_guard_name: dw 0x0067, 0x0075, 0x0061, 0x0072, 0x0064, 0x002E, 0x0074, 0x0078, 0x0074, 0
fs_guard2_name: dw 0x0067, 0x0075, 0x0061, 0x0072, 0x0064, 0x0032, 0x002E, 0x0074, 0x0078, 0x0074, 0
fs_guard_path: dw 0x03B1, 0x003A, 0x002F, 0x0067, 0x0075, 0x0061, 0x0072, 0x0064, 0x002E, 0x0074, 0x0078, 0x0074, 0
fs_guard_data: db "Yunooka guard test", 10
fs_guard_len: equ $ - fs_guard_data
line_write_ro: db "Yunooka: write refused (readonly)", 13, 10, 0
line_write_exists: db "Yunooka: write refused (exists)", 13, 10, 0
line_write_over: db "Yunooka: write over", 13, 10, 0
line_guard_write: db "Yunooka: guard write ok", 13, 10, 0
line_guard_ro: db "Yunooka: guard readonly set", 13, 10, 0
line_guard_refused: db "Yunooka: guard rewrite refused", 13, 10, 0
line_guard_other: db "Yunooka: guard other name ok", 13, 10, 0
line_guard_leaked: db "Yunooka: guard rewrite LEAKED", 13, 10, 0
line_guard_fail: db "Yunooka: guard setup failed", 13, 10, 0
; 核心清单那一层。路径是 UTF-16（盘上的名字），而清单是二进制。
fs_core_path: dw 0x03B1, 0x003A, 0x002F, 0x0063, 0x006F, 0x0072, 0x0065, 0x002E, 0x0062, 0x0069, 0x006E, 0
core_ptr: dq 0
core_left: dq 0
core_namelen: dq 0
core_hash: dq 0
core_n: dq 0
core_bad: dq 0
core_path: times 128 dw 0
line_core_ok: db "Yunooka: guard core ", 0
line_core_bad: db "Yunooka: guard core bad ", 0
line_core_missing: db "Yunooka: guard core missing ", 0
line_core_nocore: db "Yunooka: guard core no manifest", 13, 10, 0
; 补完界面那一行。形状是「event= / 键值对 / 顺序固定」—— design/GUARD.txt 第六节
; 那条「新写的事件行」的第一个样本。旧的散文不动（判据已经与它们绑在一起）。
line_repair_entry: db "Yunooka: event=guard.entry bad=", 0
line_repair_where: db " repair=mailbox version=1", 13, 10, 0
; 修补那一层的事件行，三行都是 event= 开头、键值对、顺序固定（design/GUARD.txt 第六节）。
;
;   event=guard.nopatch source=none                    这一趟没带补丁
;   event=guard.repair refused name=X                  补丁里有 X，但内容与清单不符 —— 拒绝并点名
;   event=guard.repair fixed=N verified=M refused=K    收尾的三个数
;
; 三个数分开报，因为它们指向三种不同的处境：写了但没验上、验上了但没写、以及补丁里
; 有那一项却被校验挡下来。只报一个的话，「写了」与「写对了」在串口上长得一样，
; 而这正是 fs_write_file 那一层从来分不清的那件事。
line_repair_fixed: db "Yunooka: event=guard.repair fixed=", 0
line_repair_verified: db " verified=", 0
line_repair_refused_n: db " refused=", 0
line_repair_refused: db "Yunooka: event=guard.repair refused name=", 0
line_repair_nopatch: db "Yunooka: event=guard.nopatch source=none", 13, 10, 0
; 补丁包的魔数。它与 tools/build.mjs 里那句 "YUNOPAT\0" 是同一份约定 —— 两处
; 各写一遍是可以接受的，因为它们分别处在「造」与「认」两侧；build 会核对这一行。
pat_magic: db "YUNOPAT", 0
pat_data: dq 0
pat_len: dq 0
rep_fixed: dq 0
rep_verified: dq 0
rep_refused: dq 0

; ---- OnlySign 的第二环：SHA-256 清单（design/SIGN.txt）----
;
; 三条读数分开：ok（逐项一致）、bad（点出名字）、nosign（盘上没有 sign.bin）。
; 第三条不是「验过了」，是「没东西可验」—— 那两件事在串口上必须不一样。
sign_magic: db "YUNOSIG", 0
fs_sign_path: dw 0x03B1, 0x003A, 0x002F, 0x0073, 0x0069, 0x0067, 0x006E, 0x002E, 0x0062, 0x0069, 0x006E, 0
fs_auth_path: dw 0x03B1, 0x003A, 0x002F, 0x0061, 0x0075, 0x0074, 0x0068, 0x002E, 0x0062, 0x0069, 0x006E, 0

; 第三环的公钥。它内嵌在这里而不是放盘上 —— 放上去的话，改盘的人可以把公钥与签名
; 一起换掉，这一环就退化成第二环。
;
; 这 32 个字节现在从 boot/pubkey.inc 进来：那个文件由 build 从种子派生并核对，所以
; 这一段代码不再含着一个可以随手改的常量。换密钥的方式是换 keys/onlysign.seed（或者
; 删掉它退回测试种子），然后跑一次 build —— 公钥不对时构建会停下来。
;
; 而验签那一侧的判据一个字都没变：公钥错了，auth.bin 就验不过。
;
; 标签必须在 include 之前：这个文件里那四行 db 是内容，而 onlysign_pubkey 是它的名字。
; 反过来写的话，32 个字节落在标签前面，而标签指向了空处 —— 症状是验签在第一步就失败
; （S 的大小检查），看起来像签名坏了。
onlysign_pubkey:
%include "boot/pubkey.inc"
sign_path: times 128 dw 0
sign_ptr: dq 0
sign_left: dq 0
sign_namelen: dq 0
sign_hash_ptr: dq 0
sign_n: dq 0
sign_bad: dq 0
sign_dbg: dq 0
sign_filelen: dq 0
line_sign_ok: db "Yunooka: event=onlysign ok items=", 0
line_sign_sha: db "Yunooka: event=onlysign sha256=", 0
line_sign_item: db "Yunooka: item=", 0
line_sign_len: db " len=", 0
line_sign_sha8: db " sha=", 0
line_sign_bad: db "Yunooka: event=onlysign bad name=", 0
line_sign_bad_n: db "Yunooka: event=onlysign badcount=", 0
line_sign_nosign: db "Yunooka: event=onlysign nosign", 13, 10, 0
line_sign_nomagic: db "Yunooka: event=onlysign nomagic", 13, 10, 0
line_onlysign3_ok: db "Yunooka: event=onlysign3 ok", 13, 10, 0
line_onlysign3_bad: db "Yunooka: event=onlysign3 bad where=", 0
line_onlysign3_noauth: db "Yunooka: event=onlysign3 noauth", 13, 10, 0
line_onlysign3_badsig: db "Yunooka: event=onlysign3 badsig", 13, 10, 0
line_onlysign3_nolist: db "Yunooka: event=onlysign3 nolist", 13, 10, 0
line_fp_val: db "Yunooka: fp val=", 0
line_fp_ok: db "Yunooka: event=fp ok vectors=6", 13, 10, 0
line_fp2_add: db "Yunooka: fp2 op=add val=", 0
line_fp2_sub: db "Yunooka: fp2 op=sub val=", 0
line_fp2_ok: db "Yunooka: event=fp2 ok vectors=6", 13, 10, 0
line_pt_addbb: db "Yunooka: pt add-bb ", 0
line_pt_dblb: db "Yunooka: pt dbl-b ", 0
line_pt_dbl2: db "Yunooka: pt dbl2-b ", 0
line_pt_add4: db "Yunooka: pt add-4b ", 0
line_pt_addid: db "Yunooka: pt add-ident ", 0
line_pt_ok: db "Yunooka: event=pt ok vectors=5", 13, 10, 0
line_pt_mul1: db "Yunooka: ptm mul-1 ", 0
line_pt_mul2: db "Yunooka: ptm mul-2 ", 0
line_pt_mul3: db "Yunooka: ptm mul-3 ", 0
line_pt_add3b: db "Yunooka: ptm add-3b ", 0
line_pte_b: db "Yunooka: pte b ", 0
line_pte_2b: db "Yunooka: pte 2b ", 0
line_pte_3b: db "Yunooka: pte 3b ", 0
line_pte_4b: db "Yunooka: pte 4b ", 0
line_pte_5b: db "Yunooka: pte 5b ", 0
line_ptm_mul5: db "Yunooka: ptm mul-5 ", 0
line_ptd_before: db "Yunooka: ptd before ", 0
line_ptd_after: db "Yunooka: ptd after ", 0
line_ptd_bad: db "Yunooka: ptd bad ", 0
line_sig_res: db "Yunooka: sig ", 0
line_sig_ok: db " ok=", 0
line_sig_bad: db " bad=", 0
line_sig_where: db " where=", 0
line_modl: db "Yunooka: modl ", 0
line_colon: db ":", 0
line_sig_done: db "Yunooka: event=sig ok vectors=3", 13, 10, 0
line_pt_in_a: db "Yunooka: pti in-a ", 0
line_pt_in_b: db "Yunooka: pti in-b ", 0
; SHA-256 的工作区。a..h 就放在 sha_h 里原地更新，W[0..63] 放 sha_w。
;
; 为什么全部用内存而不是寄存器：寄存器分配的错会表现为「哈希不对」，而那个症状与
; 「算法写错」分不开。内存版只有一种错法，而慢三个文件加起来不到一百字节，不是问题。
sha_ptr: dq 0
sha_len: dq 0
sha_h: times 8 dd 0
; 一个块开始时的 sha_h。feed-forward 加回的是「上一步的状态」，而轮函数会把 sha_h
; 覆盖成这一块的输出 —— 所以每个块开头各存一次，加的是它，不是固定的初值。
sha_h0: times 8 dd 0
sha_w: times 64 dd 0
sha_pad: times 128 db 0
sha_out: times 32 db 0
sha_k:
    dd 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5
    dd 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
    dd 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3
    dd 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
    dd 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc
    dd 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
    dd 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7
    dd 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
    dd 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13
    dd 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
    dd 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3
    dd 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
    dd 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5
    dd 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
    dd 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208
    dd 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2

; SHA-512 的工作区。与 SHA-256 那一组同形，只是字宽与项数不同：
; a..h 是八个 64 位字，W 有 80 项（八十轮要用 W[79]），块是 128 字节。
;
; 补齐区 256 字节而不是 128：消息余下 112 到 127 字节时要补两块，而两块都得在
; 这一段里 —— 借用 sha_pad 会与正在进行的 SHA-256 打架，那种错法是「偶发」，最贵。
sha512_ptr: dq 0
sha512_len: dq 0
sha512_h: times 8 dq 0
; 一个块开始时的状态。feed-forward 加回的是它，而轮函数会把 sha512_h 覆盖成这一块的
; 输出 —— 所以每个块开头各存一次。
sha512_h0: times 8 dq 0
sha512_w: times 80 dq 0
sha512_pad: times 256 db 0
sha512_out: times 64 db 0
; 判据用的字节串：第 i 字节就是 i & 0xFF。内容不取自盘上任何文件，理由与那七个样本
; 头一样 —— 判据要验的是这个函数，而不是「盘读得对不对」。
sha512_bt: times 256 db 0
; 六个长度，各自对应补齐的一种处境：0（空消息，唯一一个一块都不用满的）、1（末尾
; 只有一字节）、111（长度字段仍能塞进同一块）、112（正好跨到第二块）、128（正好一整
; 块）、239（两块之后还剩大半块）。最后那个 -1 是结束标记，不是长度 —— 写成 -1 而不
; 是 0xFFFFFFFF，因为 cmp 的立即数会被符号扩展，而 0xFFFFFFFF 展开之后是全 1。
sha512_lens: dq 0, 1, 111, 112, 128, 239, -1

; ---- 域算术 mod 2^255-19 的常数与工作区 --------------------------------
;
; p = 2^255 - 19，小端八个 32 位肢体。最低那个是 0xFFFFFFED 而不是 0xFFFFFFFF，
; 是因为减掉了那个 19；最高那个只有 0x7FFFFFFF，是因为第 255 位是 0。
fp_p:
    dd 0xFFFFFFED, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
fp_a: times 8 dd 0
fp_b: times 8 dd 0
fp_prod: times 16 dd 0
fp_out: times 8 dd 0
fp_vec_i: dq 0

; 判据向量：每组 64 字节，前 32 是 a、后 32 是 b，都是小端。
;
; 为什么是这六组：乘一与乘小整数最平静，能过的实现很多，看不出约简；p-1 的平方是
; 唯一一个「输入最大而结果最小」的处境，它的积是 510 位，折两轮全用到；p-1 乘二
; 走的是一条不进位的减法；两个 2^255-1 相乘那一组两个输入都大于 p，专门压「输入
; 不必先约简」这条 —— 域元素的表示允许暂时越界，约简是乘法之后的事。最后一组是
; 基点的 x 乘 y，这是曲线代码真正会走到的数，用它把向量和后面的活儿连上。
fp_vecs:
    ; 一乘一
    dd 0x00000001, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000001, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    ; 二乘三
    dd 0x00000002, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000003, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    ; (p-1) 的平方
    dd 0xFFFFFFEC, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
    dd 0xFFFFFFEC, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
    ; (p-1) 乘二
    dd 0xFFFFFFEC, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
    dd 0x00000002, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    ; (2^255-1) 的平方：两个输入都越过 p
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
    ; 基点的 x 乘 y
    dd 0x8F25D51A, 0xC9562D60, 0x9525A7B2, 0x692CC760
    dd 0xFDD6DC5C, 0xC0A4E231, 0xCD6E53FE, 0x216936D3
    dd 0x66666658, 0x66666666, 0x66666666, 0x66666666
    dd 0x66666666, 0x66666666, 0x66666666, 0x66666666

; 域加减的判据向量：每组 64 字节，前 32 是 a、后 32 是 b，都是小端。前三组走加法，
; 后三组走减法 —— 顺序本身就是信息，所以 run.mjs 那边按同一个顺序重算。
fp2_i: dq 0
fp2_vecs:
    ; 二加三
    dd 0x00000002, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000003, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    ; (p-1) 加二：越过 p，条件是必须减一次
    dd 0xFFFFFFEC, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
    dd 0x00000002, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    ; (p-1) 加自己：离八格装不下只差 38
    dd 0xFFFFFFEC, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
    dd 0xFFFFFFEC, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
    ; 二减三：借位路径
    dd 0x00000002, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000003, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    ; (p-1) 减自己：结果是零
    dd 0xFFFFFFEC, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
    dd 0xFFFFFFEC, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
    ; 零减一：被减数整个是零，每一位都要往下借
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000001, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000

; ---- 点运算的常数与工作区 ----------------------------------------------
;
; 一个点是四格域元素（X, Y, Z, T），每格八格肢体，所以一个点占三十二格 = 128 字节。
; pt_a+32 这样的偏移因此是「下一格坐标」，不是「下一个字节」。
;
; 2d 是点加公式里那个常数。它不是抄来的：d = -121665/121666 mod p，乘二之后落在
; 下面这八个肢体上。抄错了的症状是「点加算出一个不在曲线上的点」，而那要到很久以后
; 才看得出来。
fp_d2:
    dd 0x26B2F159, 0xEBD69B94, 0x8283B156, 0x00E0149A
    dd 0xEEF3D130, 0x198E80F2, 0x56DFFCE7, 0x2406D9DC
fp_zero: times 8 dd 0

; 基点 B：x 与 y 是 RFC 8032 给的那一对，Z 取一，T = x*y。
pt_base:
    dd 0x8F25D51A, 0xC9562D60, 0x9525A7B2, 0x692CC760
    dd 0xFDD6DC5C, 0xC0A4E231, 0xCD6E53FE, 0x216936D3
    dd 0x66666658, 0x66666666, 0x66666666, 0x66666666
    dd 0x66666666, 0x66666666, 0x66666666, 0x66666666
    dd 0x00000001, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0xA5B7DDA3, 0x6DDE8AB3, 0x775152F5, 0x20F09F80
    dd 0x64ABE37D, 0x66EA4E8E, 0xD78B7665, 0x67875F0F
; 单位元 O = (0, 1, 1, 0)。
pt_ident:
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000001, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000001, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000

pt_a: times 32 dd 0
pt_b: times 32 dd 0
pt_o: times 32 dd 0
pt_o2: times 32 dd 0
pt_o3: times 32 dd 0
; 点加与点倍各自的临时格。两条链不共用，因为它们各自可以被单独测。
pt_t0: times 8 dd 0
pt_t1: times 8 dd 0
pt_t2: times 8 dd 0
pt_t3: times 8 dd 0
pt_t4: times 8 dd 0
pt_t5: times 8 dd 0
pt_t6: times 8 dd 0
pt_t7: times 8 dd 0
pt_t8: times 8 dd 0
pt_t9: times 8 dd 0

; 标量乘的工作区。acc 与 bse 各是一个点，scalar 是一个 256 位的标量（八格）。
; 三个常量是判据用的 1、2、3 —— 二进制的 1、10、11 正好把「加号进不进」与「加倍
; 跑不跑」两种情形都走到。
pt_acc: times 32 dd 0
pt_bse: times 32 dd 0
pt_scalar: times 8 dd 0
pt_k1: dd 0x00000001, 0x00000000, 0x00000000, 0x00000000
      dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
pt_k2: dd 0x00000002, 0x00000000, 0x00000000, 0x00000000
      dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
pt_k3: dd 0x00000003, 0x00000000, 0x00000000, 0x00000000
      dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
; 5 是第一个 x 为奇数的倍数（1 到 4 的 x 全是偶数）。符号位那一条判据靠它才走到。
pt_k5: dd 0x00000005, 0x00000000, 0x00000000, 0x00000000
      dd 0x00000000, 0x00000000, 0x00000000, 0x00000000

; ---- 模逆与编码的工作区 ------------------------------------------------
;
; fp_im1 是 p-2，模逆的指数：p 是素数，所以 a^(p-2) 就是 a 的逆。最低那个是 0xFFFFFFEB，
; 因为 p 的最低一位是 0xED 而减二要再退两格。
fp_im1:
    dd 0xFFFFFFEB, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
fp_one:
    dd 0x00000001, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
fp_inv_a: times 8 dd 0
fp_inv_r: times 8 dd 0
fp_inv_t: times 8 dd 0
fp_inv_i: dq 0
pt_src: dq 0
pt_dst: dq 0
pt_enc: times 32 db 0

; ---- 解码的常数与工作区 ------------------------------------------------
;
; d 是曲线常数 -121665/121666；sqrt(-1) 是 2^((p-1)/4)，它的自检在 tools 那边跑过
; （平方加一在模 p 下是零）；(p+3)/8 是开方用的指数 —— p ≡ 5 (mod 8)，所以 a^((p+3)/8)
; 给出 a 的一个平方根，而它是哪一个要看运气，所以解码那一步必须平方回去验。
fp_exp_ptr: dq 0
fp_d:
    dd 0x135978A3, 0x75EB4DCA, 0x4141D8AB, 0x00700A4D
    dd 0x7779E898, 0x8CC74079, 0x2B6FFE73, 0x52036CEE
fp_sqrtm1:
    dd 0x4A0EA0B0, 0xC4EE1B27, 0xAD2FE478, 0x2F431806
    dd 0x3DFBD7A7, 0x2B4D0099, 0x4FC1DF0B, 0x2B832480
fp_sqexp:
    dd 0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
    dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x0FFFFFFF

pt_bytes: times 32 db 0
pt_y: times 8 dd 0
pt_y2: times 8 dd 0
pt_u: times 8 dd 0
pt_v: times 8 dd 0
pt_x: times 8 dd 0
pt_x2: times 8 dd 0
pt_sign: dq 0
ptd_i: dq 0
; 往返判据用的四个倍数。3 与 5 进来的理由不同：3 是位模式 11（加倍与加号交替），
; 5 是第一个 x 为奇数的倍数 —— 符号位那一半只有它能走到。
pt_dec_ks:
    dd 0x00000001, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000002, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000003, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000005, 0x00000000, 0x00000000, 0x00000000
    dd 0x00000000, 0x00000000, 0x00000000, 0x00000000
; 坏输入：y = 2。它落不到曲线上（tools 那边用欧拉判据查过：2 不是那条曲线上的 y），
; 所以解码必须拒绝。少了这一组，一个「任何输入都接受」的实现会看起来一模一样 ——
; 它在四个正确的输入上全对。
pt_bad: db 0x02
        times 31 db 0

; ---- 验签的常数、工作区与 RFC 8032 的三组向量 --------------------------
;
; L 是基点的阶：2^252 + 27742317777372353535851937790883648493，253 位。第九格是
; 零，留着让减法链有统一的格数 —— 少一格，那条链就得为「够不够借」多一个分支。
k_l:
    dd 0x5CF5D3ED, 0x5812631A, 0xA2F79CD6, 0x14DEF9DE
    dd 0x00000000, 0x00000000, 0x00000000, 0x10000000
    dd 0x00000000
k_n: times 16 dd 0
k_rem: times 9 dd 0
k_bit: dq 0
sig_cat: times 512 db 0
sig_pk: times 32 db 0
sig_sig: times 64 db 0
sig_msg: times 512 db 0
sig_msglen: dq 0
sig_res: dq 0
sig_res2: dq 0
; 走到第几步。失败时它就是最后一个成功的那一步 —— 比一串「不对」有用得多。
sig_where: dq 0
sig_w1: dq 0
sig_w2: dq 0
vt_i: dq 0
pt_A: times 32 dd 0
pt_R: times 32 dd 0
pt_SB: times 32 dd 0
pt_c1: times 8 dd 0
pt_c2: times 8 dd 0

; RFC 8032 第 7.1 节的三组向量。消息长度是 0、1、2 —— 覆盖 SHA-512 那条链的短输入，
; 而长消息的多块路径已经由 SHA-512 自己的六行判据压过（四个在两块以上）。
vec1_pk:
    db 0xD7, 0x5A, 0x98, 0x01, 0x82, 0xB1, 0x0A, 0xB7
    db 0xD5, 0x4B, 0xFE, 0xD3, 0xC9, 0x64, 0x07, 0x3A
    db 0x0E, 0xE1, 0x72, 0xF3, 0xDA, 0xA6, 0x23, 0x25
    db 0xAF, 0x02, 0x1A, 0x68, 0xF7, 0x07, 0x51, 0x1A
vec1_msg: db 0
vec1_sig:
    db 0xE5, 0x56, 0x43, 0x00, 0xC3, 0x60, 0xAC, 0x72
    db 0x90, 0x86, 0xE2, 0xCC, 0x80, 0x6E, 0x82, 0x8A
    db 0x84, 0x87, 0x7F, 0x1E, 0xB8, 0xE5, 0xD9, 0x74
    db 0xD8, 0x73, 0xE0, 0x65, 0x22, 0x49, 0x01, 0x55
    db 0x5F, 0xB8, 0x82, 0x15, 0x90, 0xA3, 0x3B, 0xAC
    db 0xC6, 0x1E, 0x39, 0x70, 0x1C, 0xF9, 0xB4, 0x6B
    db 0xD2, 0x5B, 0xF5, 0xF0, 0x59, 0x5B, 0xBE, 0x24
    db 0x65, 0x51, 0x41, 0x43, 0x8E, 0x7A, 0x10, 0x0B
vec2_pk:
    db 0x3D, 0x40, 0x17, 0xC3, 0xE8, 0x43, 0x89, 0x5A
    db 0x92, 0xB7, 0x0A, 0xA7, 0x4D, 0x1B, 0x7E, 0xBC
    db 0x9C, 0x98, 0x2C, 0xCF, 0x2E, 0xC4, 0x96, 0x8C
    db 0xC0, 0xCD, 0x55, 0xF1, 0x2A, 0xF4, 0x66, 0x0C
vec2_msg: db 0x72
vec2_sig:
    db 0x92, 0xA0, 0x09, 0xA9, 0xF0, 0xD4, 0xCA, 0xB8
    db 0x72, 0x0E, 0x82, 0x0B, 0x5F, 0x64, 0x25, 0x40
    db 0xA2, 0xB2, 0x7B, 0x54, 0x16, 0x50, 0x3F, 0x8F
    db 0xB3, 0x76, 0x22, 0x23, 0xEB, 0xDB, 0x69, 0xDA
    db 0x08, 0x5A, 0xC1, 0xE4, 0x3E, 0x15, 0x99, 0x6E
    db 0x45, 0x8F, 0x36, 0x13, 0xD0, 0xF1, 0x1D, 0x8C
    db 0x38, 0x7B, 0x2E, 0xAE, 0xB4, 0x30, 0x2A, 0xEE
    db 0xB0, 0x0D, 0x29, 0x16, 0x12, 0xBB, 0x0C, 0x00
vec3_pk:
    db 0xFC, 0x51, 0xCD, 0x8E, 0x62, 0x18, 0xA1, 0xA3
    db 0x8D, 0xA4, 0x7E, 0xD0, 0x02, 0x30, 0xF0, 0x58
    db 0x08, 0x16, 0xED, 0x13, 0xBA, 0x33, 0x03, 0xAC
    db 0x5D, 0xEB, 0x91, 0x15, 0x48, 0x90, 0x80, 0x25
vec3_msg: db 0xAF, 0x82
vec3_sig:
    db 0x62, 0x91, 0xD6, 0x57, 0xDE, 0xEC, 0x24, 0x02
    db 0x48, 0x27, 0xE6, 0x9C, 0x3A, 0xBE, 0x01, 0xA3
    db 0x0C, 0xE5, 0x48, 0xA2, 0x84, 0x74, 0x3A, 0x44
    db 0x5E, 0x36, 0x80, 0xD7, 0xDB, 0x5A, 0xC3, 0xAC
    db 0x18, 0xFF, 0x9B, 0x53, 0x8D, 0x16, 0xF2, 0x90
    db 0xAE, 0x67, 0xF7, 0x60, 0x98, 0x4D, 0xC6, 0x59
    db 0x4A, 0x7C, 0x15, 0xE9, 0x71, 0x6E, 0xD2, 0x8D
    db 0xC0, 0x27, 0xBE, 0xCE, 0xEA, 0x1E, 0xC4, 0x0A

vt_pks: dq vec1_pk, vec2_pk, vec3_pk
vt_msgs: dq vec1_msg, vec2_msg, vec3_msg
vt_sigs: dq vec1_sig, vec2_sig, vec3_sig
vt_lens: dq 0, 1, 2

; SHA-512 的 80 个常量：K[i] = floor(frac(cbrt(p_i)) * 2^64)，p_i 是第 i 个质数。
;
; 这八十个数是算出来的，不是抄来的 —— 工具在 tools/genconst.mjs，它用 BigInt 求整数
; 立方根，并把前四个与最后一个与已知值逐个对过。抄表抄错一个的症状是「哈希不对」，
; 与轮函数写错完全分不开，而那要花一整轮才能定位。
sha512_k:
    dq 0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc
    dq 0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118
    dq 0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2
    dq 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694
    dq 0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65
    dq 0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5
    dq 0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4
    dq 0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70
    dq 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df
    dq 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b
    dq 0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30
    dq 0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8
    dq 0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8
    dq 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3
    dq 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec
    dq 0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b
    dq 0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178
    dq 0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b
    dq 0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c
    dq 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817

line_sha512: db "Yunooka: event=sha512 len=", 0
line_sha512_hex: db " hex=", 0
; 家庭组第一步的那几样。
fs_share_path: dw 0x03B1, 0x003A, 0x002F, 0x0064, 0x006F, 0x0063, 0x0073, 0  ; α:/docs
; 第二块盘上的一个文件与它的盘符 —— 共享与边界见面那一条用的。
fs_share_beta: dw 0x03B2, 0x003A, 0x002F, 0x0068, 0x0065, 0x006C, 0x006C, 0x006F
               dw 0x002E, 0x0074, 0x0078, 0x0074, 0                        ; β:/hello.txt
fs_beta_drive: dw 0x03B2, 0
fs_alpha_drive: dw 0x03B1, 0     ; 只当盘符用：不指任何路径，只指「哪一块盘」
; α:/docs。与 fs_share_path 同一个名字，但那一处是「要标记共享的路径」，
; 这一处是「要 stat 的目录」—— 两件事，所以两个符号，谁改谁的不牵连对方。
fs_docs_path: dw 0x03B1, 0x003A, 0x002F, 0x0064, 0x006F, 0x0063, 0x0073, 0
; 第二块盘上那个没被共享的文件。
fs_secret_path: dw 0x03B2, 0x003A, 0x002F, 0x0073, 0x0065, 0x0063, 0x0072, 0x0065
                dw 0x0074, 0x002E, 0x0074, 0x0078, 0x0074, 0       ; β:/secret.txt
line_gate_blocked: db "Yunooka: read blocked by boundary", 13, 10, 0
line_gate_shared: db "Yunooka: shared -> ", 0
line_gate_secret: db "Yunooka: secret blocked", 13, 10, 0
line_gate_leak: db "Yunooka: boundary leaked", 13, 10, 0
line_shares: db "Yunooka: shares ", 0
line_share_dir: db " dir", 0
line_share_file: db " file", 0
line_share_first: db "Yunooka: share once", 13, 10, 0
line_share_again: db "Yunooka: share twice", 13, 10, 0
line_share_failed: db "Yunooka: share failed", 13, 10, 0
line_pci: db "Yunooka: pci dev ", 0
; AHCI 那一条：找到控制器只证明「那条路在」，ABAR 的地址才说明后面能不能走。
ahci_abar: dq 0
ahci_cap: dq 0
ahci_pi: dq 0
ahci_ssts: dq 0
ahci_ghc: dq 0
ahci_ghc_before: dq 0
; IDENTIFY 那一条的四个缓冲区与三个读数
ahci_cmdlist: dq 0
ahci_fis: dq 0
ahci_cmdtbl: dq 0
ahci_idbuf: dq 0
ahci_port: dq 0
ahci_sig: dq 0
ahci_tfd: dq 0
ahci_model: times 48 db 0
ahci_pxcmd: dq 0
ahci_pxis: dq 0
line_ahci_sig: db "Yunooka: ahci sig ", 0
line_ahci_model: db "Yunooka: ahci model ", 0
line_ahci_timeout: db "Yunooka: ahci timeout", 13, 10, 0
line_ahci_stuck: db "Yunooka: ahci stuck ", 0
line_ahci_pcicmd: db "Yunooka: ahci pcicmd ", 0
line_ahci_pi2: db "Yunooka: ahci pi2 ", 0
line_ahci_regs: db "Yunooka: ahci regs ", 0
line_ahci_bar: db "Yunooka: ahci bar ", 0
line_ahci_bohc: db "Yunooka: ahci bohc ", 0
line_ahci_ro: db "Yunooka: ahci ro ", 0
line_ahci_ctl: db "Yunooka: ahci ctl ", 0
line_ahci_ports: db "Yunooka: ahci ports ", 0
; NVMe 那一条
nvme_bar: dq 0
nvme_vs: dq 0
nvme_cap: dq 0
line_nvme_found: db "Yunooka: nvme dev ", 0
line_nvme_regs: db "Yunooka: nvme regs ", 0
line_nvme_none: db "Yunooka: nvme none", 13, 10, 0
nvme_asq: dq 0
nvme_acq: dq 0
nvme_log: dq 0
nvme_status: dq 0
nvme_cw: dq 0
nvme_temp: dq 0
nvme_spare: dq 0
nvme_used: dq 0
nvme_media: dq 0
line_nvme_noen: db "Yunooka: nvme no enable", 13, 10, 0
line_nvme_timeout: db "Yunooka: nvme cmd timeout", 13, 10, 0
line_nvme_smart: db "Yunooka: nvme smart ", 0
line_nvme_smtimeout: db "Yunooka: nvme smart -> no answer", 13, 10, 0
line_nvme_temp: db "Yunooka: nvme temp ", 0
line_nvme_smstat: db "Yunooka: nvme smstat ", 0
line_dh: db "Yunooka: event=diskhealth ", 0
line_dh_na: db "n/a", 0
line_nvme_model: db "Yunooka: nvme model ", 0
line_nvme_serial: db "Yunooka: nvme serial ", 0
nvme_model: times 48 db 0
nvme_serial: times 24 db 0
nvme_ns: dq 0
nvme_nsze: dq 0
nvme_lbads: dq 0
line_nvme_ns: db "Yunooka: nvme ns ", 0
line_nvme_nstimeout: db "Yunooka: nvme ns timeout", 13, 10, 0
line_nvme_diag: db "Yunooka: nvme diag ", 0
line_nvme_stuck: db "Yunooka: nvme stuck ", 0
line_nvme_pcicmd: db "Yunooka: nvme pcicmd ", 0
line_nvme_map: db "Yunooka: nvme map ", 0
nvme_pcicmd_before: dq 0
nvme_pcicmd: dq 0
ahci_cap_after: dq 0
pci_devbase: dq 0
ahci_bohc: dq 0
ahci_bohc2: dq 0
pci_cmd_before: dq 0
pci_cmd: dq 0
pd_pool: dq 0x4000
line_ahci_found: db "Yunooka: ahci dev ", 0
line_ahci_cap: db "Yunooka: ahci cap ", 0
line_ahci_ghc: db "Yunooka: ahci ghc ", 0
line_ahci_none: db "Yunooka: ahci none", 13, 10, 0
line_home: db "Yunooka: home ", 0
line_home_beta: db "Yunooka: beta ", 0
line_family: db "family", 13, 10, 0
line_not_family: db "not family", 13, 10, 0
line_pixel: db "Yunooka: pixel ", 0
line_line: db "Yunooka: line ", 0
line_calc_ready: db "Yunooka: calc ready", 13, 10, 0
line_calc_arrow: db "=", 0
line_calc_timeout: db "Yunooka: no line", 13, 10, 0
; 签名匹配那几样。EICAR 是公开的测试串，写在这里是为了让「一条规则」有具体的形状。
eicar_sig: db 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
eicar_len equ $ - eicar_sig
fs_eicar_path: dw 0x03B1, 0x003A, 0x002F, 0x0065, 0x0069, 0x0063, 0x0061, 0x0072
               dw 0x002E, 0x0074, 0x0078, 0x0074, 0
fs_clean_path: dw 0x03B1, 0x003A, 0x002F, 0x0063, 0x006C, 0x0065, 0x0061, 0x006E
               dw 0x002E, 0x0074, 0x0078, 0x0074, 0
line_scan_found: db "Yunooka: scan eicar -> FOUND", 13, 10, 0
line_scan_missed: db "Yunooka: scan eicar -> missed", 13, 10, 0
line_scan_clean: db "Yunooka: scan clean -> clean", 13, 10, 0
line_scan_false: db "Yunooka: scan clean -> false positive", 13, 10, 0
line_scan_nofile: db "Yunooka: scan -> no file", 13, 10, 0
fs_rules_path: dw 0x03B1, 0x003A, 0x002F, 0x0072, 0x0075, 0x006C, 0x0065, 0x0073
               dw 0x002E, 0x0074, 0x0078, 0x0074, 0
line_rules_found: db "Yunooka: rules eicar -> FOUND", 13, 10, 0
line_rules_missed: db "Yunooka: rules eicar -> missed", 13, 10, 0
line_rules_clean: db "Yunooka: rules clean -> clean", 13, 10, 0
line_rules_false: db "Yunooka: rules clean -> false positive", 13, 10, 0
line_rules_none: db "Yunooka: rules -> no rule", 13, 10, 0
line_rules_head_e: db "Yunooka: rules eicar.txt = ", 0
line_rules_head_c: db "Yunooka: rules clean.txt = ", 0
line_rule_none: db "none", 0
line_plot: db "Yunooka: plot ", 0
line_plot_none: db "Yunooka: plot -> no expression", 13, 10, 0
line_persist_ok: db "Yunooka: persist write -> same 512 bytes", 13, 10, 0
line_persist_diff: db "Yunooka: persist write -> differ", 13, 10, 0
line_persist_fail: db "Yunooka: persist write -> failed", 13, 10, 0
line_persist_survived: db "Yunooka: persist survived a reboot", 13, 10, 0
line_health: db "Yunooka: disk model ", 0
line_health_fail: db "Yunooka: disk model -> no identify", 13, 10, 0
line_smart: db "Yunooka: smart ", 0
line_smart_fail: db "Yunooka: smart -> no answer", 13, 10, 0
smart_buf: times 512 db 0
; IDENTIFY 回来的一整页：512 字节，型号、序列号与能力位都在里面。
health_buf: times 512 db 0
; KID 的索引表：16 条，每条 32 字节名字 + 4 字节扇区。
index_buf: times (40 * index_cap) db 0
index_n: dq 0
name_hello: db "hello.txt", 0
name_nosuch: db "nosuch.txt", 0
line_index_count: db "Yunooka: index count ", 0
line_index_hello: db "Yunooka: index hello.txt -> ", 0
line_index_miss: db "Yunooka: index nosuch.txt -> ", 0

; 窗口原语的参数。它们放在内存里，因为 draw_line 要占 r12 到 r15。
rect_x: dq 0
rect_y: dq 0
rect_w: dq 0
rect_h: dq 0
rect_c: db 0
line_explorer: db "Yunooka: window ", 0

; 第三层（列一个盘的条目）的游标与那几列。全部放内存：这一处要跨四个打印函数，
; 而它们各自占用的寄存器不同 —— 托付给任何一个都会在「打了点什么」之后丢掉位置。
list_ptr: dq 0
list_n: dq 0
list_namelen: dq 0
list_type: dq 0
list_size: dq 0
list_count: dq 0
list_tag: db 'a'
line_list_count: db "Yunooka: listed ", 0
line_list_miss: db "Yunooka: list -> unknown drive", 13, 10, 0

; 第四层（一个文件的详情）的六列。与层三同一族理由：要跨好几个打印函数。
stat_entry: dq 0
stat_namelen: dq 0
stat_type: dq 0
stat_start: dq 0
stat_size: dq 0
stat_index: dq 0
line_stat_head: db "Yunooka: stat ", 0
line_stat_cross: db "Yunooka: cross ", 0
line_stat_same: db "same", 0
line_stat_differ: db "differ", 0
line_stat_miss: db "Yunooka: stat -> no file", 13, 10, 0
line_ident_head: db "Yunooka: identify ", 0
line_ident_miss: db "Yunooka: identify -> no file", 13, 10, 0
line_kind_text: db "text", 0
line_kind_pkg: db "package", 0
line_kind_none: db "unknown", 0
; 别的系统的五种。名字短是为了让那一行在一行里放得下。
line_kind_pe: db "pe", 0
line_kind_elf: db "elf", 0
line_kind_macho: db "macho", 0
line_kind_zip: db "zip", 0
line_kind_dex: db "dex", 0
line_kind_gzip: db "gzip", 0
line_kind_7z: db "7z", 0
line_kind_rar: db "rar", 0
line_kind_pdf: db "pdf", 0
line_kind_png: db "png", 0
line_kind_jpeg: db "jpeg", 0
line_kind_sqlite: db "sqlite", 0
line_kind_hmgk: db "hmgk", 0
; 读字段那一条用的四段文字。数字各由 put_num64 打，所以这里只有前后缀。
line_hmgk_v:       db "Yunooka: hmgk v", 0
line_hmgk_bpm:     db " bpm ", 0
line_hmgk_struct:  db " struct ", 0
line_hmgk_pattern: db " pattern ", 0
; 嵌入形态那一条用的三段文字。类型名与偏移各由 put_ident_kind 与 put_num64 打。
; line_embed_inner 不能带前导空格：put_ident_kind 打的名字后面已经有一个空格，
; 再加一个就会变成 "pe  hmgk" —— 而判据写的是单空格，那一格因此会红成「没扫到」。
line_embed_main:    db "Yunooka: embed ", 0
line_embed_inner:   db "hmgk at ", 0
line_embed_missing: db " none", 0
; 8x8 位图那一份字模，以及它用到的两段文字。H 的中间那一横在第 4 行（从 0 起算），
; 所以它的位图是「四行两竖、一行全亮、三行两竖」—— 判据读的那四个点各自的亮暗就来自这里。
font_H:     db 0x81, 0x81, 0x81, 0x81, 0xFF, 0x81, 0x81, 0x81
; 数字 0 到 9 的 8x8 字模，每个八字节、最高位在左边。表是连续的，所以「字符减 0x30、
; 乘八、加到表头」就是它的位置 —— draw_text 里那三行的全部内容。
font_digits:
    db 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C   ; 0
    db 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x7E   ; 1
    db 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E   ; 2
    db 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x66, 0x3C   ; 3
    db 0x0C, 0x1C, 0x3C, 0x6C, 0x6C, 0x7E, 0x0C, 0x0C   ; 4
    db 0x7E, 0x60, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C   ; 5
    db 0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x3C   ; 6
    db 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x30   ; 7
    db 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x66, 0x3C   ; 8
    db 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x18, 0x30   ; 9
; 大写字母 A 到 Z 的 8x8 字模。行 0 到 6 是字形，行 7 留空 —— 所以字与字之间在竖直方向
; 也有一行空隙，而水平方向没有（字距就是字宽）。
;
; 这张表与上面那张 digit 表分开，不合成一张从 0x30 到 0x5A 的连续表：合成的话中间那
; 七个标点（: ; < = > ? @）要占位置填空白，而空白字模在判据里与「这个字符不存在」长得
; 一样。两张表各自的入口在 draw_text 里，多一个分支换掉七格假数据。
;
; font_H 那一份（单字铺绘那一格用的）与这里的 H 不同，是有意的：那一格验的是「把一份
; 八字节位图铺到屏幕上」这个机制，样本长什么样不重要；而这里的 H 是字体的一部分。
font_letters:
    db 0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x00   ; A
    db 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00   ; B
    db 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00   ; C
    db 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00   ; D
    db 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00   ; E
    db 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00   ; F
    db 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3C, 0x00   ; G
    db 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00   ; H
    db 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00   ; I
    db 0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38, 0x00   ; J
    db 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00   ; K
    db 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00   ; L
    db 0x63, 0x77, 0x7F, 0x6B, 0x63, 0x63, 0x63, 0x00   ; M
    db 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00   ; N
    db 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00   ; O
    db 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00   ; P
    db 0x3C, 0x66, 0x66, 0x66, 0x6E, 0x3C, 0x0E, 0x00   ; Q
    db 0x7C, 0x66, 0x66, 0x7C, 0x78, 0x6C, 0x66, 0x00   ; R
    db 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00   ; S
    db 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00   ; T
    db 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00   ; U
    db 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00   ; V
    db 0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00   ; W
    db 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00   ; X
    db 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00   ; Y
    db 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00   ; Z
line_text:  db "Yunooka: text ", 0
line_upper: db "Yunooka: upper ", 0
str_HO:     db "HO", 0
line_lines: db "Yunooka: lines ", 0
line_lower: db "Yunooka: lower ", 0
str_ab:     db "ab", 0
str_h0:     db "H", 10, "0", 0
str_01:     db "01", 0
line_glyph: db "Yunooka: glyph ", 0
line_clear: db "Yunooka: clear ", 0
line_space: db " ", 0
; 别的系统的五个样本的路径。名字是 ASCII，所以码元就是它自己的字节。
fs_pe_path: dw 0x03B1, 0x003A, 0x002F, 0x0070, 0x0065, 0x002E, 0x0062, 0x0069, 0x006E, 0
fs_elf_path: dw 0x03B1, 0x003A, 0x002F, 0x0065, 0x006C, 0x0066, 0x002E, 0x0062, 0x0069, 0x006E, 0
fs_macho_path: dw 0x03B1, 0x003A, 0x002F, 0x006D, 0x0061, 0x0063, 0x0068, 0x006F, 0x002E, 0x0062, 0x0069, 0x006E, 0
fs_zip_path: dw 0x03B1, 0x003A, 0x002F, 0x007A, 0x0069, 0x0070, 0x002E, 0x0062, 0x0069, 0x006E, 0
fs_dex_path: dw 0x03B1, 0x003A, 0x002F, 0x0064, 0x0065, 0x0078, 0x002E, 0x0062, 0x0069, 0x006E, 0
; 七个样本头。它们不落在盘上，而是数据段里的常量 —— 理由见调用处那段注释。
;
; 每一个只造头：判据看的是头，而一个 64 字节的「PNG」本来也打不开。
samp_gzip:
    db 0x1F, 0x8B, 0x08
    times 61 db 0
samp_7z:
    db 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C
    times 58 db 0
samp_rar:
    db 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07
    times 58 db 0
samp_pdf:
    db '%PDF-1.7', 10
    times 55 db 0
samp_png:
    db 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
    times 56 db 0
samp_jpeg:
    db 0xFF, 0xD8, 0xFF, 0xE0
    times 60 db 0
; 一份 hmgk 的头，按 design/HMGK.txt 的布局：
;   'H' 'M' 'G' 'K' | 版本 1 | 压缩格式 0 | 级别 0
;   | 结构段 40 字节 | 事件流 24 字节
;   | 音源 2 | 效果器 1 | 预设 0 | pattern 3 | track 2 | loop 5
;   | BPM 120.5（存成 120500） | 自动化 4 条 | 保留
;
; 结构段比事件流大，这不是随手挑的：一份曲子可以只有三小节音符而有二三十条轨、几十个
; 循环点、四条自动化包络，那时编排逻辑才是大头。样本按那个比例写，读的人一眼就看见
; 「哪一块占得多」。
;
; BPM 用乘以一千的整数：这一侧没有浮点的二进制布局约定，而速度要能逐字符核对。
samp_hmgk:
    db 'H', 'M', 'G', 'K'
    dw 1
    db 0, 0
    dd 40
    dd 24
    dw 2, 1, 0
    dw 3, 2, 5
    dd 120500
    dw 4, 0
    times 28 db 0

; 嵌入形态的样本：一个 PE 头，然后一份 hmgk 从偏移 256 开始。
;
; PE 那一段按 identify 要的定义造，不是按缩写：MZ 两字节，并且 offset 0x3C 那个 u32
; 指着 PE 签名在 0x40。少一样它就答不出 pe，而那时这条判据红的理由会变成「外面那层
; 不认识」，与内嵌那件事无关 —— 这正是两个断言要分开报的原因。
;
; hmgk 那一段与 samp_hmgk 的头同形（都是 36 字节），但 BPM 写成 90000 而不是 120500：
; 这样两份样本不是互为副本，读错哪一份都看得出来。
samp_embed_len equ 512
samp_embed:
    db 'M', 'Z'
    times 0x3A db 0                ; 补到偏移 0x3C
    dd 0x40                        ; e_lfanew：PE 签名在 0x40
    dd 0x00004550                  ; 'P' 'E' 0 0
    times (256 - 0x44) db 0        ; 补到偏移 256
    db 'H', 'M', 'G', 'K'
    dw 1
    db 0, 0
    dd 40
    dd 24
    dw 2, 1, 0
    dw 3, 2, 5
    dd 90000
    dw 4, 0
    times (512 - 256 - 36) db 0    ; 补到整整 512 字节

samp_sqlite:
    db 'SQLite format 3', 0
    times 48 db 0
fs_hello_path: dw 0x03B1, 0x003A, 0x002F, 0x0068, 0x0065, 0x006C, 0x006C, 0x006F
               dw 0x002E, 0x0074, 0x0078, 0x0074, 0
fs_prog_path: dw 0x03B1, 0x003A, 0x002F, 0x0070, 0x0072, 0x006F, 0x0067, 0x002E
              dw 0x0068, 0x006D, 0x0074, 0x006E, 0
fs_fake_path: dw 0x03B1, 0x003A, 0x002F, 0x0066, 0x0061, 0x006B, 0x0065, 0x002E
              dw 0x0074, 0x0078, 0x0074, 0
; 落盘那一条用的两个 512 字节缓冲：一个填满 0x2A 写下去，另一个接读回来的。
persist_buf: times 512 db 0
persist_buf2: times 512 db 0
; 绘图那条表达式的落点：盘上读进来之后放在这里（UTF-16，0 结尾）。
plot_expr: times 128 dw 0
fs_plot_path: dw 0x03B1, 0x003A, 0x002F, 0x0070, 0x006C, 0x006F, 0x0074
              dw 0x002E, 0x0074, 0x0078, 0x0074, 0
; 100.0 的八字节位模式：屏幕中线。写成一个常量而不是算出来，因为它就是「半个高度」。
const_100: dq 0x4059000000000000

; shell 的两样：要从盘上找的文件名，与它认得的第一条命令。
; 命令是 ASCII（不是 UTF-16）—— 因为 cmd.txt 的内容就是 ASCII 字节，
; 而比较那一步按字节比。
fs_cmd_name: dw 0x0063, 0x006D, 0x0064, 0x002E, 0x0074, 0x0078, 0x0074, 0
fs_cmd_files: db "files"
fs_cmd_echo: db "echo"
sh_wordlen: dq 0
; shell 认下的那一行在哪。内置 readline 从这里取 —— 而它存的是指针，内容留在原地。
sh_line_ptr: dq 0
; readline 交出去的串：u16 长度 + 最多 255 个码元。
myon_line: times 520 db 0
line_shell_prompt: db "Yunooka: shell> ", 0
; 输入从哪来。这两行不是装饰：只打 files 的答案，看不出那句话是信箱里的还是盘上的，
; 而这两件事的成败完全不同。
line_shell_from_mbox: db "Yunooka: input from mailbox", 13, 10, 0
line_shell_from_disk: db "Yunooka: input from cmd.txt", 13, 10, 0
line_shell_unknown: db "Yunooka: unknown command", 13, 10, 0
line_shell_missing: db "Yunooka: no cmd.txt", 13, 10, 0

; repl 的那几样。文件名是 UTF-16（它是目录里的名字），而盘上那份输入也是 UTF-16 ——
; 因为它是「一个 HMYR 里的名字」，而 HMYR 的串按码元算。
fs_repl_name: dw 0x0072, 0x0065, 0x0070, 0x006C, 0x002E, 0x0074, 0x0078, 0x0074, 0
line_repl_prompt: db "Yunooka: repl> ", 0
line_repl_arrow: db " -> ", 0
line_repl_units: db " units", 0
line_repl_unknown: db "Yunooka: no such name", 13, 10, 0
line_repl_missing: db "Yunooka: no repl.txt", 13, 10, 0

; 数学那几样。输入是 UTF-16（与 repl.txt 同一种：它要能被 HMYR 的名字读法读），
; 而打印是 ASCII —— 八位串口打不出中文，所以读数一律用数字与拉丁字母。
fs_math_name: dw 0x006D, 0x0061, 0x0074, 0x0068, 0x002E, 0x0074, 0x0078, 0x0074, 0
math_op_average: dw 0x0061, 0x0076, 0x0065, 0x0072, 0x0061, 0x0067, 0x0065, 0x003A
line_math_sum: db "Yunooka: math> sum -> ", 0
line_math_avg: db "Yunooka: math> average -> ", 0
line_math_unknown: db "Yunooka: unknown operation", 13, 10, 0
line_math_missing: db "Yunooka: no math.txt", 13, 10, 0
; 表达式这一边：只报左边被认成了什么，不报算出什么。左边原样打（f(x) 与 f x 的差别
; 要看得见），右边只报有没有 x —— 有没有 x 就是「能不能画」的判据。
line_curve: db "Yunooka: curve ", 0
line_curve_arrow: db " -> ", 0
line_curve_hasx: db "has x", 0
line_curve_nox: db "no x", 0
line_div: db "Yunooka: div -> ", 0

; 六位小数的位权，从大到小。用表而不是每轮除以十：除数与被除数都是常数级的小整数，
; 表把「第几位」这件事变成一次索引，读的人不必跟着一个变量推它的值。
frac_places: dq 100000, 10000, 1000, 100, 10, 1
; 十的幂，parse_decimal 用「小数部分 ÷ 十的位数」那一步取。第 0 格占位，从第 1 格起用。
pow10_tab: dq 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000

align 8
; 数学用到的浮点常量，按 f64 的位模式写死。为什么不写成 3.14159...：
; nasm 不解析浮点字面量，所以这里是那几个数的原始位模式。
; π = 0x400921FB54442D18、e = 0x4005BF0A8B145769，都用 node 的 writeDoubleLE 核过。
const_pi: dq 0x400921FB54442D18
const_e: dq 0x4005BF0A8B145769
const_1e6: dq 0x412E848000000000
const_half: dq 0x3FE0000000000000
const_signmask: dq 0x8000000000000000
math_sum: dq 0

; 「除」的判据程序：常量 π、常量 2、除、返回。四条指令，值全是 f64 的原始位模式。
; db 5 是常量的操作码，db 1 是值种类「数」，随后八字节是那个数本身 —— 与 read_value
; 的读法一一对应。28 是返回。
align 8
div_prog:
    db 5, 1
    dq 0x400921FB54442D18           ; π
    db 5, 1
    dq 0x4000000000000000           ; 2
    db 6                            ; 除
    db 28                           ; 返回
line_bad_kind: db "  kind=", 0
line_unknown_op: db "  unknown op ", 0
line_got: db "Yunooka: fn116 returned", 13, 10, 0

; 分配器的游标。从 4 MB 起 —— 前 4 MB 已经被引导扇区、第二段、页表占着，种子在
; 0x70000，而 4 MB 往上是干净且被页表映着的一片。dq 在 16 位段里只是数据定义，
; 与指令位宽无关。
align 8
heap_next: dq 0x400000

; 种子的真实字节数，由 tools/build.mjs 编译之后按符号写进来。用 32 位是因为种子
; 七万多字节，十六位装不下。放在数据区末尾，好让构建那一侧按符号表找到它。
seed_bytes: dd 0

; 上限 = 引导之后那一段占的字节数。它与 boot.asm 里那句 mov al、build.mjs 里的上限、
; 以及种子的起始扇区是同一组数 —— 四个数字一起改，少一个就会在别处报出来。
times ((($-$$)+511)/512)*512-($-$$) db 0
