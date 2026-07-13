; ---------------------------------------------------------------------------
; Copyright 2023 nand2mario
; Copyright 2026 Mateusz Nalewajski
;
; Licensed under the Apache License, Version 2.0 (the "License");
; you may not use this file except in compliance with the License.
; You may obtain a copy of the License at
;
;     http://www.apache.org/licenses/LICENSE-2.0
;
; Unless required by applicable law or agreed to in writing, software
; distributed under the License is distributed on an "AS IS" BASIS,
; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
; See the License for the specific language governing permissions and
; limitations under the License.
;
; SPDX-License-Identifier: Apache-2.0
; ---------------------------------------------------------------------------

cstart:
; ---- start with high impedance
    hiz

; ---- set interrupt transfer interval
    load 13
cstart2:
    wait
    bc connected
    be cstart2

; ---- wait 200ms after device attached
    save 15 0             ; disconnected, reset watchdog
    ldi 200
w200ms:
    wait
    dec
    bnz w200ms

; ---- enumeration sequence
    call reset            ; reset device

; GET_DESCRIPTOR (Device, 0)
    wait
    call sof
    call setup00
    call get_device
    call rcvdt
    ldi 128               ; receive 16 bytes of data from device
    start                 ; mark start of read transaction

; IN(0,0), ACK(), device descriptor
wait_get_device:
    wait
    call sof
    call in00
    call rcvdt2
    bnak wait_get_device
    call sendack
    bnz wait_get_device
; the buffer wraps, start reading from byte 8
    save 0 0              ; idVendor lsb
    save 1 1              ; idVendor msb
    save 2 2              ; idProduct lsb
    save 3 3              ; idProduct msb

; GET_DESCRIPTOR (Configuration, 0)
    wait
    call sof
    call setup00
    call get_config
    call rcvdt
    ldi 144               ; receive up to 18 bytes of data from device
    start                 ; mark start of read transaction

; IN(0,0), ACK(), configuration descriptor
wait_get_config:
    wait
    call sof
    call in00
    call rcvdt2
    bnak wait_get_config
    call sendack
    bnz wait_get_config
; the buffer wraps, start reading from byte 14
    save 4 6               ; interface class
    save 5 7               ; interface sub-class
    save 6 0               ; interface protocol

; ---- initialization sequence
    call reset            ; reset device again

; SET_ADDRESS (0, 1)
    wait
    call sof
    call setup00
    call set_address
    call rcvdt

; IN(0,0), ACK()
wait_set_address:
    wait
    call sof
    call in00
    call rcvdt
    bnak wait_set_address
    call sendack

; SET_CONFIGURATION (1, 1)
    wait
    call sof
    call setup10
    call set_config
    call rcvdt

; IN(1,0), ACK()
wait_set_config:
    wait
    call sof
    call in10
    call rcvdt
    bnak wait_set_config
    call sendack

; HID SET_IDLE/SET_PROTOCOL/report-descriptor path removed to fit
; XInput/SN30 init; keyboards/mice deprioritized on a2mega
; (gamepad-only port). wait_set_config now falls straight into
; xinput_init for every device.

xinput_init:
; Full 8BitDo SN30 Pro / XInput start sequence, mirroring the proven
; BL616 host (firmware_host/main.c xinput_send_init):
; string reads -> vendor magic -> vendor control 2 -> 4 interrupt-OUT
; packets. Genuine Microsoft pads may STALL the read data stages;
; every read loop below is stall-tolerant (shared rdloop10).
; huge thanks to Jakob
; ref: https://jakob.space/blog/sorry-guys-i-have-to-troubleshoot-my-usb-drivers-before-i-can-play.html
; ref: linux/drivers/input/joystick/xpad.c

; GET_STRING_DESCRIPTOR (index 2, lang 0x0409, wLength=2)
; SN30 Pro requires this read
    call ctrlpre
    call get_string2a
    call rcvdt
    ldi 16                ; receive 2 bytes of data from device
    call rdloop10

; GET_STRING_DESCRIPTOR (index 2, lang 0x0409, wLength=32)
    call ctrlpre
    call get_string2b
    call rcvdt
    ldi 255               ; up to 32 bytes (wk is 8 bits, 256 not encodable;
                          ; short packet ends via STALL arm of rdloop10)
    call rdloop10

; XINPUT_INIT (1) - vendor magic
; some third-party Xbox 360-style controllers
; require this message to finish initialization
    call ctrlpre
    call xinput_magic
    call rcvdt
    ldi 160               ; receive 20 bytes of data from device
    call rdloop10

; vendor control 2 (C1 01, wValue=0, wLength=8)
    call ctrlpre
    call vendor2
    call rcvdt
    ldi 64                ; receive 8 bytes of data from device
    call rdloop10

; four interrupt-OUT packets on the pad's OUT endpoint
; USB data toggle alternates DATA0, DATA1, DATA0, DATA1
    call outpre
    call xinput_led       ; 01 03 02, PID=DATA0
    call rcvdt
    call outpre
    call xinput_out2      ; 02 08 03, PID=DATA1
    call rcvdt
    call outpre
    call xinput_led       ; 01 03 02, PID=DATA0 (packet 3 = packet 1)
    call rcvdt
    call outpre
    call xinput_out4      ; 01 03 06, PID=DATA1
    call rcvdt

; ---- initialization finished
init_finished:
    save 15 1             ; connected
    bjmp cstart

; ---- interrupt polling
connected:
    call sof
    dec
    bnz cstart2
    start                 ; mark start of read transaction
    call in1x
    call rcvdt
    bnak cstart
    call sendack
    bjmp cstart

; ---- disconnect and jump start
connerr:
    save 15 0             ; disconnected
    bjmp cstart

; ---- subroutines
reset:
    out4 0x00

; ---- wait 20ms
    ldi 20
loop_reset:
    wait
    dec
    bnz loop_reset
    hiz

; ---- wait 40ms
    ldi 40
w40ms:
    wait
    call sof
    dec
    bnz w40ms
    ret

get_device:               ; get device descriptor of (0,0)
    outb 0x80             ; SYNC
    outb 0xc3             ; PID=DATA0
    outb 0x80             ; bmRequestType=80
    outb 0x06             ; bRequest=6 (Get_Descriptor)
    outb 0x00             ; Desc Index=0
    outb 0x01             ; Desc Type=1 (device)
    outb 0x00             ; Language ID=0
    outb 0x00             ;
    outb 0x10             ; wLength=16
    outb 0x00
    outb 0xe1             ; CRC16
    outb 0x94
    out4 0x03             ; EOP
    hiz
    ret

get_config:               ; get config descriptor of (0,0)
    outb 0x80             ; SYNC
    outb 0xc3             ; PID=DATA0
    outb 0x80             ; bmRequestType=0
    outb 0x06             ; bRequest=6 (Get_Descriptor)
    outb 0x00             ; Desc Index=0
    outb 0x02             ; Desc Type=2 (configuration)
    outb 0x00             ; Language ID=0
    outb 0x00             ;
    outb 0x12             ; wLength=18
    outb 0x00
    outb 0xa4             ; CRC16
    outb 0xf4
    out4 0x03             ; EOP
    hiz
    ret

set_address:              ; set address of device 0 to 1
    outb 0x80
    outb 0xc3
    outb 0x00
    outb 0x05
    outb 0x01
    outb 0x00
    outb 0x00
    outb 0x00
    outb 0x00
    outb 0x00
    outb 0xeb
    outb 0x25
    out4 0x03
    hiz
    ret

set_config:               ; set active configuration of device 1 to 1 (default config)
    outb 0x80
    outb 0xc3
    outb 0x00
    outb 0x09
    outb 0x01
    outb 0x00
    outb 0x00
    outb 0x00
    outb 0x00
    outb 0x00
    outb 0x27
    outb 0x25
    out4 0x03
    hiz
    ret

; HID SET_IDLE/SET_PROTOCOL/report-descriptor SETUP blobs removed to fit
; XInput/SN30 init; keyboards/mice deprioritized on a2mega
; (gamepad-only port).

strdesc2:                 ; shared prefix: GET_STRING_DESCRIPTOR index 2, lang 0x0409
    outb 0x80             ; SYNC
    outb 0xc3             ; PID=DATA0
    outb 0x80             ; bmRequestType=80
    outb 0x06             ; bRequest=6 (Get_Descriptor)
    outb 0x02             ; Desc Index=2 (string)
    outb 0x03             ; Desc Type=3 (string)
    outb 0x09             ; Language ID=0x0409
    outb 0x04
    ret

get_string2a:             ; string descriptor 2, wLength=2 (SN30 Pro needs this)
    call strdesc2
    outb 0x02             ; wLength=2
    outb 0x00
    outb 0xd7             ; CRC16
    outb 0x4b
    out4 0x03             ; EOP
    hiz
    ret

get_string2b:             ; string descriptor 2, wLength=32
    call strdesc2
    outb 0x20             ; wLength=32
    outb 0x00
    outb 0xcf             ; CRC16
    outb 0xeb
    out4 0x03             ; EOP
    hiz
    ret

vendor2:                  ; vendor control 2 (xpad-style)
    outb 0x80             ; SYNC
    outb 0xc3             ; PID=DATA0
    outb 0xc1             ; bmRequestType=c1
    outb 0x01             ; bRequest=1
    outb 0x00             ; wValue=0x0000
    outb 0x00
    outb 0x00             ; wIndex=0x0000
    outb 0x00
    outb 0x08             ; wLength=8
    outb 0x00
    outb 0x65             ; CRC16
    outb 0x68
    out4 0x03             ; EOP
    hiz
    ret

xinput_out2:              ; interrupt-OUT packet 2
    outb 0x80             ; SYNC
    outb 0x4b             ; PID=DATA1
    outb 0x02
    outb 0x08
    outb 0x03
    outb 0x68             ; CRC16
    outb 0x3e
    out4 0x03             ; EOP
    hiz
    ret

xinput_out4:              ; interrupt-OUT packet 4
    outb 0x80             ; SYNC
    outb 0x4b             ; PID=DATA1
    outb 0x01
    outb 0x03
    outb 0x06
    outb 0x5f             ; CRC16
    outb 0x0d
    out4 0x03             ; EOP
    hiz
    ret

xinput_led:               ; interrupt-OUT packets 1 and 3
    outb 0x80             ; SYNC
    outb 0xc3             ; PID=DATA0
    outb 0x01
    outb 0x03
    outb 0x02
    outb 0x5e             ; CRC16
    outb 0xce
    out4 0x03             ; EOP
    hiz
    ret

xinput_magic:
    outb 0x80             ; SYNC
    outb 0xc3             ; PID=DATA0
    outb 0xc1             ; bmRequestType=c1
    outb 0x01             ; bRequest=1
    outb 0x00             ; wValue=0x0100
    outb 0x01
    outb 0x00             ; wIndex=0x0000
    outb 0x00
    outb 0x14             ; wLength=20
    outb 0x00
    outb 0x50             ; CRC16
    outb 0x68
    out4 0x03             ; EOP
    hiz
    ret

rcvdt:
    ldi 64                ; receive up to 8 bytes of data from device by default
rcvdt2:
    in
rcvdt_eop:
    hiz
    be rcvdt_eop          ; wait for line idle
    hiz                   ; ensure delay before next transaction
    ret

setup00:
    outb 0x80             ; SYNC
    outb 0x2d             ; PID
    outb 0x00             ; ADDR:ENDP=0:0
    outb 0x10             ; + CRC5
    out4 0x03             ; EOP
    hiz
    ret

setup10:
    outb 0x80             ; SYNC
    outb 0x2d             ; PID
    outb 0x01             ; ADDR:ENDP=1:0
    outb 0xe8             ; + CRC5
    out4 0x03             ; EOP
    hiz
    ret

ctrlpre:                  ; frame + SETUP token to (1,0)
    wait
    call sof
    call setup10
    ret

out1x:
    outb 0x80             ; SYNC
    outb 0xe1             ; PID=OUT
    outr 10               ; ADDR:ENDP
    outr 11               ; + CRC5
    out4 0x03             ; EOP
    hiz
    ret

outpre:                   ; frame + OUT token to interrupt-OUT endpoint
    wait
    call sof
    call out1x
    ret

; IN(1,0), ACK() - shared control read data-stage loop, discards contents.
; Mirrors the proven wait_xinput_magic structure: stall-tolerant because
; genuine Microsoft pads STALL the string/vendor data stages.
; Caller does ldi <bits> first; start is folded in here.
rdloop10:
    start                 ; mark start of read transaction
rdretry10:
    wait
    call sof
    call in10
    call rcvdt2
    bstall rddone10
    bnak rdretry10
    call sendack
    bnz rdretry10
rddone10:
    ret

in00:
    outb 0x80             ; SYNC
    outb 0x69             ; PID=IN
    outb 0x00             ; ADDR:ENDP=0:0
    outb 0x10             ; + CRC5
    out4 0x03             ; EOP
    hiz
    ret

in10:
    outb 0x80             ; SYNC
    outb 0x69             ; PID=IN
    outb 0x01             ; ADDR:ENDP=1:0
    outb 0xe8             ; + CRC5
    out4 0x03             ; EOP
    hiz
    ret

in1x:
    outb 0x80             ; SYNC
    outb 0x69             ; PID=IN
    outr 8                ; ADDR:ENDP
    outr 9                ; + CRC5
    out4 0x03             ; EOP
    hiz
    ret

sendack:
    outb 0x80
    outb 0xd2
    out4 0x03
    hiz
    ret

sof:
    be connerr
    bnf keep_alive
    outb 0x80
    outb 0xa5
    outb 0x00
    outb 0x10
keep_alive:
    out4 0x03             ; low-speed keep-alive
    hiz
    ret

prgend:
