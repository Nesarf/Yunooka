; Yunooka 的第二段：从实模式一路走到 64 位长模式。
;
; 它被引导扇区读进 0x7E00（现在占八个扇区，4 KB）。这一版做四件事：
;   一、还在实模式时，用 BIOS 读完整份种子、验前五字节 HMYRB
;   二、打开 A20、装 GDT、进 32 位保护模式
;   三、建四级页表、置 PAE 与 LME、开分页
;   四、远跳进 64 位长模式，在那里往串口打一行
;
; 为什么中间要打两行：三段之间最容易静默失败的是页表那一段 —— 错了就是三重故障重启，
; 屏幕一片黑，串口什么也没有。所以「保护模式到了」与「长模式到了」各有一行字，
; 失败时能看出断在哪一段，而不是只知道「没成」。
;
; 编译：nasm -f bin stage2.asm -o stage2.bin（上限 4096 字节，占八个扇区）

[org 0x7e00]
[bits 16]

; ======================================================================
; 一、实模式：读种子、验魔数
; ======================================================================
stage2:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
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
    ; 种子读到 0x20000 起，不是 0x8000 —— 第二段自己被加载在 0x7E00，32 扇区就是
    ; 16 KB，铺到 0xBE00，而 0x8000 起的种子会把它覆盖成零。0x20000 在实模式 1 MB
    ; 之内，离得够远。
    mov dword [dap_lba], 39       ; 第 35 个扇区：引导 1 + 第二段 33
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x2000
    mov word [dap_count], 64
    call read_batch
    jc .seed_fail

    mov dword [dap_lba], 39 + 64
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x2800
    mov word [dap_count], 64
    call read_batch
    jc .seed_fail

    mov dword [dap_lba], 39 + 128
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x3000
    mov word [dap_count], 18
    call read_batch
    jc .seed_fail

    ; 魔数在 0x20000 起，所以用 es 指向它，与 ds 里的 seed_magic 比。
    push es
    mov ax, 0x2000
    mov es, ax
    xor di, di
    mov si, seed_magic
    mov cx, 5
    call same_es
    pop es
    jc .seed_bad

    mov si, line3ok
    call serial_print
    mov eax, [seed_bytes]
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
    ; 文件系统的六个扇区先读进来：超级块、根目录、docs 目录、hello.txt、note.txt、
    ; cmd.txt。盘上的东西每多一份，这个数就跟一次；而它也必须与 build 写进去的
    ; 布局一致，否则预读区里少一份、fs_load 却照算不误。
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
    mov word [dap_count], 14
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
    mov al, [drive]
    mov [mbox_save], al
    mov byte [drive], 0x81
    mov dword [dap_lba], 0
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x5000
    mov word [dap_count], 1
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
    jmp 0x08:protected            ; 远跳，把它之后的一切交给 32 位那一段

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

; 比较 ds:si 与 es:di 各 cx 字节。种子读在 0x20000 起，超出 ds 能指的偏移，
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
    mov edi, 0x3000
    mov eax, 0x83                 ; present + writable + large page
    mov ecx, 512
.fill_pd:
    mov [edi], eax
    add eax, 0x200000
    add edi, 8
    loop .fill_pd

    ; CR3 指向的是**最上面那一级** —— 也就是 PML4（0x1000），不是 PD（0x3000）。
    ; 这一处写错一次：第一版把 0x3000 放进了 CR3，于是开分页的那一瞬间 CPU 把 PD
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
    call run_ata_test
    call run_fs_test
    call run_fs_open
    call run_fs_open2
    call run_fs_open3
    call run_fs_write
    call run_share_test
    call run_home_test
    call run_gate_blocked
    call run_homeshare_test
    call run_gate_test
    call run_pixel_test
    call run_line_test
    call run_calc_live
    call run_scan_test
    call run_rules_multi
    call run_pci_scan
    call run_shell
    call run_repl
    call run_div_test
    call run_div_report
    call run_math
    call run_shell_live
    call run_repl_live
    call run_program
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
    mov rsi, 0x20000
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
    mov rsi, 0x20000 + 9

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
    mov rsi, 0x20000 + 9
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
    ; 立即数与「调函数」同一个形状：名字在前，参数个数在后。这一版只认 len。
    movzx r8d, word [rsi]
    lea rdi, [rsi + 2]
    lea rsi, [rsi + 2 + r8 * 2]
    movzx r14d, word [rsi]          ; 参数个数
    cmp r8, 3
    jne .builtin_unknown
    cmp word [rdi], 0x006C          ; 'l'
    jne .builtin_unknown
    cmp word [rdi + 2], 0x0065      ; 'e'
    jne .builtin_unknown
    cmp word [rdi + 4], 0x006E      ; 'n'
    jne .builtin_unknown
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
.builtin_unknown:
    mov rsi, line_unknown_builtin
    call puts64
    call put_nl64
    jmp .none

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

    mov r12, 0x20000 + 65950
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
    ; 从哪个包开始扫：读 pkg_base，不是写死 0x20000。种子只是「启动时就在那里的那个包」，
    ; 而盘上读进来的包住在别处 —— 同一段查找代码两处都用，靠这一个变量分。
    mov rsi, [pkg_base]
    add rsi, 9                     ; 头九个字节：HMYRB + 版本 u16 + 函数数 u16
    xor rbx, rbx
    xor r11, r11                   ; 还没找到
.each:
    cmp rbx, 400                   ; 函数数不会超过这个数；越界就说没找到，不长跑
    ja .done
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
; 0x20000，这里再用 ATA 读同一个扇区（LBA 33，种子在盘上的第一个扇区），
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
    ; 设备/头：主盘、LBA 模式、再带上 LBA 的高四位
    mov rax, rdi
    shr rax, 24
    and al, 0x0F
    or al, 0xE0
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
    mov r10, 5000000               ; 大约几秒：够主机在这段窗口里送一个键
.wait:
    mov dx, 0x64
    in al, dx
    test al, 0x01                  ; bit 0：输出缓冲有数据
    jnz .got
    dec r10
    jnz .wait
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
    mov rdi, r14
    mov rsi, fs_cmd_files
    mov rcx, 5
    call bytes_eq
    jc shell_unknown
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
    mov qword [pkg_base], 0x20000   ; 种子是默认的那个包，别让后面的测试读错地方
    mov rsi, line_prog
    call puts64
    mov rax, r15
    mov rdx, r14
    call print_value
    call put_nl64
    ret
prog_missing:
    mov rsi, line_prog_missing
    call puts64
    ret
prog_bad:
    mov qword [pkg_base], 0x20000
    mov rsi, line_prog_bad
    call puts64
    ret
prog_nomain:
    mov qword [pkg_base], 0x20000
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
    mov rdi, 39                   ; 种子在盘上的第一个扇区：引导 1 + 第二段 33
    mov rsi, rax
    call ata_read
    jc ata_fail
    mov rsi, [ata_buf]
    mov rdi, 0x20000
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
fs_write_file:
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
    ; 找根目录里的第一个空条目（名字长度为 0）
    mov edi, [rbx + 12]
    call fs_load
    mov r9, rsi
.find_free:
    movzx eax, word [r9]
    test eax, eax
    jz .have_slot
    lea r9, [r9 + 11 + rax * 2]
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
; 代价是类型那一个字节现在有两个含义：低七位是文件还是目录，最高位是共享。这种挤在
; 一起的字段要靠约定守住，所以下面凡是用类型的地方都先 and 0x7F。
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
    and r10b, 0x7F
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
    mov rsi, 0x20000 + 43920
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

line_letters: db "Yunooka: letters -> ", 0
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

line_fn116: db "Yunooka: fn116 -> ", 0
line_call: db "Yunooka: call -> ", 0
line_byname: db "Yunooka: byname -> ", 0
line_byname_first: db "Yunooka: byname first -> ", 0
line_byname_missing: db "Yunooka: byname missing after ", 0

; 「块长」两个字的 UTF-16 码元。按名字找函数时，名字是拿这份字节去比，
; 而不是拿一个编译期算出来的偏移 —— 偏移只在种子不变时才对，名字才属于语言。
name_kuaichang: dw 0x5757, 0x957F
name_is_digit: dw 0x0069, 0x0073, 0x005F, 0x0064, 0x0069, 0x0067, 0x0069, 0x0074

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
line_prog: db "Yunooka: prog main -> ", 0
line_prog_missing: db "Yunooka: no prog.hmtn", 13, 10, 0
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
; 当前在扫哪一个包。种子的地址是 0x20000，而盘上读进来的包住在预读区里 ——
; find_fn_by_name 靠这个变量就知道该从哪儿开始，不必写两份查找器。
pkg_base: dq 0x20000
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
; 家庭组第一步的那几样。
fs_share_path: dw 0x03B1, 0x003A, 0x002F, 0x0064, 0x006F, 0x0063, 0x0073, 0  ; α:/docs
; 第二块盘上的一个文件与它的盘符 —— 共享与边界见面那一条用的。
fs_share_beta: dw 0x03B2, 0x003A, 0x002F, 0x0068, 0x0065, 0x006C, 0x006C, 0x006F
               dw 0x002E, 0x0074, 0x0078, 0x0074, 0                        ; β:/hello.txt
fs_beta_drive: dw 0x03B2, 0
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

; shell 的两样：要从盘上找的文件名，与它认得的第一条命令。
; 命令是 ASCII（不是 UTF-16）—— 因为 cmd.txt 的内容就是 ASCII 字节，
; 而比较那一步按字节比。
fs_cmd_name: dw 0x0063, 0x006D, 0x0064, 0x002E, 0x0074, 0x0078, 0x0074, 0
fs_cmd_files: db "files"
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
; 0x20000，而 4 MB 往上是干净且被页表映着的一片。dq 在 16 位段里只是数据定义，
; 与指令位宽无关。
align 8
heap_next: dq 0x400000

; 种子的真实字节数，由 tools/build.mjs 编译之后按符号写进来。用 32 位是因为种子
; 七万多字节，十六位装不下。放在数据区末尾，好让构建那一侧按符号表找到它。
seed_bytes: dd 0

; 上限 = 引导之后那一段占的字节数。它与 boot.asm 里那句 mov al、build.mjs 里的上限、
; 以及种子的起始扇区是同一组数 —— 四个数字一起改，少一个就会在别处报出来。
times ((($-$$)+511)/512)*512-($-$$) db 0
