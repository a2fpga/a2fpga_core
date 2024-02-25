//
// Video Control Interface
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
// SystemVerilog interface for the video control interface, used by the
// PicoSoC to control the video output for OSD purposes
//

interface video_control_if;

    logic enable;

    logic TEXT_MODE;
    logic MIXED_MODE;
    logic PAGE2;
    logic HIRES_MODE;
    logic AN3;

    logic STORE80;
    logic COL80;
    logic ALTCHAR;

    logic [3:0] TEXT_COLOR;
    logic [3:0] BACKGROUND_COLOR;
    logic [3:0] BORDER_COLOR;
    logic MONOCHROME_MODE;
    logic MONOCHROME_DHIRES_MODE;
    logic SHRG_MODE;

    function automatic logic text_mode (bit default_mode);
        return enable ? TEXT_MODE : default_mode;
    endfunction

    function automatic logic mixed_mode (bit default_mode);
        return enable ? MIXED_MODE : default_mode;
    endfunction

    function automatic logic page2 (bit default_mode);
        return enable ? PAGE2 : default_mode;
    endfunction

    function automatic logic hires_mode (bit default_mode);
        return enable ? HIRES_MODE : default_mode;
    endfunction

    function automatic logic an3 (bit default_mode);
        return enable ? AN3 : default_mode;
    endfunction

    function automatic logic store80 (bit default_mode);
        return enable ? STORE80 : default_mode;
    endfunction

    function automatic logic col80 (bit default_mode);
        return enable ? COL80 : default_mode;
    endfunction

    function automatic logic altchar (bit default_mode);
        return enable ? ALTCHAR : default_mode;
    endfunction

    function logic [3:0] text_color (bit [3:0] default_color);
        return enable ? TEXT_COLOR : default_color;
    endfunction

    function logic [3:0] background_color (bit [3:0] default_color);
        return enable ? BACKGROUND_COLOR : default_color;
    endfunction

    function logic [3:0] border_color (bit [3:0] default_color);
        return enable ? BORDER_COLOR : default_color;
    endfunction

    function automatic logic monochrome_mode (bit default_mode);
        return enable ? MONOCHROME_MODE : default_mode;
    endfunction

    function automatic logic monochrome_dhires_mode (bit default_mode);
        return enable ? MONOCHROME_DHIRES_MODE : default_mode;
    endfunction

    function automatic logic shrg_mode (bit default_mode);
        return enable ? SHRG_MODE : default_mode;
    endfunction


    modport display (
        input enable,

        input TEXT_MODE,
        input MIXED_MODE,
        input PAGE2,
        input HIRES_MODE,
        input AN3,

        input STORE80,
        input COL80,
        input ALTCHAR,

        input TEXT_COLOR,
        input BACKGROUND_COLOR,
        input BORDER_COLOR,
        input MONOCHROME_MODE,
        input MONOCHROME_DHIRES_MODE,
        input SHRG_MODE,

        import text_mode,
        import mixed_mode,
        import page2,
        import hires_mode,
        import an3,

        import store80,
        import col80,
        import altchar,

        import text_color,
        import background_color,
        import border_color,
        import monochrome_mode,
        import monochrome_dhires_mode,
        import shrg_mode
    );

    modport control (
        output enable,

        output TEXT_MODE,
        output MIXED_MODE,
        output PAGE2,
        output HIRES_MODE,
        output AN3,

        output STORE80,
        output COL80,
        output ALTCHAR,

        output TEXT_COLOR,
        output BACKGROUND_COLOR,
        output BORDER_COLOR,
        output MONOCHROME_MODE,
        output MONOCHROME_DHIRES_MODE,
        output SHRG_MODE
    );

endinterface: video_control_if

    