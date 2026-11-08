; Yunooka 的第二段：内核那一侧的第一段。
;
; 它被引导扇区从第 2 个扇区读进 0x7E00，然后跳过来。到这里 BIOS 已经不在中间了 ——
; 引导扇区只做了三件事：初始化串口、把这段读进来、跳过来。往后再加的东西都住在这一侧。
;
; 这一版多做一件：读第 3 个扇区，看它开头五字节是不是 HMYRB —— 那是种子（.hmtn）的魔数。
; 这是 Yunooka 第一次去认 HMYR 的东西。认不出来也算一个结果，所以三条出口分开说：
; 读到且魔数对、读到但魔数不对、读都读不到。
;
; 编译：nasm -f bin stage2.asm -o stage2.bin（必须 ≤ 512 字节，占一个扇区）

[org 0x7e00]
[bits 16]

stage2:
    ; 段寄存器重设一遍。引导扇区那边设过，而这里不假设它 —— 从别处被加载时，
    ; 「上一步设过」这个假设是最容易失效的东西。
    xor ax, ax
    mov ds, ax
    mov es, ax
    ; 引导扇区跳过来的时候 dl 还带着盘号（它跳转前刚设过，而跳转不改 dl）。
    ; 这一份要留住，读第 3 个扇区时还用得上。
    mov [drive], dl

    mov si, line2
    call serial_print

    ; ---- 把整份种子读进 0x8000 起的连续内存 ----
    ; 用 BIOS 的 LBA 扩展（ah=0x42）而不是 CHS 读（ah=0x02）：CHS 一次最多 127 个扇区，
    ; 跨磁道时有些 BIOS 还会失败；LBA 扩展读多扇区是 2000 年以后的机器都有的东西。
    ;
    ; 146 个扇区仍然分批，理由不在 BIOS 而在寻址：一批 64 扇区正好 0x8000 字节，
    ; 等于正好走完一个段。于是三批各落在一个段里，段与偏移都不用做加法。
    ;   批 1  64 扇区 -> 0000:8000，覆盖物理 0x08000 到 0x10000
    ;   批 2  64 扇区 -> 1000:0000，覆盖物理 0x10000 到 0x18000
    ;   批 3  18 扇区 -> 1800:0000，覆盖物理 0x18000 到 0x1A400（种子的末尾）
    mov dword [dap_lba], 2        ; 从第 3 个扇区（LBA 2）开始
    mov word [dap_off], 0x8000
    mov word [dap_seg], 0x0000
    mov word [dap_count], 64
    call read_batch
    jc .readfail

    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x1000
    mov word [dap_count], 64
    call read_batch
    jc .readfail

    mov word [dap_off], 0x0000
    mov word [dap_seg], 0x1800
    mov word [dap_count], 18
    call read_batch
    jc .readfail

    ; ---- 前五字节是不是 HMYRB ----
    mov si, 0x8000
    mov di, seed_magic
    mov cx, 5
    call same
    jc .bad

    mov si, line3ok
    call serial_print
    jmp .hang

.bad:
    mov si, line3bad
    call serial_print
    jmp .hang

.readfail:
    mov si, line3fail
    call serial_print

.hang:
    hlt
    jmp .hang

; 比较 ds:si 与 ds:di 各 cx 字节。相等清进位，不等置进位。
; 用进位而不是返回值：调用点的两条路就在下面，进位读起来比一个约定返回值短。
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

; 一批读：按 DAP 里的段:偏移与 LBA，读到 Es:Bx 指向的地方。
; 进位由 int 0x13 给出（成功清、失败置），这里原样交回，不在中间吞掉。
read_batch:
    push si
    mov si, dap
    mov ah, 0x42
    mov dl, [drive]
    int 0x13
    pop si
    ret

; 串口打印：与引导扇区那一份同形，含 LSR 的发送器就绪等待。
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

drive: db 0
seed_magic: db "HMYRB"

; Disk Address Packet，16 字节，字段必须连续放 —— BIOS 按偏移读它，不按名字。
; 每次调用前重设 count 与 off/seg：int 0x13 会把 count 改成实际读到的扇区数，
; 也会把 lba 推进到下一批的位置。那是它的行为，不是我们的意图，所以每批都自己写一遍。
dap:
    db 0x10                 ; 结构大小，固定 16
    db 0                    ; 保留
dap_count:
    dw 64
dap_off:
    dw 0x8000
dap_seg:
    dw 0x0000
dap_lba:
    dd 2                    ; 低 32 位
    dd 0                    ; 高 32 位

line2:      db "Yunooka: stage2 ok", 13, 10, 0
line3ok:    db "Yunooka: seed ok", 13, 10, 0
line3bad:   db "Yunooka: seed bad", 13, 10, 0
line3fail:  db "Yunooka: seed unreadable", 13, 10, 0

times 510-($-$$) db 0
dw 0xaa55
