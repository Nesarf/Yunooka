; Yunooka 的第二块砖：内核那一侧的第一段。
;
; 它被引导扇区从第 2 个扇区读进 0x7E00，然后跳过来。到这里，BIOS 已经不在中间了 ——
; 引导扇区只做了三件事：初始化串口、把这段读进来、跳过来。往后再加的东西都住在这一侧，
; 而引导扇区那一 512 字节从此不必再长大。
;
; 判据与引导扇区同一条通道：串口。两行都在才算通 —— 只看到第二行，说明第一段没跑；
; 只看到第一行，说明读盘或跳转断了。这正是判据要分两行写的原因。
;
; 编译：nasm -f bin stage2.asm -o stage2.bin（必须 ≤ 512 字节，占一个扇区）

[org 0x7e00]
[bits 16]

stage2:
    ; 段寄存器在这里重设一遍。引导扇区那边设过，而这里不假设它 —— 从别处被加载时，
    ; 「上一步设过」这个假设是最容易失效的东西。
    xor ax, ax
    mov ds, ax
    mov es, ax

    mov si, line2
    call serial_print

.hang:
    hlt
    jmp .hang

; 串口打印：与引导扇区那一份同形，含 LSR 的发送器就绪等待。
; 两处各写一遍不是疏忽 —— 这一段将来会独立编译、独立加载，共用要靠链接，
; 而链接是第三块砖的事。现在重复的代价是二十行，不重复的代价是一层依赖。
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

line2: db "Yunooka: stage2 ok", 13, 10, 0

times 510-($-$$) db 0
dw 0xaa55
