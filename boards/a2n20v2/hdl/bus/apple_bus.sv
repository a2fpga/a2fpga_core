// A2N20 Version 2 - Apple II Bus Interface
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
// Interface with the Apple II Bus and sample the address and data lines
// at specific timings per the Apple II bus timing diagram in
// The Apple II Circuit Description.
// Hold the address, data, and control lines until the next sample.
// Provide control strobes that indicate when these values have been
// sampled.
//

module apple_bus #(
    parameter int CLOCK_SPEED_HZ = 50_000_000,
    parameter int APPLE_HZ = 14_318_181,
    parameter int CPU_HZ = APPLE_HZ / 14,                   // 1_022_727
    parameter int CYCLE_COUNT = CLOCK_SPEED_HZ / CPU_HZ,    // 49
    parameter int PHASE_COUNT = CYCLE_COUNT / 2,            // 24
    parameter int READ_COUNT = CYCLE_COUNT / 3,             // 16
    parameter int WRITE_COUNT = CYCLE_COUNT / 5             // 10
) (
    a2bus_if.master a2bus_if,

    output reg [2:0] a2_bridge_sel_o,
    output reg a2_bridge_bus_a_oe_n_o,
    output wire a2_bridge_bus_d_oe_n_o,
    output reg a2_bridge_rd_n_o,
    output reg a2_bridge_wr_n_o,
    input [7:0] a2_bridge_d_i,
    output reg [7:0] a2_bridge_d_o,
    output reg a2_bridge_d_oe_o,

    input data_out_en_i,
    input [7:0] data_out_i,

    input irq_n_i,

    output reg [3:0] dip_switches_n_o,

    output sleep_o

);

    // data and address latches on input
    reg [15:0] addr_r;
    reg [7:0] data_r;
    reg rw_n_r;
    reg m2sel_n_r;
    reg m2b0_r;

    reg [7:0] control_in_r;
    reg [7:0] control_out_r;
    reg [7:0] prev_control_out_r;

    always @(posedge a2bus_if.clk_logic) begin

        if (!a2bus_if.device_reset_n) begin
            control_out_r <= 8'hFF;
        end else begin
            control_out_r[2] <=  irq_n_i;
        end
    end

    wire sw_gs_w = !dip_switches_n_o[3];
    assign a2bus_if.sw_gs = sw_gs_w;

    assign a2bus_if.addr = addr_r;
    assign a2bus_if.m2sel_n = sw_gs_w ? m2sel_n_r : 0; 
    assign a2bus_if.m2b0 = sw_gs_w ? m2b0_r : 0; 
    //assign a2bus_if.m2b0 = 0; 
    assign a2bus_if.data = data_r;
    assign a2bus_if.rw_n = rw_n_r;

    reg [5:0] phase_cycles_r = 0;
    assign sleep_o = phase_cycles_r == 6'b111111;

    always @(posedge a2bus_if.clk_logic) begin

        // capture phase transtitions and count cycles
        if (a2bus_if.phi1_posedge || a2bus_if.phi1_negedge) begin
            phase_cycles_r <= 6'b0;
        end else if (phase_cycles_r != 6'b111111) begin
            phase_cycles_r <= phase_cycles_r + 1'b1;
        end

    end

    reg data_in_strobe_r;

    localparam [2:0] IO_INIT = 3'd0;
    localparam [2:0] IO_IDLE = 3'd1;
    localparam [2:0] IO_READ_ADDR = 3'd2;
    localparam [2:0] IO_WRITE_ADDR = 3'd3;
    localparam [2:0] IO_READ_DATA = 3'd4;
    localparam [2:0] IO_WRITE_DATA = 3'd5;
    localparam [2:0] IO_READ_GPIO = 3'd6;
    localparam [2:0] IO_WRITE_GPIO = 3'd7;

    reg [2:0] io_state = IO_INIT;
    reg [2:0] next_io_state = IO_IDLE;
    wire io_state_pending = (next_io_state != IO_IDLE);
    reg [2:0] io_cycle = 0;

    always @(posedge a2bus_if.clk_logic) begin

        if (!a2bus_if.device_reset_n) begin
            data_in_strobe_r <= 1'b0;

            a2_bridge_sel_o <= 3'b00;
            a2_bridge_bus_a_oe_n_o <= 1'b1;
            a2_bridge_rd_n_o <= 1'b1;
            a2_bridge_wr_n_o <= 1'b1;
            a2_bridge_d_o <= 8'b0;
            a2_bridge_d_oe_o <= 1'b0;

            control_in_r <= 8'hFF;
            prev_control_out_r <= 8'hFF;

            io_cycle <= 0;

            io_state = IO_INIT;
            next_io_state = IO_IDLE;
        end else begin
            data_in_strobe_r <= 1'b0;

            if (a2bus_if.phi1 && (phase_cycles_r == READ_COUNT)) begin
                next_io_state <= IO_READ_ADDR;
            end else if (a2bus_if.phi0 && (phase_cycles_r == WRITE_COUNT) && data_out_en_i) begin
                next_io_state <= IO_WRITE_DATA;
            end else if (a2bus_if.phi0 && (phase_cycles_r == READ_COUNT)) begin
                next_io_state <= IO_READ_DATA;
            end else if (!io_state_pending && (control_out_r != prev_control_out_r)) begin
                next_io_state <= IO_WRITE_GPIO;
                prev_control_out_r <= control_out_r;
            end

            case (io_state) 
                IO_INIT : begin
                    io_cycle <= io_cycle + 1'b1;
                    if (io_cycle == 3'd0) begin
                        a2_bridge_sel_o <= 3'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b1;
                        a2_bridge_d_o <= 8'b11111111;
                        a2_bridge_d_oe_o <= 1'b1;
                    end else if (io_cycle == 3'd1) begin
                        a2_bridge_sel_o <= 3'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b0;
                        a2_bridge_d_oe_o <= 1'b1;
                    end else if (io_cycle == 3'd2) begin
                        a2_bridge_sel_o <= 3'd5;
                        a2_bridge_rd_n_o <= 1'b0;
                        a2_bridge_wr_n_o <= 1'b1;
                        a2_bridge_d_oe_o <= 1'b0;
                    end else if (io_cycle == 3'd3) begin
                        dip_switches_n_o <= a2_bridge_d_i[3:0];
                        a2_bridge_sel_o <= 3'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b1;
                        a2_bridge_d_oe_o <= 1'b0;
                        io_state <= IO_IDLE;
                        next_io_state <= IO_IDLE;
                    end  
                end
                IO_IDLE : begin
                    io_cycle <= 0;

                    // Sample control lines on idle
                    if ((a2_bridge_sel_o == 3'b00) && a2_bridge_rd_n_o) control_in_r <= a2_bridge_d_i;
                    a2_bridge_sel_o <= 3'd0;
                    a2_bridge_rd_n_o <= 1'b0;
                    a2_bridge_wr_n_o <= 1'b1;

                    // Move to next state if requested
                    if (io_state_pending) begin
                        io_state <= next_io_state;
                        next_io_state <= IO_IDLE;
                    end
                end
                IO_READ_ADDR : begin
                    io_cycle <= io_cycle + 1'b1;
                    if (io_cycle == 3'd0) begin
                        a2_bridge_sel_o <= 3'd2;
                        a2_bridge_rd_n_o <= 1'b0;
                    end else if (io_cycle == 3'd1) begin
                        addr_r[7:0] <= a2_bridge_d_i;
                        a2_bridge_sel_o <= 3'd3;
                    end else if (io_cycle == 3'd2) begin
                        addr_r[15:8] <= a2_bridge_d_i;
                        a2_bridge_sel_o <= 3'd0;
                    end else if (io_cycle == 3'd3) begin
                        rw_n_r <= a2_bridge_d_i[0];
                        a2_bridge_sel_o <= 3'd4;
                    end else if (io_cycle == 3'd4) begin
                        m2b0_r <= a2_bridge_d_i[0];
                        m2sel_n_r <= a2_bridge_d_i[1];
                        a2_bridge_rd_n_o <= 1'b1;
                        io_state <= IO_IDLE;
                    end  
                end
                IO_READ_DATA : begin
                    io_cycle <= io_cycle + 1'b1;
                    if (io_cycle == 3'd0) begin
                        a2_bridge_sel_o <= 3'd1;
                        a2_bridge_rd_n_o <= 1'b0;
                    end else if (io_cycle == 3'd1) begin
                        data_r <= a2_bridge_d_i;
                        data_in_strobe_r <= !a2bus_if.m2sel_n;
                        a2_bridge_sel_o <= 2'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        io_state <= IO_IDLE;
                    end  
                end
                IO_WRITE_DATA : begin
                    io_cycle <= io_cycle + 1'b1;
                    if (io_cycle == 3'd0) begin
                        a2_bridge_sel_o <= 3'd1;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b1;
                        a2_bridge_d_o <= data_out_i;
                        a2_bridge_d_oe_o <= 1'b1;
                    end else if (io_cycle == 3'd1) begin
                        a2_bridge_sel_o <= 3'd1;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b0;
                        a2_bridge_d_oe_o <= 1'b1;
                    end else if (io_cycle == 3'd2) begin
                        a2_bridge_sel_o <= 3'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b1;
                        a2_bridge_d_oe_o <= 1'b0;
                        io_state <= IO_IDLE;
                    end  
                end
                IO_WRITE_GPIO : begin
                    io_cycle <= io_cycle + 1'b1;
                    if (io_cycle == 3'd0) begin
                        a2_bridge_sel_o <= 3'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b1;
                        a2_bridge_d_o <= control_out_r;
                        a2_bridge_d_oe_o <= 1'b1;
                    end else if (io_cycle == 3'd1) begin
                        a2_bridge_sel_o <= 3'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b0;
                        a2_bridge_d_oe_o <= 1'b1;
                    end else if (io_cycle == 3'd2) begin
                        a2_bridge_sel_o <= 3'd0;
                        a2_bridge_rd_n_o <= 1'b1;
                        a2_bridge_wr_n_o <= 1'b1;
                        a2_bridge_d_oe_o <= 1'b0;
                        io_state <= IO_IDLE;
                    end  
                end
            endcase
        end

    end

    assign a2_bridge_bus_d_oe_n_o = !data_out_en_i;

    assign a2bus_if.data_in_strobe = data_in_strobe_r;


endmodule
