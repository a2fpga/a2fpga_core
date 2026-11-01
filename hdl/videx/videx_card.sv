//
// Videx VideoTerm 80-Column Card — bus side
//
// Copyright (c) 2026 Brent Rector
// Copyright (c) 2026 the A2FPGA contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
//
// Description:
//
// The Apple-bus half of a Videx VideoTerm: firmware ROM, MC6845 (HD6845SP)
// register file, 2 KB VRAM with bank select, and $C800-$CFFF ownership. The
// bus logic is Brent Rector's hardware-verified implementation
// (BrentRector/a2fpga_core, hdl/videx/videx_card.sv); his HDMI-raster
// renderer is replaced by a VRAM read port + CRTC outputs consumed by
// hdl/video/videx_gen.sv, a pixel_stream_if generator (docs/video-pipeline.md).
//
// A Videx only ever works in SLOT 3 of an Apple ][+:
//   - The card enables only when the slot map places it in slot 3.
//   - It is deliberately NOT gated on a runtime ][+/IIe detector: one keyed on
//     $C00x writes (like the INTC8ROM guard in apple_memory) is tripped by
//     ][+ software -- with it, SoftCard CP/M 2.23 came up in 40 columns; without
//     it, CP/M boots in 80 columns (hardware-verified). Keeping a Videx off a
//     IIe is the OSD's job (VIDEX is a slot-3 choice labelled ][+ ONLY).
//
// Mode: videx_mode_o = enabled && TEXT && AN0 ($C059 on / $C058 off), as on
// the real card. Ctrl-Reset clears AN0 via the Autostart ROM.
//
// Clock: everything is on clk_logic (the generator shares the domain).
//

module videx_card #(
    parameter bit [7:0] ID = 7,
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave   a2bus_if,
    a2mem_if.slave   a2mem_if,
    slot_if.card     slot_if,

    output [7:0]     data_o,
    output           rd_en_o,
    output           rom_en_o,

    // To the generator (all clk_logic)
    output           videx_mode_o,      // card live && TEXT && AN0
    output [7:0]     crtc_r10_o,        // cursor start line + blink mode
    output [7:0]     crtc_r11_o,        // cursor end line
    output [10:0]    start_addr_o,      // R12:R13 display start
    output [10:0]    cursor_addr_o,     // R14:R15 cursor address

    input            gen_rd_i,          // generator VRAM read (has priority)
    input  [8:0]     gen_addr_i,        // 32-bit word address
    output [31:0]    gen_data_o,        // valid when gen_valid_o
    output           gen_valid_o        // 2 clk after gen_rd_i
);

    // ------------------------------------------------------------------
    // Card enable: slot 3 only
    // ------------------------------------------------------------------
    reg card_enable;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            card_enable <= 1'b0;
        end else if (!slot_if.config_select_n) begin
            if (slot_if.slot == 3'd0)
                card_enable <= 1'b0;
            else if (slot_if.card_id == ID)
                card_enable <= slot_if.card_enable && ENABLE && (slot_if.slot == 3'd3);
        end
    end

    wire live = card_enable;

    wire card_sel       = live && (slot_if.card_id == ID) && a2bus_if.phi0;
    wire card_dev_sel   = card_sel && !slot_if.dev_select_n;   // $C0Bx
    wire card_io_sel    = card_sel && !slot_if.io_select_n;    // $C3xx

    wire vram_window   = (a2bus_if.addr[15:9]  == 7'b1100_110); // $CC00-$CDFF
    wire exp_rom_range = (a2bus_if.addr[15:10] == 6'b110010);   // $C800-$CBFF

    // $CFFF releases C8 ownership. phi0-qualified: address transients
    // outside the valid phase must not drop ownership.
    wire cfff_access = a2bus_if.phi0 && (a2bus_if.addr == 16'hCFFF);

    // Another slot's $Cnxx: yield C8 space (all emulated cards share one
    // bus mux, so a stale owner would answer another card's ROM reads).
    wire other_slot_rom = a2bus_if.phi0 &&
                          (a2bus_if.addr[15:11] == 5'b1100_0) &&
                          (a2bus_if.addr[10:8] != 3'd3) &&
                          (a2bus_if.addr[10:8] != 3'd0);

    // ------------------------------------------------------------------
    // C8-space ownership (Videx PAL16L8 behavior + FPGA other-slot yield)
    // ------------------------------------------------------------------
    // Reads are gated by phi0 directly, not io_strobe_n: io_strobe_n
    // depends on SLOTROM (updated on phi1_posedge) and hung PR#3 in
    // Brent's testing.
    reg c8_owned;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n || !live) begin
            c8_owned <= 1'b0;
        end else if (card_io_sel) begin
            c8_owned <= 1'b1;
        end else if (!a2mem_if.INTCXROM && (cfff_access || other_slot_rom)) begin
            c8_owned <= 1'b0;
        end
    end

    wire rom_c8_active = c8_owned && !a2mem_if.INTCXROM;
    assign rom_en_o = rom_c8_active;

    // ------------------------------------------------------------------
    // Firmware ROM, 1 KB (VideoTerm 2.4). $C3xx maps to the top 256 bytes,
    // $C800-$CBFF to offsets $000-$3FF.
    // ------------------------------------------------------------------
    reg [7:0] rom[0:1023] /*synthesis syn_ramstyle="distributed_ram"*/;
    initial $readmemh("videx_rom.hex", rom);

    wire [9:0] rom_addr = card_io_sel ? {2'b11, a2bus_if.addr[7:0]} : a2bus_if.addr[9:0];

    reg [7:0] rom_data_r;
    reg [7:0] rom_data_rr;
    always_ff @(posedge a2bus_if.clk_logic) begin
        rom_data_r  <= rom[rom_addr];
        rom_data_rr <= rom_data_r;
    end

    // ------------------------------------------------------------------
    // CRTC register file (HD6845SP / Type 1: R0-R15 readable) + bank select
    // ------------------------------------------------------------------
    // Any $C0Bx access (read OR write) selects the VRAM bank from addr[3:2].
    // Even address writes the register index, odd address the data.
    reg [4:0] crtc_idx;
    reg [7:0] crtc_regs[0:15];
    reg [1:0] bank_sel;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            crtc_idx <= 5'h0;
            bank_sel <= 2'b0;
            for (int i = 0; i < 16; i++)
                crtc_regs[i] <= 8'h00;
        end else if (a2bus_if.phi1_posedge && !a2bus_if.m2sel_n &&
                     (a2bus_if.addr[15:4] == 12'hC0B) && live) begin
            bank_sel <= a2bus_if.addr[3:2];
            if (!a2bus_if.rw_n) begin
                if (!a2bus_if.addr[0])
                    crtc_idx <= a2bus_if.data[4:0];
                else if (crtc_idx < 5'd16)
                    crtc_regs[crtc_idx] <= a2bus_if.data[7:0];
            end
        end
    end

    wire crtc_read = card_dev_sel && a2bus_if.rw_n;
    wire [7:0] crtc_data = (a2bus_if.addr[0] && crtc_idx < 5'd16)
                         ? crtc_regs[crtc_idx] : 8'h00;

    assign crtc_r10_o    = crtc_regs[10];
    assign crtc_r11_o    = crtc_regs[11];
    assign start_addr_o  = {crtc_regs[12][2:0], crtc_regs[13]};
    assign cursor_addr_o = {crtc_regs[14][2:0], crtc_regs[15]};

    assign videx_mode_o  = live && a2mem_if.TEXT_MODE && a2mem_if.AN0;

    // ------------------------------------------------------------------
    // VRAM: 2 KB in one SDPB (8-bit write, 32-bit read, 2-cycle latency)
    // ------------------------------------------------------------------
    wire [10:0] vram_addr = {bank_sel, a2bus_if.addr[8:0]};

    wire vram_we = !a2bus_if.rw_n && a2bus_if.data_in_strobe &&
                   rom_c8_active && vram_window;

    // Read port shared by the generator (priority) and CPU read-back. A
    // CPU read is held for the whole of phi0, so a cycle lost to the
    // generator is simply retried on the next clock.
    wire cpu_vram_rd = rom_c8_active && a2bus_if.phi0 && vram_window && a2bus_if.rw_n;
    wire        cpu_rd_go    = cpu_vram_rd && !gen_rd_i;
    wire [8:0]  vram_rd_addr = gen_rd_i ? gen_addr_i : vram_addr[10:2];
    wire        vram_rd_en   = gen_rd_i || cpu_vram_rd;
    wire [31:0] vram_rd_data;

    SDPB videx_vram (
        .CLKA(a2bus_if.clk_logic),
        .CEA(vram_we),
        .RESETA(1'b0),
        .BLKSELA(3'b000),
        .ADA({vram_addr, 3'b000}),
        .DI({24'b0, a2bus_if.data}),

        .CLKB(a2bus_if.clk_logic),
        .CEB(vram_rd_en),
        .RESETB(1'b0),
        .OCE(1'b1),
        .BLKSELB(3'b000),
        .ADB({vram_rd_addr, 5'b00000}),
        .DO(vram_rd_data)
    );
    defparam videx_vram.READ_MODE   = 1'b1;
    defparam videx_vram.BIT_WIDTH_0 = 8;
    defparam videx_vram.BIT_WIDTH_1 = 32;
    defparam videx_vram.RESET_MODE  = "SYNC";
    defparam videx_vram.BLK_SEL_0   = 3'b000;
    defparam videx_vram.BLK_SEL_1   = 3'b000;

    reg gen_rd_d1, gen_rd_d2;
    reg cpu_rd_d1, cpu_rd_d2;
    reg [1:0] byte_sel_d1, byte_sel_d2;
    reg [31:0] cpu_hold;

    always_ff @(posedge a2bus_if.clk_logic) begin
        gen_rd_d1   <= gen_rd_i;
        gen_rd_d2   <= gen_rd_d1;
        cpu_rd_d1   <= cpu_rd_go;
        cpu_rd_d2   <= cpu_rd_d1;
        byte_sel_d1 <= vram_addr[1:0];
        byte_sel_d2 <= byte_sel_d1;
        if (cpu_rd_d2)
            cpu_hold <= vram_rd_data;
    end

    assign gen_data_o  = vram_rd_data;
    assign gen_valid_o = gen_rd_d2;

    wire [7:0] vram_read_byte = byte_sel_d2 == 2'd0 ? cpu_hold[7:0]   :
                                byte_sel_d2 == 2'd1 ? cpu_hold[15:8]  :
                                byte_sel_d2 == 2'd2 ? cpu_hold[23:16] :
                                                      cpu_hold[31:24];

    // ------------------------------------------------------------------
    // Bus read responses
    // ------------------------------------------------------------------
    wire slot_rom_read = card_io_sel && a2bus_if.rw_n;
    wire exp_rom_read  = rom_c8_active && a2bus_if.phi0 && exp_rom_range && a2bus_if.rw_n;
    wire vram_read     = rom_c8_active && a2bus_if.phi0 && vram_window && a2bus_if.rw_n;

    assign rd_en_o = live && (crtc_read || slot_rom_read || exp_rom_read || vram_read);
    assign data_o  = crtc_read ? crtc_data :
                     vram_read ? vram_read_byte :
                     rom_data_rr;

endmodule
