// Ensoniq DOC5503 Sound Engine
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
// The DOC5503 is a 32 voice polyphonic sound engine used in the Apple IIgs and
// a number of Ensoniq synthesizers. It is a digital sound engine that uses
// wavetable synthesis to produce sound.
//
// The DOC5503 consists of 32 time-multiplexed digital oscillators that are
// mixed together to produce the final output. Each oscillator has a 24-bit
// accumulator that is used to address a 256 to 32768 byte wavetable in the
// system's RAM. The accumulator is incremented by a frequency value that is
// loaded from a 16-bit frequency register. The output of the wavetable is
// scaled by a 8-bit volume register and then mixed with the outputs of the
// other oscillators.
//
// In the IIgs, the DOC5503 is clocked using the Apple II 7.15909 MHz clock
// rather than its intended 8 MHz clock. The 7.15909 MHz clock is derived from
// the 14.31818 MHz clock that is used to drive the video system. The DOC5503
// divdes this clock by 8 for every oscillator cycle, so the effective
// oscillator maximum frequency is 894886.25 Hz. This module is assumed to be
// clocked at at least 50 MHz on clk_i with a single clk pulse on clk_en_i
// on 7.15909 MHz clock timing.  Although the main DOC5503 FSM operates on the
// clk_en_i pulse, register memory and the oscillator outputs are updated on
// the rising edge of clk_i. At 50 MHz, there are aproximately 5 clk_i pulses
// in between each clk_en_i pulse that can be used to update the control
// registers before the next FSM state change.
//
// The core logic of the DOC5503 is not particularly complex, but the large
// number of oscillators and the control registers for each oscillator make
// for a complex memory structure that is difficult to implement as a typical
// register file. This module is designed to provide the memory access logic
// for the DOC5503 and to infer the memory as block RAMs or distributed RAMs
// during synthesis. This is implemented in the companion doc5503_register_ram
// module. The use of the doc5503_register_ram module for the control registers
// greatly simplifies the logic in the main FSM since the control registers
// can be easily read and modified asynchronously to the FSM's state changes
// on clk_en_i pulses.
//

module doc5503 #(
    parameter int OUTPUT_CHANNEL_MIX = 1,
    parameter int NUM_CHANNELS = 16,
    parameter int OUTPUT_MONO_MIX = 1,
    parameter int OUTPUT_STEREO_MIX = 1,
    parameter int CHANNEL_MAX = OUTPUT_CHANNEL_MIX && (NUM_CHANNELS > 1) ? NUM_CHANNELS - 1 : 1
) (
    input clk_i,
    input reset_n_i,
    input clk_en_i,

    output reg irq_n_o,

    input cs_n_i,
    input we_n_i,

    input [7:0] addr_i,
    input [7:0] data_i,
    output reg [7:0] data_o,

    output reg [15:0] wave_address_o,
    output reg wave_rd_o,
    input wave_data_ready_i,
    input [7:0] wave_data_i,

    output signed [15:0] mono_mix_o,
    output signed [15:0] left_mix_o,
    output signed [15:0] right_mix_o,

    output signed [15:0] channel_o[CHANNEL_MAX:0]

);

    reg [7:0] osc_int_r;            // Oscillator Interrupt Register
    reg [7:0] osc_en_r;             // Oscillator Enable Register

    wire [15:0] f_w;
    wire [7:0] vol_w;
    wire [7:0] wds_w;
    wire [7:0] wtp_w;
    wire [7:0] rts_w;
    wire [7:0] control_w;
    wire [7:0] partner_control_w;
    wire [7:0] next_control_w;

    wire [7:0] fl_o_w;
    wire [7:0] fh_o_w;
    wire [7:0] vol_o_w;
    wire [7:0] wds_o_w;
    wire [7:0] wtp_o_w;
    wire [7:0] control_o_w;
    wire [7:0] rts_o_w;

    assign data_o = addr_i[7:5] == 3'b000 ? fl_o_w :
        addr_i[7:5] == 3'b001 ? fh_o_w :
        addr_i[7:5] == 3'b010 ? vol_o_w :
        addr_i[7:5] == 3'b011 ? wds_o_w :
        addr_i[7:5] == 3'b100 ? wtp_o_w :
        addr_i[7:5] == 3'b101 ? control_o_w :
        addr_i[7:5] == 3'b110 ? rts_o_w :
        addr_i == 8'hE0 ? osc_int_r :
        addr_i == 8'hE1 ? osc_en_r :
        8'b0;

    wire odd_osc_w = cycle_r[0];
    wire even_osc_w = ~odd_osc_w;
    wire [4:0] partner_w = 5'(cycle_r^1);

    wire [2:0] wts_w = rts_w[5:3];
    wire [2:0] res_w = rts_w[2:0];

    wire halt_w = control_w[0];
    wire [1:0] mode_w = control_w[2:1];

    wire partner_halt_w = partner_control_w[0];
    wire [1:0] partner_mode_w = partner_control_w[2:1];

    wire next_halt_w = next_control_w[0];
    wire [1:0] next_mode_w = next_control_w[2:1];

    wire [23:0] acc_w;
    reg [15:0] wave_addr_r;

    localparam [1:0] MODE_FREE = 2'b00;
	localparam [1:0] MODE_ONESHOT = 2'b01;
    localparam [1:0] MODE_SYNC_AM = 2'b10;
    localparam [1:0] MODE_SWAP = 2'b11;

    reg [4:0] cycle_r;
    reg [4:0] cycle_step_r;
    wire [4:0] osc_en_num_w = osc_en_r[5:1];
    wire [4:0] cycle_max_w = osc_en_num_w == 0 ? 0 : 5'(osc_en_num_w - 1'b1);

    reg [5:0] mixer_cycle_r;
    wire [7:0] mixer_control_w;
    wire signed [15:0] mixer_output_w;

    reg [4:0] last_osc_r;

    reg ready_r;
    reg [4:0] init_cycle_r;

    always @(posedge clk_i) begin
        if (!reset_n_i) begin
            ready_r <= 1'b0;
            init_cycle_r <= '0;
        end else begin
            if (!ready_r) begin
                init_cycle_r <= init_cycle_r + 1'd1;
                if (init_cycle_r == 5'd31) begin
                    ready_r <= 1'b1;
                end
            end
        end
    end

    // cycles are 8 steps long except for last cycle is 24 steps long, corresponds to RAM refresh
    wire last_cycle_w = cycle_r == cycle_max_w;
    wire last_cycle_step_w = last_cycle_w ? (cycle_step_r == 5'd23) : (cycle_step_r == 5'd7);

    always @(posedge clk_i) begin
        if (!reset_n_i) begin
            cycle_r <= '0;
            cycle_step_r <= '0;
        end else begin
           if (ready_r & clk_en_i) begin
                cycle_step_r <= last_cycle_step_w ? '0 : cycle_step_r + 1'd1;
                cycle_r <= last_cycle_step_w ? (last_cycle_w ? '0 : cycle_r + 1'd1) : cycle_r;
           end
        end
    end

    reg inhibit_host_writes_r;

    // Oscillator Frequency Lo

    doc5503_register_ram #(
        .PRIORITY_WRITE_PORTS(1),
        .PRIORITY_READ_PORTS(1)
    ) osc_fl_r_inst (
        .clk_i(clk_i),
        .inhibit_i(inhibit_host_writes_r),
        .priority_write_req_i('{
            !cs_n_i & !we_n_i & (addr_i[7:5] == 3'b000)
        }),
        .priority_write_addr_i('{
            addr_i[4:0]
        }),
        .priority_write_data_i('{
            data_i
        }),
        .priority_read_req_i('{
            !cs_n_i & we_n_i & (addr_i[7:5] == 3'b000)
        }),
        .priority_read_addr_i('{
            addr_i[4:0]
        }),
        .priority_read_data_o('{
            fl_o_w
        }),
        .addr_a_i(cycle_r),
        .data_a_o(f_w[7:0]),
        .addr_b_i('0),
        .data_b_o()
    );

    // Oscillator Frequency Hi

    doc5503_register_ram #(
        .PRIORITY_WRITE_PORTS(1),
        .PRIORITY_READ_PORTS(1)
    ) osc_fh_r_inst (
        .clk_i(clk_i),
        .inhibit_i(inhibit_host_writes_r),
        .priority_write_req_i('{
            !cs_n_i & !we_n_i & (addr_i[7:5] == 3'b001)
        }),
        .priority_write_addr_i('{
            addr_i[4:0]
        }),
        .priority_write_data_i('{
            data_i
        }),
        .priority_read_req_i('{
            !cs_n_i & we_n_i & (addr_i[7:5] == 3'b001)
        }),
        .priority_read_addr_i('{
            addr_i[4:0]
        }),
        .priority_read_data_o('{
            fh_o_w
        }),
        .addr_a_i(cycle_r),
        .data_a_o(f_w[15:8]),
        .addr_b_i('0),
        .data_b_o()
    );

    // Oscillator Volume

    reg next_am_req_r;

    doc5503_register_ram #(
        .PRIORITY_WRITE_PORTS(2),
        .PRIORITY_READ_PORTS(1),
        .LAST_PRIORITY_WRITE_PORT_INHIBITABLE(1)
    ) osc_vol_r_inst (
        .clk_i(clk_i),
        .inhibit_i(inhibit_host_writes_r),
        .priority_write_req_i('{
            next_am_req_r,
            !cs_n_i & !we_n_i & (addr_i[7:5] == 3'b010)
        }),
        .priority_write_addr_i('{
            cycle_r + 1'b1,
            addr_i[4:0]
        }),
        .priority_write_data_i('{
            wds_w,
            data_i
        }),
        .priority_read_req_i('{
            !cs_n_i & we_n_i & (addr_i[7:5] == 3'b010)
        }),
        .priority_read_addr_i('{
            addr_i[4:0]
        }),
        .priority_read_data_o('{
            vol_o_w
        }),
        .addr_a_i(cycle_r),
        .data_a_o(vol_w),
        .addr_b_i('0),
        .data_b_o()
    );

    // Oscillator Waveform Data Sample

    reg current_wds_reset_req_r;

    doc5503_register_ram #(
        .FIRST_PRIORITY_WRITE_PORT_LEVEL_TRIGGERED(1),
        .PRIORITY_WRITE_PORTS(4),
        .PRIORITY_READ_PORTS(1),
        .LAST_PRIORITY_WRITE_PORT_INHIBITABLE(1)
    ) osc_wds_r_inst (
        .clk_i(clk_i),
        .inhibit_i(inhibit_host_writes_r),
        .priority_write_req_i('{
            !ready_r,
            current_wds_reset_req_r,
            wave_data_ready_i,
            !cs_n_i & !we_n_i & (addr_i[7:5] == 3'b011)
        }),
        .priority_write_addr_i('{
            init_cycle_r,
            cycle_r,
            last_osc_r,
            addr_i[4:0]
        }),
        .priority_write_data_i('{
            8'h80,
            8'h80,
            wave_data_i,
            data_i
        }),
        .priority_read_req_i('{
            !cs_n_i & we_n_i & (addr_i[7:5] == 3'b011)
        }),
        .priority_read_addr_i('{
            addr_i[4:0]
        }),
        .priority_read_data_o('{
            wds_o_w
        }),
        .addr_a_i(cycle_r),
        .data_a_o(wds_w),
        .addr_b_i('0),
        .data_b_o()
    );

    // Oscillator Waveform Table Pointer

    doc5503_register_ram #(
        .PRIORITY_WRITE_PORTS(1),
        .PRIORITY_READ_PORTS(1)
    ) osc_wtp_r_inst (
        .clk_i(clk_i),
        .inhibit_i(inhibit_host_writes_r),
        .priority_write_req_i('{
            !cs_n_i & !we_n_i & (addr_i[7:5] == 3'b100)
        }),
        .priority_write_addr_i('{
            addr_i[4:0]
        }),
        .priority_write_data_i('{
            data_i
        }),
        .priority_read_req_i('{
            !cs_n_i & we_n_i & (addr_i[7:5] == 3'b100)
        }),
        .priority_read_addr_i('{
            addr_i[4:0]
        }),
        .priority_read_data_o('{
            wtp_o_w
        }),
        .addr_a_i(cycle_r),
        .data_a_o(wtp_w),
        .addr_b_i('0),
        .data_b_o()
    );    

    // Oscillator Control

    reg current_osc_halt_req_r;
    reg partner_unhalt_req_r;
    reg partner_control_load_req_r;
    reg next_control_load_req_r;

    doc5503_register_ram #(
        .PRIORITY_WRITE_PORTS(4),
        .PRIORITY_READ_PORTS(3),
        .FIRST_PRIORITY_WRITE_PORT_LEVEL_TRIGGERED(1),
        .LAST_PRIORITY_WRITE_PORT_INHIBITABLE(1),
        .PORT_B_ENABLE(1)
    ) osc_control_r_inst (
        .clk_i(clk_i),
        .inhibit_i(inhibit_host_writes_r),
        .priority_write_req_i('{
            !ready_r,
            current_osc_halt_req_r,
            partner_unhalt_req_r,
            !cs_n_i & !we_n_i & (addr_i[7:5] == 3'b101)
        }),
        .priority_write_addr_i('{
            init_cycle_r,
            cycle_r,
            partner_w,
            addr_i[4:0]
        }),
        .priority_write_data_i('{
            8'h01,
            control_w | 1'b1,
            partner_control_w & 8'b11111110,
            data_i
        }),
        .priority_read_req_i('{
            !cs_n_i & we_n_i & (addr_i[7:5] == 3'b101),
            partner_control_load_req_r,
            next_control_load_req_r
        }),
        .priority_read_addr_i('{
            addr_i[4:0],
            partner_w,
            cycle_r + 1'b1
        }),
        .priority_read_data_o('{
            control_o_w,
            partner_control_w,
            next_control_w
        }),
        .addr_a_i(cycle_r),
        .data_a_o(control_w),
        .addr_b_i(5'(mixer_cycle_r + 1'b1)),
        .data_b_o(mixer_control_w)
    );

    // Oscillator Resolution Table Size

    doc5503_register_ram #(
        .PRIORITY_WRITE_PORTS(1),
        .PRIORITY_READ_PORTS(1)
    ) osc_rts_r_inst (
        .clk_i(clk_i),
        .inhibit_i(inhibit_host_writes_r),
        .priority_write_req_i('{
            !cs_n_i & !we_n_i & (addr_i[7:5] == 3'b110)
        }),
        .priority_write_addr_i('{
            addr_i[4:0]
        }),
        .priority_write_data_i('{
            data_i
        }),
        .priority_read_req_i('{
            !cs_n_i & we_n_i & (addr_i[7:5] == 3'b110)
        }),
        .priority_read_addr_i('{
            addr_i[4:0]
        }),
        .priority_read_data_o('{
            rts_o_w
        }),
        .addr_a_i(cycle_r),
        .data_a_o(rts_w),
        .addr_b_i('0),
        .data_b_o()
    );

    // Oscillator Accumulator

    reg current_acc_add_req_r;
    reg current_acc_reset_req_r;
    reg partner_acc_reset_req_r;

    doc5503_register_ram #(
        .DATA_WIDTH(24),
        .PRIORITY_WRITE_PORTS(3),
        .PRIORITY_READ_PORTS(0)
    ) osc_acc_r_inst (
        .clk_i(clk_i),
        .inhibit_i(inhibit_host_writes_r),
        .priority_write_req_i('{
            current_acc_add_req_r,
            current_acc_reset_req_r,
            partner_acc_reset_req_r
        }),
        .priority_write_addr_i('{
            cycle_r,
            cycle_r,
            partner_w
        }),
        .priority_write_data_i('{
            acc_w + f_w,
            24'h000000,
            24'h000000
        }),
        .priority_read_req_i('{0}),
        .priority_read_addr_i('{0}),
        .priority_read_data_o(),
        .addr_a_i(cycle_r),
        .data_a_o(acc_w),
        .addr_b_i('0),
        .data_b_o()
    );

    // Oscillator Output

    reg signed [15:0] output_r;                                         // Current scaled oscillator output        

    // DSP Multipler
    always @(posedge clk_i) begin
        automatic logic signed [7:0] data_w = wds_w ^ 8'h80;            // convert waveform data to signed
        automatic logic signed [7:0] vol_w = {2'b0, vol_w[7:2]};        // convert volume to signed
        output_r <= data_w * vol_w;                                     // output is waveform data * volume
    end

    reg output_reset_req;
    reg output_update_req;

    doc5503_register_ram #(
        .PRIORITY_WRITE_PORTS(3),
        .PRIORITY_READ_PORTS(0),
        .FIRST_PRIORITY_WRITE_PORT_LEVEL_TRIGGERED(1),
        .PORT_A_ENABLE(0),
        .PORT_B_ENABLE(1),
        .DATA_WIDTH(16)
    ) osc_output_r_inst (
        .clk_i(clk_i),
        .inhibit_i(inhibit_host_writes_r),
        .priority_write_req_i('{
            !ready_r,
            output_reset_req,
            output_update_req
        }),
        .priority_write_addr_i('{
            init_cycle_r,
            cycle_r,
            cycle_r
        }),
        .priority_write_data_i('{
            16'h0000,
            16'h0000,
            output_r
        }),
        .priority_read_req_i('{0}),
        .priority_read_addr_i('{0}),
        .priority_read_data_o(),
        .addr_a_i('0),
        .data_a_o(),
        .addr_b_i(5'(mixer_cycle_r + 1'b1)),
        .data_b_o(mixer_output_w)
    );

    // Host Interface

    reg prev_cs_n_r;
    wire req_cs_w = !cs_n_i & prev_cs_n_r;

    always @(posedge clk_i) begin
        if (!reset_n_i) begin
            osc_int_r <= '0;
            osc_en_r <= 8'h02;
        end else begin
            prev_cs_n_r <= cs_n_i;

            if (req_cs_w & !we_n_i) begin
                if (addr_i[7:5] == 3'b111) begin
                    if (addr_i[4:0] == 5'd0) osc_int_r <= data_i;
                    else if (addr_i[4:0] == 5'd1) osc_en_r <= data_i;
                end
            end
        end
    end

    // Wave Processor FSM

    localparam [2:0] OSC_IDLE = 3'd0;
    localparam [2:0] OSC_START = 3'd1;
    localparam [2:0] OSC_ACC = 3'd2;
    localparam [2:0] OSC_ADDR = 3'd3;
    localparam [2:0] OSC_READ_DATA = 3'd4;
    localparam [2:0] OSC_HALT = 3'd5;
    localparam [2:0] OSC_OUT = 3'd6;

    reg [2:0] osc_state_r;

    always @(posedge clk_i) begin
        if (!reset_n_i) begin

            irq_n_o <= '1;

            wave_address_o <= '0;
            wave_rd_o <= '0;

            next_am_req_r <= 0;

            current_wds_reset_req_r <= 0;

            current_acc_add_req_r <= 0;
            current_acc_reset_req_r <= 0;
            partner_acc_reset_req_r <= 0;

            partner_control_load_req_r <= 0;
            next_control_load_req_r <= 0;
            current_osc_halt_req_r <= 0;
            partner_unhalt_req_r <= 0;

            output_reset_req <= 0;
            output_update_req <= 0;

            inhibit_host_writes_r <= 0;

        end else begin
            wave_rd_o <= '0;

            next_am_req_r <= 0;

            current_wds_reset_req_r <= 0;

            current_acc_add_req_r <= 0;
            current_acc_reset_req_r <= 0;
            partner_acc_reset_req_r <= 0;

            partner_control_load_req_r <= 0;
            next_control_load_req_r <= 0;
            current_osc_halt_req_r <= 0;
            partner_unhalt_req_r <= 0;

            output_reset_req <= 0;
            output_update_req <= 0;
            
            if (clk_en_i) begin
                if (ready_r) begin
                    unique case (osc_state_r)
                        OSC_START: begin
                            // Start Oscillator
                            // Cycle Step 0

                            partner_control_load_req_r <= 1;
                            next_control_load_req_r <= 1;

                            osc_state_r <= OSC_ACC;
                        end
                        OSC_ACC: begin
                            // Accumulator 
                            // Cycle Step 1

                            if (!halt_w) begin
                                current_acc_add_req_r <= 1;
                                osc_state_r <= OSC_ADDR;
                            end else begin
                                if (mode_w[0]) begin
                                    current_acc_reset_req_r <= 1;
                                end
                                output_reset_req <= 1;
                                osc_state_r <= OSC_IDLE;
                            end
                        end
                        OSC_ADDR: begin
                            // Address Pointer (big barrel shifter)
                            // Cycle Step 2

                            automatic logic [4:0] shift_w = 5'd9 + res_w - wts_w;
                            wave_addr_r <= 16'(acc_w >> shift_w);
                            osc_state_r <= OSC_READ_DATA;
                        end
                        OSC_READ_DATA: begin
                            // Read Waveform Data
                            // Cycle Step 3

                            automatic logic [3:0] high_bit_w = {1'b1, wts_w};
                            automatic logic overflow = wave_addr_r[high_bit_w];
                            automatic logic zero_byte_w = (wds_w == 8'h00);

                            osc_state_r <= OSC_OUT;
                            if (!(overflow & mode_w[0]) & !zero_byte_w) begin
                                // Read next byte from SDRAM
                                automatic logic [7:0] ptr_hi_mask_w = 8'hFF << wts_w;
                                automatic logic [15:0] ptr_w = {ptr_hi_mask_w & wtp_w, 8'b0};
                                automatic logic [15:0] addr_w = (overflow ? 16'b0 : wave_addr_r) | ptr_w;
                                wave_rd_o <= 1'b1; 
                                wave_address_o <= addr_w;
                                last_osc_r <= cycle_r;
                            end 
                            if (overflow | zero_byte_w) begin
                                current_acc_reset_req_r <= 1;                                   // reset accumulator
                                if (zero_byte_w | mode_w[0]) begin                              // zero byte halts oscillator
                                    osc_state_r <= OSC_HALT;
                                end  
                                if (mode_w == MODE_SYNC_AM) begin                               // Sync AM Mode
                                    if (even_osc_w) begin                                       // Sync Mode, even oscillator
                                        partner_acc_reset_req_r <= 1;                           // reset partner oscillator
                                    end
                                end
                            end
                            // reload control registers from RAM
                            partner_control_load_req_r <= 1;
                            next_control_load_req_r <= 1;
                            inhibit_host_writes_r <= 1;
                        end
                        OSC_HALT: begin
                            // Halt Oscillator
                            // Cycle Step 4

                            current_wds_reset_req_r <= 1;                                       // silence output

                            current_osc_halt_req_r <= 1;                                        // halt current oscillator
                            
                            if (mode_w == MODE_SWAP) begin                                      // Swap Mode
                                partner_unhalt_req_r <= 1;                                      // unhalt partner oscillator
                                partner_acc_reset_req_r <= 1;                                   // reset partner accumulator
                            //end else if ((partner_mode_w == MODE_SWAP) && even_osc_w) begin     // Partner Swap Mode, even oscillator
                            //    current_osc_halt_req_r <= 0;                                    // belay the halt request
                            end
                            
                            osc_state_r <= OSC_IDLE;
                        end
                        OSC_OUT: begin
                            // Oscillator Output
                            // Cycle Step 4

                            if ((mode_w == MODE_SYNC_AM) & odd_osc_w) begin                     // Sync AM Mode, odd oscillator outputs nothing
                                output_reset_req <= 1;                                          // silence output
                                if ((cycle_r < 30) & !next_halt_w) begin                        // if next oscillator is not halted
                                    next_am_req_r <= 1;                                         // it's volume is set to current oscillator's waveform data
                                end
                            end else begin
                                output_update_req <= 1;                                         // output is waveform data * volume
                            end
                            
                            osc_state_r <= OSC_IDLE;
                        end
                        default: begin
                            // Idle
                            // Cycle Step 2 or 5 on enter

                            inhibit_host_writes_r <= 0;

                            if (last_cycle_step_w) begin
                                osc_state_r <= OSC_START;
                            end
                        end
                    endcase
                end
            end
        end

    end

    // Mixer

    localparam int MIXER_SUM_RESOLUTION = 16;

    reg signed [15:0] mono_mix_r;
    assign mono_mix_o = mono_mix_r;
    reg signed [MIXER_SUM_RESOLUTION-1:0] next_mono_mix_r;

    reg signed [15:0] left_mix_r;
    assign left_mix_o = left_mix_r;
    reg signed [MIXER_SUM_RESOLUTION-1:0] next_left_mix_r;

    reg signed [15:0] right_mix_r;
    assign right_mix_o = right_mix_r;
    reg signed [MIXER_SUM_RESOLUTION-1:0] next_right_mix_r;

    reg signed [15:0] channel_r[CHANNEL_MAX:0]; 
    assign channel_o = channel_r;
    reg signed [MIXER_SUM_RESOLUTION-1:0] next_channel_r[CHANNEL_MAX:0]; 


    localparam [1:0] MIXER_INIT = 2'd0;
    localparam [1:0] MIXER_ZERO = 2'd1;
    localparam [1:0] MIXER_ADD = 2'd2;
    localparam [1:0] MIXER_OUTPUT = 2'd3;

    reg [1:0] mixer_state_r;
    reg [3:0] mixer_channel_r;

    always @(posedge clk_i) begin
        if (!reset_n_i) begin
            mixer_state_r <= MIXER_INIT;
            mixer_channel_r <= '0;
            
            mono_mix_r <= '0;
            left_mix_r <= '0;
            right_mix_r <= '0;

        end else begin
            case (mixer_state_r)
                MIXER_INIT: begin
                    channel_r[mixer_channel_r] <= '0;

                    mixer_channel_r <= mixer_channel_r + 1'd1;
                    if (mixer_channel_r == CHANNEL_MAX) mixer_state_r <= MIXER_ZERO;
                end
                MIXER_ZERO: begin
                    mixer_cycle_r <= 6'd31;

                    next_channel_r[mixer_channel_r] <= '0;

                    next_mono_mix_r <= '0;
                    next_left_mix_r <= '0;
                    next_right_mix_r <= '0;

                    mixer_channel_r <= mixer_channel_r + 1'd1;
                    if (mixer_channel_r == CHANNEL_MAX) begin
                        mixer_state_r <= MIXER_ADD;
                        mixer_cycle_r <= '0;
                    end
                end
                MIXER_ADD: begin
                    automatic logic [3:0] ca = mixer_control_w[7:4];

                    if (OUTPUT_CHANNEL_MIX) next_channel_r[ca] <= next_channel_r[ca] + mixer_output_w;

                    if (OUTPUT_MONO_MIX) next_mono_mix_r <= next_mono_mix_r + mixer_output_w;

                    if (OUTPUT_STEREO_MIX) begin
                        if (ca[0]) next_left_mix_r <= next_left_mix_r + mixer_output_w;
                        else next_right_mix_r <= next_right_mix_r + mixer_output_w;
                    end

                    mixer_cycle_r <= (mixer_cycle_r == cycle_max_w) ? '0 : mixer_cycle_r + 1'd1;
                    if (mixer_cycle_r == cycle_max_w) mixer_state_r <= MIXER_OUTPUT;
                end
                MIXER_OUTPUT: begin                    
                    channel_r[mixer_channel_r] <= next_channel_r[mixer_channel_r][MIXER_SUM_RESOLUTION-1:MIXER_SUM_RESOLUTION-16];

                    mono_mix_r <= next_mono_mix_r[MIXER_SUM_RESOLUTION-1:MIXER_SUM_RESOLUTION-16];
                    left_mix_r <= next_left_mix_r[MIXER_SUM_RESOLUTION-1:MIXER_SUM_RESOLUTION-16];
                    right_mix_r <= next_right_mix_r[MIXER_SUM_RESOLUTION-1:MIXER_SUM_RESOLUTION-16];

                    mixer_channel_r <= mixer_channel_r + 1'd1;
                    if (mixer_channel_r == CHANNEL_MAX) mixer_state_r <= MIXER_ZERO;
                end
            endcase
        end
    end

    
endmodule