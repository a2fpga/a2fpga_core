// A2P25 - Apple II Bus Interface
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
    parameter int GS = 0,
    parameter int CLOCK_SPEED_HZ = 54_000_000,                      // 18.52 ns
    parameter int APPLE_HZ = 14_318_181,
    parameter bit ENABLE_DENOISE = 0,
    parameter int CYCLE_COUNT = CLOCK_SPEED_HZ * 14 / APPLE_HZ,     // 52
    parameter int APPLE_14M_CYCLE_COUNT = CLOCK_SPEED_HZ / APPLE_HZ, // 3
    parameter int PHASE_COUNT = CYCLE_COUNT / 2,                    // 26
    parameter int M2B0_COUNT = 12,
    parameter int ADDR_COUNT = 18,                                  // 333ns from Phi1 rising edge
    parameter int DATA_COUNT = 15                                   // 419ns from Phi0 rising edge
) (
    input clk_logic_i,
    input clk_pixel_i,
    input system_reset_n_i,
    input device_reset_n_i,
    input a2_phi1_i,
    input a2_q3_i,
    input a2_7M_i,

    a2bus_if.master a2bus_if,

    input [15:0] a2_a_i,
    input [7:0] a2_d_i,
    input a2_rw_n_i,

    input  a2_inh_n,
    input  a2_rdy_n,
    input  a2_dma_n,
    input  a2_nmi_n,
    input  a2_reset_n,
    input  a2_mb20,
    input  a2_sync_n,
    input  a2_m2sel_n,
    output  a2_res_out_n,
    output  a2_int_out_n,
    input  a2_int_in_n,
    output  a2_dma_out_n,
    input  a2_dma_in_n,

    input irq_n_i,

    output sleep_o

);

    assign a2_dma_out_n = a2_dma_in_n;
    assign a2_int_out_n = a2_int_in_n;
    assign a2_res_out_n = 1'b0;
    
    assign a2bus_if.clk_logic = clk_logic_i;
    assign a2bus_if.clk_pixel = clk_pixel_i;
    assign a2bus_if.system_reset_n = system_reset_n_i;
    assign a2bus_if.device_reset_n = device_reset_n_i;

    a2bus_timing #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ),
        .ENABLE_DENOISE(ENABLE_DENOISE)
    ) a2bus_timing_inst(
        .clk_logic_i(clk_logic_i),
        .a2_phi1_i(a2_phi1_i),
        .a2_q3_i(a2_q3_i),
        .a2_7M_i(a2_7M_i),

        .phi0_o(a2bus_if.phi0),
        .phi0_posedge_o(a2bus_if.phi0_posedge),
        .phi0_negedge_o(a2bus_if.phi0_negedge),
        
        .phi1_o(a2bus_if.phi1),
        .phi1_posedge_o(a2bus_if.phi1_posedge),
        .phi1_negedge_o(a2bus_if.phi1_negedge),
        
        .q3_o(a2bus_if.clk_q3),
        .q3_posedge_o(a2bus_if.clk_q3_posedge),
        .q3_negedge_o(a2bus_if.clk_q3_negedge),
        
        .clk_7M_o(a2bus_if.clk_7M),
        .clk_7M_posedge_o(a2bus_if.clk_7M_posedge),
        .clk_7M_negedge_o(a2bus_if.clk_7M_negedge),
        
        .clk_14M_posedge_o(a2bus_if.clk_14M_posedge)
    );

    // data and address latches on input
    reg [15:0] addr_r;
    reg [7:0] data_r;
    reg rw_n_r;
    reg m2sel_n_r;

    assign a2bus_if.addr = addr_r;
    assign a2bus_if.data = data_r;
    assign a2bus_if.rw_n = rw_n_r;

    wire a2_gs = GS;
    assign a2bus_if.sw_gs = a2_gs;
    assign a2bus_if.m2sel_n = a2_gs ? m2sel_n_r : 1'b0;

    reg m2b0_r;
    wire a2_m2b0_w;
    cdc_2ff cdc_2ff_inst(.clk(a2bus_if.clk_logic), .i(a2_gs ? a2_mb20 : 1'b0), .o(a2_m2b0_w));
	//always @(posedge a2bus_if.clk_logic) begin
    //    if (a2bus_if.phi1 && a2bus_if.clk_q3_negedge) m2b0_r <= a2_gs ? a2_mb20 : 1'b0;
	//end
    assign a2bus_if.m2b0 = m2b0_r; 

    assign a2bus_if.control_inh_n = a2_inh_n;
    assign a2bus_if.control_irq_n = 1'b1;
    assign a2bus_if.control_rdy_n = a2_rdy_n;
    assign a2bus_if.control_dma_n = a2_dma_n;
    assign a2bus_if.control_nmi_n = a2_nmi_n;
    assign a2bus_if.control_reset_n = a2_reset_n;

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

    // tuned bus timings
    // We need to account for delays due to CDC delays and actual bus signal setup times

    // Apple TN# 68 - Tips for I/O Expansion Slot Card Design
    // We're seeing the falling edge of Q3 too late, need to sample earlier
    wire a2_m2b0_start_w = a2bus_if.phi1 && (phase_cycles_r == M2B0_COUNT);
    always @(posedge a2bus_if.clk_logic) begin
        if (a2bus_if.phi1 && a2_m2b0_start_w) m2b0_r <= a2_m2b0_w;
	end

    // Per Gaylor timing diagrams, sample address from bus at 350ns from Phi1 rising edge
    wire a2_addr_in_start_w = a2bus_if.phi1 && (phase_cycles_r == ADDR_COUNT);

    always @(posedge a2bus_if.clk_logic) begin

        if (a2_addr_in_start_w) begin
            addr_r <= a2_a_i;
            rw_n_r <= a2_rw_n_i;
            m2sel_n_r <= a2_m2sel_n;
        end

    end

    // Per Gaylor timing diagrams, sample data from bus at 419ns from Phi0 rising edge
    // /CAS goes high
    // tuned to 300ns from Phi0 rising edge (15 cycles)
    wire a2_data_in_valid_w = a2bus_if.phi0 && (phase_cycles_r == DATA_COUNT);
    //wire a2_data_in_start_w = a2_data_in_valid_w && !rw_n_r;
    reg data_in_strobe_r;

    always @(posedge a2bus_if.clk_logic) begin
        data_in_strobe_r <= 1'b0;
        if (a2_data_in_valid_w) begin
            if (!rw_n_r) data_r <= a2_d_i;
            data_in_strobe_r <= 1'b1;
        end

    end

    assign a2bus_if.data_in_strobe = data_in_strobe_r;

    reg [6:0] cycle_timer_r = 0;
    reg extended_cycle_r = 0;
    assign a2bus_if.extended_cycle = extended_cycle_r;
    always @(posedge a2bus_if.clk_logic) begin
        extended_cycle_r <= 0;
        cycle_timer_r <= cycle_timer_r + 1'b1;
        // capture cycle transitions and count cycles
        if (a2bus_if.phi1_posedge) begin
            cycle_timer_r <= 7'b0;
            // check if last cycle was extended duration
            if (cycle_timer_r >= (CYCLE_COUNT + APPLE_14M_CYCLE_COUNT)) begin
                extended_cycle_r <= 1'b1;
            end
        end

    end

endmodule
