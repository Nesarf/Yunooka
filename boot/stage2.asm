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

    ; 三批各读一个段。
    ;
    ; 种子读到 0x20000 起，不是 0x8000 —— 这一条是实测出来的：第二段自己被加载在
    ; 0x7E00，它的数据区一直铺到 0x8E00，而 0x8000 起的种子会把 seed_bytes 那一格
    ; 覆盖成零。症状是串口打印 0 而盘上明明是 74594，两个地方看起来都「对」。
    ; 0x20000 在实模式 1 MB 之内，离第二段够远，读多少都碰不到它。
    mov dword [dap_lba], 9        ; 种子在第 10 个扇区起（前九个是引导与第二段）
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x2000
    mov word [dap_count], 64
    call read_batch
    jc .seed_fail
    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x2800
    mov word [dap_count], 64
    call read_batch
    jc .seed_fail
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

.hang64:
    cli
    hlt
    jmp .hang64

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
line_nl:   db 13, 10, 0

; 种子的真实字节数，由 tools/build.mjs 编译之后按符号写进来。用 32 位是因为种子
; 七万多字节，十六位装不下。放在数据区末尾，好让构建那一侧按符号表找到它。
seed_bytes: dd 0

times 4096-($-$$) db 0
