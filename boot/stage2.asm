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
    mov dword [dap_lba], 33       ; 第 34 个扇区：引导 1 + 第二段 32
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x2000
    mov word [dap_count], 64
    call read_batch
    jc .seed_fail

    mov dword [dap_lba], 33 + 64
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x2800
    mov word [dap_count], 64
    call read_batch
    jc .seed_fail

    mov dword [dap_lba], 33 + 128
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
    mov word [dap_count], 8
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
    call run_ata_test
    call run_fs_test
    call run_fs_open
    call run_fs_open2
    call run_shell
    call run_repl
    call run_div_test
    call run_div_report
    call run_math
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
    mov rsi, 0x20000 + 9
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

; 预读进来的那六份东西：扇区 1024 起，落在 0x40000，每扇区 512 字节。
; 接口与 ata_read 一样（rdi = 扇区号），但它不读盘 —— 它只是算出地址。
; 长模式下的文件系统一路都走这里，PIO 那条路只在 run_ata_test 里留作对照。
fs_load:
    sub rdi, 1024
    shl rdi, 9
    mov rsi, 0x40000
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

; 打印号码与「栈上那一个数」，然后停机。
;
; 为什么要打第二个数：只打号码只能说「出的是哪一类」，说不出「出在哪里」。而没有位置
; 的异常号在这台机器上帮助有限 —— 它会把一次崩溃变成一次猜测。
;
; 第二个数是什么取决于异常：不带错误码的（除零、断点、未定义指令）那里是 RIP；
; 带错误码的（双重故障、通用保护、页不存在）那里是错误码，RIP 在再往上一格。
; 两种都打是不必要的：看到号码就知道该按哪一种读。这一处含糊是故意的，写在这里
; 是为了下一个读的人不必猜。
;
; 不恢复：这一版没有「异常之后继续跑」的地基（没有进程，也没有可以回到的干净状态），
; 假装能继续会让错误在后面更远的地方出现，那时线索更少。
idt_common:
    mov r15, [rsp]                  ; 号码
    mov r14, [rsp + 8]              ; 见上：RIP 或错误码
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
    mov rdi, 33                   ; 种子在盘上的第一个扇区：引导 1 + 第二段 32
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

run_fs_open2:
    mov rdi, fs_path2
    movzx eax, word [rdi]
    cmp ax, 0x03B1
    jne fs_open_drive
    mov rdi, 1024
    call fs_load
    mov [fs_buf], rsi
    mov rax, [fs_buf]
    mov r13d, [rax + 12]          ; 根目录扇区
    mov r8, fs_seg1               ; 第一段：docs
    mov r9, 4
    mov rsi, r13
    call fs_lookup
    test rax, rax
    jz fs_open_miss
    mov r8, fs_seg2               ; 第二段：note.txt，在 docs 里面找
    mov r9, 8
    mov rsi, r15
    call fs_lookup
    test rax, rax
    jz fs_open_miss
    mov rdi, r15
    call fs_load
    mov [fs_buf], rsi
    mov rsi, line_fs_open
    call puts64
    mov rdi, fs_seg1
    call put_utf16_ascii
    mov al, '/'
    call putc64
    mov rdi, fs_seg2
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

times 16384-($-$$) db 0
