//
// Memory port arbiter — N pulse-and-wait clients share one controller port
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
// Latch-and-replay arbiter: each client pulses rd/wr with addr/data valid
// and waits for its ready before issuing another request (single
// outstanding per client — the same contract sdram_ports imposes on a
// dedicated port). Requests are latched, granted lowest-index-first, and
// the controller-side request is held until the completion pulse, which is
// routed back only to the owning client. One dead cycle between grants
// gives the controller's edge detector a fresh edge.
//
// A per-client word-address base is added on grant, replacing the
// PORT_BASE_ADDR the client's dedicated controller port would have applied.
//
// Exists so low-bandwidth clients (MCU XFER, Disk II track window, HDD
// block window) can share one controller port: sdram_ports' priority/mux
// cone fails 108 MHz timing above 7 ports.
//

module mem_port_arb #(
    parameter NUM_CLIENTS = 2,
    parameter PORT_ADDR_WIDTH = 21,
    parameter DATA_WIDTH = 32,
    parameter DQM_WIDTH = 4,
    parameter PORT_OUTPUT_WIDTH = 32,
    parameter [PORT_ADDR_WIDTH-1:0] CLIENT_BASE_ADDR [NUM_CLIENTS] = '{NUM_CLIENTS{0}}
) (
    input clk_i,
    input rst_n_i,

    mem_port_if.controller clients[NUM_CLIENTS-1:0],
    mem_port_if.client controller
);

    // Latched requests (one outstanding per client)
    reg                        pend_rd_r   [NUM_CLIENTS-1:0];
    reg                        pend_wr_r   [NUM_CLIENTS-1:0];
    reg                        pend_burst_r[NUM_CLIENTS-1:0];
    reg [PORT_ADDR_WIDTH-1:0]  pend_addr_r [NUM_CLIENTS-1:0];
    reg [DATA_WIDTH-1:0]       pend_data_r [NUM_CLIENTS-1:0];
    reg [DQM_WIDTH-1:0]        pend_be_r   [NUM_CLIENTS-1:0];

    // Plain-array mirrors of the client interface signals (interface arrays
    // cannot be indexed with a procedural variable)
    wire req_rd_w[NUM_CLIENTS-1:0];
    wire req_wr_w[NUM_CLIENTS-1:0];
    wire cl_burst_w[NUM_CLIENTS-1:0];
    wire [PORT_ADDR_WIDTH-1:0] cl_addr_w[NUM_CLIENTS-1:0];
    wire [DATA_WIDTH-1:0]      cl_data_w[NUM_CLIENTS-1:0];
    wire [DQM_WIDTH-1:0]       cl_be_w  [NUM_CLIENTS-1:0];

    reg busy_r, req_r, req_is_wr_r;
    reg [$clog2(NUM_CLIENTS)-1:0] owner_r;
    reg [PORT_ADDR_WIDTH-1:0] addr_r;
    reg [DATA_WIDTH-1:0] data_r;
    reg [DQM_WIDTH-1:0] be_r;
    reg burst_r;

    generate
        for (genvar gi = 0; gi < NUM_CLIENTS; gi++) begin : client_io
            assign req_rd_w[gi] = clients[gi].rd;
            assign req_wr_w[gi] = clients[gi].wr;
            assign cl_burst_w[gi] = clients[gi].burst;
            assign cl_addr_w[gi] = clients[gi].addr;
            assign cl_data_w[gi] = clients[gi].data;
            assign cl_be_w[gi] = clients[gi].byte_en;
            assign clients[gi].q = controller.q;
            assign clients[gi].ready = controller.ready && busy_r &&
                                       (owner_r == ($clog2(NUM_CLIENTS))'(gi));
            assign clients[gi].available = controller.available && !busy_r;
        end
    endgenerate

    integer i;
    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            for (i = 0; i < NUM_CLIENTS; i = i + 1) begin
                pend_rd_r[i] <= 1'b0;
                pend_wr_r[i] <= 1'b0;
            end
            busy_r  <= 1'b0;
            req_r   <= 1'b0;
            owner_r <= '0;
        end else begin
            // Latch request pulses (addr/data are valid with the pulse and
            // held by the client until ready, but latch them anyway so the
            // grant can happen any number of cycles later)
            for (i = 0; i < NUM_CLIENTS; i = i + 1) begin
                if (req_rd_w[i] || req_wr_w[i]) begin
                    pend_rd_r[i]    <= req_rd_w[i];
                    pend_wr_r[i]    <= req_wr_w[i];
                    pend_burst_r[i] <= cl_burst_w[i];
                    pend_addr_r[i]  <= cl_addr_w[i];
                    pend_data_r[i]  <= cl_data_w[i];
                    pend_be_r[i]    <= cl_be_w[i];
                end
            end

            if (busy_r) begin
                if (controller.ready) begin
                    busy_r <= 1'b0;
                    req_r  <= 1'b0;   // dead cycle before the next grant
                end
            end else if (!req_r) begin
                for (i = NUM_CLIENTS - 1; i >= 0; i = i - 1) begin
                    if (pend_rd_r[i] || pend_wr_r[i]) begin
                        busy_r      <= 1'b1;
                        req_r       <= 1'b1;
                        req_is_wr_r <= pend_wr_r[i];
                        owner_r     <= ($clog2(NUM_CLIENTS))'(i);
                        addr_r      <= CLIENT_BASE_ADDR[i] + pend_addr_r[i];
                        data_r      <= pend_data_r[i];
                        be_r        <= pend_be_r[i];
                        burst_r     <= pend_burst_r[i];
                        pend_rd_r[i] <= 1'b0;
                        pend_wr_r[i] <= 1'b0;
                    end
                end
            end
        end
    end

    assign controller.rd = req_r && !req_is_wr_r;
    assign controller.wr = req_r && req_is_wr_r;
    assign controller.addr = addr_r;
    assign controller.data = data_r;
    assign controller.byte_en = be_r;
    assign controller.burst = burst_r;

endmodule
