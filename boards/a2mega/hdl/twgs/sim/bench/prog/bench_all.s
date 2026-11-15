; bench_all.s — S7 fast-core benchmark set for tb_cpu_bench (ca65, 65816).
; Seven workloads separated by checkpoint marks.  Every workload self-checks
; a known result (status != 0 on failure); the bench additionally compares the
; DUT against the stock core at every instruction boundary.
;
;   mark 1  sieve      BYTE sieve, 8191 flags, 16-bit zp arithmetic, (zp),Y
;   mark 2  fib16      iterative 16-bit Fibonacci, 512 x 23 additions
;   mark 3  strings    (zp),Y copy + compare, 256 x 64 bytes
;   mark 4  bcd        decimal-mode ADC/SBC sweep (8-bit), flags checked by ref
;   mark 5  stack      recursive Fibonacci, JSR/RTS/PHA/PLX, stack-relative ADC
;   mark 6  interp     bytecode interpreter, JMP (abs,X) dispatch
;   mark 7  native     16-bit native mode: copy, sum, MVN, shift-add mul, 16-bit BCD
;   mark 8  corners    BIT #imm, direct page,X in emulation mode with DL = 0 and
;                      DL != 0, RTL in emulation mode at the top of page 1
.setcpu "65816"

BENCH_DONE = $BFF0
BENCH_PUTC = $BFF1
BENCH_MARK = $BFF2

FLAGS   = $2000         ; 8192 bytes
STRBUF  = $4000
ISTACK  = $4100         ; interpreter operand stack
NATSRC  = $5000         ; 4 KB
NATDST  = $6000         ; 4 KB
BCDBUF  = $7000         ; decimal sweep results

.segment "ZEROPAGE"
ptr:    .res 2
ptr2:   .res 2
i:      .res 2
k:      .res 2
prime:  .res 2
count:  .res 2
fa:     .res 2
fb:     .res 2
tmp:    .res 2
cnt:    .res 2
status: .res 1
bcd:    .res 2
ip:     .res 2
isp:    .res 1
icount: .res 1
result: .res 1
opa:    .res 1
opb:    .res 1
n_sum:  .res 2
n_mul:  .res 2
n_mula: .res 2
n_mulb: .res 2

.macro MARK n
    lda #n
    sta BENCH_MARK
.endmacro

.macro FAIL n
    lda #n
    sta status
.endmacro

; a byte RTL may pull at offset pos above $0100: in page 1 (wrapped), and in page 2
; where the pull runs over the top of the page
.macro PUTB val, pos
    lda #val
    sta $0100 + ((pos) & $FF)
    .if (pos) > $FF
    sta $0100 + (pos)
    .endif
.endmacro
; RTL in emulation mode with the stack pointer at $01xx
.macro RTLT spl
    .local back
    PUTB <(back - 1), spl + 1
    PUTB >(back - 1), spl + 2
    PUTB 0, spl + 3
    ldx #spl
    txs
    rtl
back:
.endmacro

.segment "CODE"

reset:
    sei
    cld
    ldx #$FF
    txs
    stz status
    ldx #0
@banner:
    lda banner,x
    beq @go
    sta BENCH_PUTC
    inx
    bra @banner
@go:
    jsr sieve
    MARK 1
    jsr fib16
    MARK 2
    jsr strings
    MARK 3
    jsr bcdtest
    MARK 4
    jsr stacktest
    MARK 5
    jsr interp
    MARK 6
    jsr native
    MARK 7

;----------------------------------------------------------------- 8 corners
; At the top level: it moves the stack pointer.  Nothing here checks a result of
; its own; the stock core is the reference, step by step.
    ; BIT #imm: the one instruction that loads Z and nothing else
    lda #$0F
    bit #$F0                ; Z set
    bit #$01                ; Z clear
    lda #$C0
    bit #$3F                ; Z set, N and V stay
    sec
    bit #$80                ; Z clear, C stays
    clc
    xce
    rep #$30
    .a16
    .i16
    lda #$00FF
    bit #$FF00
    bit #$0001
    sep #$30
    .a8
    .i8
    sec
    xce
    ; direct page,X in emulation mode: DL = 0 wraps in the page ...
    ldx #$20
    ldy #$30
    lda $F0,x               ; $0010
    lda ($F0,x)             ; pointer at $0010
    ldx $F0,y               ; $0020
    ldx #$20
    ora $E8,x               ; $0008
    cmp ($F4,x)
    ; ... DL != 0 does not (D = $0180: $0180 + $F0 + $20 = $0290)
    lda #$01
    xba
    lda #$80
    tcd
    lda $F0,x
    lda ($F0,x)
    ldx $F0,y
    ldx #$20
    ora $E8,x
    lda #$00
    xba
    lda #$00
    tcd
    ; RTL in emulation mode with the stack pointer at the top of page 1
    RTLT $FB
    RTLT $FC
    RTLT $FD
    RTLT $FE
    RTLT $FF
    RTLT $00
    RTLT $7F
    ldx #$FF
    txs
    MARK 8
    lda status
    sta BENCH_DONE
hang:
    bra hang

trap:                       ; any unexpected vector
    sep #$20
    lda #$EE
    sta BENCH_DONE
    bra trap

;----------------------------------------------------------------- 1 sieve
sieve:
    lda #<FLAGS
    sta ptr
    lda #>FLAGS
    sta ptr+1
    ldx #32
    lda #1
    ldy #0
@fill:
    sta (ptr),y
    iny
    bne @fill
    inc ptr+1
    dex
    bne @fill
    stz count
    stz count+1
    stz i
    stz i+1
@outer:
    lda i
    sta ptr
    lda i+1
    clc
    adc #>FLAGS
    sta ptr+1
    lda (ptr)
    beq @next
    lda i                   ; prime = i + i + 3
    asl
    sta prime
    lda i+1
    rol
    sta prime+1
    lda prime
    clc
    adc #3
    sta prime
    bcc :+
    inc prime+1
:   lda i                   ; k = i + prime
    clc
    adc prime
    sta k
    lda i+1
    adc prime+1
    sta k+1
@inner:
    lda k+1                 ; while k < 8191
    cmp #>8191
    bcc @ok
    bne @innerdone
    lda k
    cmp #<8191
    bcs @innerdone
@ok:
    lda k
    sta ptr2
    lda k+1
    clc
    adc #>FLAGS
    sta ptr2+1
    lda #0
    sta (ptr2)
    lda k
    clc
    adc prime
    sta k
    lda k+1
    adc prime+1
    sta k+1
    bra @inner
@innerdone:
    inc count
    bne @next
    inc count+1
@next:
    inc i
    bne :+
    inc i+1
:   lda i+1
    cmp #>8191
    bcc @outer
    lda i
    cmp #<8191
    bcc @outer
    lda count
    cmp #<1899
    bne @bad
    lda count+1
    cmp #>1899
    bne @bad
    rts
@bad:
    FAIL 1
    rts

;----------------------------------------------------------------- 2 fib16
fib16:
    lda #0
    sta cnt
    lda #2
    sta cnt+1               ; 512 repetitions
@rep:
    stz fa
    stz fa+1
    lda #1
    sta fb
    stz fb+1
    ldx #23
@loop:
    clc
    lda fa
    adc fb
    sta tmp
    lda fa+1
    adc fb+1
    sta tmp+1
    lda fb
    sta fa
    lda fb+1
    sta fa+1
    lda tmp
    sta fb
    lda tmp+1
    sta fb+1
    dex
    bne @loop
    dec cnt
    bne @rep
    dec cnt+1
    bne @rep
    lda fb                  ; fib(24) = 46368 = $B520
    cmp #$20
    bne @bad
    lda fb+1
    cmp #$B5
    bne @bad
    rts
@bad:
    FAIL 2
    rts

;----------------------------------------------------------------- 3 strings
strings:
    lda #<msg
    sta ptr
    lda #>msg
    sta ptr+1
    lda #<STRBUF
    sta ptr2
    lda #>STRBUF
    sta ptr2+1
    ldx #0                  ; 256 repetitions
@rep:
    ldy #63
@cp:
    lda (ptr),y
    sta (ptr2),y
    dey
    bpl @cp
    ldy #63
@cmp:
    lda (ptr2),y
    cmp (ptr),y
    bne @bad
    dey
    bpl @cmp
    dex
    bne @rep
    rts
@bad:
    FAIL 3
    rts

;----------------------------------------------------------------- 4 bcd
; (a) 1000 decimal increments then 1000 decrements of a 4-digit counter
; (b) sweep: opa = 0..255, opb = 0,17,34,..,255; ADC and SBC with carry 0/1;
;     results stored to BCDBUF (write stream + flags compared against ref)
bcdtest:
    sed
    stz bcd
    stz bcd+1
    ldy #4
@o1:
    ldx #250
@i1:
    clc
    lda bcd
    adc #1
    sta bcd
    lda bcd+1
    adc #0
    sta bcd+1
    dex
    bne @i1
    dey
    bne @o1
    cld
    lda bcd
    bne @bad
    lda bcd+1
    cmp #$10
    bne @bad
    sed
    ldy #4
@o2:
    ldx #250
@i2:
    sec
    lda bcd
    sbc #1
    sta bcd
    lda bcd+1
    sbc #0
    sta bcd+1
    dex
    bne @i2
    dey
    bne @o2
    cld
    lda bcd
    ora bcd+1
    bne @bad
    ; (b) sweep
    lda #<BCDBUF
    sta ptr
    lda #>BCDBUF
    sta ptr+1
    stz opa
@sa:
    stz opb
@sb:
    ldy #0
    sed
    clc
    lda opa
    adc opb
    sta (ptr),y
    iny
    php
    pla
    sta (ptr),y
    iny
    sec
    lda opa
    adc opb
    sta (ptr),y
    iny
    sec
    lda opa
    sbc opb
    sta (ptr),y
    iny
    php
    pla
    sta (ptr),y
    iny
    clc
    lda opa
    sbc opb
    sta (ptr),y
    cld
    lda opb
    clc
    adc #17
    sta opb
    bcc @sb
    inc opa
    bne @sa
    rts
@bad:
    cld
    FAIL 4
    rts

;----------------------------------------------------------------- 5 stack
stacktest:
    ; PLB / PLD / TSX / TXS coverage (emulation mode): the fast core
    ; pre-decodes these opcodes' flag-load specials into the microcode
    tsx                     ; N/Z from SP (8-bit X)
    lda #$00
    pha
    plb                     ; DBR = 0, Z set
    lda #$80
    pha
    plb                     ; DBR = $80, N set
    lda #$00
    pha
    plb                     ; back to bank 0
    lda #$12
    pha                     ; high byte first: PLD pulls low from SP+1, high from SP+2
    lda #$34
    pha
    pld                     ; D = $1234 (N/Z from $1234)
    tdc
    cmp #$34
    bne @bad_d
    pea $0000
    pld                     ; D back to 0
    ldy #20
@rep:
    lda #13
    jsr rfib                ; fib(13) = 233
    cmp #233
    bne @bad
    dey
    bne @rep
    rts
@bad_d:
    pea $0000
    pld                     ; restore D so the status write lands in zero page
@bad:
    FAIL 5
    rts

rfib:                       ; A = n -> A = fib(n), 8-bit, recursive
    cmp #2
    bcc @ret
    pha                     ; [n]
    dec a
    jsr rfib                ; A = fib(n-1)
    plx                     ; X = n
    pha                     ; [fib(n-1)]
    txa
    dec a
    dec a
    jsr rfib                ; A = fib(n-2)
    clc
    adc 1,s                 ; + fib(n-1)  (stack-relative)
    plx
@ret:
    rts

;----------------------------------------------------------------- 6 interp
; bytecode: 0 PUSH imm8 | 1 ADD | 2 DUP | 3 DJNZ abs16 | 4 HALT | 5 STORE
interp:
    lda #20
    sta cnt
irep:
    lda #200
    sta icount
    stz isp
    lda #<bytecode
    sta ip
    lda #>bytecode
    sta ip+1
idispatch:
    lda (ip)
    asl
    tax
    jmp (optab,x)
op_push:
    jsr ip_inc
    lda (ip)
    ldy isp
    sta ISTACK,y
    inc isp
    jsr ip_inc
    bra idispatch
op_add:
    ldy isp
    dey
    lda ISTACK,y
    dey
    clc
    adc ISTACK,y
    sta ISTACK,y
    iny
    sty isp
    jsr ip_inc
    bra idispatch
op_dup:
    ldy isp
    dey
    lda ISTACK,y
    iny
    sta ISTACK,y
    iny
    sty isp
    jsr ip_inc
    bra idispatch
op_djnz:
    dec icount
    beq @fall
    ldy #1
    lda (ip),y
    tax
    iny
    lda (ip),y
    sta ip+1
    stx ip
    bra idispatch
@fall:
    jsr ip_inc
    jsr ip_inc
    jsr ip_inc
    bra idispatch
op_store:
    ldy isp
    dey
    lda ISTACK,y
    sta result
    sty isp
    jsr ip_inc
    bra idispatch
op_halt:
    lda result              ; stack [3k, 3] after k=200 -> ADD = 603 mod 256 = $5B
    cmp #$5B
    bne @bad
    dec cnt
    beq @done
    jmp irep
@done:
    rts
@bad:
    FAIL 6
    rts

ip_inc:
    inc ip
    bne :+
    inc ip+1
:   rts

optab:
    .word op_push, op_add, op_dup, op_djnz, op_halt, op_store

;----------------------------------------------------------------- 7 native
native:
    clc
    xce                     ; native mode
    rep #$30
    .a16
    .i16
    ldx #0
@f:
    txa
    eor #$A5C3
    sta NATSRC,x
    inx
    inx
    cpx #4096
    bne @f
    ldy #4
@rep:
    ldx #0
@c:
    lda NATSRC,x
    sta NATDST,x
    inx
    inx
    cpx #4096
    bne @c
    dey
    bne @rep
    lda #0
    ldx #0
@s:
    clc
    adc NATDST,x
    inx
    inx
    cpx #4096
    bne @s
    sta n_sum
    ldx #NATSRC             ; MVN 4096 bytes bank 0 -> bank 0
    ldy #NATDST
    lda #4095
    .byte $54, $00, $00
    lda NATDST
    cmp NATSRC
    bne @bad
    lda NATDST+4094
    cmp NATSRC+4094
    bne @bad
    ldy #200
@m:
    tya
    eor #$1234
    sta n_mula
    tya
    clc
    adc #$57
    sta n_mulb
    jsr mul16
    dey
    bne @m
    tsx                     ; 16-bit TSX
    pea $8000
    pld                     ; D = $8000 (N set)
    pea $0000
    pld                     ; D = 0 (Z set)
    phb
    plb
    sed                     ; 16-bit decimal
    lda #$1234
    sta bcd
    ldx #256
@d:
    clc
    lda bcd
    adc #$0199
    sta bcd
    sec
    lda bcd
    sbc #$0098
    sta bcd
    dex
    bne @d
    cld
    sep #$30
    .a8
    .i8
    sec
    xce
    rts
@bad:
    .a16
    .i16
    sep #$30
    .a8
    .i8
    sec
    xce
    FAIL 7
    rts

mul16:                      ; n_mul = n_mula * n_mulb (low 16 bits), 16-bit mode
    .a16
    .i16
    lda #0
    sta n_mul
    ldx #16
@l:
    lsr n_mulb
    bcc @skip
    lda n_mul
    clc
    adc n_mula
    sta n_mul
@skip:
    asl n_mula
    dex
    bne @l
    rts
    .a8
    .i8

.segment "RODATA"
banner: .byte "cpu_bench", 10, 0
msg:    .byte "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 0123456789 ABCDEFGHIJKLMNOP"
bytecode:
    .byte 0, 1              ; PUSH 1
    .byte 0, 2              ; PUSH 2
bc_loop:
    .byte 1                 ; ADD
    .byte 0, 3              ; PUSH 3
    .byte 3                 ; DJNZ bc_loop
    .word bc_loop
    .byte 1                 ; ADD
    .byte 5                 ; STORE
    .byte 4                 ; HALT

.segment "VECTORS"
    ; native: COP BRK ABORT NMI (res) IRQ @ FFE4..FFEF
    .word trap, trap, trap, trap, trap, trap
    ; emulation: (res) (res) COP (res) ABORT NMI RESET IRQ @ FFF0..FFFF
    .word trap, trap, trap, trap, trap, trap, reset, trap
