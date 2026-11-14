// A2MEGA - S7 accelerator: expansion memory behind the broker's far path (S7d)
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
// The card's copy of the expansion banks (02 up) in a memory of any latency -
// the DDR3, through whatever crosses to its clock.  gs_accel_broker reaches
// the big memories only on a near-memory miss, and for this one it waits
// (lm_rwait) instead of counting clks; this module is what it waits for.
//
// One queue, in program order: every write the broker makes to a bank above
// 01 goes in, and so does a read when one is launched.  The memory port takes
// them one at a time (m_req_o / m_ready_i) and answers reads in the order it
// took them (m_rvalid_i).  A read therefore sees every write made before it,
// whatever the memory's latency.
//
// Read:   rd_i (the broker's lm_ren_o with lm_rexp_o) queues it and raises
//         rwait_o from the next clk.  When the byte comes back rwait_o falls
//         (the clk after m_rvalid_i) and rdata_o holds the byte from that clk
//         until the next read.  rsel_o: the last far read launched was one
//         of these - the caller's data mux (the RAM's byte is rdata_o).
// Write:  wr_i queues it.  wbusy_o (a register, a clk behind the queue): the
//         queue is within WMARGIN entries of full - the broker then holds every step that could write here at its
//         strobe (a step already past it still makes its one write).  A native
//         step is never held: its writes come once per PHI2 cycle, far below
//         what the memory takes.  ovf_o (sticky): something was queued with
//         the queue full, and lost - it must never be seen.
// Line:   with LINE the memory answers a read with the sixteen bytes of the
//         address's line (m_rdata_i: byte k of the line in bits 8k+7..8k; the
//         low four address bits of a read it is given mean nothing to it).
//         rline_o holds them as rdata_o holds the byte, which is the one asked for.
// Reset:  the queue is kept (its writes were made by steps that completed).
//         A read whose step the reset cut short still comes back: it is counted
//         and its byte dropped.
//
module gs_accel_exp #(
    parameter int QLOG    = 4,           // queue depth 2^QLOG
    parameter int WMARGIN = 6,           // wbusy_o with this many entries or fewer free
    parameter int AW      = 23,          // address bits (8 MB)
    parameter bit LINE    = 1'b0         // a read is answered with its 16-byte line
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          run_i,         // the core is out of reset (the broker's cpu_rst_n_o)

    input  logic          rd_i,
    input  logic          rnx_i,         // a far read of something else is launched
    input  logic [AW-1:0] raddr_i,
    input  logic          wr_i,
    input  logic [AW-1:0] waddr_i,
    input  logic [7:0]    wdata_i,
    output logic          rwait_o,
    output logic          rsel_o,
    output logic [7:0]    rdata_o,
    output logic [127:0]  rline_o,       // (LINE)
    output logic          wbusy_o,
    output logic          ovf_o,
    output logic          busy_o,        // something is still in the queue (for a bench)

    // memory port, same clock
    output logic          m_req_o,       // a request is offered ...
    input  logic          m_ready_i,     // ... and taken in the clk both are high
    output logic          m_we_o,
    output logic [AW-1:0] m_addr_o,
    output logic [7:0]    m_wdata_o,
    input  logic          m_rvalid_i,    // a read's byte, in the order the reads were taken
    input  logic [(LINE ? 128 : 8)-1:0] m_rdata_i
);
    localparam int D = 1 << QLOG;
    // The queue: a small RAM between two registers.  What the broker asks is
    // registered first (in_*: the queue's write is a clk behind it, and nothing of
    // the broker's reaches the RAM in the clk it is made); the entry at its head
    // is registered before the memory port sees it (out_*: the RAM's own output
    // register - the GW5A has no distributed RAM, and as registers the queue was
    // five hundred of them and a 16-way mux beside the broker; a block has room to
    // spare).  The read in the clk an entry is written to the empty queue returns
    // nothing that is used: out_v stays low and the entry is read again.
    logic [AW+8:0]   q [0:D-1] /* synthesis syn_ramstyle = "block_ram" */;   // {we, addr, data}
    logic [QLOG:0]   wp, rp;
    wire  [QLOG:0]   used  = wp - rp;
    wire             full  = used[QLOG];
    wire             empty = (wp == rp);
    logic            in_v, out_v;
    logic [AW+8:0]   in_d, out_d;
    wire             take  = out_v & m_ready_i;

    logic        pend;                   // a read of the running core is on its way
    logic [3:0]  rlo;                    // (LINE) ... the byte of its line that it asked for
    logic [3:0]  skip;                   // reads on their way whose step is gone

    // (a read and a write are never made in the same clk by the broker: the write
    // of a step is a clk and more before any launch)
    always_ff @(posedge clk) in_d <= wr_i ? {1'b1, waddr_i, wdata_i} : {1'b0, raddr_i, 8'h00};
    // (written whenever something is queued: with the queue full - never, ovf_o -
    // that takes the place of the oldest entry, where it used to be dropped; lost
    // either way.  Its enable is then a register and nothing of the pointers'.)
    always_ff @(posedge clk) if (in_v)            q[wp[QLOG-1:0]] <= in_d;
    always_ff @(posedge clk) if (take | ~out_v)   out_d <= q[rp[QLOG-1:0]];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= '0; rp <= '0; in_v <= 1'b0; out_v <= 1'b0;
            pend <= 1'b0; skip <= '0; rsel_o <= 1'b0; rdata_o <= '0; ovf_o <= 1'b0; wbusy_o <= 1'b0;
            rlo <= '0; rline_o <= '0;
        end else begin
            in_v <= wr_i | rd_i;
            if (wr_i & rd_i) ovf_o <= 1'b1;                        // (never: see above)
            if (in_v) begin
                if (full) ovf_o <= 1'b1;
                else      wp <= wp + 1'b1;
            end
            if (take | ~out_v) begin
                out_v <= ~empty;
                if (!empty) rp <= rp + 1'b1;
            end
            wbusy_o <= (used >= (QLOG+1)'(D - WMARGIN));

            if (rd_i)       rsel_o <= 1'b1;
            else if (rnx_i) rsel_o <= 1'b0;

            // the byte of a read: the running core's, or one to drop
            if (m_rvalid_i) begin
                if (skip != 4'd0) skip <= skip - 4'd1;
                else begin
                    rdata_o <= LINE ? m_rdata_i[8 * rlo +: 8] : m_rdata_i[7:0];
                    rline_o <= 128'(m_rdata_i);
                    pend    <= 1'b0;
                end
            end
            if (rd_i) begin pend <= 1'b1; rlo <= raddr_i[3:0]; end
            // the core went into reset with a read on its way
            if (!run_i & pend & ~(m_rvalid_i & (skip == 4'd0))) begin
                pend <= 1'b0;
                skip <= skip + 4'd1 - {3'd0, m_rvalid_i};
            end
        end
    end

    assign m_req_o   = out_v;
    assign {m_we_o, m_addr_o, m_wdata_o} = out_d;
    // (from registers alone: they go straight into the broker's sequencer)
    assign rwait_o   = pend;
    assign busy_o    = in_v | ~empty | out_v;
endmodule
