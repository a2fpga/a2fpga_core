// A2N20v2_enhanced - Tang Nano 20K SDRAM implementation of Apple II memory
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
// Handle the writing of data to the shadow memory copy of the Apple II's
// memory that is kept in the FPGA's SDRAM. IIgs SHRG memory is in blockram.
//

module apple_memory #(
    parameter SHADOW_ALL_MEMORY = 1'b0  // 1 = shadow all memory, 0 = shadow only video memory
) (
    a2bus_if.slave a2bus_if,
    a2mem_if.master a2mem_if,
    
    mem_port_if.client main_mem_if,
    mem_port_if.client video_mem_if,
    
    input [15:0] video_address_i,
    input video_bank_i,
    input video_rd_i,
    output [31:0] video_data_o,

    input vgc_active_i,
    input [12:0] vgc_address_i,
    input vgc_rd_i,
    output [31:0] vgc_data_o

);

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

    // Aux memory bank, linear
    
    // The aux memory bank for hires is 16KB, but but when VGC_MEMORY is set, an additional 16KB is added

    // Set up reads and combine ouputs for VGC

    wire [11:0] hires_aux_read_offset = vgc_address_i[12:1];
    
    wire [31:0] hires_data_aux_6000_9FFF;

    assign vgc_data_o = vgc_active_i ? interleave_mux(vgc_address_i[0], hires_data_aux, hires_data_aux_6000_9FFF) : 32'b0;

    // Set up writes

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

    end

    sdpram32 #(
        .ADDR_WIDTH(12)
    ) hires_aux_2000_5FFF (
        .clk(a2bus_if.clk_logic),
        .write_addr(write_offset_aux_2000_5FFF),
        .write_data(write_word),
        .write_enable(write_enable_aux_2000_5FFF),
        .byte_enable(hires_byte_enable_aux_2000_5FFF),
        .read_addr(hires_aux_read_offset),
        .read_enable(1'b1),
        .read_data(hires_data_aux)
    );

    sdpram32 #(
        .ADDR_WIDTH(12)
    ) hires_aux_6000_9FFF (
        .clk(a2bus_if.clk_logic),
        .write_addr(write_offset_aux_6000_9FFF),
        .write_data(write_word),
        .write_enable(write_enable_aux_6000_9FFF),
        .byte_enable(hires_byte_enable_aux_6000_9FFF),
        .read_addr(hires_aux_read_offset),
        .read_enable(1'b1),
        .read_data(hires_data_aux_6000_9FFF)
    );

    // SDRAM interace

    wire write_en = !a2bus_if.rw_n && 
        a2bus_if.data_in_strobe && 
        (SHADOW_ALL_MEMORY || bus_addr_2000_5FFF || bus_addr_0400_0BFF) && 
        !a2bus_if.m2sel_n;

    assign main_mem_if.rd = 1'b0;
    assign main_mem_if.wr = write_en;
    assign main_mem_if.addr = {6'b0, a2bus_if.addr[15:1]};
    assign main_mem_if.data = write_word;
    assign main_mem_if.byte_en = 1'b1 << {a2bus_if.addr[0], aux_mem_r || a2bus_if.m2b0};
    assign main_mem_if.burst = 1'b0;

    assign video_mem_if.rd = video_rd_i;
    assign video_mem_if.wr = 1'b0;
    assign video_mem_if.addr = {5'b0, video_bank_i, video_address_i[15:1]};
    assign video_mem_if.data = 32'b0;
    assign video_mem_if.byte_en = 4'b1111;
    assign video_mem_if.burst = 1'b0;
    assign video_data_o = video_mem_if.q;

endmodule
