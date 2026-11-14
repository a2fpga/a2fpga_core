// S7 accelerator timing probe (boards/a2mega/docs/gs_socket_s7_fast_core_exploration.md).
//
// The whole accelerator domain as the accelerator-only build will have it,
// on the real GS-socket balls of the 138B SOM: gs_socket_phy, gs_accel_broker
// (data-late, with gs_mmu_replica), the F65C816 core, and the two local
// memories in block RAM - banks 00/01 (128 KB, dual-port: read launch on one
// port, write on the other) and the ROM 01 image (128 KB).  No expansion
// RAM, no control plane: the mode inputs come from a small register walked by
// the SOM pushbutton so that nothing is constant-folded.
//
// (ACCEL_PROBE_NEAR) The same with the near memory in front of those two and
// the two-clk step (gs_accel_broker NEAR): a 16K-entry cache of {tag, byte}
// beside the core, fourteen blocks of 16K x 1, which is all the core's next
// address reaches; the banks and the ROM image are read only from registers
// and are left to the placer.  a2mega_accel_probe_138b_n2.gprj: 100 MHz,
// 50 MHz steps.
//
// clk50_in stands in for the 108 MHz pin-sequencer clock (the constraint
// file declares it as such); the core steps every STEP_CLKS = 3 clks = 36 MHz.
// A second project declares it 100 MHz and steps every two clks = 50 MHz.
// The probe is a timing instrument and is never flashed: the memories are
// uninitialised and the ROM image has a stand-in loader port.
module accel_probe_top (
    input  logic        clk50_in,
    input  logic        button,          // SOM pushbutton, active low
    output logic [3:0]  led,             // active low

    input  logic        gs_ph2,
    input  logic        gs_rdy,
    input  logic        gs_irq_n,
    input  logic        gs_nmi_n,
    input  logic        gs_res_n,
    input  logic        gs_abort_n,
    input  logic        gs_be,
    inout  wire  [7:0]  gs_d,
    output logic [15:0] gs_a,
    output logic        gs_rw,
    output logic        gs_vp,
    output logic        gs_rdy_out,
    output logic        gs_d_dir,
    output logic        gs_data_oe_n,
    output logic        gs_addr_oe_n,
    output logic        gs_oe_n
);
    // (ACCEL_PROBE_STEP2: the 50 MHz variant - two clks of a 100 MHz clock per
    // step, the step decided in its first clk; a2mega_accel_probe_138b_s2.gprj)
    // (ACCEL_PROBE_NEAR: two clks per step, every step decoded in its first clk
    // from registers)
`ifdef ACCEL_PROBE_NEAR
    localparam int STEP_CLKS = 2;
    localparam int ADDR_CLKS = 2;
`elsif ACCEL_PROBE_STEP2
    localparam int STEP_CLKS = 2;
    localparam int ADDR_CLKS = 1;
`else
    localparam int STEP_CLKS = 3;
    localparam int ADDR_CLKS = 2;
`endif
    localparam int SLOW_CLKS = 3;

    wire clk = clk50_in;

    // ---- reset and the walked configuration register
    logic [4:0] rst_cnt = 5'd0;
    always_ff @(posedge clk) if (!rst_cnt[4]) rst_cnt <= rst_cnt + 5'd1;
    wire rst_n = rst_cnt[4];

    logic [2:0]  btn_s = 3'b111;
    logic [10:0] cfg   = 11'b000_0000_0111;   // {exp_banks[6:0], cxrom_local, armed, mem_bypass, native}
    always_ff @(posedge clk) begin
        btn_s <= {btn_s[1:0], button};
        if (btn_s[2] & ~btn_s[1]) cfg <= {cfg[9:0], ~cfg[10]};
    end

    // ---- socket PHY
    logic [23:0] phy_a;
    logic [7:0]  phy_d_out, gs_d_o;
    logic        phy_we_n, phy_vpa, phy_vda, phy_vp_n, gs_d_oe;
    logic        enabled, running, fall_evt, issue_evt, ph2_alive, be_ok;
    logic [31:0] cycle_count;

    gs_socket_phy #(.CORE_SUBST(1'b0), .WDATA_LATE(1'b1)) u_phy (  // the broker substitutes internal I/O cycles itself
        .force_slow_i(1'b0),
        .clk(clk), .rst_n(rst_n), .armed_i(cfg[2]), .listen_i(1'b0), .out_extra_i(4'd0),
        .cpu_clk_o(), .cpu_rst_n_o(),
        .cpu_a_i(phy_a), .cpu_d_out_i(phy_d_out), .cpu_we_n_i(phy_we_n), .cpu_vp_n_i(phy_vp_n),
        .cpu_vpa_i(phy_vpa), .cpu_vda_i(phy_vda),
        .gs_ph2_i(gs_ph2), .gs_rdy_i(gs_rdy), .gs_res_n_i(gs_res_n), .gs_be_i(gs_be),
        .gs_d_o(gs_d_o), .gs_d_oe_o(gs_d_oe),
        .gs_a_o(gs_a), .gs_rw_o(gs_rw), .gs_vp_o(gs_vp), .gs_rdy_out_o(gs_rdy_out),
        .gs_d_dir_o(gs_d_dir), .gs_data_oe_n_o(gs_data_oe_n), .gs_addr_oe_n_o(gs_addr_oe_n),
        .gs_ctl_oe_n_o(gs_oe_n),
        .ph2_alive_o(ph2_alive), .running_o(running), .enabled_o(enabled), .be_ok_o(be_ok),
        .fall_evt_o(fall_evt), .issue_evt_o(issue_evt), .ended_read_o(),
        .cycle_count_o(cycle_count), .stall_count_o(), .be_count_o()
    );
    assign gs_d = gs_d_oe ? gs_d_o : 8'bz;

    // ---- broker
    logic        cpu_rst_n, cpu_ce, cpu_irq_n, cpu_nmi_n, cpu_abort_n;
    logic [3:0]  cpu_ce_c;
    logic [7:0]  cpu_d_in, cpu_d_out;
    logic [23:0] cpu_a, cpu_na;
    logic [13:0] cpu_na_b;
    logic [2:0]  cpu_nst;
    logic        cpu_we_n, cpu_vp_n, cpu_vpa, cpu_vda, cpu_mlb, cpu_iflag, cpu_rdyo;
    logic [RA_COPIES-1:0] lm_ren_c, lm_wen_c;
    wire         lm_ren = lm_ren_c[0];
    logic [23:0] lm_raddr, lm_waddr;
`ifdef ACCEL_PROBE_NEAR
    localparam bit NEAR      = 1'b1;
    localparam int RA_COPIES = 1;                // the far memories are read from registers: no copies, no floorplan
`else
    localparam bit NEAR      = 1'b0;
    localparam int RA_COPIES = 4;                // one copy of the read addresses and enables per quarter of the floorplan
`endif
    // near memory: the tag holds A14-A17 (banks 00/01 and the ROM image; this probe
    // has no expansion memory), so an entry is 8 + 6 bits
    localparam int NEAR_AW = 14, NEAR_KW = 4, NTW = NEAR_KW + 2;
    logic               nm_ren, nm_wen;
    logic [NEAR_AW-1:0] nm_ra, nm_wa;
    logic [7:0]         nm_rdata, nm_wdata;
    logic [NTW-1:0]     nm_rtag, nm_wtag;
    // The second local memory: 8 blocks per bit = the whole 128 KB ROM image of a
    // ROM 01 machine; (ACCEL_PROBE_ROM3) 16 per bit = the 256 KB of a ROM 3; or
    // (ACCEL_PROBE_SMALL_ROM) 2 per bit = 32 KB, the size of a cache in front of a
    // backing store.  Three projects, to measure what the footprint of the memory costs.
`ifdef ACCEL_PROBE_SMALL_ROM
    localparam int ROM_BLKS = 2;
`elsif ACCEL_PROBE_ROM3
    localparam int ROM_BLKS = 16;
`else
    localparam int ROM_BLKS = 8;
`endif
    localparam int ROM_SELW = $clog2(ROM_BLKS);
    logic [RA_COPIES*17-1:0] lm_ram_ra;
    logic [RA_COPIES*18-1:0] lm_rom_ra;
    logic [7:0]  lm_wdata, lm_ram_rdata, lm_rom_rdata;
    logic        brk_fast, verify_miss, pw_busy, sock_idle;
    logic [15:0] verify_count;
    logic [31:0] stat_steps, stat_sock, stat_posted, stat_pwwait, stat_rd_hit, stat_rd_miss;
    logic [7:0]  r_shadow, r_cyareg, r_sltromsel, r_statereg, r_misc;

    gs_accel_broker #(.STEP_CLKS(STEP_CLKS), .ADDR_CLKS(ADDR_CLKS), .SLOW_CLKS(SLOW_CLKS), .DATA_LATE(1'b1), .RA_COPIES(RA_COPIES), .CE_COPIES(4),
                      .NEAR(NEAR), .NEAR_AW(NEAR_AW), .NEAR_KW(NEAR_KW)) u_brk (
        .nm_ren_hi_o(), .nm_ra_hi_o(), .lm_rexp_o(), .lm_rwait_i(1'b0), .lm_wbusy_i(1'b0),
        .clk(clk), .rst_n(rst_n),
        .native_i(cfg[0]), .mem_bypass_i(cfg[1]),
        .cxrom_local_i(cfg[3]), .exp_banks_i(cfg[10:4]), .slow_local_i(1'b0),
        .hold_i(1'b0), .idle_a_i(24'd0), .held_o(), .idle_stb_o(), .idle_d_o(),
        .nm_flush_i(1'b0), .nm_flush_idx_i('0),
        .phy_enabled_i(enabled), .phy_running_i(running),
        .phy_fall_evt_i(fall_evt), .phy_issue_evt_i(issue_evt),
        .phy_a_o(phy_a), .phy_d_out_o(phy_d_out), .phy_we_n_o(phy_we_n),
        .phy_vpa_o(phy_vpa), .phy_vda_o(phy_vda), .phy_vp_n_o(phy_vp_n),
        .gs_ph2_i(gs_ph2), .gs_d_i(gs_d), .gs_rdy_i(gs_rdy),
        .gs_irq_n_i(gs_irq_n), .gs_nmi_n_i(gs_nmi_n), .gs_abort_n_i(gs_abort_n),
        .cpu_rst_n_o(cpu_rst_n), .cpu_ce_o(cpu_ce), .cpu_ce_c_o(cpu_ce_c), .cpu_d_in_o(cpu_d_in),
        .cpu_irq_n_o(cpu_irq_n), .cpu_nmi_n_o(cpu_nmi_n), .cpu_abort_n_o(cpu_abort_n),
        .cpu_a_i(cpu_a), .cpu_d_out_i(cpu_d_out), .cpu_we_n_i(cpu_we_n),
        .cpu_vpa_i(cpu_vpa), .cpu_vda_i(cpu_vda), .cpu_vp_n_i(cpu_vp_n), .cpu_na_i(cpu_na), .cpu_nst_i(cpu_nst), .cpu_rdy_i(cpu_rdyo),
        .lm_ren_o(lm_ren_c), .lm_ram_ra_o(lm_ram_ra), .lm_rom_ra_o(lm_rom_ra), .lm_raddr_o(lm_raddr),
        .lm_ram_rdata_i(lm_ram_rdata), .lm_rom_rdata_i(lm_rom_rdata),
        .lm_wen_o(lm_wen_c), .lm_waddr_o(lm_waddr), .lm_wdata_o(lm_wdata), .lm_wfwd_o(),
        .nm_ren_o(nm_ren), .nm_ra_o(nm_ra), .nm_rdata_i(nm_rdata), .nm_rtag_i(nm_rtag),
        .nm_wen_o(nm_wen), .nm_wa_o(nm_wa), .nm_wdata_o(nm_wdata), .nm_wtag_o(nm_wtag),
        .fast_o(brk_fast), .step_evt_o(), .sock_evt_o(), .sock_idle_o(sock_idle), .pw_busy_o(pw_busy),
        .verify_miss_o(verify_miss), .verify_addr_o(), .verify_count_o(verify_count),
        .slow_o(), .verify_scount_o(), .verify_saddr_o(),
        .stat_steps_o(stat_steps), .stat_sock_o(stat_sock), .stat_posted_o(stat_posted),
        .stat_pwwait_o(stat_pwwait), .stat_rd_hit_o(stat_rd_hit), .stat_rd_miss_o(stat_rd_miss),
        .shadow_o(r_shadow), .cyareg_o(r_cyareg), .sltromsel_o(r_sltromsel),
        .statereg_o(r_statereg), .sw_misc_o(r_misc)
    );

    // ---- core
    F65C816 u_cpu (
        .CLK(clk), .RST_N(cpu_rst_n), .CE(cpu_ce), .CE_X(cpu_ce_c), .RDY_IN(1'b1),
        .NMI_N(cpu_nmi_n), .IRQ_N(cpu_irq_n), .ABORT_N(cpu_abort_n),
        .D_IN(cpu_d_in), .D_OUT(cpu_d_out), .A_OUT(cpu_a), .WE(cpu_we_n), .RDY_OUT(cpu_rdyo),
        .VPA(cpu_vpa), .VDA(cpu_vda), .MLB(cpu_mlb), .VPB(cpu_vp_n), .I_FLAG(cpu_iflag),
        .NA_OUT(cpu_na), .NST_OUT(cpu_nst), .NA_OUT_B(cpu_na_b)
    );

    // ---- local memories: 64 blocks of 16Kx1 each, written out block by block so
    // that the floorplan (accel_probe_138b.cst) and the read-address copies can be
    // tied to them.  The die's BSRAM sites are sparse (about 38 per strip across
    // the whole width, strips 18 rows apart), so 128 blocks cover a large area
    // whatever is done; the data bits are grouped two to a quadrant around the
    // core, and each quadrant has its own copy of the two read addresses.  For
    // every data bit: eight RAM blocks and eight ROM-image blocks read at once,
    // and a registered block select picks one of each.  The ROM image is loaded
    // at bring-up in the real build, so it is a RAM here too: a stand-in loader
    // port (button held: write the registered data pads at a running address)
    // keeps synthesis from collapsing it.
    logic [17:0] ld_a = 18'd0;
    logic [7:0]  ld_d = 8'd0;
    logic        ld_we = 1'b0;
    always_ff @(posedge clk) begin
        ld_we <= ~btn_s[2];
        ld_d  <= gs_d;
        if (ld_we) ld_a <= ld_a + 18'd1;
    end
    wire ram_bank = (lm_waddr[23:17] == 7'd0);      // a write to banks 00/01

    for (genvar b = 0; b < 8; b++) begin : g_bit
        localparam int CI = (b / 2) % RA_COPIES;
        wire [16:0] ra = lm_ram_ra[CI * 17 +: 17];
        wire [17:0] oa = lm_rom_ra[CI * 18 +: 18];
        wire        ren = lm_ren_c[CI];              // this quarter's copies of the enables
        wire        wen = lm_wen_c[CI];
        logic [2:0] ram_sel;
        logic [ROM_SELW-1:0] rom_sel;
        logic [7:0] ram_q;
        logic [ROM_BLKS-1:0] rom_q;
        always_ff @(posedge clk) if (ren) begin
            ram_sel <= ra[16:14];
            rom_sel <= oa[14 +: ROM_SELW];
        end
        for (genvar k = 0; k < 8; k++) begin : g_blk
            logic mram [0:16383];
            always_ff @(posedge clk) if (ren) ram_q[k] <= mram[ra[13:0]];
            always_ff @(posedge clk) if (wen && ram_bank && lm_waddr[16:14] == 3'(k)) mram[lm_waddr[13:0]] <= lm_wdata[b];
        end
        for (genvar k = 0; k < ROM_BLKS; k++) begin : g_rblk
            logic mrom [0:16383];
            always_ff @(posedge clk) if (ren) rom_q[k] <= mrom[oa[13:0]];
            always_ff @(posedge clk) if (ld_we && ld_a[14 +: ROM_SELW] == ROM_SELW'(k)) mrom[ld_a[13:0]] <= ld_d[b];
        end
        assign lm_ram_rdata[b] = ram_q[ram_sel];
        assign lm_rom_rdata[b] = rom_q[rom_sel];
    end

    // ---- near memory: one 16K x 1 block per entry bit, no output mux.  The tag is
    // stored inverted, so that a block RAM's power-up zeros read as "no entry".
    // The read address is the core's next address, its latest output, and the blocks
    // sit in two rows of block RAM 18 rows apart (gen_floorplan.py near): the blocks of
    // the second row take the core's second copy of it (NA_OUT_B), so that neither
    // copy's net spans both rows.
    if (NEAR) begin : g_near
        localparam logic [8+NTW-1:0] ROW_B = 14'b11_0000_1100_1100;      // entry bits placed in R64
        wire [8+NTW-1:0] nm_wv = {~nm_wtag, nm_wdata};
        logic [8+NTW-1:0] nm_q;
        for (genvar b = 0; b < 8 + NTW; b++) begin : g_nb
            logic nmem [0:(1<<NEAR_AW)-1];
            wire [NEAR_AW-1:0] ra = ROW_B[b] ? cpu_na_b[NEAR_AW-1:0] : nm_ra;
            always_ff @(posedge clk) if (nm_ren) nm_q[b] <= nmem[ra];
            always_ff @(posedge clk) if (nm_wen) nmem[nm_wa] <= nm_wv[b];
        end
        assign nm_rdata = nm_q[7:0];
        assign nm_rtag  = ~nm_q[8 +: NTW];
    end else begin : g_nonear
        assign nm_rdata = 8'h00;
        assign nm_rtag  = '1;
    end

    // ---- keep the telemetry observable
    logic [3:0] par = 4'd0;
    logic [6:0] lm_raddr_q = 7'd0;      // the expansion-bank bits, as an expansion memory would register them
    always_ff @(posedge clk) if (lm_ren) lm_raddr_q <= lm_raddr[23:17];
    always_ff @(posedge clk) begin
        par[0] <= ^{stat_steps, stat_sock, stat_posted, stat_pwwait};
        par[1] <= ^{stat_rd_hit, stat_rd_miss, verify_count, verify_miss, pw_busy, sock_idle, brk_fast};
        par[2] <= ^{r_shadow, r_cyareg, r_sltromsel, r_statereg, r_misc, cycle_count, ph2_alive, be_ok};
        par[3] <= ^{cpu_mlb, cpu_iflag, cpu_rdyo, lm_raddr_q};
    end
    assign led = ~par;
endmodule
