; ******************************************************************************
; A2FPGA - STARTROM.S
;
; /INH ROM for A2FPGA startup
;
; This ROM code is used to initialize the A2FPGA board.  It is mapped into
; the 6502 address space at $F800-$FFFF.  The code is executed by the 6502
; at startup time by the A2FPGA board asserting the /INH signal prior to
; releasing the 6502 from reset.  The primary purpose of this code is to
; poll the Apple II keyboard and wait for the FPGA to signal that it is ready
; for the 6502 to resume the normal Apple II boot process.
; ******************************************************************************
;
KBD      =        $C000        ; APPLE KEYBOARD DATA
KBDSTRB  =        $C010        ; KEYBOARD DATA CLEAR
FPGADONE =        $F7FF        ; TBD - SOME MEMORY LOCATION
RESETVEC =        $FFFC        ; JUMP TARGET
SPKR     =        $C030        ; SPEAKER
;
; **************************  INITIALIZE ***************************************
;
        ORG $F800              ; PROGRAM START ADDRESS

RESET   CLD
        ;JSR     BELL            ; RING BELL
        ;JSR     BELL            ; RING BELL
        ;JSR     BELL            ; RING BELL
        
KBDLOOP LDA     KBD             ; TEST KEYBOARD
        BPL     CHKDONE
        BIT     KBDSTRB         ; CLEAR KEYBOARD DATA

CHKDONE LDA     FPGADONE        ; FETCH FPGADONE
        BEQ     KBDLOOP         ; CONTINUE TO LOOP IF FPGADONE IS 0  
        BIT     KBDSTRB         ; CLEAR KEYBOARD DATA
        JMP     (RESETVEC)      ; JUMP TO RESET VECTOR

IRQ     PHA
        TXA
        PHA
                                ; TBD - Interrupt code goes here
        PLA
        TAX
        PLA
        RTI

BELL    LDA     #$40
        JSR     WAIT
        LDY     #$C0
BELL2   LDA     #$0C
        JSR     WAIT
        LDA     SPKR
        DEY
        BNE     BELL2
RTS2B   RTS

WAIT    SEC
WAIT2   PHA
WAIT3   SBC     #$01
        BNE     WAIT3
        PLA
        SBC     #$01
        BNE     WAIT2
        RTS

; Dynamically pad from current address up to $FFFA
        ORG *                  ; Ensure we are at the current location

PAD_SIZE = $FFFA - *           ; Calculate the number of bytes needed to reach $FFFA
        DS PAD_SIZE            ; Reserve the required number of padding bytes

        ORG $FFFA              ; Set up interrupt vectors at the exact memory location
VECTORS DW IRQ                 ; Set NMI vector
        DW RESET               ; Set RESET vector
        DW IRQ                 ; Set IRQ vector
;
; <<EoF>>
;