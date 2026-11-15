// A2MEGA - IIgs CPU socket accelerator: the ROM image, read through the socket
//
// (c) 2026 Ed Anuff <ed@a2fpga.com>
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
// Description
// -----------
// The card serves ROM from an image of its own (gs_accel_broker: the far ROM
// memory).  The image is the machine's: this module reads it through the
// socket, as docs/gs_socket_s7_accelerator_scoping.md 2.6 has it, and nothing
// of Apple's is in the bitstream.
//
// On start_i it asks the broker to hold the core between two steps.  While
// the core is held the socket's idle cycles are reads of the address given
// here; each completed one is a byte of the image.  128 KB (ROM 01: FE0000 -
// FFFFFF) is 131072 PHI2 cycles, about 46 ms, during which the machine sees
// a CPU that reads ROM and takes no interrupt.  Then every entry of the near
// memory is made empty (a byte read from the image before the copy may be
// in it), the hold is dropped and the core goes on with the step it was
// about to take.
//
// Neither memory's write port is in a hurry, and the far ROM image is sixty-four
// blocks anywhere on the die, so both are given time (the board build's
// constraints say so): a byte's address and data are registered two clks before
// its write enable, which lasts two clks; a near-memory index is held for two
// clks with the flush asserted throughout (a write that lands on another index
// while the address moves makes that entry empty too, which is the point).
//
// valid_o says a complete image has been copied since power-up; it drops
// when a new copy starts and when one is cut short (the socket lost, /RES).
// usable_o is what the caller grants the card's memory on: valid_o, or a
// complete image being copied again.  Nothing is written before the core is
// held and the hold lasts until the copy is complete, so no step sees the
// image in between; and a step must not fall back to the socket's bytes for
// the length of a copy, because once the card's memory has been the memory of
// record the machine's copy of RAM is stale.  (With valid_o alone the step
// that was held ran from the socket: found in the bench, 2026-11-13.)
//
module gs_accel_romcopy #(
    parameter bit ROM3    = 1'b0,        // 0 = ROM 01, 128 KB at FE0000; 1 = ROM 3, 256 KB at FC0000
    parameter int NEAR_AW = 14,
    parameter bit SIM_PRESET = 1'b0      // SIMULATION ONLY: valid_o is 1 out of reset (a bench loaded the image)
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start_i,         // one clk: copy now (ignored while busy or without ready_i)
    input  logic        ready_i,         // the socket is ours and the core is out of reset

    // gs_accel_broker
    output logic        hold_o,
    output logic [23:0] idle_a_o,
    input  logic        held_i,
    input  logic        idle_stb_i,
    input  logic [7:0]  idle_d_i,
    output logic        nm_flush_o,
    output logic [NEAR_AW-1:0] nm_flush_idx_o,

    // the ROM image's write port (address as the broker reads it: {bank[1:0], address})
    output logic        rom_we_o,
    output logic [17:0] rom_wa_o,
    output logic [7:0]  rom_wd_o,

    output logic        busy_o,
    output logic        valid_o,
    output logic        usable_o,
    output logic [15:0] sum_o,           // sum of the image's bytes, modulo 65536
    output logic [7:0]  copies_o         // complete copies since power-up (saturates)
);
    localparam int AW = ROM3 ? 18 : 17;
    typedef enum logic [1:0] { C_IDLE, C_WAIT, C_COPY, C_FLUSH } cst_t;
    cst_t               cs;
    logic [17:0]        n;
    logic [NEAR_AW-1:0] f;
    logic               f2;              // second clk of a near-memory index
    logic [3:0]         we_sr;           // a byte was registered 1, 2, 3, 4 clks ago
    // the two counts' last values, from registers: n moves once per PHI2 cycle and
    // f every second clk, and each flag is read a clk or more after its count moved
    logic               n_last, f_last;
    logic               was_valid;       // the copy in progress is over a complete image
    always_ff @(posedge clk) begin
        n_last <= (n[AW-1:0] == '1);
        f_last <= (f == '1);
    end

    assign hold_o         = (cs != C_IDLE);
    assign busy_o         = (cs != C_IDLE);
    assign usable_o       = valid_o | ((cs != C_IDLE) & was_valid);
    assign idle_a_o       = ROM3 ? {6'b111111, n[17:0]} : {7'b1111111, n[16:0]};
    assign nm_flush_o     = (cs == C_FLUSH);
    assign nm_flush_idx_o = f;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs <= C_IDLE; n <= '0; f <= '0; f2 <= 1'b0; we_sr <= '0;
            rom_we_o <= 1'b0; rom_wa_o <= '0; rom_wd_o <= '0;
            valid_o <= SIM_PRESET; sum_o <= '0; copies_o <= '0; was_valid <= 1'b0;
        end else begin
            we_sr    <= {we_sr[2:0], 1'b0};
            rom_we_o <= we_sr[1] | we_sr[2];
            unique case (cs)
                C_IDLE: if (start_i & ready_i) begin
                    cs <= C_WAIT; n <= '0; sum_o <= '0; valid_o <= 1'b0; was_valid <= valid_o;
                end
                C_WAIT: begin
                    if (!ready_i)    cs <= C_IDLE;
                    else if (held_i) cs <= C_COPY;
                end
                C_COPY: begin
                    if (!ready_i | !held_i) cs <= C_IDLE;
                    else if (idle_stb_i) begin
                        we_sr[0] <= 1'b1;
                        rom_wa_o <= ROM3 ? n : {1'b1, n[16:0]};
                        rom_wd_o <= idle_d_i;
                        sum_o    <= sum_o + {8'h00, idle_d_i};
                        n        <= n + 18'd1;
                        if (n_last) begin cs <= C_FLUSH; f <= '0; f2 <= 1'b0; end
                    end
                end
                default: begin   // C_FLUSH
                    if (!ready_i | !held_i) cs <= C_IDLE;
                    else begin
                        f2 <= ~f2;
                        if (f2) f <= f + 1'b1;
                        if (f2 && f_last) begin
                            cs <= C_IDLE; valid_o <= 1'b1;
                            if (copies_o != 8'hFF) copies_o <= copies_o + 8'd1;
                        end
                    end
                end
            endcase
        end
    end
`ifdef VERILATOR
    always @(posedge clk) if (rst_n) begin
        if (cs == C_COPY && idle_stb_i && n_last !== (n[AW-1:0] == '1)) begin $display("ERROR: gs_accel_romcopy: n_last is stale"); $finish; end
        if (cs == C_FLUSH && f2 && f_last !== (f == '1))                begin $display("ERROR: gs_accel_romcopy: f_last is stale"); $finish; end
    end
`endif
endmodule
