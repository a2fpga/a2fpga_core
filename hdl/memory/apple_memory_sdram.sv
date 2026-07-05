// Tang Nano 20K SDRAM implementation of Apple II memory
//
// (c) 2023,2024,2025,2026 Ed Anuff <ed@a2fpga.com>
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
// Handle the writing of data to the shadow memory copy of the Apple II's
// memory that is kept in the FPGA's SDRAM. Text and hires main memory are
// in SDRAM to free BSRAM. VGC aux memory stays in BSRAM (interleave_mux
// requires dual-BRAM read).
//
// Shared by the SDRAM-based a2n20v2-family boards (a2n20v2-GS,
// a2n20v2-Enhanced). The BSRAM-only implementation used by other boards
// is hdl/memory/apple_memory.sv.
//

module apple_memory_sdram #(
    parameter VGC_MEMORY = 0,        // 1 = extend aux memory to 32KB for VGC, 0 = 16KB
    parameter SHADOW_ALL_MEMORY = 0, // 1 = shadow all memory to SDRAM, 0 = only video pages
    parameter VGC_IN_SDRAM = 0       // 1 = SHR aux bytes stored pre-interleaved in SDRAM
                                     //     (frees both aux BSRAM banks; VGC fetches share
                                     //     video_mem_if via an internal arbiter)
) (
    a2bus_if.slave a2bus_if,
    a2mem_if.master a2mem_if,

    // SDRAM ports for shadow memory
    mem_port_if.client main_mem_if,    // CPU writes to SDRAM
    mem_port_if.client video_mem_if,   // video gen reads (shared with VGC when VGC_IN_SDRAM)

    input [15:0] video_address_i,
    input video_bank_i,
    input video_rd_i,
    output [31:0] video_data_o,
    output video_ready_o,

    input vgc_active_i,
    input [12:0] vgc_address_i,
    input vgc_rd_i,
    output [31:0] vgc_data_o,
    output vgc_ready_o                 // read-data beat for vgc_gen (BSRAM mode: fixed
                                       // 2-cycle sdpram32 latency; SDRAM mode: port ready)

);

    // Pre-interleaved aux region (VGC_IN_SDRAM): word addresses 0x8000-0x9FFF,
    // above the flat shadow (words 0x0000-0x7FFF = full 64K x {main,aux} via
    // byte lanes) and below the Ensoniq region at word 0x10000.
    localparam [20:0] VGC_AUX_WORD_OFFSET = 21'h008000;

    wire write_strobe = !a2bus_if.rw_n && a2bus_if.data_in_strobe;
    wire read_strobe = a2bus_if.rw_n && a2bus_if.data_in_strobe;

   // II Soft switches
    reg SWITCHES_II[8];
    assign a2mem_if.TEXT_MODE = SWITCHES_II[0];
    assign a2mem_if.MIXED_MODE = SWITCHES_II[1];
    assign a2mem_if.PAGE2 = SWITCHES_II[2];
    assign a2mem_if.HIRES_MODE = SWITCHES_II[3];
    assign a2mem_if.AN0 = SWITCHES_II[4];
    assign a2mem_if.AN1 = SWITCHES_II[5];
    assign a2mem_if.AN2 = SWITCHES_II[6];
    assign a2mem_if.AN3 = SWITCHES_II[7];

    // ][e auxilary switches
    reg SWITCHES_IIE[8];
    assign a2mem_if.STORE80 = SWITCHES_IIE[0];
    assign a2mem_if.RAMRD = SWITCHES_IIE[1];
    assign a2mem_if.RAMWRT = SWITCHES_IIE[2];
    assign a2mem_if.INTCXROM = SWITCHES_IIE[3];
    assign a2mem_if.ALTZP = SWITCHES_IIE[4];
    assign a2mem_if.SLOTC3ROM = SWITCHES_IIE[5];
    assign a2mem_if.COL80 = SWITCHES_IIE[6];
    assign a2mem_if.ALTCHAR = SWITCHES_IIE[7];


    reg INTC8ROM;
    assign a2mem_if.INTC8ROM = INTC8ROM;

    reg [2:0] SLOTROM;
    assign a2mem_if.SLOTROM = SLOTROM;

    // capture the soft switches
    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            SWITCHES_II <= '{1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1};
        end else if ((a2bus_if.phi1_posedge) && (a2bus_if.addr[15:4] == 12'hC05) && !a2bus_if.m2sel_n) begin
            SWITCHES_II[a2bus_if.addr[3:1]] <= a2bus_if.addr[0];
        end else if (!a2bus_if.rw_n && (a2bus_if.phi1_posedge) && (a2bus_if.addr == 16'hC068) && !a2bus_if.m2sel_n) begin
            SWITCHES_II[2] <= a2bus_if.data[6];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            SWITCHES_IIE <= '{8{1'b0}};
        end else if (!a2bus_if.rw_n && (a2bus_if.phi1_posedge) && (a2bus_if.addr[15:4] == 12'hC00) && !a2bus_if.m2sel_n) begin
            SWITCHES_IIE[a2bus_if.addr[3:1]] <= a2bus_if.addr[0];
        end else if (!a2bus_if.rw_n && (a2bus_if.phi1_posedge) && (a2bus_if.addr == 16'hC068) && !a2bus_if.m2sel_n) begin
            SWITCHES_IIE[1] <= a2bus_if.data[5];
            SWITCHES_IIE[2] <= a2bus_if.data[4];
            SWITCHES_IIE[3] <= a2bus_if.data[0];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.device_reset_n) begin
        if (!a2bus_if.device_reset_n) begin
            a2mem_if.BACKGROUND_COLOR <= 4'h0;
            a2mem_if.TEXT_COLOR <= 4'hF;
        end else if (write_strobe && (a2bus_if.addr == 16'hC022)) begin
            a2mem_if.BACKGROUND_COLOR <= a2bus_if.data[3:0];
            a2mem_if.TEXT_COLOR <= a2bus_if.data[7:4];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.device_reset_n) begin
        if (!a2bus_if.device_reset_n) begin
            a2mem_if.BORDER_COLOR <= 4'h0;
        end else if (write_strobe && (a2bus_if.addr == 16'hC034)) begin
            a2mem_if.BORDER_COLOR <= a2bus_if.data[3:0];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            a2mem_if.MONOCHROME_MODE <= 1'b0;
        end else if (write_strobe && (a2bus_if.addr == 16'hC021)) begin
            a2mem_if.MONOCHROME_MODE <= a2bus_if.data[7];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            a2mem_if.MONOCHROME_DHIRES_MODE <= 1'b0;
            a2mem_if.LINEARIZE_MODE <= 1'b0;
            a2mem_if.SHRG_MODE <= 1'b0;
        end else if (write_strobe && (a2bus_if.addr == 16'hC029)) begin
            a2mem_if.MONOCHROME_DHIRES_MODE <= a2bus_if.data[5];
            a2mem_if.LINEARIZE_MODE <= a2bus_if.data[6] | a2bus_if.data[7];
            a2mem_if.SHRG_MODE <= a2bus_if.data[7];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            INTC8ROM <= 1'b0;
            SLOTROM <= 3'b0;
        end else if ((a2bus_if.phi1_posedge) && (a2bus_if.addr == 16'hCFFF) && !a2bus_if.m2sel_n) begin
            INTC8ROM <= 1'b0;
            SLOTROM <= 3'b0;
        end else if ((a2bus_if.phi1_posedge) && (a2bus_if.addr >= 16'hC100) && (a2bus_if.addr < 16'hC800) && !a2bus_if.m2sel_n) begin
            if (!a2mem_if.SLOTC3ROM && (a2bus_if.addr[15:8] == 8'hC3)) INTC8ROM <= 1'b1; // Slot C3 ROM
            SLOTROM <= a2bus_if.addr[10:8];
        end
    end

    reg [7:0] keycode_r;
    reg keypress_strobe_r;

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            keycode_r <= 8'h00;
            keypress_strobe_r <= 1'b0;
        end else begin
            keypress_strobe_r <= 1'b0;
            if (read_strobe && (a2bus_if.addr == 16'hC000)) begin
                if (a2bus_if.data[7] & !keycode_r[7]) begin
                    keycode_r <= a2bus_if.data;
                    keypress_strobe_r <= 1'b1;
                end
            end else if (a2bus_if.data_in_strobe && (a2bus_if.addr == 16'hC010)) begin
                keycode_r[7] <= 1'b0;
            end
        end
    end

    assign a2mem_if.keycode = keycode_r;
    assign a2mem_if.keypress_strobe = keypress_strobe_r;

    logic aux_mem_r;

    always_comb begin
        aux_mem_r = 1'b0;
        if (a2bus_if.addr[15:9] == 7'b0000000 | a2bus_if.addr[15:14] == 2'b11)		// Page 00,01,C0-FF
            aux_mem_r = a2mem_if.ALTZP;
        else if (a2bus_if.addr[15:10] == 6'b000001)		// Page 04-07
            aux_mem_r = (a2mem_if.STORE80 & a2mem_if.PAGE2) | ((~a2mem_if.STORE80) & (a2mem_if.RAMWRT & !a2bus_if.rw_n));
        else if (a2bus_if.addr[15:13] == 3'b001)		// Page 20-3F
            aux_mem_r = (a2mem_if.STORE80 & a2mem_if.PAGE2 & a2mem_if.HIRES_MODE) | (((~a2mem_if.STORE80) | (~a2mem_if.HIRES_MODE)) & (a2mem_if.RAMWRT & !a2bus_if.rw_n));
        else
            aux_mem_r = (a2mem_if.RAMWRT & !a2bus_if.rw_n);
    end
    assign a2mem_if.aux_mem = aux_mem_r;

    // Original 16-bit address space
    //                1111 1100 0000 0000
    //                5432 1098 7654 3210
    // 16'h0400 = 16'b0000_0100_0000_0000
    // 16'h0BFF = 16'b0000_1011_1111_1111
    // 16'h2000 = 16'b0010_0000_0000_0000
    // 16'h5FFF = 16'b0101_1111_1111_1111
    // 16'h6000 = 16'b0110_0000_0000_0000
    // 16'9FFFF = 16'b1001_1111_1111_1111

    wire E1 = aux_mem_r || a2bus_if.m2b0;

    wire [31:0] write_word = {a2bus_if.data, a2bus_if.data, a2bus_if.data, a2bus_if.data};

    // Apple II bus address ranges
    wire bus_addr_0400_0BFF = a2bus_if.addr[15:10] inside {6'b000001, 3'b000010};
    wire bus_addr_2000_5FFF = a2bus_if.addr[15:13] inside {3'b001, 3'b010};
    wire bus_addr_6000_9FFF = a2bus_if.addr[15:13] inside {3'b011, 3'b100};
    wire bus_addr_2000_9FFF = bus_addr_2000_5FFF || bus_addr_6000_9FFF;

    wire [14:0] hires_write_offset = 15'({3'(a2bus_if.addr[15:13] - 1'b1), a2bus_if.addr[12:0]});

    wire [31:0] hires_data_aux;

    function automatic [31:0] interleave_mux(input hi, input [31:0] data_a, input [31:0] data_b);
        logic [31:0] result = 0;
        if (hi) result = {data_b[31:24], data_a[31:24], data_b[23:16], data_a[23:16]};
        else result = {data_b[15:8], data_a[15:8], data_b[7:0], data_a[7:0]};
        return result;
    endfunction

    wire [3:0] hires_byte_enable = 4'(1 << hires_write_offset[1:0]);

    wire [31:0] hires_data_aux_6000_9FFF;

    // VGC read offset into the BSRAM aux banks (unused when VGC_IN_SDRAM)
    logic [11:0] hires_aux_read_offset;

    always_comb begin
        if (!VGC_IN_SDRAM && VGC_MEMORY && vgc_active_i) begin
            hires_aux_read_offset = vgc_address_i[12:1];
        end else begin
            hires_aux_read_offset = 12'b0;
        end
    end

    generate
    if (VGC_IN_SDRAM) begin : vgc_sdram_read
        // Aux bytes live pre-interleaved in SDRAM (see the write path below),
        // so a VGC fetch is a single 32-bit read — no interleave_mux needed.
        //
        // VGC fetches share video_mem_if with apple_video_gen through a
        // latch-and-replay arbiter rather than an extra controller port —
        // an 8th port fails 108 MHz timing in the controller's priority/mux
        // cone. Sharing is safe: both clients pulse a read and capture data
        // exactly on their ready beat, and only one generator's output is
        // ever displayed (SHRG is fullscreen), so the hidden client's added
        // latency is harmless. Video has priority.
        reg vid_pend_r, vgc_pend_r;
        reg [20:0] vid_addr_r, vgc_addr_r;
        reg busy_r, owner_vgc_r, rd_r;
        reg [20:0] addr_r;

        wire vid_req_w = video_rd_i;
        wire vgc_req_w = vgc_rd_i && vgc_active_i;

        always @(posedge a2bus_if.clk_logic) begin
            if (!a2bus_if.system_reset_n) begin
                vid_pend_r  <= 1'b0;
                vgc_pend_r  <= 1'b0;
                busy_r      <= 1'b0;
                owner_vgc_r <= 1'b0;
                rd_r        <= 1'b0;
            end else begin
                // Each client has at most one outstanding request
                if (vid_req_w) begin
                    vid_pend_r <= 1'b1;
                    vid_addr_r <= {5'b0, video_bank_i, video_address_i[15:1]};
                end
                if (vgc_req_w) begin
                    vgc_pend_r <= 1'b1;
                    vgc_addr_r <= VGC_AUX_WORD_OFFSET + {8'b0, vgc_address_i};
                end

                if (busy_r) begin
                    if (video_mem_if.ready) begin
                        busy_r <= 1'b0;
                        rd_r   <= 1'b0;   // one dead cycle before the next grant
                    end
                end else if (rd_r) begin
                    rd_r <= 1'b0;         // (defensive; rd_r falls with busy_r)
                end else if (vid_pend_r) begin
                    busy_r      <= 1'b1;
                    owner_vgc_r <= 1'b0;
                    rd_r        <= 1'b1;
                    addr_r      <= vid_addr_r;
                    vid_pend_r  <= vid_req_w;  // don't lose a same-cycle new pulse
                end else if (vgc_pend_r) begin
                    busy_r      <= 1'b1;
                    owner_vgc_r <= 1'b1;
                    rd_r        <= 1'b1;
                    addr_r      <= vgc_addr_r;
                    vgc_pend_r  <= vgc_req_w;
                end
            end
        end

        assign video_mem_if.rd = rd_r;
        assign video_mem_if.wr = 1'b0;
        assign video_mem_if.addr = addr_r;
        assign video_mem_if.data = 32'b0;
        assign video_mem_if.byte_en = 4'b1111;
        assign video_mem_if.burst = 1'b0;

        assign video_data_o  = video_mem_if.q;
        assign video_ready_o = video_mem_if.ready && busy_r && !owner_vgc_r;

        assign vgc_data_o  = vgc_active_i ? video_mem_if.q : 32'b0;
        assign vgc_ready_o = video_mem_if.ready && busy_r && owner_vgc_r;
    end else begin : vgc_bsram_read
        // vgc_data_o comes from BSRAM via interleave_mux (unchanged)
        assign vgc_data_o = vgc_active_i ? interleave_mux(vgc_address_i[0], hires_data_aux, hires_data_aux_6000_9FFF) : 32'b0;

        // Ready = fixed 2-cycle sdpram32 read latency after the read strobe
        reg vgc_rd_d1_r, vgc_rd_d2_r;
        always @(posedge a2bus_if.clk_logic) begin
            vgc_rd_d1_r <= vgc_rd_i && vgc_active_i;
            vgc_rd_d2_r <= vgc_rd_d1_r;
        end
        assign vgc_ready_o = vgc_rd_d2_r;

        // video gen reads pass straight through to SDRAM
        assign video_mem_if.rd = video_rd_i;
        assign video_mem_if.wr = 1'b0;
        assign video_mem_if.addr = {5'b0, video_bank_i, video_address_i[15:1]};
        assign video_mem_if.data = 32'b0;
        assign video_mem_if.byte_en = 4'b1111;
        assign video_mem_if.burst = 1'b0;

        assign video_data_o  = video_mem_if.q;
        assign video_ready_o = video_mem_if.ready;
    end
    endgenerate

    // Aux memory writes — still go to BSRAM for VGC reads

    logic write_enable_aux_2000_5FFF;
    logic write_enable_aux_6000_9FFF;
    logic [11:0] write_offset_aux_2000_5FFF;
    logic [11:0] write_offset_aux_6000_9FFF;
    logic [3:0] hires_byte_enable_aux_2000_5FFF;
    logic [3:0] hires_byte_enable_aux_6000_9FFF;

    always_comb begin
        write_enable_aux_2000_5FFF = 1'b0;
        write_offset_aux_2000_5FFF = 12'b0;
        hires_byte_enable_aux_2000_5FFF = 4'b0;

        write_enable_aux_6000_9FFF = 1'b0;
        write_offset_aux_6000_9FFF = 12'b0;
        hires_byte_enable_aux_6000_9FFF = 4'b0;

        if (VGC_MEMORY || VGC_IN_SDRAM) begin
            if (a2mem_if.LINEARIZE_MODE) begin
                write_enable_aux_2000_5FFF = write_strobe && bus_addr_2000_9FFF && E1;
                write_offset_aux_2000_5FFF = hires_write_offset[14:3];
                hires_byte_enable_aux_2000_5FFF = hires_write_offset[0] ? 4'b0 : 4'(1 << hires_write_offset[2:1]);

                write_enable_aux_6000_9FFF = write_strobe && bus_addr_2000_9FFF && E1;
                write_offset_aux_6000_9FFF = hires_write_offset[14:3];
                hires_byte_enable_aux_6000_9FFF = hires_write_offset[0] ? 4'(1 << hires_write_offset[2:1]) : 4'b0;

            end else begin
                if (bus_addr_2000_5FFF) begin
                    write_enable_aux_2000_5FFF = write_strobe && bus_addr_2000_5FFF && E1;
                    write_offset_aux_2000_5FFF = hires_write_offset[13:2];
                    hires_byte_enable_aux_2000_5FFF = hires_byte_enable;
                end else if (bus_addr_6000_9FFF) begin
                    write_enable_aux_6000_9FFF = write_strobe && bus_addr_6000_9FFF && E1;
                    write_offset_aux_6000_9FFF = hires_write_offset[13:2];
                    hires_byte_enable_aux_6000_9FFF = hires_byte_enable;
                end
            end
        end else begin
            // only write to the aux 2000-5FFF bank when VGC_MEMORY is not set
            write_enable_aux_2000_5FFF = write_strobe && bus_addr_2000_5FFF && E1;
            write_offset_aux_2000_5FFF = hires_write_offset[13:2];
            hires_byte_enable_aux_2000_5FFF = hires_byte_enable;
        end
    end

    generate
    if (VGC_IN_SDRAM) begin : no_aux_bsram
        // Aux storage lives in SDRAM — no BSRAM banks
        assign hires_data_aux = 32'b0;
        assign hires_data_aux_6000_9FFF = 32'b0;
    end else begin : aux_bsram
        sdpram32 #(
            .ADDR_WIDTH(12)
        ) hires_aux_2000_5FFF (
            .clk(a2bus_if.clk_logic),
            .write_addr(write_offset_aux_2000_5FFF),
            .write_data(write_word),
            .write_enable(write_enable_aux_2000_5FFF),
            .byte_enable(hires_byte_enable_aux_2000_5FFF),
            .read_addr(hires_aux_read_offset),
            .read_enable(vgc_rd_i && vgc_active_i),
            .read_data(hires_data_aux)
        );

        if (VGC_MEMORY) begin
            sdpram32 #(
                .ADDR_WIDTH(12)
            ) hires_aux_6000_9FFF (
                .clk(a2bus_if.clk_logic),
                .write_addr(write_offset_aux_6000_9FFF),
                .write_data(write_word),
                .write_enable(write_enable_aux_6000_9FFF),
                .byte_enable(hires_byte_enable_aux_6000_9FFF),
                .read_addr(hires_aux_read_offset),
                .read_enable(vgc_rd_i && vgc_active_i),
                .read_data(hires_data_aux_6000_9FFF)
            );
        end else begin
            assign hires_data_aux_6000_9FFF = 32'b0;
        end
    end
    endgenerate

    // SDRAM write path — CPU writes text and hires to SDRAM

    wire write_en = !a2bus_if.rw_n &&
        a2bus_if.data_in_strobe &&
        (SHADOW_ALL_MEMORY || bus_addr_2000_5FFF || bus_addr_0400_0BFF) &&
        !a2bus_if.m2sel_n;

    generate
    if (VGC_IN_SDRAM) begin : wr_seq
        // Aux write target derived from the BSRAM-era enables: exactly one
        // (bank, word offset, byte lane) per CPU write, in both LINEARIZE
        // and non-LINEARIZE modes (the byte enables are mutually exclusive).
        wire aux_bank_w = write_enable_aux_6000_9FFF && (hires_byte_enable_aux_6000_9FFF != 4'b0);
        wire aux_wr_w = aux_bank_w ||
            (write_enable_aux_2000_5FFF && (hires_byte_enable_aux_2000_5FFF != 4'b0));
        wire [11:0] aux_off_w  = aux_bank_w ? write_offset_aux_6000_9FFF : write_offset_aux_2000_5FFF;
        wire [3:0]  aux_be1h_w = aux_bank_w ? hires_byte_enable_aux_6000_9FFF : hires_byte_enable_aux_2000_5FFF;
        wire [1:0]  aux_lane_w = aux_be1h_w[3] ? 2'd3 : aux_be1h_w[2] ? 2'd2 : aux_be1h_w[1] ? 2'd1 : 2'd0;

        // Pre-interleaved layout: source byte (bank s, word o, lane l) lands
        // at SDRAM word {o, l[1]}, byte lane {l[0], s} — exactly the word
        // interleave_mux would assemble, so a VGC fetch is one 32-bit read.
        wire [20:0] aux_word_addr_w = VGC_AUX_WORD_OFFSET + {8'b0, aux_off_w, aux_lane_w[1]};
        wire [3:0]  aux_byte_en_w = 4'(1'b1 << {aux_lane_w[0], aux_bank_w});

        // A single bus write can need two SDRAM writes: the flat shadow copy
        // (for apple_video_gen) and the pre-interleaved aux copy (for the
        // VGC). The port queues one request at a time, so sequence them —
        // bus writes are ~1 us apart, the pair completes in well under that.
        reg wr_busy_r, wr_aux_pend_r, wr_r;
        reg [20:0] wr_addr_r;
        reg [31:0] wr_data_r;
        reg [3:0]  wr_be_r;
        reg [20:0] aux_addr_r;
        reg [3:0]  aux_be_r;
        always @(posedge a2bus_if.clk_logic) begin
            if (!a2bus_if.system_reset_n) begin
                wr_busy_r     <= 1'b0;
                wr_aux_pend_r <= 1'b0;
                wr_r          <= 1'b0;
            end else if (!wr_busy_r) begin
                if (write_en || aux_wr_w) begin
                    wr_busy_r <= 1'b1;
                    wr_r      <= 1'b1;
                    wr_data_r <= write_word;
                    if (write_en) begin
                        wr_addr_r     <= {6'b0, a2bus_if.addr[15:1]};
                        wr_be_r       <= 4'(1'b1 << {a2bus_if.addr[0], aux_mem_r || a2bus_if.m2b0});
                        wr_aux_pend_r <= aux_wr_w;
                        aux_addr_r    <= aux_word_addr_w;
                        aux_be_r      <= aux_byte_en_w;
                    end else begin
                        wr_addr_r     <= aux_word_addr_w;
                        wr_be_r       <= aux_byte_en_w;
                        wr_aux_pend_r <= 1'b0;
                    end
                end
            end else if (wr_r) begin
                if (main_mem_if.ready) begin
                    wr_r <= 1'b0;
                    if (!wr_aux_pend_r) wr_busy_r <= 1'b0;
                end
            end else if (wr_aux_pend_r) begin
                // wr was low for one cycle — issue the aux copy (new edge)
                wr_addr_r     <= aux_addr_r;
                wr_be_r       <= aux_be_r;
                wr_aux_pend_r <= 1'b0;
                wr_r          <= 1'b1;
            end else begin
                wr_busy_r <= 1'b0;
            end
        end

        assign main_mem_if.rd = 1'b0;
        assign main_mem_if.wr = wr_r;
        assign main_mem_if.addr = wr_addr_r;
        assign main_mem_if.data = wr_data_r;
        assign main_mem_if.byte_en = wr_be_r;
        assign main_mem_if.burst = 1'b0;
    end else begin : wr_comb
        assign main_mem_if.rd = 1'b0;
        assign main_mem_if.wr = write_en;
        assign main_mem_if.addr = {6'b0, a2bus_if.addr[15:1]};
        assign main_mem_if.data = write_word;
        assign main_mem_if.byte_en = 1'b1 << {a2bus_if.addr[0], aux_mem_r || a2bus_if.m2b0};
        assign main_mem_if.burst = 1'b0;
    end
    endgenerate

endmodule
