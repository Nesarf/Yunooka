; Yunooka 的第一块砖：一个真正的引导扇区。
;
; 它在被 BIOS 加载到 0x7C00 之后做三件事：初始化 COM1、把一行字写进去、停机。
; 没有屏幕输出 —— 判据走串口，因为 VBoxManage 能把 COM1 的字节写进主机的一个文件，
; 于是「它说得出话吗」变成「文件里有没有那段字节」，这件事可以自动比对。
;
; 为什么从引导扇区起步而不是从 GRUB 或 UEFI：512 字节是这个国家里最小的入口，
; 它不需要任何工具链之外的东西（nasm 就够），而它要么打出那行字、要么打不出 ——
; 没有中间状态可以含糊过去。GRUB 与 UEFI 是之后的事，那时这块砖还在。
;
; 编译：nasm -f bin boot.asm -o boot.img
; 尺寸必须正好 512 字节，末两字节是 0x55 0xAA —— 那是 BIOS 认它作引导扇区的方式。

[org 0x7c00]
[bits 16]

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    sti

    ; 串口 9600 8N1：先设 DLAB 再写除数，最后关 DLAB 并定帧格式。
    ; 这几步的顺序不能换 —— 除数寄存器与数据寄存器共用端口，DLAB 决定它是哪一个。
    mov dx, 0x3F9           ; IER：先关中断
    mov al, 0x00
    out dx, al

    mov dx, 0x3FB           ; LCR：置 DLAB
    mov al, 0x80
    out dx, al

    mov dx, 0x3F8           ; DLL：除数低字节，12 = 115200/12 = 9600
    mov al, 12
    out dx, al

    mov dx, 0x3F9           ; DLM：除数高字节
    mov al, 0x00
    out dx, al

    mov dx, 0x3FB           ; LCR：8 位、无校验、1 停止位，并清 DLAB
    mov al, 0x03
    out dx, al

    mov dx, 0x3FA           ; FCR：开 FIFO、清空、14 字节阈值
    mov al, 0xC7
    out dx, al

    mov si, message
    call serial_print

    mov si, message
    call video_print

.hang:
    hlt
    jmp .hang

; 串口打印：每发一个字节之前先等发送器空（LSR 的第 5 位）。
;
; 这个等待不是可选的。第一版没有它，跑起来只收到 "nooka: boot ok" —— 开头三个字符
; 丢了。原因是初始化刚写完 FCR 时发送器还没就绪，抢先写进去的字节没有落进 FIFO。
; 十六个字节的整句在 9600 波特下本来能靠 FIFO 撑过去，可第一个字节偏偏不行。
serial_print:
    lodsb
    test al, al
    jz .done
    mov dx, 0x3FD           ; LSR
.wait:
    in al, dx
    test al, 0x20           ; THR 空？
    jz .wait
    mov al, [si-1]          ; 把刚才为查询用掉的字节取回来
    mov dx, 0x3F8
    out dx, al
    jmp serial_print
.done:
    ret

; 屏幕打印：BIOS 的 int 0x10 遥测服务，只为让人眼也看得到同一句话。
video_print:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0e
    mov bx, 0x0007
    int 0x10
    jmp video_print
.done:
    ret

message: db "Yunooka: boot ok", 13, 10, 0

times 510-($-$$) db 0
dw 0xaa55
