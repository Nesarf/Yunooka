; Yunooka 的加载器：引导扇区只读这八个扇区，而它把主体读到 0x10000 再跳过去。
;
; 为什么要有这一层：引导扇区那一次 int 0x13 不能跨 64 KB DMA 边界，而主体原先从
; 0x7E00 起 —— 于是它最多 64 个扇区（0xFE00 就到界）。主体长到 32768 字节的那一天
; 那条界顶住了，而症状是「引导读了、内容却不对」，看起来像主体自己崩了。
;
; 加一层之后，主体住在 0x10000。上限先是 0x20000（一百二十八个扇区），而那是种子
; 当时的地盘；种子搬到 0x70000 之后，这里读三批、每批 64 个扇区，上限就到 0x28000
; （一百九十二个扇区）。再要长就得加第四批 —— 第四批现在故意没有：加它只是多一次
; int 0x13，而眼下没有人需要那六十四格。
;
; 编译：nasm -f bin loader.asm -o loader.bin（上限 8 个扇区，4096 字节）

[org 0x7e00]
[bits 16]

loader:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    ; 这里**不** sti。与 long_entry 那一句同一个道理：从这儿到主体装好 IDT 之前，
    ; 任何中断都没有处理者。主体自己会在设好栈之后 sti。
    mov [drive], dl                ; 引导跳过来时 dl 还带着盘号

    ; 开 A20。主体要读到 0x10000 以上，而 0x10000 就是 A20 那条线 —— 不开的话
    ; BIOS 的 int 0x13 会拒绝那一次读，或者更糟：静默回绕到 0。
    ; 这一版用 BIOS 的 int 0x15 / ax=0x2401，不走 8042 那一路 —— 那一路在
    ; VirtualBox 上会把 out 卡住（主体里那段注释记着这件事）。
    mov ax, 0x2401
    int 0x15

    ; 两次读都用 LBA 模式（AH=0x42），不用 CHS（AH=0x02）。两个理由，都是踩出来的：
    ;
    ; 一、CHS 的扇区号只到 63 —— 而 CL 的高两位其实是柱面号的一部分。第一版把
    ;     「第 74 号扇区」写成 cl = 74，于是柱面成了 1、扇区成了 11，而 int 0x13
    ;     返回 AH=0x01（看起来像参数写错了）。
    ; 二、一次读不能跨磁道，而 int 0x13 在磁道末尾就停 —— 它**不报错**，只在 AL
    ;     里返回实际读了多少。第一版第一批「成功」了，而它只读了 54 个扇区而不是 64。
    ;
    ; LBA 没有这两个问题：它按线性扇区号给，一段一段读到底。
    ;
    ; 第一批：LBA 9（从 0 数）= 主体第 0 扇区，64 个扇区，到 0x10000
    mov word [dap_count], 64
    mov word [dap_off], 0
    mov word [dap_seg], 0x1000
    mov dword [dap_lba], 9
    mov dword [dap_lba + 4], 0
    mov byte [dbg], '1'
    mov si, dap
    mov dl, [drive]
    mov ah, 0x42
    int 0x13
    jc fail

    ; 第二批：LBA 73（9 + 64），64 个扇区，到 0x18000
    mov word [dap_seg], 0x1800
    mov dword [dap_lba], 73
    mov byte [dbg], '2'
    mov si, dap
    mov dl, [drive]
    mov ah, 0x42
    int 0x13
    jc fail

    ; 第三批：LBA 137（9 + 128），64 个扇区，到 0x20000
    ;
    ; 后面两批是「第二段从小房子搬到大房子」那天加的。原先两批刚好铺满 0x10000 到
    ; 0x20000，而那是种子的地盘 —— 于是主体最多一百二十八个扇区，最后只剩两百来个
    ; 字节可以写。种子搬到 0x70000 之后，这里就能一直往上数。
    mov word [dap_seg], 0x2000
    mov dword [dap_lba], 137
    mov byte [dbg], '3'
    mov si, dap
    mov dl, [drive]
    mov ah, 0x42
    int 0x13
    jc fail

    ; 跳进主体。段寄存器也一起拨过去 —— 主体一开头会重设它们，但这里不该留一份
    ; 指向加载器自己的 ds 给它收拾。
    mov ax, 0x1000
    mov ds, ax
    mov es, ax
    jmp 0x1000:0x0000

fail:
    ; 失败要说话，而且要说出**为什么** —— 「loader failed」与「loader failed 0x0C」
    ; 是两条完全不同的消息。int 0x13 失败时 AH 是错误码，@ 后面是第几批。
    ; 这里只用最小的串口写：不查 LSR，因为这时什么初始化都还没做过。
    mov [err], ah
    mov si, line_fail
.puts:
    lodsb
    test al, al
    jz .hex
    call .outc
    jmp .puts
.hex:
    mov al, [err]
    shr al, 4
    call .nib
    mov al, [err]
    and al, 0x0F
    call .nib
    mov al, '@'
    call .outc
    mov al, [dbg]
    call .outc
    mov al, 13
    call .outc
    mov al, 10
    call .outc
.hang:
    cli
    hlt
    jmp .hang
.nib:
    cmp al, 10
    jb .num
    add al, 'A' - 10
    jmp .outc
.num:
    add al, '0'
; 打一个字节。要等 LSR 的 THR 空（bit 5）—— 加载器还没初始化过串口（那是主体开头
; 做的一件事），而不查它会把字符挤掉：实测失败那一行少打了前四个字节，还多出乱码，
; 于是那个「错误码」本身就不值得相信。
.outc:
    push ax
    mov dx, 0x3FD
.wlsr:
    in al, dx
    test al, 0x20
    jz .wlsr
    pop ax
    mov dx, 0x3F8
    out dx, al
    ret

; 磁盘地址包。16 字节，字段顺序是 int 0x13 扩展读规定的。
dap: db 16, 0
dap_count: dw 0
dap_off: dw 0
dap_seg: dw 0
dap_lba: dq 0

drive: db 0
err: db 0
dbg: db '?'
line_fail: db "Yunooka: loader failed 0x", 0

; 填到整整八个扇区。这一句不是「凑整」—— 引导扇区按 8 个扇区读这个加载器，而主体的
; 位置从「1 + 8」算起；填到 1 个扇区的话，主体会整体错位七个扇区，而症状是
; 「loader failed」或者更糟：读进来一截别的代码。build 会核对这个数。
times ((($-$$)+4095)/4096)*4096-($-$$) db 0
