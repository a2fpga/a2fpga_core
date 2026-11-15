//
// HyperBus PHY for Gowin GW5A (Arora V) — x8, single-ended CK
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
// Description:
//
// Thin primitive layer under hyperram_ctrl. Every signal the controller
// drives is presented once per clk_mem cycle as a (first-half, second-half)
// byte pair; ODDR/IDDR turn those into DDR at the pins. Approach follows
// nand2mario's psram-tang-nano-9k controller (ODDR/IDDR, phase-shifted CK),
// re-targeted to GW5A and extended with a trainable input delay.
//
// Output path (all on clk_mem, identical ODDR latency): a pair (o_r, o_f)
// the ODDR samples at clk_mem rising edge E is on the pin during
// [E + 2T, E + 3T): o_r for the first half (clk_mem high), o_f for the
// second half. The tristate (TX -> Q1) follows the same timing. A value
// hyperram_ctrl assigns at edge c is sampled at c+1, so it is on the pin
// in pin-cycle c+3 (verified with the GW5A simulation primitives).
//
// CK: ODDR clocked by clk_mem_90 (+90 deg) with D0 = ck_en, D1 = 0, so a
// CK high pulse spans [T/4, 3T/4] of the data cycle — rising edge centred
// on the first byte, falling edge centred on the second (HyperBus write and
// CA data are centre-aligned to CK). ck_en is re-timed through a negedge
// clk_mem_90 stage so neither hop is shorter than T/2: clk_mem posedge ->
// clk_mem_90 negedge = 3T/4 for the fabric hop from the controller's FSM
// (which routed 4.6 ns in the a2p25 full core at 97 % CLS when this stage
// was on clk_mem's negedge and had only T/2), then clk_mem_90 negedge ->
// posedge = T/2 into the ODDR next to the pin. The ODDR samples the same
// cycle's ck_en at the same edge either way; ck_en is presented in the
// SAME cycle as the data byte pair it clocks.
//
// Input path: pad -> IODELAY (dynamic, 12.5 ps/tap in the Gowin model,
// 256 taps = 3.2 ns, less than the 4.63 ns bit time at 108 MHz) -> IDDR
// on clk_cap. Q0 is the rising-edge sample (earlier byte) taken at edge E,
// Q1 the falling-edge sample taken at E + T/2; both update at E + 2T.
// clk_cap is normally clk_mem; a board can feed a phase-shifted copy if
// the trained window lands at the end of the tap range (see the a2p25 plan
// doc). The same delay code is applied to DQ[7:0] and RWDS: the read
// framing in hyperram_ctrl keys off RWDS, which the device drives
// edge-aligned with DQ (tDSS/tDSH +-0.45 ns), so they must see the same
// delay.
//
// ⚠ IODELAY dynamic-load semantics are taken from the GW5A simulation
// model (DLYSTEP is loaded while SDTAP=0 on a VALUE/SDTAP event). The
// controller pulses dly_load after every code change. Confirm against
// UG289 at bring-up (the BIST eye scan shows whether the code takes).
// STA: DLYSTEP is quasi-static — false-path it from hyperram_ctrl's
// dly_code registers (see the hyperram_ctrl header).
//

module hyperram_phy_gw5a #(
    parameter DQ_WIDTH = 8
) (
    input  wire                 clk_mem,      // HyperBus CK rate (e.g. 108 MHz)
    input  wire                 clk_mem_90,   // clk_mem + 90 deg
    input  wire                 clk_cap,      // read capture clock (normally clk_mem)

    // Controller side (clk_mem domain unless noted)
    input  wire                 cs_n,
    input  wire                 ck_en,        // CK pulse for this cycle's byte pair
    input  wire                 dq_oe,
    input  wire [DQ_WIDTH-1:0]  dq_o_r,
    input  wire [DQ_WIDTH-1:0]  dq_o_f,
    input  wire                 rwds_oe,
    input  wire                 rwds_o_r,
    input  wire                 rwds_o_f,

    output wire [DQ_WIDTH-1:0]  dq_i_r,       // clk_cap domain
    output wire [DQ_WIDTH-1:0]  dq_i_f,
    output wire                 rwds_i_r,
    output wire                 rwds_i_f,

    input  wire [7:0]           dly_code,     // input delay tap
    input  wire                 dly_load,     // pulse after dly_code changes

    // Pins
    output wire                 hr_ck,
    output wire                 hr_cs_n,
    inout  wire                 hr_rwds,
    inout  wire [DQ_WIDTH-1:0]  hr_dq
);

    // ---------------------------------------------------------------------
    // CK
    // ---------------------------------------------------------------------
    reg ck_en_n90;
    always @(negedge clk_mem_90) ck_en_n90 <= ck_en;

    ODDR u_ck (
        .CLK (clk_mem_90),
        .D0  (ck_en_n90),
        .D1  (1'b0),
        .TX  (1'b0),
        .Q0  (hr_ck),
        .Q1  ()
    );

    // ---------------------------------------------------------------------
    // CS#
    // ---------------------------------------------------------------------
    ODDR #(.INIT(1'b1)) u_cs (
        .CLK (clk_mem),
        .D0  (cs_n),
        .D1  (cs_n),
        .TX  (1'b0),
        .Q0  (hr_cs_n),
        .Q1  ()
    );

    // ---------------------------------------------------------------------
    // DQ / RWDS bidirectional
    // ---------------------------------------------------------------------
    // ODDR TX: 0 = drive. Q1 carries the registered tristate control.
    wire [DQ_WIDTH-1:0] dq_out;
    wire [DQ_WIDTH-1:0] dq_tri;
    wire [DQ_WIDTH-1:0] dq_in_dly;

    genvar i;
    generate
        for (i = 0; i < DQ_WIDTH; i = i + 1) begin : g_dq
            ODDR u_dq_o (
                .CLK (clk_mem),
                .D0  (dq_o_r[i]),
                .D1  (dq_o_f[i]),
                .TX  (~dq_oe),
                .Q0  (dq_out[i]),
                .Q1  (dq_tri[i])
            );
            assign hr_dq[i] = dq_tri[i] ? 1'bz : dq_out[i];

            IODELAY #(
                .C_STATIC_DLY (0),
                .DYN_DLY_EN   ("TRUE"),
                .ADAPT_EN     ("FALSE")
            ) u_dq_dly (
                .DI      (hr_dq[i]),
                .DO      (dq_in_dly[i]),
                .DF      (),
                .DLYSTEP (dly_code),
                .SDTAP   (1'b0),
                .VALUE   (dly_load)
            );

            IDDR u_dq_i (
                .CLK (clk_cap),
                .D   (dq_in_dly[i]),
                .Q0  (dq_i_r[i]),
                .Q1  (dq_i_f[i])
            );
        end
    endgenerate

    wire rwds_out, rwds_tri, rwds_in_dly;

    ODDR u_rwds_o (
        .CLK (clk_mem),
        .D0  (rwds_o_r),
        .D1  (rwds_o_f),
        .TX  (~rwds_oe),
        .Q0  (rwds_out),
        .Q1  (rwds_tri)
    );
    assign hr_rwds = rwds_tri ? 1'bz : rwds_out;

    IODELAY #(
        .C_STATIC_DLY (0),
        .DYN_DLY_EN   ("TRUE"),
        .ADAPT_EN     ("FALSE")
    ) u_rwds_dly (
        .DI      (hr_rwds),
        .DO      (rwds_in_dly),
        .DF      (),
        .DLYSTEP (dly_code),
        .SDTAP   (1'b0),
        .VALUE   (dly_load)
    );

    IDDR u_rwds_i (
        .CLK (clk_cap),
        .D   (rwds_in_dly),
        .Q0  (rwds_i_r),
        .Q1  (rwds_i_f)
    );

endmodule
