// A2MEGA - IIgs CPU socket: arm sequencer (the S6 reset rule in gateware)
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
// The S6 bench rule (docs/gs_socket_65816_scoping.md 8b, test log G45-G74):
// the socket stays completely off - nothing driven, the control-input
// shifter not even enabled - until the machine's /RESET has been released,
// and the core is armed 20 ms after that edge, because a ROM 01 machine
// re-asserts /RESET 9.95-9.99 ms after a rising edge of the line if a CPU is
// running in the socket when that mark arrives.
//
// S6 implements this in the ESP32 firmware (gs_socket.c, mode 4): it polls
// the slot /RESET level about once a millisecond and writes CTRL.arm once it
// has read high for `late` ms.  The rule as decided on 2026-11-11 is that
// the reference is the LAST RELEASE of /RESET, WHOEVER HELD IT: the card
// must coexist with any card that holds the open-drain line (an a2p25 holds
// it until its disks are mounted).  This module is that rule with one-clock
// resolution and no dependence on a polling task:
//
//  * res_n_i is the slot /RESET line itself - the wired-AND of the
//    motherboard, this card's own hold and every other card's.  It is
//    synchronised here; any low sample restarts the count.
//  * A request (arm_i and/or listen_i) is passed to the PHY only once the
//    line has been continuously high for delay_ms_i milliseconds.  The count
//    starts at the release, so the PHY is armed delay_ms_i after the LAST
//    rising edge, never earlier, however long and however often the line
//    was held before.  If the line has already been high that long when the
//    request arrives (a machine that has been running), it passes at once.
//  * Until then arm_o and listen_o are both low: the PHY keeps every enable
//    inactive, including the control-input shifter.
//  * After the request has passed it stays passed while it is asserted
//    (S6 behaviour: a later /RESET is handled by the PHY, which holds the
//    core in reset on a driven bus and restarts it on the release).  With
//    rearm_i = 1 a later /RESET fall drops the socket again and the whole
//    sequence repeats from the next release - for machines or cards that
//    need every release treated like the first.
//  * seq_en_i = 0 bypasses the module: arm_o = arm_i, listen_o = listen_i,
//    i.e. S6 with the firmware doing the timing.
//
// No dependency on the slot-side logic: the only inputs are the request
// bits and one pin.
//
module gs_socket_arm_seq #(
    parameter int MS_CLKS = 108_000      // clks per millisecond (clk frequency / 1000)
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        seq_en_i,        // 1 = sequence here; 0 = pass the requests straight through
    input  logic        rearm_i,         // 1 = every /RESET fall drops the socket and re-runs the sequence
    input  logic [7:0]  delay_ms_i,      // arm this long after the last release (S6: 20)

    input  logic        arm_i,           // arm request (CTRL.arm)
    input  logic        listen_i,        // listen request (CTRL.listen)
    input  logic        res_n_i,         // slot /RESET line, asynchronous

    output logic        arm_o,           // -> gs_socket_phy.armed_i
    output logic        listen_o,        // -> gs_socket_phy.listen_i

    // telemetry (clk domain)
    output logic [1:0]  state_o,         // 0 no request, 1 waiting: line low, 2 waiting: timing, 3 passed
    output logic [7:0]  high_ms_o,       // whole ms the line has been high (saturates at 255)
    output logic [7:0]  restarts_o       // times a low line restarted a count in progress (saturates)
);

    localparam int PW = $clog2(MS_CLKS);

    logic [1:0]    res_s;
    logic [PW-1:0] pre;             // prescaler: clks into the current millisecond
    logic [7:0]    high_ms;
    logic          open_r;          // the request has passed
    logic          counting;        // a count is in progress for a pending request

    wire req      = arm_i | listen_i;
    wire res_high = res_s[1];
    wire elapsed  = res_high & (high_ms >= delay_ms_i);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res_s      <= 2'b00;
            pre        <= '0;
            high_ms    <= '0;
            open_r     <= 1'b0;
            counting   <= 1'b0;
            restarts_o <= '0;
        end else begin
            res_s <= {res_s[0], res_n_i};

            // time since the last low sample of the line
            if (!res_high) begin
                pre     <= '0;
                high_ms <= '0;
            end else if (pre == PW'(MS_CLKS - 1)) begin
                pre <= '0;
                if (high_ms != 8'hFF) high_ms <= high_ms + 8'd1;
            end else begin
                pre <= pre + 1'b1;
            end

            // the request passes once the line has been high long enough
            if (!req) begin
                open_r   <= 1'b0;
                counting <= 1'b0;
            end else if (open_r) begin
                if (rearm_i && !res_high) open_r <= 1'b0;
            end else if (elapsed) begin
                open_r   <= 1'b1;
                counting <= 1'b0;
            end else if (res_high) begin
                counting <= 1'b1;
            end else begin
                if (counting && restarts_o != 8'hFF) restarts_o <= restarts_o + 8'd1;
                counting <= 1'b0;
            end
        end
    end

    assign arm_o     = seq_en_i ? (arm_i & open_r)    : arm_i;
    assign listen_o  = seq_en_i ? (listen_i & open_r) : listen_i;
    assign high_ms_o = high_ms;
    assign state_o   = !req ? 2'd0 : open_r ? 2'd3 : res_high ? 2'd2 : 2'd1;

endmodule
