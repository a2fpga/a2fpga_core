// S7d bench: a memory behind gs_accel_exp's port, with the manners of a DDR3 behind
// a clock crossing - it is not always ready, a read's byte comes back a varying
// number of clks later, and reads are answered in the order they were taken.
// The delays come from an LFSR that steps with what the port is asked, so two
// instances given the same requests in the same clks behave identically (the
// bench's own design and gs_accel beside it).
module gs_exp_mem_sim #(
    parameter int AW   = 23,
    parameter int SEED = 16'hACE1,
    parameter int LMIN = 8,              // read latency, clks: LMIN .. LMIN + 31
    parameter int GAP  = 3,              // clks not ready after a request: 0 .. GAP
    parameter bit LINE = 1'b0            // a read is answered with the 16 bytes of its line (byte k in bits 8k+7..8k)
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          m_req_i,
    output logic          m_ready_o,
    input  logic          m_we_i,
    input  logic [AW-1:0] m_addr_i,
    input  logic [7:0]    m_wdata_i,
    output logic          m_rvalid_o,
    output logic [(LINE ? 128 : 8)-1:0] m_rdata_o
);
    logic [7:0] mem [0:(1<<AW)-1];
    logic [15:0] lfsr = 16'(SEED);
    longint      now = 0, last_due = 0;
    int          gap = 0;
    // +xlat=N: a read's byte comes back N .. N + 31 clks later (default LMIN);
    // +xgap=N: not ready for N .. N + GAP clks after a request (default 0: a memory
    // slower than the core writes fills the queue in front of it)
    int          xlat = LMIN, xgap = 0;
    initial begin
        void'($value$plusargs("xlat=%d", xlat));
        void'($value$plusargs("xgap=%d", xgap));
    end
    typedef struct { longint due; logic [127:0] d; } rsp_t;
    rsp_t rq [$];
    longint n_rd = 0, n_wr = 0;

    initial begin
        for (int i = 0; i < (1<<AW); i++) mem[i] = 8'h00;
        m_ready_o = 1'b0; m_rvalid_o = 1'b0; m_rdata_o = '0;
    end
    always_ff @(posedge clk) begin
        now <= now + 1;
        m_rvalid_o <= 1'b0;
        if (rq.size() != 0 && rq[0].due <= now) begin
            m_rvalid_o <= 1'b1; m_rdata_o <= LINE ? (LINE ? 128 : 8)'(rq[0].d) : (LINE ? 128 : 8)'(rq[0].d[7:0]); void'(rq.pop_front());
        end
        if (m_req_i && m_ready_o) begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            if (m_we_i) begin mem[m_addr_i] <= m_wdata_i; n_wr <= n_wr + 1; end
            else begin
                longint due;
                due = now + xlat + {59'd0, lfsr[4:0]};
                if (due <= last_due) due = last_due + 1;
                last_due <= due;
                begin
                    logic [127:0] ln;
                    ln = '0;
                    if (LINE) for (int k = 0; k < 16; k++) ln[8*k +: 8] = mem[{m_addr_i[AW-1:4], 4'(k)}];
                    else ln[7:0] = mem[m_addr_i];
                    rq.push_back('{due: due, d: ln});
                end
                n_rd <= n_rd + 1;
            end
            gap <= xgap + ((GAP == 0) ? 0 : int'(lfsr[7:6]) % (GAP + 1));
            m_ready_o <= 1'b0;
        end else if (gap != 0) begin
            gap <= gap - 1; m_ready_o <= 1'b0;
        end else m_ready_o <= rst_n;
    end
endmodule
