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
// during synthesis. 
//

module doc5503 #(
    parameter int CLOCK_SPEED_HZ = 54_000_000,
    parameter int DOC_CLOCK_SPEED_HZ = 7_159_090 // 7.15909 MHz
) (
    input clk_i,
    input reset_n_i,
    input clk_en_i,

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

    output signed [15:0] channel_o[16],
    
    output logic ready_o,          // Indicate when out of reset and ready to process

    output [7:0] debug_osc_en_o,   // Debug output for oscillator enable register
    output [1:0] debug_osc_mode_o[8], // Debug output for oscillator mode register;
    output [7:0] debug_osc_halt_o // Debug output for oscillator halt register

);

    reg [7:0] host_addr_r;         // Address register for host access
    reg [7:0] host_data_r;        // Data register for host access
    reg host_we_n_r;              // Write enable register for host access
    reg prev_cs_n_r;          // Previous chip select state
    reg prev_we_n_r;          // Previous write enable state
    reg host_access_r;         // Host access register

    always_ff @(posedge clk_i) begin
        if (!reset_n_i) begin
            host_addr_r <= '0;
            host_data_r <= '0;
            host_we_n_r <= 1'b1;
        end else begin
            prev_cs_n_r <= cs_n_i;
            prev_we_n_r <= we_n_i;
            host_access_r <= 1'b0;
            if (!cs_n_i) begin
                host_addr_r <= addr_i;
                host_data_r <= data_i;
                host_we_n_r <= we_n_i;

                // Pulse host_access_r on negative edge of cs_n_i
                // if cs_n_i is low and negative edge of we_n_i
                if (prev_cs_n_r || (!we_n_i && prev_we_n_r)) begin
                    host_access_r <= 1'b1;
                end
            end
        end
    end

    // Registers

    reg [7:0] osc_int_r;            // $E0    : Oscillator Interrupt Register
    reg [7:0] osc_en_r;             // $E1    : Oscillator Enable Register
    assign debug_osc_en_o = osc_en_r;

    reg [1:0] debug_osc_mode_r[8];
    assign debug_osc_mode_o = debug_osc_mode_r;
    reg [7:0] debug_osc_halt_r;
    assign debug_osc_halt_o = debug_osc_halt_r;

    // Oscillator registers as RAM
    // Necessary to use RAMs to implement the large number of registers but adds
    // complexity to the design.  Current implementation uses synchronous writes
    // and asynchronous reads which means that read data is available on the next
    // clock cycle.

    // Oscillator RAM control signals

    reg [4:0] ram_fl_osc_r;         // RAM oscillator for frequency low operation
    reg [4:0] ram_fh_osc_r;         // RAM oscillator for frequency high operation
    reg [4:0] ram_vol_osc_r;        // RAM oscillator for volume operation
    reg [4:0] ram_wds_osc_r;        // RAM oscillator for waveform data sample operation
    reg [4:0] ram_wtp_osc_r;        // RAM oscillator for waveform table pointer operation
    reg [4:0] ram_control_osc_r;    // RAM oscillator for control operation
    reg [4:0] ram_rts_osc_r;        // RAM oscillator for resolution table size operation
    reg [4:0] ram_acc_osc_r;        // RAM oscillator for accumulator operation

    reg ram_fl_we_r;                // RAM oscillator write enable for frequency low register
    reg ram_fh_we_r;                // RAM oscillator write enable for frequency high register
    reg ram_vol_we_r;               // RAM oscillator write enable for volume register
    reg ram_wds_we_r;               // RAM oscillator write enable for waveform data sample register
    reg ram_wtp_we_r;               // RAM oscillator write enable for waveform table pointer register
    reg ram_control_we_r;           // RAM oscillator write enable for control register
    reg ram_rts_we_r;               // RAM oscillator write enable for resolution table size register
    reg ram_acc_we_r;               // RAM oscillator write enable for accumulator register

    reg [7:0] ram_fl_din_r;         // RAM oscillator data in for frequency low register
    reg [7:0] ram_fh_din_r;         // RAM oscillator data in for frequency high register
    reg [7:0] ram_vol_din_r;        // RAM oscillator data in for volume register
    reg [7:0] ram_wds_din_r;        // RAM oscillator data in for waveform data sample register
    reg [7:0] ram_wtp_din_r;        // RAM oscillator data in for waveform table pointer register
    reg [7:0] ram_control_din_r;    // RAM oscillator data in for control register
    reg [7:0] ram_rts_din_r;        // RAM oscillator data in for resolution table size register
    reg [23:0] ram_acc_din_r;       // RAM oscillator data in for accumulator register

    wire [7:0] ram_fl_dout_w;       // RAM oscillator data out for frequency low register
    wire [7:0] ram_fh_dout_w;       // RAM oscillator data out for frequency high register
    wire [7:0] ram_vol_dout_w;      // RAM oscillator data out for volume register
    wire [7:0] ram_wds_dout_w;      // RAM oscillator data out for waveform data sample register
    wire [7:0] ram_wtp_dout_w;      // RAM oscillator data out for waveform table pointer register
    wire [7:0] ram_control_dout_w;  // RAM oscillator data out for control register
    wire [7:0] ram_rts_dout_w;      // RAM oscillator data out for resolution table size register
    wire [23:0] ram_acc_dout_w;     // RAM oscillator data out for accumulator register

    // Instantiate the RAMs for each oscillator register

    // $00-1F : Frequency Low Register
    osc_reg_ram fl_ram (
        .clk_i(clk_i),
        .osc_i(ram_fl_osc_r),
        .we_i(ram_fl_we_r),
        .data_i(ram_fl_din_r),
        .data_o(ram_fl_dout_w)
    );

    // $20-3F : Frequency High Register
    osc_reg_ram fh_ram (
        .clk_i(clk_i),
        .osc_i(ram_fh_osc_r),
        .we_i(ram_fh_we_r),
        .data_i(ram_fh_din_r),
        .data_o(ram_fh_dout_w)
    );

    // $40-5F : Volume Register
    osc_reg_ram vol_ram (
        .clk_i(clk_i),
        .osc_i(ram_vol_osc_r),
        .we_i(ram_vol_we_r),
        .data_i(ram_vol_din_r),
        .data_o(ram_vol_dout_w)
    );

    // $60-7F : Waveform Data Sample Register
    osc_reg_ram wds_ram (
        .clk_i(clk_i),
        .osc_i(ram_wds_osc_r),
        .we_i(ram_wds_we_r),
        .data_i(ram_wds_din_r),
        .data_o(ram_wds_dout_w)
    );

    // $80-9F : Waveform Table Pointer Register
    osc_reg_ram wtp_ram (
        .clk_i(clk_i),
        .osc_i(ram_wtp_osc_r),
        .we_i(ram_wtp_we_r),
        .data_i(ram_wtp_din_r),
        .data_o(ram_wtp_dout_w)
    );

    // $A0-BF : Control Register
    osc_reg_ram control_ram (
        .clk_i(clk_i),
        .osc_i(ram_control_osc_r),
        .we_i(ram_control_we_r),
        .data_i(ram_control_din_r),
        .data_o(ram_control_dout_w)
    );

    // $C0-DF : Resolution Table Size Register
    osc_reg_ram rts_ram (
        .clk_i(clk_i),
        .osc_i(ram_rts_osc_r),
        .we_i(ram_rts_we_r),
        .data_i(ram_rts_din_r),
        .data_o(ram_rts_dout_w)
    );

    // $E0-FF : Oscillator Accumulator Register
    osc_reg_ram #(.DATA_WIDTH(24)) acc_ram (
        .clk_i(clk_i),
        .osc_i(ram_acc_osc_r),
        .we_i(ram_acc_we_r),
        .data_i(ram_acc_din_r),
        .data_o(ram_acc_dout_w)
    );

    // Current oscillator state, copied from the register file at the start of each cycle
    reg [7:0] curr_fl_r;
    reg [7:0] curr_fh_r;
    reg [7:0] curr_vol_r;
    reg [7:0] curr_wds_r;
    reg [7:0] curr_wtp_r;
    reg [7:0] curr_control_r;
    reg [7:0] curr_rts_r;
    reg [7:0] partner_control_r;
    reg [7:0] next_control_r;
    reg [7:0] prev_control_r;

    wire zero_byte_w = (curr_wds_r == 8'h00);
    
    reg [4:0] curr_osc_r;
    wire curr_osc_odd_w = curr_osc_r[0];
    wire curr_osc_even_w = ~curr_osc_odd_w;
    wire [4:0] partner_osc_w = curr_osc_r ^ 5'b1;

    wire [2:0] curr_wts_w = curr_rts_r[5:3];
    wire [2:0] curr_res_w = curr_rts_r[2:0];
    wire [4:0] curr_shift_w = 5'd9 + curr_res_w - curr_wts_w;
    wire [23:0] curr_acc_mask_w = {8'((1 << (1'd1 + curr_res_w)) - 1), 16'hFFFF};

    wire halt_w = curr_control_r[0];
    wire [1:0] curr_mode_w = curr_control_r[2:1];
    wire [3:0] curr_ca_w = curr_control_r[7:4];

    wire partner_halt_w = partner_control_r[0];
    wire [1:0] partner_mode_w = partner_control_r[2:1];

    wire next_halt_w = next_control_r[0];
    wire [1:0] next_mode_w = next_control_r[2:1];

    wire prev_halt_w = prev_control_r[0];
    wire [1:0] prev_mode_w = prev_control_r[2:1];

    reg [23:0] curr_acc_r;
    reg signed [17:0] curr_output_r;

    // Incoming wave date requested by the FSM

    reg [7:0] loaded_wds_r;

    always_ff @(posedge clk_i) begin
        if (!reset_n_i) begin
            loaded_wds_r <= 8'h80;
        end else begin
            if (wave_data_ready_i) begin
                loaded_wds_r <= wave_data_i;
            end
        end
    end

    // Use 24-bit accumulators for mixing to provide more headroom and prevent clipping
    localparam int MIXER_SUM_RESOLUTION = 24;

    // Adjustable parameters for output scaling
    // TOP_BIT_OFFSET: How many bits from the top to start the window (0 = full amplitude)
    // WINDOW_SIZE: Number of bits to use for magnitude portion (should be 15 for 16-bit output with sign bit)
    localparam int TOP_BIT_OFFSET = 6;   // Skip this many bits from the top of the accumulator
    localparam int WINDOW_SIZE = 15;     // Use this many bits for magnitude

    reg signed [15:0] channel_r[16]; 
    assign channel_o = channel_r;
    reg signed [MIXER_SUM_RESOLUTION-1:0] next_channel_r[16]; 
    reg signed [MIXER_SUM_RESOLUTION-1:0] channel_sum_r;

    reg signed [15:0] mono_mix_r;
    assign mono_mix_o = mono_mix_r;
    reg signed [MIXER_SUM_RESOLUTION-1:0] next_mono_mix_r;

    reg signed [15:0] left_mix_r;
    assign left_mix_o = left_mix_r;
    reg signed [MIXER_SUM_RESOLUTION-1:0] next_left_mix_r;

    reg signed [15:0] right_mix_r;
    assign right_mix_o = right_mix_r;
    reg signed [MIXER_SUM_RESOLUTION-1:0] next_right_mix_r;

    localparam [1:0] MODE_FREE = 2'b00;
	localparam [1:0] MODE_ONE_SHOT = 2'b01;
    localparam [1:0] MODE_SYNC_AM = 2'b10;
    localparam [1:0] MODE_SWAP = 2'b11;

    // Use bits 5:1 to determine the number of oscillators enabled (divide by 2)
    wire [4:0] osc_max_w = osc_en_r[5:1];

    // Timing generator

    localparam int TICKS_PER_CYCLE = CLOCK_SPEED_HZ / (DOC_CLOCK_SPEED_HZ / 8);
    localparam int CYCLE_WIDTH = (TICKS_PER_CYCLE <= 1) ? 1 : $clog2(TICKS_PER_CYCLE + 1);
    logic [CYCLE_WIDTH-1:0] cycle_timer_r;

    localparam [1:0] CYCLE_RESET = 2'b00;
    localparam [1:0] CYCLE_OSC = 2'b01;
    localparam [1:0] CYCLE_REFRESH_0 = 2'b10;
    localparam [1:0] CYCLE_REFRESH_1 = 2'b11;

   localparam int OSC_STATE_COUNT = 14;
    typedef enum logic [$clog2(OSC_STATE_COUNT)-1:0] {
        OSC_IDLE,
        OSC_START,
        OSC_LOAD_REGISTERS,
        OSC_LOAD_PARTNER_CONTROL,
        OSC_LOAD_NEXT_CONTROL,
        OSC_REQUEST_DATA,
        OSC_HANDLE_DATA,
        OSC_OUT,
        OSC_MIX,
        OSC_ACC,
        OSC_HALT,
        OSC_HALT_ONE_SHOT_OR_ZERO_BYTE,
        OSC_START_PARTNER,
        OSC_RETRIGGER
    } osc_state_e;
    osc_state_e osc_state_r; 
    
    reg [1:0] cycle_state_r;
    wire ready_w = (cycle_state_r != CYCLE_RESET);
    assign ready_o = ready_w;
    reg cycle_start_r;

    reg [2:0] clk_count_r;
    always @(posedge clk_i) begin
        if (!reset_n_i) begin
            clk_count_r <= '0;
            cycle_timer_r <= '0;
            cycle_state_r <= CYCLE_RESET;
            curr_osc_r <= '0;
            cycle_start_r <= 1'b0;
        end else begin
            cycle_timer_r <= cycle_timer_r + 1'd1;
            cycle_start_r <= 1'b0;
            if (clk_en_i) begin
                clk_count_r <= clk_count_r + 1'd1;
                if (clk_count_r == 3'b111) begin
                    cycle_timer_r <= '0;
                    cycle_start_r <= 1'b1;

                    if (cycle_state_r == CYCLE_RESET) begin
                        curr_osc_r <= '0;
                        cycle_state_r <= CYCLE_OSC;
                    end else if (cycle_state_r == CYCLE_OSC) begin
                        if (curr_osc_r == osc_max_w) begin
                            cycle_state_r <= CYCLE_REFRESH_0;
                        end else begin
                            curr_osc_r <= curr_osc_r + 1'd1;
                        end
                    end else if (cycle_state_r == CYCLE_REFRESH_0) begin
                        cycle_state_r <= CYCLE_REFRESH_1;
                    end else if (cycle_state_r == CYCLE_REFRESH_1) begin
                        curr_osc_r <= '0;
                        cycle_state_r <= CYCLE_OSC;
                    end
                end
            end
        end
    end

    reg loaded_wds_pending_r;

    reg halt_zero_r = 1'b0;
    reg halt_overflow_r = 1'b0;

    reg host_request_pending_r = 1'b0;
    reg device_response_pending_r = 1'b0;

    always_ff @(posedge clk_i) begin
        if (!reset_n_i) begin
            osc_state_r <= OSC_IDLE;
            wave_address_o <= '0;
            wave_rd_o <= '0;
            loaded_wds_pending_r <= '0;
            halt_zero_r <= 1'b0;
            halt_overflow_r <= 1'b0;

            host_request_pending_r <= 1'b0;
            device_response_pending_r <= 1'b0;

            // Reset all oscillator RAM control signals

            ram_fl_osc_r <= '0;
            ram_fh_osc_r <= '0;
            ram_vol_osc_r <= '0;
            ram_wds_osc_r <= '0;
            ram_wtp_osc_r <= '0;
            ram_control_osc_r <= '0;
            ram_rts_osc_r <= '0;
            ram_acc_osc_r <= '0;

            ram_fl_din_r <= '0;
            ram_fh_din_r <= '0;
            ram_vol_din_r <= '0;
            ram_wds_din_r <= '0;
            ram_wtp_din_r <= '0;
            ram_control_din_r <= '0;
            ram_rts_din_r <= '0;
            ram_acc_din_r <= '0;

            ram_fl_we_r <= 1'b0;
            ram_fh_we_r <= 1'b0;
            ram_vol_we_r <= 1'b0;
            ram_wds_we_r <= 1'b0;
            ram_wtp_we_r <= 1'b0;
            ram_control_we_r <= 1'b0;
            ram_rts_we_r <= 1'b0;
            ram_acc_we_r <= 1'b0;

        end else begin

            wave_rd_o <= '0;

            if (host_access_r) begin
                host_request_pending_r <= 1'b1;
            end
            device_response_pending_r <= 1'b0;

            // Default all target oscillators to the current oscillator
            ram_fl_osc_r <= curr_osc_r;
            ram_fh_osc_r <= curr_osc_r;
            ram_vol_osc_r <= curr_osc_r;
            ram_wds_osc_r <= curr_osc_r;
            ram_wtp_osc_r <= curr_osc_r;
            ram_control_osc_r <= curr_osc_r;
            ram_rts_osc_r <= curr_osc_r;
            ram_acc_osc_r <= curr_osc_r;

            // Default all target write enables to 0
            ram_fl_we_r <= 1'b0;
            ram_fh_we_r <= 1'b0;
            ram_vol_we_r <= 1'b0;
            ram_wds_we_r <= 1'b0;
            ram_wtp_we_r <= 1'b0;
            ram_control_we_r <= 1'b0;
            ram_rts_we_r <= 1'b0;
            ram_acc_we_r <= 1'b0;

            if (wave_data_ready_i) begin
                loaded_wds_pending_r <= 1'b1;
            end

            case (cycle_state_r)
                CYCLE_RESET: cycle_reset();
                CYCLE_OSC: cycle_osc();
                CYCLE_REFRESH_0: cycle_refresh0();
                CYCLE_REFRESH_1: cycle_refresh1();
            endcase // case (cycle_state_r)

        end // else: !if(!reset_n_i)

    end // always_ff

    task automatic host_request();
        // Handles CPU register read/write access to DOC registers
        // Processes access to oscillator interrupt (0xE0) and enable (0xE1) registers
        // Handles access to oscillator-specific registers (frequency, volume, waveform, etc.)

        if (host_request_pending_r) begin
            host_request_pending_r <= 1'b0;

            if (!host_we_n_r) begin
                data_o <= host_data_r;
                if (host_addr_r == 8'hE0) begin
                    // Oscillator Interrupt Register
                    osc_int_r <= host_data_r; 
                end else if (host_addr_r == 8'hE1) begin
                    // Oscillator Enable Register
                    osc_en_r <= host_data_r;
                end else if (host_addr_r >= 8'h00 && host_addr_r <= 8'hDF) begin
                    // Oscillator Registers
                    case (host_addr_r[7:5])
                        3'b000: begin                               // $00-1F
                            ram_fl_osc_r <= host_addr_r[4:0];
                            ram_fl_din_r <= host_data_r;
                            ram_fl_we_r <= 1'b1;
                        end
                        3'b001: begin                               // $20-3F
                            ram_fh_osc_r <= host_addr_r[4:0];
                            ram_fh_din_r <= host_data_r;
                            ram_fh_we_r <= 1'b1;
                        end
                        3'b010: begin                               // $40-5F
                            ram_vol_osc_r <= host_addr_r[4:0];
                            ram_vol_din_r <= host_data_r;
                            ram_vol_we_r <= 1'b1;
                        end
                        3'b011: begin                               // $60-7F
                            ram_wds_osc_r <= host_addr_r[4:0];
                            ram_wds_din_r <= host_data_r;
                            ram_wds_we_r <= 1'b1;
                        end
                        3'b100: begin                               // $80-9F
                            ram_wtp_osc_r <= host_addr_r[4:0];
                            ram_wtp_din_r <= host_data_r;
                            ram_wtp_we_r <= 1'b1;
                        end
                        3'b101: begin                               // $A0-BF
                            ram_control_osc_r <= host_addr_r[4:0];
                            ram_control_din_r <= host_data_r;
                            ram_control_we_r <= 1'b1;
                            if (!host_data_r[0]) begin
                                ram_acc_osc_r <= host_addr_r[4:0];
                                ram_acc_din_r <= '0; // Reset the accumulator if halt bit is cleared
                                ram_acc_we_r <= 1'b1;
                            end
                        end
                        3'b110: begin                               // $C0-DF
                            ram_rts_osc_r <= host_addr_r[4:0];
                            ram_rts_din_r <= host_data_r;
                            ram_rts_we_r <= 1'b1;
                        end
                    endcase
                end
            end else begin
                // Host read access to oscillator registers
                // Set the device response pending flag to indicate a read request
                // and set up the address for the read operation to be ready
                // for the next cycle
                device_response_pending_r <= 1'b1;

                if (host_addr_r >= 8'h00 && host_addr_r <= 8'hDF) begin
                    case (host_addr_r[7:5])
                        3'b000: ram_fl_osc_r <= host_addr_r[4:0];
                        3'b001: ram_fh_osc_r <= host_addr_r[4:0];
                        3'b010: ram_vol_osc_r <= host_addr_r[4:0];
                        3'b011: ram_wds_osc_r <= host_addr_r[4:0];
                        3'b100: ram_wtp_osc_r <= host_addr_r[4:0];
                        3'b101: ram_control_osc_r <= host_addr_r[4:0];
                        3'b110: ram_rts_osc_r <= host_addr_r[4:0];
                    endcase
                end
            end

        end
    endtask: host_request

    task automatic device_response();
        if (device_response_pending_r) begin
            device_response_pending_r <= 1'b0;
            // Handle device response to host request

            if (host_we_n_r) begin
                if (host_addr_r >= 8'h00 && host_addr_r <= 8'hDF) begin
                    // Read from oscillator registers
                    case (host_addr_r[7:5])
                        3'b000: begin                               // $00-1F
                            data_o <= ram_fl_dout_w;
                        end
                        3'b001: begin                               // $20-3F
                            data_o <= ram_fh_dout_w;
                        end
                        3'b010: begin                               // $40-5F
                            data_o <= ram_vol_dout_w;
                        end
                        3'b011: begin                               // $60-7F
                            data_o <= ram_wds_dout_w;
                        end
                        3'b100: begin                               // $80-9F
                            data_o <= ram_wtp_dout_w;
                        end
                        3'b101: begin                               // $A0-BF
                            data_o <= ram_control_dout_w;
                        end
                        3'b110: begin                               // $C0-DF
                            data_o <= ram_rts_dout_w;
                        end
                    endcase
                end else if (host_addr_r == 8'hE0) begin
                    // Oscillator Interrupt Register
                    data_o <= osc_int_r; 
                end else if (host_addr_r == 8'hE1) begin
                    // Oscillator Enable Register
                    data_o <= osc_en_r;
                end else begin
                    data_o <= '0; // Default value for unrecognized addresses
                end
            end
        end
    endtask: device_response

    task automatic host_access();
        host_request();
        device_response();
    endtask: host_access

    task automatic cycle_reset();
        // Initialize all oscillator registers during reset cycle
        // Sets frequency, volume, waveform, control registers to default values
        // Ensures all oscillators start in non-halted state with zeroed accumulators
        // This differs from the original DOC5503 which initializes the register bits to 1
        // Called during CYCLE_RESET state only

         // Set target oscillators based on cycle time
        ram_fl_osc_r <= cycle_timer_r[4:0];
        ram_fh_osc_r <= cycle_timer_r[4:0];
        ram_vol_osc_r <= cycle_timer_r[4:0];
        ram_wds_osc_r <= cycle_timer_r[4:0];
        ram_wtp_osc_r <= cycle_timer_r[4:0];
        ram_control_osc_r <= cycle_timer_r[4:0];
        ram_rts_osc_r <= cycle_timer_r[4:0];
        ram_acc_osc_r <= cycle_timer_r[4:0];

        ram_fl_we_r <= 1'b1;
        ram_fh_we_r <= 1'b1;
        ram_vol_we_r <= 1'b1;
        ram_wds_we_r <= 1'b1;
        ram_wtp_we_r <= 1'b1;
        ram_control_we_r <= 1'b1;
        ram_rts_we_r <= 1'b1;
        ram_acc_we_r <= 1'b1;

        ram_fl_din_r <= '0;
        ram_fh_din_r <= '0;
        ram_vol_din_r <= '0;
        ram_wds_din_r <= '0;
        ram_wtp_din_r <= '0;
        ram_control_din_r <= '1;
        ram_rts_din_r <= '0;
        ram_acc_din_r <= '0;

    endtask: cycle_reset

    task automatic cycle_refresh0();
        // First phase of output channel refresh cycle
        // Copies next_channel values to channel output registers
        // Updates mono_mix, left_mix, and right_mix final output values
        // Only updates final mix values when processing the last channel (15)

        if (cycle_timer_r < 'd16) begin
            if (cycle_start_r) begin
                device_response();
            end
    
            channel_r[cycle_timer_r[3:0]] <= {
                // Sign bit
                next_channel_r[cycle_timer_r[3:0]][MIXER_SUM_RESOLUTION-1],
                // Magnitude bits - using parameterized window 
                next_channel_r[cycle_timer_r[3:0]][MIXER_SUM_RESOLUTION-1-TOP_BIT_OFFSET -: WINDOW_SIZE]
            };
            
            // Only copy the final values when processing the last channel (15)
            if (cycle_timer_r[3:0] == 4'hF) begin
                mono_mix_r <= {
                    next_mono_mix_r[MIXER_SUM_RESOLUTION-1],
                    next_mono_mix_r[MIXER_SUM_RESOLUTION-1-TOP_BIT_OFFSET -: WINDOW_SIZE]
                };
                left_mix_r <= {
                    next_left_mix_r[MIXER_SUM_RESOLUTION-1],
                    next_left_mix_r[MIXER_SUM_RESOLUTION-1-TOP_BIT_OFFSET -: WINDOW_SIZE]
                };
                right_mix_r <= {
                    next_right_mix_r[MIXER_SUM_RESOLUTION-1],
                    next_right_mix_r[MIXER_SUM_RESOLUTION-1-TOP_BIT_OFFSET -: WINDOW_SIZE]
                };
                // Debug: Print the final mix values
            end
        end else begin
            // use remaining time to process host access
            host_access();
        end

    endtask: cycle_refresh0

    task automatic cycle_refresh1();
        // Second phase of output channel refresh cycle 
        // Resets next_channel accumulators for the next oscillator processing cycle
        // Clears mono_mix, left_mix, and right_mix accumulators when processing last channel

        if (cycle_timer_r < 'd16) begin
            if (cycle_start_r) begin
                device_response();
            end

            next_channel_r[cycle_timer_r[3:0]] <= '0;
            
            // Only reset the mix values when processing the last channel (15)
            if (cycle_timer_r[3:0] == 4'hF) begin
                next_mono_mix_r <= '0;
                next_left_mix_r <= '0;
                next_right_mix_r <= '0;
        end
        end else begin
            // use remaining time to process host access
            host_access();
        end

    endtask: cycle_refresh1

    task automatic cycle_osc();
        // Force oscillator state machine to idle state if at the start of a cycle
        automatic osc_state_e osc_state_w;
        osc_state_w = cycle_start_r ? OSC_IDLE : osc_state_r;
        case (osc_state_w)
            OSC_IDLE: osc_idle();
            OSC_START: osc_start();
            OSC_LOAD_REGISTERS: osc_load_registers();
            OSC_LOAD_PARTNER_CONTROL: osc_load_partner_control();
            OSC_LOAD_NEXT_CONTROL: osc_load_next_control();
            OSC_REQUEST_DATA: osc_request_data();
            OSC_HANDLE_DATA: osc_handle_data();
            OSC_OUT: osc_out();
            OSC_MIX: osc_mix();
            OSC_ACC: osc_acc();
            OSC_HALT: osc_halt();
            OSC_HALT_ONE_SHOT_OR_ZERO_BYTE: osc_halt_one_shot_or_zero_byte();
            OSC_START_PARTNER: osc_start_partner();
            OSC_RETRIGGER: osc_retrigger();
            default: osc_idle();
        endcase // case (osc_state_r)
    endtask: cycle_osc
    
    task automatic osc_idle();
        // Idle state for oscillator state machine
        // Waits for the start of a new cycle to begin processing
        // Handles host access to oscillator registers
        // Sets the oscillator state to OSC_START when a new cycle begins

        osc_state_r <= OSC_IDLE;
        host_access();

        if (cycle_start_r) begin
            osc_state_r <= OSC_START;
        end

    endtask : osc_idle

    task automatic osc_start();
        device_response();

        // Init other working values
        curr_output_r <= '0;
        halt_zero_r <= 1'b0;
        halt_overflow_r <= 1'b0;

        osc_state_r <= OSC_LOAD_REGISTERS;
    endtask: osc_start

    task automatic osc_load_registers();
        // Load all current oscillator registers from register file RAM
        // Transitions to OSC_REQUEST_DATA state to begin oscillator processing
        curr_fl_r <= ram_fl_dout_w;                  // Frequency low
        curr_fh_r <= ram_fh_dout_w;                  // Frequency high
        curr_vol_r <= ram_vol_dout_w;                // Volume
        curr_wds_r <= ram_wds_dout_w;                // Waveform data sample
        curr_wtp_r <= ram_wtp_dout_w;                // Waveform table pointer
        curr_control_r <= ram_control_dout_w;        // Control
        curr_rts_r <= ram_rts_dout_w;                // Resolution/table size
        curr_acc_r <= ram_acc_dout_w;                // Accumulator

        ram_control_osc_r <= partner_osc_w;

        osc_state_r <= OSC_LOAD_PARTNER_CONTROL;             // Request data from memory
    endtask: osc_load_registers

    task automatic osc_load_partner_control();
        partner_control_r <= ram_control_dout_w;
        ram_control_osc_r <= curr_osc_r + 1'b1;
        osc_state_r <= OSC_LOAD_NEXT_CONTROL;
    endtask: osc_load_partner_control

    task automatic osc_load_next_control();
        next_control_r <= ram_control_dout_w;
        ram_control_osc_r <= curr_osc_r - 1'b1;
        osc_state_r <= OSC_REQUEST_DATA;
    endtask: osc_load_next_control

    task automatic osc_request_data();
        // Generate wave table address and request data if oscillator not halted
        // If oscillator is halted, handles one-shot mode accumulator reset
        // Note: This differs from the original DOC5503 in that it appears that the
        // DOC5503 may not actually request and retrieve wave data in the same cycle
        // Rather, it appears that it plays the wave data that is already in the
        // wds register and then requests the next wave data sample.

        automatic logic [15:0] curr_wave_addr_w = 16'(curr_acc_r >> curr_shift_w);
        if (!halt_w) begin
            // Address Output Multiplexer - create wave table address from accumulator
            // Create mask for wave table pointer based on wave table size
            automatic logic [7:0] ptr_hi_mask_w = 8'(8'hFF << curr_wts_w);
            // Create pointer to wave table with ignored bits masked out
            automatic logic [15:0] ptr_w = {ptr_hi_mask_w & curr_wtp_r, 8'b0};
            // 
            automatic logic [15:0] addr_w = curr_wave_addr_w | ptr_w;

            // Read next byte from SDRAM
            loaded_wds_pending_r <= 1'b0;
            wave_rd_o <= 1'b1; 
            wave_address_o <= addr_w;
                                                
            osc_state_r <= OSC_HANDLE_DATA;

        end else begin
            // When halted but in one-shot mode, clear accumulator
            if (curr_mode_w[0]) begin
                ram_acc_we_r <= 1'b1;
                ram_acc_din_r <= '0;
            end
            // When halted, skip OUT and return to IDLE state
            osc_state_r <= OSC_IDLE;
        end

        if (curr_osc_r < 5'd8) begin
            debug_osc_mode_r[curr_osc_r[2:0]] <= curr_mode_w;
            debug_osc_halt_r[3'd7 - curr_osc_r[2:0]] <= curr_control_r[0];
        end

        // load prev control register (needed later)
        prev_control_r <= ram_control_dout_w;
    endtask: osc_request_data

    task automatic osc_handle_data();
        // Processes wave data received from memory request
        // Stores loaded_wds_r into both wds_r array and curr_wds_r
        // Detects zero byte (0x00) which triggers special halt behavior
        // Sets halt_zero_r flag when zero byte detected

        if (loaded_wds_pending_r) begin
            loaded_wds_pending_r <= 1'b0;
            ram_wds_we_r <= 1'b1;
            ram_wds_din_r <= loaded_wds_r;
            curr_wds_r <= loaded_wds_r;
            if (loaded_wds_r == 8'h00) begin
                halt_zero_r <= 1'b1;                                    // Set halt zero flag
                osc_state_r <= OSC_HALT;
            end else begin
                osc_state_r <= OSC_OUT;
            end
        end else if (clk_count_r == 3'd6) begin
            // If no data received, set default waveform data to 0x80
            curr_wds_r <= 8'h80;
            osc_state_r <= OSC_OUT;
        end

    endtask: osc_handle_data

    task automatic osc_out();
        // Calculates audio output by scaling waveform data by volume
        // Handles special case for SYNC_AM mode where odd oscillators don't output
        // but instead modify the volume of the following even oscillator

        if ((curr_mode_w == MODE_SYNC_AM) & curr_osc_odd_w) begin           // Sync AM Mode, odd oscillator outputs nothing
            if ((curr_osc_r != 5'd31) & !next_halt_w) begin                     // if next oscillator is not halted
                ram_vol_osc_r <= curr_osc_r + 1'b1;                      // set target oscillator to next one
                ram_vol_we_r <= 1'b1;                                    // write to volume register
                ram_vol_din_r <= curr_wds_r;                             // set volume to waveform data
            end
            // Skip mixing for odd oscillators in SYNC_AM mode
            osc_state_r <= OSC_ACC;
        end else begin
            // Fixed waveform data polarity and volume calculation
            automatic logic signed [7:0] data_w = curr_wds_r ^ 8'h80;       // convert waveform data to signed (8'h80 = 0)
            automatic logic signed [8:0] vol_s = {1'b0, curr_vol_r};        // convert volume to signed (unsigned expanded)
            automatic logic signed [17:0] output_w = data_w * vol_s;        // output is waveform data * volume (signed * signed)
            curr_output_r <= output_w;                                      // store calculated output
            channel_sum_r <= next_channel_r[curr_ca_w];                     // load channel accumulator
            
            // Always go to OSC_MIX from here except in the special case above
            osc_state_r <= OSC_MIX;
        end
    endtask: osc_out

    task automatic osc_mix();
        // Mixes the oscillator output into the appropriate channel and stereo mix
        // Accumulates output into next_channel_r for the current channel assignment (curr_ca_w)
        // Updates mono (all channels), left (odd channels), and right (even channels) mixes

        next_channel_r[curr_ca_w] <= channel_sum_r + curr_output_r;
        
        // Add to mono mix (all channels)
        next_mono_mix_r <= next_mono_mix_r + curr_output_r;
        
        // Add to left/right mix based on channel number
        // Channel 0,2,4,etc. go to right, 1,3,5,etc. go to left
        if (curr_ca_w[0]) 
            next_right_mix_r <= next_right_mix_r + curr_output_r;
        else 
            next_left_mix_r <= next_left_mix_r + curr_output_r;
        
        osc_state_r <= OSC_ACC;
    endtask: osc_mix

    task automatic osc_acc();
        // Updates oscillator accumulator by adding frequency value
        // Detects overflow based on resolution and table size settings
        // Applies appropriate masking to ensure proper wraparound within wave table

        automatic logic [24:0] temp_acc = curr_acc_r + {curr_fh_r, curr_fl_r};
        automatic int high_bit_w = 17 + curr_res_w;
        automatic logic overflow = temp_acc[high_bit_w];
        halt_overflow_r <= overflow;
        ram_acc_we_r <= 1'b1;
        ram_acc_din_r <= temp_acc[23:0] & curr_acc_mask_w;      // wrap around address

        osc_state_r <= OSC_IDLE;
        if (overflow) begin
            osc_state_r <= OSC_HALT;
        end
    endtask: osc_acc

    task automatic osc_halt();
        // Handles oscillator state on halt events (overflow or zero byte)
        // Special processing for SYNC_AM mode where even oscillator halt
        // resets the accumulator of the previous odd oscillator

        if (curr_mode_w == MODE_SYNC_AM) begin
            if (curr_osc_even_w) begin
                // we're even, so if the odd oscillator 1 below us is playing,
                // restart it.
                if (!prev_halt_w) begin
                    ram_acc_osc_r <= curr_osc_r - 1'b1;                // set target oscillator to previous one
                    ram_acc_we_r <= 1'b1;                              // write to accumulator register
                    ram_acc_din_r <= '0;                               // set accumulator to zero
                end
            end
        end
        osc_state_r <= OSC_HALT_ONE_SHOT_OR_ZERO_BYTE;
    endtask: osc_halt

    task automatic osc_halt_one_shot_or_zero_byte();
        // Determines if oscillator should be marked as halted in the control register
        // Halts oscillator if in one-shot mode (MODE_ONE_SHOT) or zero byte was detected
        // Handles special transition cases for SWAP mode and partner oscillator interactions

        if (curr_mode_w[0] || halt_zero_r) begin
            ram_control_we_r <= 1'b1;                                   // write to control register
            ram_control_din_r <= {curr_control_r[7:1], 1'b1};           // set halt bit
            curr_control_r <= {curr_control_r[7:1], 1'b1};              // set halt bit in working copy
        end

        osc_state_r <= OSC_IDLE;

	    // if we're in swap mode, start the partner
        if (curr_mode_w == MODE_SWAP) begin                             // Swap Mode
            osc_state_r <= OSC_START_PARTNER;
        end else begin
		    // if we're not swap and we're the even oscillator of the pair and the partner's swap
		    // but we aren't, we retrigger (!!!)  Verified on IIgs hardware.
            if ((partner_mode_w == MODE_SWAP) && curr_osc_even_w) begin
                osc_state_r <= OSC_RETRIGGER;
            end
        end
    endtask: osc_halt_one_shot_or_zero_byte

    task automatic osc_start_partner();
        // Starts partner oscillator when in SWAP mode
        // Clears halt bit in partner's control register
        // Resets partner's accumulator to start from beginning of wave table
        // Used specifically for SWAP mode to implement alternate triggering behavior

        ram_control_osc_r <= partner_osc_w;                         // set target oscillator to partner
        ram_control_we_r <= 1'b1;                                   // write to control register
        ram_control_din_r <= {partner_control_r[7:1], 1'b0};        // set halt bit to zero

        ram_acc_osc_r <= partner_osc_w;                             // set target oscillator to partner
        ram_acc_we_r <= 1'b1;                                       // write to accumulator register
        ram_acc_din_r <= '0;                                        // set accumulator to zero

        // After halting partner, skip the current output
        osc_state_r <= OSC_IDLE;
    endtask: osc_start_partner

    task automatic osc_retrigger();
        // Handles the specific edge case where an even oscillator retriggering is needed
        // This occurs when the even oscillator is halted but its odd partner is in SWAP mode
        // This behavior was verified on actual Apple IIgs hardware

        ram_control_we_r <= 1'b1;                                   // write to control register
        ram_control_din_r <= {curr_control_r[7:1], 1'b0};           // set halt bit to zero    

        osc_state_r <= OSC_IDLE;
    endtask: osc_retrigger

endmodule

module osc_reg_ram #(
    parameter int DATA_WIDTH = 8
) (
    input clk_i,
    input [4:0] osc_i,
    input we_i,
    input [DATA_WIDTH-1:0] data_i,
    output [DATA_WIDTH-1:0] data_o
);
    // This should infer as a RAM16 single port SSRAM during synthesis on Gowin
    // that is implemented in LUTs via Configurable Function Units,
    // allowing for synchronous write and asynchronous read.
    // Other FPGA families may use different synthesis directives.
    // Use of a different RAM structure like blockram might require
    // a different approach if asynchronous read is not supported, such as
    // requiring waiting an additional clock cycle from address valid to
    // data available.
    reg [DATA_WIDTH-1:0] osc_reg_r[32] /*synthesis syn_ramstyle="distributed_ram"*/; 
    always_ff @(posedge clk_i) begin
        if (we_i) begin
            osc_reg_r[osc_i] <= data_i;
        end
    end

    assign data_o = osc_reg_r[osc_i];

endmodule

