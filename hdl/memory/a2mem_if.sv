//
// Apple II Memory Interface
//
// (c) 2023,2024 Ed Anuff <ed@a2fpga.com> 
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Description:
//
// SystemVerilog interface for the Apple II memory soft switches and
// memory configuration
//

interface a2mem_if;

    // II Soft switches
    logic TEXT_MODE;
    logic MIXED_MODE;
    logic PAGE2;
    logic HIRES_MODE;
    logic AN0;
    logic AN1;
    logic AN2;
    logic AN3;

    // ][e auxilary switches
    logic STORE80;
    logic RAMRD;
    logic RAMWRT;
    logic INTCXROM;
    logic ALTZP;
    logic SLOTC3ROM;
    logic COL80;
    logic ALTCHAR;

    logic INTC8ROM;

    logic [2:0] SLOTROM;

    // IIgs configuration
    logic [3:0] TEXT_COLOR;
    logic [3:0] BACKGROUND_COLOR;
    logic [3:0] BORDER_COLOR;
    logic MONOCHROME_MODE;
    logic MONOCHROME_DHIRES_MODE;
    logic SHRG_MODE;
    logic LINEARIZE_MODE;

    logic aux_mem;

    logic [7:0] keycode;
    logic keypress_strobe;

    modport master (
        output TEXT_MODE,
        output MIXED_MODE,
        output PAGE2,
        output HIRES_MODE,
        output AN0,
        output AN1,
        output AN2,
        output AN3,

        output STORE80,
        output RAMRD,
        output RAMWRT,
        output INTCXROM,
        output ALTZP,
        output SLOTC3ROM,
        output COL80,
        output ALTCHAR,

        output INTC8ROM,

        output SLOTROM,

        output TEXT_COLOR,
        output BACKGROUND_COLOR,
        output BORDER_COLOR,
        output MONOCHROME_MODE,
        output MONOCHROME_DHIRES_MODE,
        output SHRG_MODE,
        output LINEARIZE_MODE,

        output aux_mem,

        output keycode,
        output keypress_strobe
    );

    modport slave (
        input TEXT_MODE,
        input MIXED_MODE,
        input PAGE2,
        input HIRES_MODE,
        input AN0,
        input AN1,
        input AN2,
        input AN3,

        input STORE80,
        input RAMRD,
        input RAMWRT,
        input INTCXROM,
        input ALTZP,
        input SLOTC3ROM,
        input COL80,
        input ALTCHAR,

        input INTC8ROM,

        input SLOTROM,

        input TEXT_COLOR,
        input BACKGROUND_COLOR,
        input BORDER_COLOR,
        input MONOCHROME_MODE,
        input MONOCHROME_DHIRES_MODE,
        input SHRG_MODE,
        input LINEARIZE_MODE,

        input aux_mem,

        input keycode,
        input keypress_strobe
    );

endinterface: a2mem_if



