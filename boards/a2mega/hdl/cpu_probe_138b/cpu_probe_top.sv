// S7 fast-core Fmax probe (boards/a2mega/docs/gs_socket_s7_fast_core_exploration.md).
//
// The 65C816 core plus a 128 KB byte-wide BSRAM (banks $00/$01 of the S7
// memory-of-record) in the two-clock step the accelerator plan uses:
//   address clock: the BSRAM captures A_OUT (A_OUT is a function of core
//                  state only — verified: no D_IN term in ADDR_BUS);
//   data clock:    BSRAM data -> core datapath -> registers, CE = 1.
// So the clock Fmax the tool reports is the cone frequency of the slower of
// (BSRAM out -> ALU -> flags) and (regs -> A_OUT -> BSRAM address); the step
// rate is Fmax / 2 here and 108 / N on the real card (N = clocks per step).
//
// CPU_PROBE_DATALATE (the _fast_dl project): the data-late step.  One clock
// per step; the memory's read address is the core's NA_OUT (the address of
// the next step, formed from next-state values) registered inside the BSRAM
// at the step edge, so the clock period IS the step time and the reported
// Fmax is the step rate.  Writes go to the registered A_OUT at the step
// edge through the second port; a read of the byte written at the same edge
// is served by a one-entry bypass (bench: tb_cpu_bench.sv +datalate).
//
// Stock core (P65C816) when CPU_PROBE_STOCK is defined (the _stock project
// lists cpu_probe_stock_defines.v first); the fast variant F65C816 otherwise.
// Memory image = the bench program (hdl/twgs/sim/bench/prog/bench_all.s),
// so the core executes real code and nothing is constant-folded.  The probe
// is a timing instrument and is never flashed.
module cpu_probe_top (
    input  logic       clk50_in,
    input  logic       button,      // SOM pushbutton, active low = reset
    output logic [3:0] led          // active low
);
    wire clk = clk50_in;

    // ---- reset: 16 clocks after configuration, or while the button is held
    logic [4:0] rst_cnt = 5'd0;
    always_ff @(posedge clk)
        if (!button)          rst_cnt <= 5'd0;
        else if (!rst_cnt[4]) rst_cnt <= rst_cnt + 5'd1;
    wire rst_n = rst_cnt[4];

    // ---- step phase: 0 = address clock, 1 = data clock (core steps at its end)
    logic phase = 1'b0;
    always_ff @(posedge clk)
        if (!rst_n) phase <= 1'b0;
        else        phase <= ~phase;
`ifdef CPU_PROBE_DATALATE
    wire ce = 1'b1;
`else
    wire ce = phase;
`endif

    // ---- core
    logic [23:0] a, na;
    logic [7:0]  din, dout;
    logic        we, vpa, vda, vpb, mlb, rdyo, iflag;

`ifdef CPU_PROBE_STOCK
    P65C816 u_cpu (
`else
    F65C816 u_cpu (
`endif
        .CLK(clk), .RST_N(rst_n), .CE(ce), .CE_X({4{ce}}), .RDY_IN(1'b1),
        .NMI_N(1'b1), .IRQ_N(1'b1), .ABORT_N(1'b1),
        .D_IN(din), .D_OUT(dout), .A_OUT(a), .WE(we), .RDY_OUT(rdyo),
        .VPA(vpa), .VDA(vda), .MLB(mlb), .VPB(vpb), .I_FLAG(iflag)
`ifndef CPU_PROBE_STOCK
        , .NA_OUT(na)
`endif
        );

    // ---- 128 KB BSRAM, synchronous read on the address clock, write on the
    // step clock.  The two never coincide, and keeping them in if/else keeps
    // GowinSynthesis from inferring read-before-write (WRITE_MODE 2'b10),
    // which the GW5A single-port BSRAM rejects at PnR (PA2122).  The hex is
    // named bare: synthesis finds files listed in the .gprj by name, and a
    // path it cannot open is only a WARN (EX3988) that leaves the ROM zero.
    // CPU_PROBE_SMALL_MEM: one 2 KB block (no output mux) — isolates the
    // core's own cone from the memory's clock-to-out + 64:1 mux share.
`ifdef CPU_PROBE_SMALL_MEM
    localparam int MEM_AW = 11;
`elsif CPU_PROBE_NEAR_MEM
    // 16 KB: eight 16K x 1 blocks, no output mux - the size of a near memory
    // (cache) in front of the banks, to see what the core does with one
    localparam int MEM_AW = 14;
`else
    localparam int MEM_AW = 17;
`endif
    logic [7:0] mem [0:(1<<MEM_AW)-1];
    initial $readmemh("cpu_probe_mem.hex", mem);
    logic [7:0] rdata;
`ifdef CPU_PROBE_DATALATE
    // read port: next-step address, registered in the BSRAM when the core steps
    always_ff @(posedge clk) if (rdyo) rdata <= mem[na[MEM_AW-1:0]];
    // write port: this step's address and data, at the step edge
    always_ff @(posedge clk) if (rdyo && !we) mem[a[MEM_AW-1:0]] <= dout;
    // bypass: the byte written at the last edge, if this step reads it
    logic              byp_wr = 1'b0;
    logic [MEM_AW-1:0] byp_a;
    logic [7:0]        byp_d;
    always_ff @(posedge clk) if (rdyo) begin
        byp_wr <= !we;
        byp_a  <= a[MEM_AW-1:0];
        byp_d  <= dout;
    end
    assign din = (byp_wr && byp_a == a[MEM_AW-1:0]) ? byp_d : rdata;
`else
    always_ff @(posedge clk) begin
        if (ce && !we) mem[a[MEM_AW-1:0]] <= dout;
        else           rdata <= mem[a[MEM_AW-1:0]];
    end
    assign din = rdata;
`endif

    // ---- keep every output observable
    logic [23:0] hb = 24'd0;
    always_ff @(posedge clk) hb <= hb + 24'd1;
    logic par_a = 1'b0, par_d = 1'b0;
    always_ff @(posedge clk) if (ce) begin
        par_a <= ^a;
        par_d <= ^dout ^ we ^ vpa ^ vda ^ vpb ^ mlb ^ iflag;
    end
    assign led = ~{hb[23], par_a, par_d, rdyo};
endmodule
