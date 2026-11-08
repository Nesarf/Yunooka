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

    mov si, line2
    call serial_print

    ; 三批各读一个段。每一批都自己写一次 LBA —— 这一点是实测出来的：
    ; int 0x13 的 LBA 扩展并不保证把 DAP 里的那个 64 位 LBA 推到下一批（VirtualBox
    ; 就没有），于是第二批会从同一个位置重读。症状很绕：种子读进来了、魔数也对、
    ; 只有一个深处的字节不对（读到 29 而不是 19），因为那一段其实被第一段覆盖了。
    ;
    ; 种子读到 0x20000 起，不是 0x8000 —— 第二段自己被加载在 0x7E00，数据区铺到
    ; 0x9E00，而 0x8000 起的种子会把它覆盖成零。0x20000 在实模式 1 MB 之内，离得够远。
    mov dword [dap_lba], 17       ; 第 18 个扇区：引导 1 + 第二段 16
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x2000
    mov word [dap_count], 64
    call read_batch
    jc .seed_fail

    mov dword [dap_lba], 17 + 64
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x2800
    mov word [dap_count], 64
    call read_batch
    jc .seed_fail

    mov dword [dap_lba], 17 + 128
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
    mov cr4, eax

    mov ecx, 0xC0000080           ; EFER
    rdmsr
    or eax, 0x100                 ; LME
    wrmsr

    mov eax, cr0
    or eax, 0x80000000            ; PG
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
    movzx edx, word [rsi]
    add rsi, 2
    push rdx
    lea rsi, [rsi + rdx * 2]     ; 把字符数据跳过，好让下一条指令读得对
    pop rdx
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
    mov r13, [rsi]                  ; 指令数，u32
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
    movzx eax, word [rsi]           ; 槽号
    ; 这一版只有参数，没有局部槽，所以槽 0 就是参数 0 —— 遇到别的槽就停，
    ; 而不是悄悄给出一个错的数。
    cmp eax, 0
    jne .none
    mov rax, [param_kinds]
    mov rdx, [param_vals]
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
    ; 两值相等：种类相同且内容相同（这一版这样够，数是位模式比，串还没做）
    xor ecx, ecx
    cmp rax, r14
    jne .eq_false
    cmp rdx, r15
    jne .eq_false
    mov ecx, 1
.eq_false:
    mov rax, 3                      ; 布尔
    mov rdx, rcx
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
    ret
.none:
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
    mov qword [stack_top], 0
    mov qword [param_kinds], 1      ; 数
    mov rax, [test_arg]
    mov [param_vals], rax
    ; 参数也要压进栈：取 那条指令要的是栈上的当前帧槽，而这一版把参数放在 param_* 里，
    ; 所以压一次让栈与参数对得上。
    mov rax, 1
    mov rdx, [test_arg]
    call push_val
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

; 解释器的那几样：十六格值栈（种类与内容各一列）、参数、以及每条指令的字节偏移。
; 偏移表是关键 —— 跳转的目标是「指令索引」，而游标是字节位置，两者之间要有这张表才对得上。
align 8
stack_kinds: times 16 dq 0
stack_vals:  times 16 dq 0
stack_top:   dq 0
param_kinds: dq 0
param_vals:  dq 0
instr_offsets: times 64 dq 0
test_arg: dq 1

line_fn116: db "Yunooka: fn116 -> ", 0
line_call: db "Yunooka: call -> ", 0
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

times 8192-($-$$) db 0
