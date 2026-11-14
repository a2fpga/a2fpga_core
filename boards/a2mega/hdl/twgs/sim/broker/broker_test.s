; broker_test.s - traffic generator for the S7 broker bench (tb_gs_broker.sv)
;
; Built by run_gs_broker_sim.sh (ca65 / ld65, broker_rom.cfg) into a 128 KB
; ROM image laid out like a ROM 01: bank FE, then bank FF.  The bench loads
; it into the card's ROM image AND into the motherboard / reference machine
; models, exactly as the real ROM would be (scoping doc 2.6).
;
; The program runs in bank FF in native mode, so nothing it does to the
; bank-00/01 map (language card, RAMRD, ALTZP, IOLC inhibit) moves the code
; under it.  It walks every kind of access the broker has to place - local
; RAM and ROM, forwarded (shadowed) writes back to back, posted writes with a
; socket read right behind them, I/O, R-M-W on I/O, banks E0/E1, the
; language card, aux memory, STATEREG, block moves, slot space, IOLC inhibit,
; all-banks shadow, a BRK through the interrupt-dispatch ROM - and stores
; what it read in $0300... .  It does not judge the results itself: a
; lockstep reference core on an ideal machine does (every byte the broker
; delivers is compared), and the bench checks a few of the stored values and
; the signature at $037F.
;
; The comments give the byte each "res" is expected to store.

        .p816
        .a8
        .i8

RES     = $0300
SIG     = $037F                 ; $A5 when the walk is complete
IRQCNT  = $0380                 ; incremented by the IRQ handler
BRKCNT  = $0381                 ; incremented by the BRK handler
WAIFLG  = $0382                 ; set once the loop has waited in WAI
EXPFLG  = $0383                 ; set by T22 if the machine has RAM in bank 02
TOPFLG  = $0384                 ; set by T24 if the machine has RAM in bank 7F
HIFLG   = $0385                 ; set by T23 if the machine has RAM in bank 04
LOOPCNT = $0390

resn    .set 0
.macro  res
        sta RES + resn
        resn .set resn + 1
.endmacro

; ---------------------------------------------------------------- bank FE
.segment "FEDATA"
        .res $1000, $FE
        .byte $E1, $E2, $E3, $E4

; ---------------------------------------------------------------- bank FF, main
.segment "MAIN"
main:
        stz SIG                 ; (the walk also runs again after a warm reset)
        stz IRQCNT
        stz BRKCNT
        stz WAIFLG
        stz EXPFLG
        stz TOPFLG
        stz HIFLG
        lda #$80
        sta $C036               ; FPI fast mode

        ; ---- T1 local RAM, zero page, stack
        lda #$55
        sta $0200
        lda #$AA
        sta $0201
        lda $0200
        clc
        adc $0201
        res                     ; $FF
        sta $10
        inc $10
        lda $10
        res                     ; $00
        lda #$5C
        pha
        lda #$00
        pla
        res                     ; $5C

        ; ---- T2 text page 1: forwarded writes back to back, read back at once
        ldx #$00
t2:     txa
        sta $0400,x
        inx
        cpx #$40
        bne t2
        lda $043F               ; just posted: the card's own byte
        res                     ; $3F
        inc $0410               ; R-M-W on a forwarded location
        lda $0410
        res                     ; $11

        ; ---- T3 a socket read right behind a posted write must not overtake it
        lda #$C3
        sta $0420
        lda $E00420             ; the Mega II copy the FPI just made
        res                     ; $C3
        lda #$3C
        sta $0421
        lda $C022               ; I/O read behind a posted write
        lda $E00421
        res                     ; $3C

        ; ---- T4 I/O register file: write, read, R-M-W (internal cycle in I/O space)
        lda #$A5
        sta $C022
        lda $C022
        res                     ; $A5
        inc $C022
        lda $C022
        res                     ; $A6
        lda #$01
        tsb $C022
        lda $C022
        res                     ; $A7

        ; ---- T5 Mega II RAM, hires shadow
        lda #$77
        sta $E12000
        lda $E12000
        res                     ; $77
        lda #$5A
        sta $2000               ; hires page 1: forwarded
        sta $4000               ; hires page 2: forwarded
        sta $6000               ; not shadowed from bank 00
        lda $E02000
        res                     ; $5A
        lda $E04000
        res                     ; $5A
        lda $E06000
        res                     ; $00

        ; ---- T6 SHADOW inhibit bits
        lda #$09                ; text page 1 inhibited
        sta $C035
        lda #$EE
        sta $0430               ; stays on the card
        lda $E00430
        res                     ; $00
        lda $0430
        res                     ; $EE
        lda #$0E                ; hires 1 + 2 inhibited, text on
        sta $C035
        lda #$11
        sta $2001
        sta $0431
        lda $E02001
        res                     ; $00
        lda $E00431
        res                     ; $11
        lda #$08
        sta $C035               ; reset value

        ; ---- T7 aux memory: RAMWRT, RAMRD, 80STORE + PAGE2, ALTZP
        sta $C005               ; RAMWRT on
        lda #$B1
        sta $0800               ; -> 01/0800
        sta $2002               ; -> 01/2002, aux hires: forwarded, shadowed to E1
        sta $C004
        lda $0800
        res                     ; $00 (main)
        lda $010800
        res                     ; $B1
        lda $E12002
        res                     ; $B1
        sta $C003               ; RAMRD on
        lda $0800
        res                     ; $B1 (aux)
        sta $C002
        sta $C001               ; 80STORE on
        sta $C055               ; PAGE2: text page 1 is aux
        lda #$B2
        sta $0440               ; -> 01/0440, shadowed to E1
        sta $C054
        lda $0440
        res                     ; $00 (main)
        lda $E10440
        res                     ; $B2
        sta $C000               ; 80STORE off
        sta $C009               ; ALTZP on
        lda #$B3
        sta $20                 ; -> 01/0020
        sta $C008
        lda $20
        res                     ; $00
        lda $010020
        res                     ; $B3

        ; ---- T8 super hi-res shadow (bank 01 $2000-$9FFF)
        lda #$00
        sta $C035               ; everything shadowed
        lda #$C8
        sta $017000
        lda $E17000
        res                     ; $C8
        lda #$08
        sta $C035
        lda #$C9
        sta $017001             ; inhibited again: stays on the card
        lda $E17001
        res                     ; $00
        lda $017001
        res                     ; $C9

        ; ---- T9 language card
        lda $C083
        lda $C083               ; RAM bank 2, write-enabled
        lda #$D2
        sta $D000
        lda #$E2
        sta $E000
        lda $C08B
        lda $C08B               ; RAM bank 1
        lda #$D1
        sta $D000
        lda $D000
        res                     ; $D1
        lda $E000
        res                     ; $E2
        lda $C083
        lda $C083
        lda $D000
        res                     ; $D2
        lda $C080               ; bank 2, write-protected
        lda #$00
        sta $D000               ; discarded
        lda $D000
        res                     ; $D2
        lda $C081               ; ROM read; one read does not write-enable
        lda #$01
        sta $D000               ; discarded
        lda $D000
        res                     ; $D0 (ROM)
        lda $C081               ; the second read does (RAM written under ROM)
        lda #$D3
        sta $D000
        lda $C080
        lda $D000
        res                     ; $D3
        inc $C083               ; R-M-W on the switch: read, read, write = write-enabled
        lda #$D4
        sta $D000
        lda $D000
        res                     ; $D4
        lda $FFFC               ; RAM under the vectors
        res                     ; $00
        lda $C082               ; ROM read, write-protected
        lda $FFFC
        res                     ; low byte of the reset vector

        ; ---- T10 STATEREG
        lda $C068
        res                     ; $0C
        lda #$30                ; RAMRD + RAMWRT, LC RAM read, bank 1
        sta $C068
        lda #$5E
        sta $0900               ; -> aux
        ldx $D000               ; LC bank 1, main (ALTZP off)
        lda #$0C
        sta $C068
        txa
        res                     ; $D1
        lda $010900
        res                     ; $5E

        ; ---- T11 ROM banks, expansion, nothing
        lda $FE1000
        res                     ; $E1
        lda #$42
        sta $FE1000             ; a write to ROM
        lda $FE1001
        res                     ; $E2
        lda $FE1000
        res                     ; $E1
        lda #$21
        sta $020000
        lda $020000
        res                     ; $21 with expansion RAM, else floating
        lda #$22
        sta $03FFFF
        lda $03FFFF
        res
        lda $400000             ; nothing there
        res

        ; ---- T12 block moves
        rep #$30
        .a16
        .i16
        ldx #$0400
        ldy #$3000
        lda #$000F
        .byte $54, $E1, $00     ; MVN: 16 bytes 00/0400 -> E1/3000 (local reads, socket writes)
        ldx #$0300
        ldy #$0480
        lda #$001F
        .byte $54, $00, $00     ; MVN: 32 bytes 00/0300 -> 00/0480 (forwarded, back to back)
        sep #$30
        .a8
        .i8
        lda #$00
        pha
        plb                     ; DBR = 0 again
        lda $E13005
        res                     ; $05
        lda $E00485
        res                     ; copy of RES+5

        ; ---- T13 slot space
        lda $C100
        res                     ; $C1 internal firmware
        lda $C300               ; internal; sets INTC8ROM
        res                     ; $C3
        lda $C800
        res                     ; $C8 internal
        lda $CFFF               ; clears INTC8ROM
        res                     ; $CF
        lda $C800
        res                     ; $FF: a slot card's expansion ROM, and there is none
        sta $C007               ; INTCXROM
        lda $C400
        res                     ; $C4
        lda $C800
        res                     ; $C8
        sta $C006
        lda #$06                ; slots 1 and 2: cards
        sta $C02D
        lda $C100
        res                     ; $FF
        lda $C500
        res                     ; $C5
        lda #$00
        sta $C02D

        ; ---- T14 IOLC inhibit: $C000-$FFFF of banks 00/01 is plain RAM
        lda #$48
        sta $C035
        lda #$1C
        sta $C100
        sta $C035               ; RAM now, not the register
        sta $E001
        lda $C100
        res                     ; $1C
        lda $C035
        res                     ; $1C
        lda $E001
        res                     ; $1C
        lda #$08
        sta $E0C035             ; the register is still reachable through bank E0
        lda $C035
        res                     ; $08

        ; ---- T15 all-banks shadow (CYAREG bit 4)
        lda #$90
        sta $C036
        lda #$A1
        sta $020400             ; bank 02 text page: shadowed to E0
        lda $E00400
        res                     ; $A1
        lda $02C022             ; I/O answers in bank 02
        res                     ; $A7
        lda #$80
        sta $C036

        ; ---- T16 code running from RAM (the common case): a routine copied
        ;      from bank FF to 00/1000 and called there
        stz $0392
        rep #$30
        .a16
        .i16
        ldx #ramcode
        ldy #$1000
        lda #ramcode_end - ramcode - 1
        .byte $54, $00, $FF     ; MVN FF -> 00
        sep #$30
        .a8
        .i8
        jsl $001000
        lda $0392
        res                     ; $28

        ; ---- T16b self-modifying code: a read-modify-write of the NEXT opcode
        ;      byte.  The read of $1105 is the last read launched before the
        ;      write to it, and the next read is the fetch of the same byte: a
        ;      broker that still believed its memory output held $1105 would
        ;      execute the old opcode.
        rep #$30
        .a16
        .i16
        ldx #ramcode2
        ldy #$1100
        lda #ramcode2_end - ramcode2 - 1
        .byte $54, $00, $FF     ; MVN FF -> 00
        sep #$30
        .a8
        .i8
        lda $5105               ; (a cache in front of the memory: same index as $1105,
                                ; so the read of $1105 below has to be fetched again)
        jsl $001100
        txa
        res                     ; $01

        ; ---- T16c an internal cycle aimed at I/O space straight after a LOCAL step:
        ;      abs,X with a 16-bit index always has one, here at $C0xx, and the
        ;      operand fetch before it comes from the card's ROM image.  The broker
        ;      has that step's status a step ahead and must still substitute the
        ;      previous address for it, not put a new I/O address on the bus.
        rep #$10
        .i16
        ldx #$0022
        lda $C000,x             ; = $C022
        sep #$10
        .i8
        res

        ; ---- T18 one byte, two addresses: $C000-$CFFF of bank 00 is the language
        ;      card's bank 1 (seen at $Dxxx) and, with IOLC shadowing inhibited,
        ;      plain RAM at $Cxxx.  Written and read both ways round (a cache in
        ;      front of the card's memory must keep ONE copy of it).
        lda $C08B
        lda $C08B               ; RAM bank 1, write-enabled
        lda #$A5
        sta $D123               ; physical $C123
        lda $D123
        res                     ; $A5
        lda #$48
        sta $C035               ; IOLC inhibited
        lda #$5A
        sta $C123               ; the same byte, as plain RAM
        lda #$08
        sta $E0C035
        lda $D123               ; bank 1 again
        res                     ; $5A
        lda #$48
        sta $C035
        lda $C123
        res                     ; $5A
        lda $D123
        res                     ; $00: plain RAM at $D123 now
        lda #$08
        sta $E0C035
        lda $C082

        ; ---- T19 a read that goes to one bank while writes go to the other
        ;      (RAMRD without RAMWRT), of an address last written in the other
        sta $C005               ; RAMWRT on
        lda #$22
        sta $6100               ; -> 01/6100
        sta $C004
        lda #$11
        sta $6100               ; -> 00/6100
        sta $C003               ; RAMRD on
        lda $6100
        res                     ; $22 (aux)
        sta $C002
        lda $6100
        res                     ; $11 (main)

        ; ---- T20 the two ROM banks at one address (a cache in front of the ROM
        ;      image keeps them apart by the bank, here in both orders)
        lda $FE1000
        res                     ; $E1
        lda $FF1000
        res                     ; whatever bank FF holds there (the reference decides)
        lda $FE1000
        res                     ; $E1
        lda $FE1001
        lda $FF1001
        lda $FE1001
        res                     ; $E2

        ; ---- T17 BRK with the language card in RAM: the vector comes from ROM
        ;      (VP) and leads to the dispatch bytes at $C071
        lda $C083
        lda $C083
        brk
        .byte $EA
        lda $C082
        lda BRKCNT
        res                     ; $01

        ; ---- T21 code and 16-bit data in a Mega II bank: socket cycles back to
        ;      back (opcode and operand fetches, two-byte reads and writes, a
        ;      16-bit R-M-W), with internal cycles and stack pushes between
        lda #$34
        sta $E16100
        lda #$12
        sta $E16101
        ldx #megacode_end - megacode - 1
t21:    lda f:$FF0000 + megacode,x
        sta $E16000,x
        dex
        bpl t21
        jsl $E16000
        res                     ; $36
        lda $E16103
        res                     ; $13
        ldx #megaloop_end - megaloop - 1
t21b:   lda f:$FF0000 + megaloop,x
        sta $E16040,x           ; (the steady-state loop calls it, with interrupts on)
        dex
        bpl t21b

        ; ---- T22 code in an expansion bank, where the machine has one (the card's
        ;      own memory if it backs the bank, socket cycles if it does not)
        lda #$5A
        sta $026100
        lda $026100
        cmp #$5A
        bne t22n                ; nothing there
        ldx #megaloop_end - megaloop - 1
t22:    lda f:$FF0000 + megaloop,x
        sta $026040,x
        dex
        bpl t22
        inc EXPFLG
        ; the same near-memory indexes read in bank 00: what a cache in front of the
        ; card's memory holds of 02/6040.. and 02/6100 goes, and the code and the byte
        ; are then read from the expansion memory itself
        ldx #megaloop_end - megaloop - 1
t22e:   lda $6040,x
        dex
        bpl t22e
        lda $6100               ; bank 00's own byte, untouched by the write to 02/6100
        sta $E16105             ; (on the socket: the byte the card's memory gave)
        lda $026100
        sta $E16104             ; (likewise)
        res                     ; $5A (written only with a bank 02)
        ; a block move into the bank: writes as fast as a program makes them (a memory
        ; that takes them more slowly fills the queue in front of it)
        rep #$30
        .a16
        .i16
        ldx #$0300
        ldy #$7000
        lda #$005F
        .byte $54, $02, $00     ; MVN: 96 bytes 00/0300 -> 02/7000
        sep #$30
        .a8
        .i8
        lda #$00
        pha
        plb                     ; (the move left the data bank at 02)
        lda $7010               ; bank 00's 7010: the entry of 02/7010 goes
        lda $027010
        sta $E16109
        jsl $026040             ; comes back with $E16100
        bra t22r
t22n:   lda #$00
        res                     ; $00 (written only without a bank 02)
        lda #$00
t22r:   res                     ; $34, or $00 without a bank 02

        ; ---- T23 banks above 03, where the machine has them: a cache in front of the
        ;      card's memory must keep 04/6100 and 08/6100 apart from 00/6100 and from
        ;      each other - they share its index and the low bits of its tag
        lda #$C3
        sta $046100
        lda $046100
        cmp #$C3
        bne t23n
        lda $6100               ; bank 00's byte, not 04's
        sta $E16106             ; (on the socket)
        res                     ; $11 (written only with a bank 04)
        ; code and its data in bank 04, called from the loop: a program loaded above
        ; bank 03, where no step is one of the cheap view's
        ldx #hicode_end - hicode - 1
t23c:   lda f:$FF0000 + hicode,x
        sta $046040,x
        dex
        bpl t23c
        inc HIFLG
        lda #$3C
        sta $086100
        lda $086100
        cmp #$3C
        bne t23n
        lda $046100             ; 04's byte, not 08's
        sta $E16107
        res                     ; $C3 (written only with a bank 08)
        lda $086100
        sta $E16108
t23n:

        ; ---- T24 the top 16K of bank 7F, where the machine has it: the last RAM a card
        ;      can hold, and the highest tag a RAM entry of a cache in front of the
        ;      card's memory can have.  A byte there is read before anything wrote it
        ;      (a cache with no entry for it must not answer), and again in the loop
        ;      (a ROM copy empties the cache: the byte is then the memory's alone)
        lda $7FD955             ; never written
        sta $E1610A             ; (on the socket)
        lda #$7E
        sta $7FE100
        lda $7FE100
        cmp #$7E
        bne t24n
        inc TOPFLG
        lda $6100               ; bank 00's byte: the entry of 7F/E100 goes
        lda $7FE100
        res                     ; $7E (written only with a bank 7F)
t24n:

        lda #$A5
        sta SIG
        cli

        ; ---- steady state: mostly local, with a forwarded write, an I/O read
        ;      and a Mega II write per pass
loop:   inc LOOPCNT
        lda LOOPCNT
        sta $0450               ; forwarded
        ldx #$18
spin:   dex
        bne spin
        lda $C022               ; I/O
        sta $E10450             ; Mega II
        jsl $E16040             ; a few instructions run from the Mega II bank
        lda EXPFLG
        beq noexp
        lda $6040               ; (its first two bytes out of a cache in front of the card's memory)
        lda $6041
        jsl $026040             ; ... and from the expansion bank
noexp:
        lda TOPFLG
        beq notop
        lda $7FE100             ; the top of bank 7F
        sta $E10451             ; (on the socket)
        lda $7FD955             ; ... and a byte of it nothing has written
        sta $E10452
notop:
        lda HIFLG
        beq nohi
        jsl $046040             ; code and data in bank 04
nohi:
        inc LOOPCNT+1
        ; once, after the first interrupt has been served: wait in WAI for the
        ; second (runs without interrupts never get here)
        lda IRQCNT
        cmp #$01
        bne nowai
        lda WAIFLG
        bne nowai
        inc WAIFLG
        wai
nowai:  jmp loop

; copied to RAM by T16
ramcode:
        ldx #$28
rcl:    inc $0392
        dex
        bne rcl
        rtl
ramcode_end:

; copied to E1/6000 by T21
megacode:
        phb
        lda #$E1
        pha
        plb                     ; data bank E1
        rep #$20
        .a16
        lda $6100               ; $1234
        clc
        adc #$0101
        sta $6102               ; $1335
        inc $6102               ; $1336: a 16-bit R-M-W in the Mega II bank
        sep #$20
        .a8
        ldx #$40
mcl:    dex
        bne mcl
        lda $6102
        plb
        rtl
megacode_end:

; copied to E1/6040 by T21 and to 02/6040 by T22: eight-bit code only, so an interrupt can land in it
megaloop:
        ldx #$06
mll:    dex
        bne mll
        lda $E16100
        rtl
megaloop_end:

; copied to 04/6040 by T23: eight-bit code, its data in its own bank
hicode:
        phb
        lda #$04
        pha
        plb                     ; data bank 04
        ldx #$02
hcl:    inc $6200               ; a R-M-W in the bank
        lda $6200
        sta $6201
        dex
        bne hcl
        plb
        rtl
hicode_end:

; copied to RAM at $1100 by T16b
ramcode2:
        ldx #$00
        inc $1100 + smc - ramcode2      ; $E7 -> $E8
smc:    .byte $E7                       ; runs as INX
        rtl
ramcode2_end:

; interrupt handlers (bank FF, entered through the dispatch bytes)
irq_handler:
        pha
        phb
        lda #$00
        pha
        plb
        inc IRQCNT
        sta $C047               ; acknowledge: the bench's device releases /IRQ
        plb
        pla
        rti

brk_handler:
        pha
        inc BRKCNT
        pla
        rti

; ---------------------------------------------------------------- $C071: dispatch ROM
.segment "IRQROM"
        jml $FF0000 + brk_handler       ; $C071
        jml $FF0000 + irq_handler       ; $C075

; ---------------------------------------------------------------- $C100-$CFFF: "firmware"
.segment "CX"
        .repeat 15, i
        .res 256, $C1 + i
        .endrepeat

; ---------------------------------------------------------------- $D000: ROM under the language card
.segment "DROM"
        .res $2000, $D0

; ---------------------------------------------------------------- boot (seen at 00/F000 through the ROM window)
.segment "BOOT"
reset:
        sei
        cld
        ldx #$FF
        txs                     ; S = $01FF while still in emulation mode
        clc
        xce                     ; native, 8-bit A/X/Y
        jml $FF0000 + main

.segment "VECTORS"
        .word $0000             ; FFE4 COP    (native)
        .word $C071             ; FFE6 BRK
        .word $0000             ; FFE8 ABORT
        .word $0000             ; FFEA NMI
        .word $0000             ; FFEC
        .word $C075             ; FFEE IRQ
        .word $0000, $0000      ; FFF0, FFF2
        .word $0000             ; FFF4 COP    (emulation)
        .word $0000             ; FFF6
        .word $0000             ; FFF8 ABORT
        .word $0000             ; FFFA NMI
        .word reset             ; FFFC RESET
        .word $C075             ; FFFE IRQ/BRK
