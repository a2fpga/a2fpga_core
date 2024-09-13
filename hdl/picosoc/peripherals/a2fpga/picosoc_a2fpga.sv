//
// PicoSoC peripheral to interface the PicoSoC to the A2FPGA core
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
// Exposes the A2FPGA core to the PicoSoC as memory-mapped I/O
//


module picosoc_a2fpga #(parameter int CLOCK_SPEED_HZ = 0)
(
	input clk,
	input resetn,

	input iomem_valid,
	input [3:0]  iomem_wstrb,
	input [31:0] iomem_addr,
	output reg [31:0] iomem_rdata,
	output reg iomem_ready,
	input [31:0] iomem_wdata,

    a2bus_if.slave a2bus_if,
    a2mem_if.slave a2mem_if,
    a2bus_control_if.control a2bus_control_if,
    video_control_if.control video_control_if
);

    localparam ADDR_SYS_TIME =                  8'h00;      // System Time
    localparam ADDR_KEYCODE =                   8'h04;      // Keycode
    localparam ADDR_VIDEO_ENABLE =              8'h08;      // Keycode
    localparam ADDR_TEXT_MODE =                 8'h0C;      // 
    localparam ADDR_MIXED_MODE =                8'h10;      // 
    localparam ADDR_PAGE2 =                     8'h14;      // 
    localparam ADDR_HIRES_MODE =                8'h18;      // 
    localparam ADDR_AN3 =                       8'h1C;      // 
    localparam ADDR_STORE80 =                   8'h20;      // 
    localparam ADDR_COL80 =                     8'h24;      // 
    localparam ADDR_ALTCHAR =                   8'h28;      // 
    localparam ADDR_TEXT_COLOR =                8'h2C;      // 
    localparam ADDR_BACKGROUND_COLOR =          8'h30;      // 
    localparam ADDR_BORDER_COLOR =              8'h34;      // 
    localparam ADDR_MONOCHROME_MODE =           8'h38;      // 
    localparam ADDR_MONOCHROME_DHIRES_MODE =    8'h3C;      // 
    localparam ADDR_SHRG_MODE =                 8'h40;      // 
    localparam ADDR_A2_CMD =                    8'h44;      // 
    localparam ADDR_A2_DATA =                   8'h48;      // 
    localparam ADDR_COUNTDOWN =                 8'h4C;      // 
    localparam ADDR_A2BUS_READY =               8'h50;      //
    localparam ADDR_SLOT_0_CONFIG =             8'h54;      //
    localparam ADDR_SLOT_1_CONFIG =             8'h58;      //
    localparam ADDR_SLOT_2_CONFIG =             8'h5C;      //
    localparam ADDR_SLOT_3_CONFIG =             8'h60;      //
    localparam ADDR_SLOT_4_CONFIG =             8'h64;      //
    localparam ADDR_SLOT_5_CONFIG =             8'h68;      //
    localparam ADDR_SLOT_6_CONFIG =             8'h6C;      //
    localparam ADDR_SLOT_7_CONFIG =             8'h70;      //

    reg [7:0] keycode_r;

    wire [31:0] system_time_w;
    timer #(
        .CLOCK_FREQ(CLOCK_SPEED_HZ)
    ) sys_time (
        .clk(clk),
        .reset(!resetn),
        .counter(system_time_w)
    );

    wire [31:0] countdown_w;
    wire countdown_done_w;
    countdown #(
        .CLOCK_FREQ(CLOCK_SPEED_HZ)
    ) countdown (
        .clk(clk),
        .reset(!resetn),
        .we(iomem_valid & |iomem_wstrb & !iomem_addr[7] & (iomem_addr[6:2] == ADDR_COUNTDOWN[6:2])),
        .start(iomem_wdata),
        .counter(countdown_w),
        .done(countdown_done_w)
    );

    reg video_enable_r;

    reg text_mode_r = 1'b1;
    reg mixed_mode_r = 1'b1;
    reg page2_r;
    reg hires_mode_r;
    reg an3_r = 1'b1;

    reg store80_r;
    reg col80_r;
    reg altchar_r;

    reg [3:0] text_color_r = 4'd15;
    reg [3:0] background_color_r = 4'd2;
    reg [3:0] border_color_r = 4'd2;
    reg monochrome_mode_r;
    reg monochrome_dhires_mode_r;
    reg shrg_mode_r;

    reg [7:0] a2_cmd_r;

    reg a2bus_ready_r;
    assign a2bus_control_if.ready = a2bus_ready_r;

    assign video_control_if.enable = video_enable_r;
    assign video_control_if.TEXT_MODE = text_mode_r;
    assign video_control_if.MIXED_MODE = mixed_mode_r;
    assign video_control_if.PAGE2 = page2_r;
    assign video_control_if.HIRES_MODE = hires_mode_r;
    assign video_control_if.AN3 = an3_r;

    assign video_control_if.STORE80 = store80_r;
    assign video_control_if.COL80 = col80_r;
    assign video_control_if.ALTCHAR = altchar_r;

    assign video_control_if.TEXT_COLOR = text_color_r;
    assign video_control_if.BACKGROUND_COLOR = background_color_r;
    assign video_control_if.BORDER_COLOR = border_color_r;
    assign video_control_if.MONOCHROME_MODE = monochrome_mode_r;
    assign video_control_if.MONOCHROME_DHIRES_MODE = monochrome_dhires_mode_r;
    assign video_control_if.SHRG_MODE = shrg_mode_r;

	always @(posedge clk) begin
        if (a2mem_if.keypress_strobe) begin
            keycode_r <= a2mem_if.keycode;
        end

        //if (a2bus_if.rw_n && a2bus_if.data_in_strobe && (a2bus_if.addr == 16'hC000)) begin
        //    keycode_r <= a2bus_if.data;
        //end 

        if (!a2bus_if.rw_n && a2bus_if.data_in_strobe && (a2bus_if.addr == 16'hC7FF)) begin
            a2_cmd_r <= a2bus_if.data;
        end

      	iomem_ready <= 0;
        iomem_rdata <= 32'b0;

        if (iomem_valid) begin
            if (|iomem_wstrb) begin
                case (iomem_addr[6:2])
                    ADDR_KEYCODE[6:2]: keycode_r <= iomem_wdata[7:0];
                    ADDR_VIDEO_ENABLE[6:2]: video_enable_r <= iomem_wdata[0];
                    ADDR_TEXT_MODE[6:2]: text_mode_r <= iomem_wdata[0];
                    ADDR_MIXED_MODE[6:2]: mixed_mode_r <= iomem_wdata[0];
                    ADDR_PAGE2[6:2]: page2_r <= iomem_wdata[0];
                    ADDR_HIRES_MODE[6:2]: hires_mode_r <= iomem_wdata[0];
                    ADDR_AN3[6:2]: an3_r <= iomem_wdata[0];
                    ADDR_STORE80[6:2]: store80_r <= iomem_wdata[0];
                    ADDR_COL80[6:2]: col80_r <= iomem_wdata[0];
                    ADDR_ALTCHAR[6:2]: altchar_r <= iomem_wdata[0];
                    ADDR_TEXT_COLOR[6:2]: text_color_r <= iomem_wdata[3:0];
                    ADDR_BACKGROUND_COLOR[6:2]: background_color_r <= iomem_wdata[3:0];
                    ADDR_BORDER_COLOR[6:2]: border_color_r <= iomem_wdata[3:0];
                    ADDR_MONOCHROME_MODE[6:2]: monochrome_mode_r <= iomem_wdata[0];
                    ADDR_MONOCHROME_DHIRES_MODE[6:2]: monochrome_dhires_mode_r <= iomem_wdata[0];
                    ADDR_SHRG_MODE[6:2]: shrg_mode_r <= iomem_wdata[0];
                    ADDR_A2_CMD[6:2]: a2_cmd_r <= iomem_wdata[7:0];
                    ADDR_A2BUS_READY[6:2]: a2bus_ready_r <= iomem_wdata[0];
                    default: ;
                endcase
            end else begin
                case (iomem_addr[6:2])
                    ADDR_SYS_TIME[6:2]: iomem_rdata <= system_time_w;
                    ADDR_KEYCODE[6:2]: iomem_rdata <= {25'b0, keycode_r[6:0]};
                    ADDR_VIDEO_ENABLE[6:2]: iomem_rdata <= {31'b0, video_enable_r};
                    ADDR_TEXT_MODE[6:2]: iomem_rdata <= {31'b0, text_mode_r};
                    ADDR_MIXED_MODE[6:2]: iomem_rdata <= {31'b0, mixed_mode_r};
                    ADDR_PAGE2[6:2]: iomem_rdata <= {31'b0, page2_r};
                    ADDR_HIRES_MODE[6:2]: iomem_rdata <= {31'b0, hires_mode_r};
                    ADDR_AN3[6:2]: iomem_rdata <= {31'b0, an3_r};
                    ADDR_STORE80[6:2]: iomem_rdata <= {31'b0, store80_r};
                    ADDR_COL80[6:2]: iomem_rdata <= {31'b0, col80_r};
                    ADDR_ALTCHAR[6:2]: iomem_rdata <= {31'b0, altchar_r};
                    ADDR_TEXT_COLOR[6:2]: iomem_rdata <= {28'b0, text_color_r};
                    ADDR_BACKGROUND_COLOR[6:2]: iomem_rdata <= {28'b0, background_color_r};
                    ADDR_BORDER_COLOR[6:2]: iomem_rdata <= {28'b0, border_color_r};
                    ADDR_MONOCHROME_MODE[6:2]: iomem_rdata <= {31'b0, monochrome_mode_r};
                    ADDR_MONOCHROME_DHIRES_MODE[6:2]: iomem_rdata <= {31'b0, monochrome_dhires_mode_r};
                    ADDR_SHRG_MODE[6:2]: iomem_rdata <= {31'b0, shrg_mode_r};
                    ADDR_A2_CMD[6:2]: iomem_rdata <= {24'b0, a2_cmd_r};
                    ADDR_COUNTDOWN[6:2]: iomem_rdata <= countdown_w;
                    ADDR_A2BUS_READY[6:2]: iomem_rdata <= {31'b0, a2bus_ready_r};
                    default: ;
                endcase
            end

            iomem_ready <= 1;
        end
	end

endmodule
