// A2N20v2-SDRAM - Tang Nano 20K SDRAM Version
//
// Handle the writing of data to the shadow memory copy of the Apple II's
// memory that is kept in the FPGA's SDRAM.
//

module apple_memory #(
    parameter SHADOW_ALL_MEMORY = 1'b0  // 1 = shadow all memory, 0 = shadow only video memory
) (
    a2bus_if.slave a2bus_if,
    a2mem_if.master a2mem_if,
    
    sdram_port_if.client main_mem_if,
    sdram_port_if.client video_mem_if,
    
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
    reg switches_ii_r[8];
    assign a2mem_if.TEXT_MODE = switches_ii_r[0];
    assign a2mem_if.MIXED_MODE = switches_ii_r[1];
    assign a2mem_if.PAGE2 = switches_ii_r[2];
    assign a2mem_if.HIRES_MODE = switches_ii_r[3];
    assign a2mem_if.AN0 = switches_ii_r[4];
    assign a2mem_if.AN1 = switches_ii_r[5];
    assign a2mem_if.AN2 = switches_ii_r[6];
    assign a2mem_if.AN3 = switches_ii_r[7];

    // ][e auxilary switches
    reg switches_iie_r[8];
    assign a2mem_if.STORE80 = switches_iie_r[0];
    assign a2mem_if.RAMRD = switches_iie_r[1];
    assign a2mem_if.RAMWRT = switches_iie_r[2];
    assign a2mem_if.CXROM = switches_iie_r[3];
    assign a2mem_if.ALTZP = switches_iie_r[4];
    assign a2mem_if.C3ROM = switches_iie_r[5];
    assign a2mem_if.COL80 = switches_iie_r[6];
    assign a2mem_if.ALTCHAR = switches_iie_r[7];

    reg [3:0] text_color_r;
    reg [3:0] background_color_r;
    reg [3:0] border_color_r;
    reg monochrome_mode_r;
    reg monochrome_dhires_mode_r;
    reg shrg_mode_r;

    assign a2mem_if.TEXT_COLOR = text_color_r;
    assign a2mem_if.BACKGROUND_COLOR = background_color_r;
    assign a2mem_if.BORDER_COLOR = border_color_r;
    assign a2mem_if.MONOCHROME_MODE = monochrome_mode_r;
    assign a2mem_if.MONOCHROME_DHIRES_MODE = monochrome_dhires_mode_r;
    assign a2mem_if.SHRG_MODE = shrg_mode_r;

    // capture the soft switches
    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            switches_ii_r <= '{1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1};
        end else if ((a2bus_if.phi1_posedge) && (a2bus_if.addr[15:4] == 12'hC05) && !a2bus_if.m2sel_n)
            switches_ii_r[a2bus_if.addr[3:1]] <= a2bus_if.addr[0];
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            switches_iie_r <= '{8{1'b0}};
        end else if (!a2bus_if.rw_n && (a2bus_if.phi1_posedge) && (a2bus_if.addr[15:4] == 12'hC00) && !a2bus_if.m2sel_n) 
            switches_iie_r[a2bus_if.addr[3:1]] <= a2bus_if.addr[0];
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.device_reset_n) begin
        if (!a2bus_if.device_reset_n) begin
            background_color_r <= 4'h0;
            text_color_r <= 4'hF;
        end else if (write_strobe && (a2bus_if.addr == 16'hC022)) begin
            background_color_r <= a2bus_if.data[3:0];
            text_color_r <= a2bus_if.data[7:4];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.device_reset_n) begin
        if (!a2bus_if.device_reset_n) begin
            border_color_r <= 4'h0;
        end else if (write_strobe && (a2bus_if.addr == 16'hC034)) begin
            border_color_r <= a2bus_if.data[3:0];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            monochrome_mode_r <= 1'b0;
        end else if (write_strobe && (a2bus_if.addr == 16'hC021)) begin
            monochrome_mode_r <= a2bus_if.data[7];
        end
    end

    always @(posedge a2bus_if.clk_logic or negedge a2bus_if.system_reset_n) begin
        if (!a2bus_if.system_reset_n) begin
            monochrome_dhires_mode_r <= 1'b0;
            shrg_mode_r <= 1'b0;
        end else if (write_strobe && (a2bus_if.addr == 16'hC029)) begin
            monochrome_dhires_mode_r <= a2bus_if.data[5];
            shrg_mode_r <= a2bus_if.data[7];
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

    reg aux_mem_r;
    
    always @(*)
    begin: aux_ctrl
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

    // Apple II bus address ranges
    wire bus_addr_0400_0BFF = a2bus_if.addr[15:10] inside {6'b000001, 3'b000010};
    wire bus_addr_2000_5FFF = a2bus_if.addr[15:13] inside {3'b001, 3'b010};
    wire bus_addr_6000_9FFF = a2bus_if.addr[15:13] inside {3'b011, 3'b100};
    wire bus_addr_2000_9FFF = bus_addr_2000_5FFF || bus_addr_6000_9FFF;

    wire write_en = !a2bus_if.rw_n && 
        a2bus_if.data_in_strobe && 
        (SHADOW_ALL_MEMORY || bus_addr_2000_5FFF || bus_addr_0400_0BFF) && 
        !a2bus_if.m2sel_n;

    wire [31:0] write_word = {a2bus_if.data, a2bus_if.data, a2bus_if.data, a2bus_if.data};

    assign main_mem_if.rd = 1'b0;
    assign main_mem_if.wr = write_en;
    assign main_mem_if.addr = {6'b0, a2bus_if.addr[15:1]};
    assign main_mem_if.data = write_word;
    assign main_mem_if.byte_en = 1'b1 << {a2bus_if.addr[0], aux_mem_r || a2bus_if.m2b0};

    assign video_mem_if.rd = video_rd_i;
    assign video_mem_if.wr = 1'b0;
    assign video_mem_if.addr = {5'b0, video_bank_i, video_address_i[15:1]};
    assign video_mem_if.data = 32'b0;
    assign video_mem_if.byte_en = 4'b1111;
    assign video_data_o = video_mem_if.q;

    wire [14:0] hires_write_offset = 15'({3'(a2bus_if.addr[15:13] - 1'b1), a2bus_if.addr[12:0]});

    sdpram32 #(
        .ADDR_WIDTH(13)
    ) hires_aux (
        .clk(a2bus_if.clk_logic),
        .write_addr(hires_write_offset[14:2]),
        .write_data(write_word),
        .write_enable(write_strobe && bus_addr_2000_9FFF && E1),
        .byte_enable(4'(1 << hires_write_offset[1:0])),
        .read_addr(vgc_address_i),
        .read_enable(1'b1),
        .read_data(vgc_data_o)
    );

endmodule
