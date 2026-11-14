// S7b bench - the accelerator broker (gs_accel_broker + gs_mmu_replica) and
// the unchanged socket PHY (gs_socket_phy) with a 65C816 core stepped in the
// PHY's clock domain, against a behavioural IIgs at the socket.
// Bench for Verilator --timing (see run_gs_broker_sim.sh).
//
// The socket side is the S2-S6 bench (tb_gs_socket.sv): the FPI PHI2 model
// (5-tick fast cycles, refresh, the 65th-PH0 stretch, sync cycles on the PH0
// grid, 1 MHz slow mode), the level-shifter delays and the W65C816S timing
// checks (tADS, tBAS, tAH, tBH, tMDS, tDHW, contention, RDY repeats, BE).
// What is new:
//
//  * The machine behind the socket is the golden model (sim/mmu/
//    iigs_mmu_model.h through DPI): soft switches, language card, aux
//    memory, shadow copies into E0/E1, ROM, an I/O register file.  The FPI's
//    choice of fast or sync cycle follows slow_class_now of the MiSTer
//    rtl/clock_divider.v (I/O, E0/E1 and SHADOWED WRITES are sync cycles).
//  * A REFERENCE core (stock P65C816) is stepped with the same clock enable
//    as the core under test, on a second, ideal instance of the machine
//    model.  Every step is compared (address, R/W, VPA/VDA/VPB, write data)
//    and every byte the broker delivers to the core - from the card's memory
//    or from the socket - must be the byte the ideal machine holds.
//  * EXPECTED SOCKET CYCLES.  From the reference side alone (golden decode,
//    not the RTL replica) the bench derives which steps must appear on the
//    socket and queues them in program order.  Every PHI2 cycle on the
//    socket must then be either the cycle at the head of the queue
//    (address, direction, write data) or an idle read of the park address.
//    That one check covers: no cycle the machine should not see, none
//    missing, none twice, I/O and Mega II cycles in program order, and a
//    posted write never overtaken by a later cycle.
//  * Whenever nothing is outstanding, the motherboard model's Mega II RAM,
//    I/O registers and soft switches must equal the ideal machine's; at the
//    end the card's banks 00/01 (and expansion) must equal the ideal
//    machine's fast RAM.
//  * NEAR builds (the near memory and the two-clk step): the near memory is
//    modelled as the block RAM it will be (a read launched in the clk of a
//    write to the same index returns the new tag with the wrong byte), and
//    at the end every entry must be the byte of the card's memory its tag
//    names.
//  * +mode=native|paced: an S6 PHY + PHI2-clocked core run beside the
//    design under test on the same socket inputs, and every pin the card
//    drives is compared every clk (native mode = S6, pin for pin).
//
// Plusargs
//   +rom=<file>     128 KB ROM image (the built test ROM, or a ROM 01)
//   +mode=native    every step a socket cycle, data from the socket (S6)
//         paced     every step a socket cycle, card memory of record (verify)
//         fast      (default) local steps at STEP_CLKS, socket cycles as needed
//         toggle    paced <-> fast switched at pseudo-random points
//   +steps=N        core steps to run (default 60000)
//   +exp=N          expansion banks backed by the card and present in the machine
//   +mbexp=N        expansion banks in the machine (default = +exp)
//   +cxrom=1        serve internal $C100-$CFFF firmware from the card
//   +irq            raise /IRQ twice once the test program reaches its loop
//   +recopy         (+mode=copy) a second copy of the ROM image, asked for from fast mode after step 20000
//                   (+recopyat=N: after step N)
//   +reset          a warm reset (/RES low for 12 cycles) half way through
//   +resetw         the same, with /RES falling in the middle of a socket write cycle
//   +resetx         the same, with /RES falling while a step waits for the expansion memory (EXP_DDR)
//   +resetpw        the same, with /RES falling in the cycle before a native-mode write
//                   (FAST_CORE builds, +mode=native: the bench waits for such a cycle)
//   +nostall +nobe  no RDY stalls / no BE (DMA) pause
//   +stallp=N       a RDY stall every N PHI2 cycles (default 311)
//   +wbforce        the expansion queue's "nearly full" forced high in long bursts (it only ever holds
//                   steps: nothing may change but the time; gs_accel beside the design is not compared)
//   +noturbo        ignore $C036 bit 7: the FPI stays at 1 MHz
//   +expect         check the test program's result table
//   +wlog=<file>    write the socket-visible write stream (I/O, Mega II,
//                   shadowed ranges, slot space) to <file>
//   +trace +vcd
//
`timescale 1ns/1ps

module tb_gs_broker #(
    parameter int STEP_CLKS = 4,
    parameter int ADDR_CLKS = 1,
    parameter bit DATA_LATE = 1'b0,    // broker launches reads one step ahead (FAST_CORE builds only)
    parameter int RA_COPIES = 1,       // copies of the read addresses the broker puts out
    parameter bit NEAR      = 1'b0,    // near memory and the two-clk step (DATA_LATE builds, ADDR_CLKS = 2)
    parameter int NEAR_AW   = 14,
    parameter int NEAR_KW   = 10,
    parameter bit SOCK_PRE  = 1'b1,    // broker: socket-only steps requested in their first clk (0: for comparison)
    parameter int FAR_CLKS  = 1,       // broker: clks the far memories' data has to reach it (2 with gs_accel beside)
    parameter bit EXP_DDR   = 1'b0,    // the card's expansion banks are in a memory of varying latency behind
                                       // gs_accel_exp (the DDR3): here gs_exp_mem_sim; the near memory's tag is split
    parameter bit NEAR_SPLIT = 1'b0,   // EXP_DDR: the near memory's tag is split, its address bits above A17 read
                                       // a clk late (the broker's and gs_accel's NEAR_SPLIT); else the tag is whole
    parameter int ACC_EXP   = 0,       // ACCEL_SHADOW: gs_accel's expansion banks; it is compared in runs with +exp= this
    parameter bit ROM_PRESET = 1'b1    // 1 = the bench loads the card's ROM image; 0 = it starts empty and
                                       // +mode=copy has the design read it through the socket
);

    import "DPI-C" function int  mach_load_rom(input string path);
    import "DPI-C" function void mach_config(input int ram_banks);
    import "DPI-C" function void mach_reset(input int m);
    import "DPI-C" function void mach_poke(input int addr, input int data);
    import "DPI-C" function int  mach_peek(input int m, input int addr, input int vpb_n);
    import "DPI-C" function void mach_commit(input int m, input int addr, input int we, input int data, input int vpb_n);
    import "DPI-C" function int  mach_class(input int m, input int addr, input int we, input int vpb_n);
    import "DPI-C" function int  mach_ext(input int m, input int addr, input int we, input int vpb_n,
                                          input int cxrom_local, input int exp_banks);
    import "DPI-C" function int  mach_get(input int m, input int space, input int addr);
    import "DPI-C" function int  mach_diff(input int space, input int lo, input int hi);
    import "DPI-C" function int  mach_diff_where();
    import "DPI-C" function int  mach_stat(input int m, input int which);
    import "DPI-C" function void mach_sync_slow();

    //---------------------------------------------------------------- params
    localparam real T14    = 69.841;   // 14.31818 MHz
`ifdef CLK100
    localparam real TCLK   = 10.0;     // 100 MHz accelerator domain
`elsif CLK105
    localparam real TCLK   = 9.524;    // 105 MHz: the accelerator-only build's alternative (gowin_acc_pll)
`elsif CLK110
    localparam real TCLK   = 9.091;    // 110 MHz: the socket PLL of the board builds (gowin_gs_pll)
`else
    localparam real TCLK   = 9.259;    // 108 MHz
`endif
    localparam real T_XCVR = 5.0;      // 74ALVC164245 / LV1T125 tpd
    localparam real T_XEN  = 6.0;      // enable / disable
    // W65C816S, 4 MHz grade (datasheet table 4-2)
    localparam real T_ADS = 75.0, T_BAS = 75.0, T_AH = 20.0, T_BH = 20.0;
    localparam real T_MDS = 70.0, T_DHW = 20.0, T_DHR = 20.0;
    localparam real T_BVD = 200.0;     // see tb_gs_socket.sv
    localparam real T_ACC   = 100.0;   // read data driven this long after the rise
    localparam real T_GARB  = 35.0;    // garbage driven until fall + T_GARB
    localparam logic [23:0] PARK = 24'hFF0000;
    localparam int EXP_MAX = 126;      // expansion banks the bench can back (02-7F)
    // RAM does not power up empty: one byte of bank 7F, where the machine has it, that
    // nothing writes (T24 reads it: out of the memory, not out of an entry that holds nothing)
    localparam logic [23:0] TOP_A = 24'h7FD955;
    localparam logic [7:0]  TOP_D = 8'hD9;

    //---------------------------------------------------------------- clocks
    logic clk = 1'b0;
    always #(TCLK/2.0) clk = ~clk;
    logic rst_n = 1'b0;

    logic tick = 1'b0;
    always #(T14/2.0) tick = ~tick;

    //---------------------------------------------------------------- configuration
    string       mode_s = "fast";
    bit          cfg_native = 0, cfg_bypass = 0, cfg_toggle = 0;
    int          cfg_exp = 0, cfg_mbexp = 0, cfg_cxrom = 0;
    int          stall_period = 311;      // PHI2 cycles between RDY stalls (+stallp=)
    bit          do_irq = 0, do_stall = 1, do_be = 1, do_expect = 0, s6cmp = 0, do_reset = 0, do_resetw = 0, do_resetpw = 0, do_resetx = 0;
    int          n_dropped = 0;      // posted writes dropped by a reset (documented: at most one each)
    int          n_kept = 0;         // local writes of a step cut short by a reset (documented: they stay written)
    longint      max_steps = 60000;
    int          wlog = 0;
    logic        native_i = 1'b1, mem_bypass_i = 1'b1;
    // +mode=copy: native with every byte from the socket until the ROM image has been
    // copied through the socket, then fast (what gs_accel grants its control inputs)
    bit          cfg_copy = 0;
    logic        copy_req = 1'b0, copy_q = 1'b0, copy_start = 1'b0;
    logic        copy_hold, copy_held, copy_stb, copy_flush, copy_we, copy_busy, copy_valid, copy_usable;
    logic [23:0] copy_a;
    logic [7:0]  copy_d, copy_wd, copy_copies;
    logic [17:0] copy_wa;
    logic [15:0] copy_sum;
    logic [NEAR_AW-1:0] copy_fidx;
    longint      n_copy = 0, n_copy_tail = 0, n_copy_cur = 0;
    int          n_copies_want = 1;
    bit          do_recopy = 0, recopy_done = 0, hold_cyc_q = 0;
    int          recopy_at = 20000;       // +recopyat=N: the second copy is asked for after step N
    logic        held_q = 1'b0, copy_busy_q = 1'b0;
    wire         native_w = cfg_copy ? ~copy_usable : native_i;
    wire         bypass_w = cfg_copy ? ~copy_usable : mem_bypass_i;

    //---------------------------------------------------------------- DUT pins
    logic        gs_ph2_f, gs_rdy_f, gs_irq_n_f, gs_nmi_n_f, gs_res_n_f, gs_abort_n_f, gs_be_f;
    logic [7:0]  gs_d_i_f, gs_d_o_f;
    logic        gs_d_oe_f;
    logic [15:0] gs_a_f;
    logic        gs_rw_f, gs_vp_f, gs_rdy_out_f, gs_d_dir_f, gs_data_oe_n_f, gs_addr_oe_n_f, gs_ctl_oe_n_f;
    logic        armed = 1'b0;
    logic        ph2_alive, running, enabled, fall_evt, issue_evt;
    logic [31:0] cycle_count;
    logic [15:0] stall_count, be_count;

    // broker <-> PHY
    logic [23:0] phy_a;
    logic [7:0]  phy_d_out;
    logic        phy_we_n, phy_vpa, phy_vda, phy_vp_n;
    // broker <-> core
    logic        cpu_rst_n, cpu_ce, cpu_irq_n, cpu_nmi_n, cpu_abort_n;
    logic [3:0]  cpu_ce_c;
    logic [7:0]  cpu_d_in, cpu_d_out;
    logic [23:0] cpu_a;
    logic        cpu_we_n, cpu_vp_n, cpu_rdy_out, cpu_vpa, cpu_vda, cpu_mlb, cpu_iflag;
    // broker <-> local memory
    logic [RA_COPIES-1:0] lm_ren_c, lm_wen_c;
    wire         lm_ren = lm_ren_c[0], lm_wen = lm_wen_c[0];
    logic [23:0] lm_raddr, lm_waddr, cpu_na;
    logic [RA_COPIES*17-1:0] lm_ram_ra_c;
    logic [RA_COPIES*18-1:0] lm_rom_ra_c;
    wire  [16:0] lm_ram_ra = lm_ram_ra_c[16:0];
    wire  [17:0] lm_rom_ra = lm_rom_ra_c[17:0];
    logic [7:0]  lm_wdata, lm_ram_rdata, lm_rom_rdata;
    // FAR_CLKS = 2: the far memories' data has two clks to reach the broker - it reads
    // WRONG in the clk after its launch, so that a broker that looked at it then shows
    logic        far_bad = 1'b0;
    // (a build may make a RAM write a clk or two after the broker does - gs_accel one:
    // no read may be launched within two clks of a write)
    logic        lm_wen_q1 = 1'b0, lm_wen_q2 = 1'b0;
    localparam int NTW = NEAR_KW + 2;
    // the tag of an entry that holds nothing (the broker's NM_EMPTY)
    localparam logic [NTW-1:0] NM_EMPTY = NEAR_SPLIT ? NTW'((3 << NEAR_KW) | 15) : '1;
    logic               nm_ren, nm_wen;
    logic [NEAR_AW-1:0] nm_ra, nm_wa;
    logic [7:0]         nm_rdata, nm_wdata;
    logic [NTW-1:0]     nm_rtag, nm_wtag;
    logic               nm_ren_hi;
    logic [NEAR_AW-1:0] nm_ra_hi;
    // expansion memory behind gs_accel_exp (EXP_DDR)
    logic               lm_rexp, xq_rwait, xq_rsel, xq_wbusy, xq_ovf, xq_req, xq_skip_w;
    bit                 wb_en = 0;                    // +wbforce
    logic [15:0]        wb_lfsr = 16'hACE1;
    logic [4:0]         wb_div = '0;
    always @(posedge clk) begin
        wb_div <= wb_div + 5'd1;
        if (wb_div == '0) wb_lfsr <= {wb_lfsr[14:0], wb_lfsr[15] ^ wb_lfsr[13] ^ wb_lfsr[12] ^ wb_lfsr[10]};
    end
    wire                wb_force = wb_en & (wb_lfsr[1:0] != 2'b00);
    bit                 x_check = 1'b0;
    logic [7:0]         xq_rdata;
    logic [31:0] stat_rd_hit, stat_rd_miss;
    logic [2:0]  cpu_nst;
    // telemetry
    logic        brk_fast, verify_miss;
    logic [23:0] verify_addr;
    logic [15:0] verify_count;
    logic [31:0] stat_steps, stat_sock, stat_posted, stat_pwwait;

    gs_socket_phy #(.CORE_SUBST(1'b0), .WDATA_LATE(1'b1)) u_phy (  // the broker substitutes internal I/O cycles itself
        .force_slow_i(1'b0),
        .clk(clk), .rst_n(rst_n), .armed_i(armed), .listen_i(1'b0), .out_extra_i(4'd0),
        .cpu_clk_o(), .cpu_rst_n_o(),
        .cpu_a_i(phy_a), .cpu_d_out_i(phy_d_out), .cpu_we_n_i(phy_we_n), .cpu_vp_n_i(phy_vp_n),
        .cpu_vpa_i(phy_vpa), .cpu_vda_i(phy_vda),
        .gs_ph2_i(gs_ph2_f), .gs_rdy_i(gs_rdy_f), .gs_res_n_i(gs_res_n_f), .gs_be_i(gs_be_f),
        .gs_d_o(gs_d_o_f), .gs_d_oe_o(gs_d_oe_f),
        .gs_a_o(gs_a_f), .gs_rw_o(gs_rw_f), .gs_vp_o(gs_vp_f), .gs_rdy_out_o(gs_rdy_out_f),
        .gs_d_dir_o(gs_d_dir_f), .gs_data_oe_n_o(gs_data_oe_n_f), .gs_addr_oe_n_o(gs_addr_oe_n_f),
        .gs_ctl_oe_n_o(gs_ctl_oe_n_f),
        .ph2_alive_o(ph2_alive), .running_o(running), .enabled_o(enabled), .be_ok_o(),
        .fall_evt_o(fall_evt), .issue_evt_o(issue_evt), .ended_read_o(),
        .cycle_count_o(cycle_count), .stall_count_o(stall_count), .be_count_o(be_count)
    );

    gs_accel_broker #(.STEP_CLKS(STEP_CLKS), .ADDR_CLKS(ADDR_CLKS), .PARK_ADDR(PARK), .DATA_LATE(DATA_LATE), .RA_COPIES(RA_COPIES), .CE_COPIES(4),
                      .NEAR(NEAR), .NEAR_AW(NEAR_AW), .NEAR_KW(NEAR_KW), .SOCK_PRE(SOCK_PRE), .FAR_CLKS(FAR_CLKS),
                      .EXP_WAIT(EXP_DDR), .NEAR_SPLIT(NEAR_SPLIT)) u_brk (
        .clk(clk), .rst_n(rst_n),
        .native_i(native_w), .mem_bypass_i(bypass_w),
        .cxrom_local_i(cfg_cxrom[0]), .exp_banks_i(cfg_exp[6:0]),
        .hold_i(copy_hold), .idle_a_i(copy_a), .held_o(copy_held), .idle_stb_o(copy_stb), .idle_d_o(copy_d),
        .nm_flush_i(copy_flush), .nm_flush_idx_i(copy_fidx),
        .phy_enabled_i(enabled), .phy_running_i(running),
        .phy_fall_evt_i(fall_evt), .phy_issue_evt_i(issue_evt),
        .phy_a_o(phy_a), .phy_d_out_o(phy_d_out), .phy_we_n_o(phy_we_n),
        .phy_vpa_o(phy_vpa), .phy_vda_o(phy_vda), .phy_vp_n_o(phy_vp_n),
        .gs_ph2_i(gs_ph2_f), .gs_d_i(gs_d_i_f), .gs_rdy_i(gs_rdy_f),
        .gs_irq_n_i(gs_irq_n_f), .gs_nmi_n_i(gs_nmi_n_f), .gs_abort_n_i(gs_abort_n_f),
        .cpu_rst_n_o(cpu_rst_n), .cpu_ce_o(cpu_ce), .cpu_ce_c_o(cpu_ce_c), .cpu_d_in_o(cpu_d_in),
        .cpu_irq_n_o(cpu_irq_n), .cpu_nmi_n_o(cpu_nmi_n), .cpu_abort_n_o(cpu_abort_n),
        .cpu_a_i(cpu_a), .cpu_d_out_i(cpu_d_out), .cpu_we_n_i(cpu_we_n),
        .cpu_vpa_i(cpu_vpa), .cpu_vda_i(cpu_vda), .cpu_vp_n_i(cpu_vp_n), .cpu_na_i(cpu_na), .cpu_nst_i(cpu_nst), .cpu_rdy_i(cpu_rdy_out),
        .lm_ren_o(lm_ren_c), .lm_ram_ra_o(lm_ram_ra_c), .lm_rom_ra_o(lm_rom_ra_c), .lm_raddr_o(lm_raddr),
        .lm_ram_rdata_i(xq_rsel ? xq_rdata : (lm_ram_rdata ^ {8{far_bad}})), .lm_rom_rdata_i(lm_rom_rdata ^ {8{far_bad}}),
        .lm_rexp_o(lm_rexp), .lm_rwait_i(xq_rwait), .lm_wbusy_i(xq_wbusy | wb_force),
        .nm_ren_hi_o(nm_ren_hi), .nm_ra_hi_o(nm_ra_hi),
        .lm_wen_o(lm_wen_c), .lm_waddr_o(lm_waddr), .lm_wdata_o(lm_wdata),
        .nm_ren_o(nm_ren), .nm_ra_o(nm_ra), .nm_rdata_i(nm_rdata), .nm_rtag_i(nm_rtag),
        .nm_wen_o(nm_wen), .nm_wa_o(nm_wa), .nm_wdata_o(nm_wdata), .nm_wtag_o(nm_wtag),
        .fast_o(brk_fast), .step_evt_o(), .sock_evt_o(), .sock_idle_o(), .pw_busy_o(),
        .verify_miss_o(verify_miss), .verify_addr_o(verify_addr), .verify_count_o(verify_count),
        .stat_steps_o(stat_steps), .stat_sock_o(stat_sock), .stat_posted_o(stat_posted),
        .stat_pwwait_o(stat_pwwait), .stat_rd_hit_o(stat_rd_hit), .stat_rd_miss_o(stat_rd_miss),
        .shadow_o(), .cyareg_o(), .sltromsel_o(), .statereg_o(), .sw_misc_o()
    );

    // The core under test, through its port list: stock P65C816, or the
    // restructured F65C816 (+define+FAST_CORE)
`ifdef FAST_CORE
    F65C816 u_cpu (
`else
    P65C816 u_cpu (
`endif
        .CLK(clk), .RST_N(cpu_rst_n), .CE(cpu_ce), .RDY_IN(1'b1),
        .NMI_N(cpu_nmi_n), .IRQ_N(cpu_irq_n), .ABORT_N(cpu_abort_n),
        .D_IN(cpu_d_in), .D_OUT(cpu_d_out), .A_OUT(cpu_a), .WE(cpu_we_n), .RDY_OUT(cpu_rdy_out),
        .VPA(cpu_vpa), .VDA(cpu_vda), .MLB(cpu_mlb), .VPB(cpu_vp_n), .I_FLAG(cpu_iflag)
`ifdef FAST_CORE
        , .CE_X(cpu_ce_c)
        , .NA_OUT(cpu_na), .NST_OUT(cpu_nst)
`endif
    );
`ifndef FAST_CORE
    assign cpu_na = 24'd0;
    assign cpu_nst = 3'b110;
    initial if (DATA_LATE) begin $display("DATA_LATE needs the FAST_CORE build"); $finish; end
`endif

    // The ROM image through the socket (gs_accel_romcopy), as gs_accel has it: the
    // request is registered into a one-clk start, the image is the bench's lrom.
    always_ff @(posedge clk) begin
        copy_q     <= copy_req;
        copy_start <= copy_req & ~copy_q;
        // a copy ends with the near memory empty, and the step that was held does not
        // trust the byte launched for it
        held_q      <= copy_held;
        copy_busy_q <= copy_busy;
        if (held_q && !copy_held && rst_n && u_brk.run_c && u_brk.nl_ok) begin
            $display("ERROR: the near memory's byte is trusted in the step after a hold"); $finish;
        end
        if (copy_busy_q && !copy_busy && copy_valid) begin
            int n_left;
            n_left = 0;
            for (int i = 0; i < (1<<NEAR_AW); i++) if (nmt[i] != NM_EMPTY) n_left++;
            if (n_left != 0) begin $display("ERROR: %0d near memory entries left after a ROM copy", n_left); $finish; end
        end
    end
    gs_accel_romcopy #(.NEAR_AW(NEAR_AW), .SIM_PRESET(ROM_PRESET)) u_copy (
        .clk(clk), .rst_n(rst_n),
        .start_i(copy_start), .ready_i(enabled & running),
        .hold_o(copy_hold), .idle_a_o(copy_a), .held_i(copy_held), .idle_stb_i(copy_stb), .idle_d_i(copy_d),
        .nm_flush_o(copy_flush), .nm_flush_idx_o(copy_fidx),
        .rom_we_o(copy_we), .rom_wa_o(copy_wa), .rom_wd_o(copy_wd),
        .busy_o(copy_busy), .valid_o(copy_valid), .usable_o(copy_usable), .sum_o(copy_sum), .copies_o(copy_copies)
    );

    //---------------------------------------------------------------- expansion memory of varying latency (EXP_DDR)
    logic        xm_req, xm_ready, xm_we, xm_rvalid;
    logic [22:0] xm_addr;
    logic [7:0]  xm_wdata, xm_rdata;
    if (EXP_DDR) begin : g_x
        gs_accel_exp #(.AW(23)) u_xq (
            .clk(clk), .rst_n(rst_n), .run_i(cpu_rst_n),
            .rd_i(lm_ren & lm_rexp), .rnx_i(lm_ren & ~lm_rexp), .raddr_i(lm_raddr[22:0]),
            .wr_i(lm_wen & (|lm_waddr[23:17])), .waddr_i(lm_waddr[22:0]), .wdata_i(lm_wdata),
            .rwait_o(xq_rwait), .rsel_o(xq_rsel), .rdata_o(xq_rdata), .wbusy_o(xq_wbusy), .ovf_o(xq_ovf), .busy_o(xq_req),
            .m_req_o(xm_req), .m_ready_i(xm_ready), .m_we_o(xm_we), .m_addr_o(xm_addr), .m_wdata_o(xm_wdata),
            .m_rvalid_i(xm_rvalid), .m_rdata_i(xm_rdata)
        );
        gs_exp_mem_sim #(.AW(23)) u_xmem (
            .clk(clk), .rst_n(rst_n), .m_req_i(xm_req), .m_ready_o(xm_ready), .m_we_i(xm_we), .m_addr_i(xm_addr),
            .m_wdata_i(xm_wdata), .m_rvalid_o(xm_rvalid), .m_rdata_o(xm_rdata)
        );
        assign xq_skip_w = (u_xq.skip != 4'd0);
        initial begin #100; if (cfg_exp >= 126) u_xmem.mem[TOP_A[22:0]] = TOP_D; end
        always @(posedge clk) if (rst_n && xq_ovf) begin $display("ERROR: the expansion memory's queue overflowed"); $finish; end
        // every byte the broker takes from it is the byte the mirror holds
        always @(posedge clk) if (rst_n && xm_rvalid && u_xq.skip == 4'd0 && u_xq.pend) begin
            if (xm_rdata !== lexp[23'(u_brk.ml_phys - 24'h020000)])
                begin $display("ERROR: expansion memory gave %02h for %06h, the mirror has %02h", xm_rdata, u_brk.ml_phys, lexp[23'(u_brk.ml_phys - 24'h020000)]); $finish; end
        end
        // at the end of the run: the memory holds what was written to it
        always @(posedge x_check) begin
            int k; k = 0;
            for (int a = 0; a < cfg_exp * 65536; a++) if (u_xmem.mem[24'h020000 + a] !== lexp[a]) k++;
            if (k != 0) err($sformatf("the expansion memory differs from what was written to it in %0d bytes", k));
        end
    end else begin : g_x
        assign {xq_rwait, xq_rsel, xq_wbusy, xq_ovf, xq_req, xq_skip_w} = '0;
        assign xq_rdata = '0;
        assign {xm_req, xm_ready, xm_we, xm_rvalid} = '0;
        assign xm_addr = '0; assign xm_wdata = '0; assign xm_rdata = '0;
    end
    longint n_xrd = 0, n_xwait = 0, n_xrep = 0, n_xrd_nat = 0, n_xbusy = 0, n_resetx = 0, n_xskip = 0;
    logic [23:0] last_real_a = '0;
    bit          last_real_r = 0;
    always @(posedge clk) begin
        if (lm_ren && lm_rexp) n_xrd <= n_xrd + 1;
        if (lm_ren && lm_rexp && u_brk.mode_native) n_xrd_nat <= n_xrd_nat + 1;
        if (xq_rwait) n_xwait <= n_xwait + 1;
        if (xq_wbusy) n_xbusy <= n_xbusy + 1;
        if (xm_rvalid && xq_skip_w) n_xskip <= n_xskip + 1;
    end

    //---------------------------------------------------------------- the card's memories (behavioural)
    logic [7:0] lram [0:(1<<17)-1];              // banks 00/01
    logic [7:0] lrom [0:(1<<18)-1];              // ROM image, FC0000-FFFFFF
    logic [7:0] lexp [0:EXP_MAX*65536-1];        // expansion banks 02.. (EXP_DDR: a mirror of what was written)
    // Synchronous, as the block RAMs will be: a read launch registers the data
    // of BOTH memories as they are at that edge; a write is a separate port.
    // The broker never launches and writes in the same clk (checked).
    wire [23:0] lexp_ridx = lm_raddr - 24'h020000;
    wire [23:0] lexp_widx = lm_waddr - 24'h020000;
    always_ff @(posedge clk) begin
        if (lm_ren) begin
            // the 128 KB RAM and the ROM image each read at their own address; the
            // expansion memory at the physical address.  (The bench returns whichever
            // RAM the physical address names, as a build's data mux will.)
            lm_rom_rdata <= lrom[lm_rom_ra];
            lm_ram_rdata <= (lm_raddr[23:17] == 7'd0) ? lram[lm_ram_ra] : lexp[lexp_ridx[22:0]];
        end
        if (lm_wen) begin
            if (lm_waddr[23:17] == 7'd0) lram[lm_waddr[16:0]] <= lm_wdata;
            else                         lexp[lexp_widx[22:0]] <= lm_wdata;
        end
        if (copy_we) lrom[copy_wa] <= copy_wd;
        far_bad   <= (FAR_CLKS == 2) & lm_ren;
        lm_wen_q1 <= lm_wen; lm_wen_q2 <= lm_wen_q1;
        if (NEAR && lm_ren && (lm_wen_q1 || lm_wen_q2)) begin $display("ERROR: local memory read launched within two clks of a write"); $finish; end
        if (copy_we && lm_ren) begin $display("ERROR: ROM image written in the clk of a read launch"); $finish; end
        if (lm_ren && lm_wen) begin $display("ERROR: local memory read launch and write in the same clk"); $finish; end
        if (lm_ren && (lm_ram_ra_c != {RA_COPIES{lm_ram_ra}} || lm_rom_ra_c != {RA_COPIES{lm_rom_ra}})) begin
            $display("ERROR: the read-address copies differ at a launch"); $finish;
        end
        if (lm_ren_c != {RA_COPIES{lm_ren}} || lm_wen_c != {RA_COPIES{lm_wen}}) begin
            $display("ERROR: the memory enable copies differ"); $finish;
        end
    end

    // The near memory: {tag, byte} entries, one read port and one write port,
    // every entry empty at power-up (and its byte one the memories do not hold: it
    // is never the core's).  A read launched in the clk of a
    // write to the same index is undefined in a block RAM: here it returns the
    // NEW tag with the wrong byte, the worst case for a broker that used it.
    logic [7:0]     nmd [0:(1<<NEAR_AW)-1];
    logic [NTW-1:0] nmt [0:(1<<NEAR_AW)-1];
    longint n_nm_fill = 0, n_nm_wr = 0, n_fast2 = 0, n_loc_other = 0;
    always_ff @(posedge clk) if (cpu_ce && brk_fast) begin
        if (u_brk.fast_q) n_fast2 <= n_fast2 + 1;
        else if (u_brk.st != 2'd3) n_loc_other <= n_loc_other + 1;      // (not a socket step)
    end
    // step lengths in fast mode, by what the step was (statistics): clks from one
    // step of the core to the next.  0 two-clk; other local steps: 1 internal, 2 / 3
    // read below bank 04 (and ROM) / in banks 04-7F, 4 / 5 write likewise; 6 socket
    longint sl_n [0:6], sl_c [0:6], sl_h [0:6][0:8];
    longint t_step = 0;
    initial for (int k = 0; k < 7; k++) begin sl_n[k] = 0; sl_c[k] = 0; for (int j = 0; j < 9; j++) sl_h[k][j] = 0; end
    always_ff @(posedge clk) if (cpu_ce) begin
        t_step <= clk_no;
        if (brk_fast && cpu_rst_n) begin
            int k, len;
            bit hi;
            len = int'(clk_no - t_step);
            hi  = (u_brk.eff_addr[23:16] >= 8'h04) && !u_brk.eff_addr[23];
            k   = u_brk.fast_q ? 0 : (u_brk.st == 2'd3) ? 6 : u_brk.internal ? 1 :
                  u_brk.eff_we ? (hi ? 5 : 4) : (hi ? 3 : 2);
            sl_n[k] <= sl_n[k] + 1;
            sl_c[k] <= sl_c[k] + longint'(len);
            sl_h[k][(len > 9) ? 8 : (len < 2) ? 0 : len - 2] <= sl_h[k][(len > 9) ? 8 : (len < 2) ? 0 : len - 2] + 1;
        end
    end
    task automatic step_lengths();
        static string nm [0:6] = '{"two-clk", "local internal", "local read, banks 00-03 and ROM", "local read, banks 04-7F",
                                   "local write, banks 00-03", "local write, banks 04-7F", "socket"};
        for (int k = 0; k < 7; k++) if (sl_n[k] != 0)
            $display("---- step lengths: %-32s %8d steps, %6.2f clks each; of 2..9 clks and more: %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                     nm[k], sl_n[k], real'(sl_c[k]) / real'(sl_n[k]),
                     sl_h[k][0], sl_h[k][1], sl_h[k][2], sl_h[k][3], sl_h[k][4], sl_h[k][5], sl_h[k][6], sl_h[k][7], sl_h[k][8]);
    endtask
    initial begin
        for (int i = 0; i < (1<<NEAR_AW); i++) begin nmd[i] = 8'hEE; nmt[i] = NM_EMPTY; end
        nm_rdata = 8'h00; nm_rtag = NM_EMPTY;
    end
    always_ff @(posedge clk) begin
        if (nm_ren) begin
            nm_rdata <= (nm_wen && nm_wa == nm_ra) ? ~nm_wdata : nmd[nm_ra];
            if (!NEAR_SPLIT) nm_rtag <= (nm_wen && nm_wa == nm_ra) ? nm_wtag : nmt[nm_ra];
            else begin
                // split tag: {ROM, A12} and A14-A17 now
                logic [NTW-1:0] t;
                t = (nm_wen && nm_wa == nm_ra) ? nm_wtag : nmt[nm_ra];
                nm_rtag[NTW-1:NTW-2] <= t[NTW-1:NTW-2];
                nm_rtag[3:0]         <= t[3:0];
            end
        end
        // ... the high address bits a clk later, at the step's own address (a read in the clk
        // of a write to that entry returns the other value, the worst case)
        if (NEAR_SPLIT && nm_ren_hi) begin
            logic [NTW-1:0] t;
            t = nmt[nm_ra_hi];
            nm_rtag[NEAR_KW-1:4] <= (nm_wen && nm_wa == nm_ra_hi) ? ~t[NEAR_KW-1:4] : t[NEAR_KW-1:4];
        end
        if (nm_ren_hi && !NEAR_SPLIT) begin $display("ERROR: split near-memory read without NEAR_SPLIT"); $finish; end
        if (nm_wen) begin
            nmd[nm_wa] <= nm_wdata;
            nmt[nm_wa] <= nm_wtag;
            if (copy_flush) begin
                if (nm_wtag != NM_EMPTY || nm_wa != copy_fidx) begin $display("ERROR: near memory flush wrote %04h tag %03h", nm_wa, nm_wtag); $finish; end
            end else if (u_brk.nfill_r) n_nm_fill <= n_nm_fill + 1; else n_nm_wr <= n_nm_wr + 1;
        end
        if ((nm_ren || nm_wen) && !NEAR) begin $display("ERROR: near memory used without NEAR"); $finish; end
        if (nm_wen && !copy_flush && u_brk.nfill_r && (lm_wen || clk_no - t_launch < 2)) begin
            $display("ERROR: near memory filled %0d clks after the far launch", clk_no - t_launch); $finish;
        end
    end
    // every entry of the near memory is the byte of the card's memory its tag names
    task automatic near_check();
        int n_bad, n_valid, a12;
        logic [23:0] ph;
        logic [7:0]  want;
        n_bad = 0; n_valid = 0;
        for (int i = 0; i < (1<<NEAR_AW); i++) if (nmt[i] != NM_EMPTY) begin
            n_valid++;
            if (nmt[i][NTW-1] && !(NEAR_SPLIT && nmt[i][NTW-2])) begin
                want = lrom[{nmt[i][3:0], 14'(i)}];
            end else begin
                // (split tag: {1, 1} marks RAM above bank 03, where nothing moves A12)
                a12  = (NEAR_SPLIT && nmt[i][NTW-1]) ? i[12] : i[12] ^ nmt[i][NTW-2];
                ph   = 24'({nmt[i][NEAR_KW-1:0], 14'(i)});
                ph[12] = a12[0];
                want = (ph[23:17] == 7'd0) ? lram[ph[16:0]] : lexp[23'(ph - 24'h020000)];
            end
            if (nmd[i] !== want) begin
                if (n_bad < 4) $display("   near memory entry %04h tag %03h = %02h, the card's memory has %02h", i, nmt[i], nmd[i], want);
                n_bad++;
            end
        end
        if (n_bad != 0) err($sformatf("the near memory differs from the card's memory in %0d of %0d entries", n_bad, n_valid));
        $display("---- near memory: %0d of %0d entries in use, %0d fills, %0d writes; %0d two-clk steps, %0d other local steps (%.1f %% two-clk)",
                 n_valid, 1<<NEAR_AW, n_nm_fill, n_nm_wr, n_fast2, n_loc_other,
                 (n_fast2 + n_loc_other) ? 100.0 * real'(n_fast2) / real'(n_fast2 + n_loc_other) : 0.0);
    endtask

    // The timing contract the build's multicycle constraints will rely on, checked
    // in clks: in fast mode consecutive core steps are at least STEP_CLKS apart
    // (core register -> register paths), and local read data is taken no sooner
    // after its launch than the memory -> core path is allowed (STEP_CLKS with
    // DATA_LATE, STEP_CLKS - ADDR_CLKS in the two-edge step).
    longint clk_no = 0, t_launch = 0, t_nlaunch = 0, t_ce = -100, t_sel = 0, t_sw = -100;
    logic [2:0] sel_q = 3'b000;
    logic       rdy_q = 1'b1;
    logic [7:0] alt_qq = 8'h00;
    longint     t_alt = 0;
    logic [2:0] il_q = 3'b111;
    longint     t_il = 0;
    wire  [2:0] il_now = {cpu_irq_n, cpu_nmi_n, cpu_abort_n};
    wire  [2:0] sel_now = {u_brk.near_r, u_brk.use_lm_r, u_brk.rom_r};
    always_ff @(posedge clk) begin
        clk_no <= clk_no + 1;
        if (lm_ren) t_launch <= clk_no;
        if (nm_ren) t_nlaunch <= clk_no;
        // the data-source select (as the core sees it this clk) and when it last changed
        sel_q <= sel_now;
        if (sel_q != sel_now) t_sel <= clk_no;
        // nothing is registered from the core's outputs before the strobe clk
        // (the two-clk paths of a build with ADDR_CLKS = 2)
        // (near memory: the write is made from registers, in the clk after the decision)
        if ((u_brk.strobe || u_brk.mem_evt || (lm_wen && !NEAR)) && u_brk.run_c && clk_no - t_ce < ADDR_CLKS) begin
            $display("ERROR: step decision %0d clks after the core stepped (ADDR_CLKS %0d)", clk_no - t_ce, ADDR_CLKS); $finish;
        end
        // ... and the registered copy of the decode (a step that was not decoded ahead)
        // is not acted on before it has had SLOW - 1 clks to settle
        if (DATA_LATE && u_brk.run_c && !u_brk.fresh_ok &&
            ((u_brk.strobe && !u_brk.mode_native) || u_brk.mem_evt) && clk_no - t_ce < u_brk.SLOW) begin
            $display("ERROR: registered decode used %0d clks after the core stepped (needs %0d)", clk_no - t_ce, u_brk.SLOW); $finish;
        end
        // ... and the memory-map switches (changed by a socket cycle that touches I/O
        // or $Cxxx) have two clks to reach that registered decode and three to reach
        // a launch (read address, the decode registered with it)
        if (DATA_LATE && u_brk.sw_touch) t_sw <= clk_no;
        if (DATA_LATE && u_brk.run_c && !u_brk.fresh_ok &&
            ((u_brk.strobe && !u_brk.mode_native) || u_brk.mem_evt) && clk_no - t_sw < 3) begin
            $display("ERROR: registered decode used %0d clks after the switches changed (needs 3)", clk_no - t_sw); $finish;
        end
        // (near memory: the first-clk decision is made from the decode itself, one clk after
        // the switches changed at the soonest - ordinary one-clk paths in a build)
        // ... and with RDY high (RDY low at the last PHI2 fall holds local steps)
        rdy_q <= u_brk.rdy_c;
        if (NEAR && u_brk.fast_q && !rdy_q) begin
            $display("ERROR: a local step completed at once, decided while RDY was low"); $finish;
        end
        if (NEAR && u_brk.fast_q && clk_no - t_sw < 2) begin
            $display("ERROR: first-clk decision made in the clk the switches changed"); $finish;
        end
        if (DATA_LATE && ((u_brk.pf_launch && !NEAR) || lm_ren) && clk_no - t_sw < 3) begin
            $display("ERROR: read launched %0d clks after the switches changed (needs 3)", clk_no - t_sw); $finish;
        end
        // near memory: the core's other data source (far data or the socket byte,
        // registered) and the first clk it showed its present value
        alt_qq <= u_brk.alt_q;
        if (alt_qq != u_brk.alt_q) t_alt <= clk_no;
        // near memory: the interrupt lines the core sees (held from step to step in
        // fast mode; in native mode the pads of the PHI2 fall, registered) and the
        // first clk they showed their present value
        il_q <= il_now;
        if (il_q != il_now) t_il <= clk_no;
        if (cpu_ce) begin
            t_ce <= clk_no;
            if (NEAR && u_brk.rd_step && !u_brk.near_r && u_brk.run_c &&
                (alt_qq != u_brk.alt_q || clk_no - t_alt < 1)) begin
                $display("ERROR: the core's data register changed %0d clks before the step (socket %0d)",
                         clk_no - t_alt, !u_brk.use_lm_r); $finish;
            end
            if (NEAR && u_brk.run_c && (il_q != il_now || clk_no - t_il < 1)) begin
                $display("ERROR: the core's interrupt lines changed %0d clks before the step (native %0d)",
                         clk_no - t_il, u_brk.mode_native); $finish;
            end
            if (brk_fast && clk_no - t_ce < STEP_CLKS) begin
                $display("ERROR: fast-mode steps %0d clks apart (STEP_CLKS %0d)", clk_no - t_ce, STEP_CLKS); $finish;
            end
            // (near memory: its own launch; the far memories' data goes through a register)
            if (u_brk.use_lm_r && brk_fast && u_brk.rd_step &&
                (NEAR ? (u_brk.near_r ? clk_no - t_nlaunch < 2 : clk_no - t_launch < STEP_CLKS + 1)
                      : clk_no - t_launch < (DATA_LATE ? STEP_CLKS : STEP_CLKS - ADDR_CLKS))) begin
                $display("ERROR: local read data taken %0d clks after its launch (near %0d: %0d)",
                         clk_no - t_launch, u_brk.near_r, clk_no - t_nlaunch); $finish;
            end
            // data-late: on a step whose data the core uses, the select has been
            // steady for a whole step (t_sel is the first clk it showed its new value)
            if (DATA_LATE && brk_fast && u_brk.rd_step &&
                (sel_q != sel_now || clk_no - t_sel < STEP_CLKS - 1)) begin
                $display("ERROR: data-source select changed %0d clks before the step", clk_no - t_sel); $finish;
            end
        end
    end

    //---------------------------------------------------------------- reference core on the ideal machine
    logic [7:0]  ref_din = 8'h00, ref_dout;
    logic [23:0] ref_a;
    logic        ref_we_n, ref_vp_n, ref_rdy_out, ref_vpa, ref_vda, ref_mlb, ref_iflag;

    P65C816 u_ref (
        .CLK(clk), .RST_N(cpu_rst_n), .CE(cpu_ce), .RDY_IN(1'b1),
        .NMI_N(cpu_nmi_n), .IRQ_N(cpu_irq_n), .ABORT_N(cpu_abort_n),
        .D_IN(ref_din), .D_OUT(ref_dout), .A_OUT(ref_a), .WE(ref_we_n), .RDY_OUT(ref_rdy_out),
        .VPA(ref_vpa), .VDA(ref_vda), .MLB(ref_mlb), .VPB(ref_vp_n), .I_FLAG(ref_iflag)
    );

    //---------------------------------------------------------------- S6 beside it (native modes)
    logic        s6_clk, s6_rst_n, s6_we_n, s6_vp_n, s6_vpa, s6_vda;
    logic [7:0]  s6_dout, s6_d_o;
    logic [23:0] s6_cpu_a;
    logic [15:0] s6_a;
    logic        s6_d_oe, s6_rw, s6_vp, s6_d_dir, s6_data_oe_n, s6_addr_oe_n, s6_ctl_oe_n;

    gs_socket_phy u_s6phy (
        .force_slow_i(1'b0),
        .clk(clk), .rst_n(rst_n), .armed_i(armed), .listen_i(1'b0), .out_extra_i(4'd0),
        .cpu_clk_o(s6_clk), .cpu_rst_n_o(s6_rst_n),
        .cpu_a_i(s6_cpu_a), .cpu_d_out_i(s6_dout), .cpu_we_n_i(s6_we_n), .cpu_vp_n_i(s6_vp_n),
        .cpu_vpa_i(s6_vpa), .cpu_vda_i(s6_vda),
        .gs_ph2_i(gs_ph2_f), .gs_rdy_i(gs_rdy_f), .gs_res_n_i(gs_res_n_f), .gs_be_i(gs_be_f),
        .gs_d_o(s6_d_o), .gs_d_oe_o(s6_d_oe),
        .gs_a_o(s6_a), .gs_rw_o(s6_rw), .gs_vp_o(s6_vp), .gs_rdy_out_o(),
        .gs_d_dir_o(s6_d_dir), .gs_data_oe_n_o(s6_data_oe_n), .gs_addr_oe_n_o(s6_addr_oe_n),
        .gs_ctl_oe_n_o(s6_ctl_oe_n),
        .ph2_alive_o(), .running_o(), .enabled_o(), .be_ok_o(),
        .fall_evt_o(), .issue_evt_o(), .ended_read_o(),
        .cycle_count_o(), .stall_count_o(), .be_count_o()
    );
    P65C816 u_s6cpu (
        .CLK(s6_clk), .RST_N(s6_rst_n), .CE(1'b1), .RDY_IN(gs_rdy_f),
        .NMI_N(gs_nmi_n_f), .IRQ_N(gs_irq_n_f), .ABORT_N(gs_abort_n_f),
        .D_IN(gs_d_i_f), .D_OUT(s6_dout), .A_OUT(s6_cpu_a), .WE(s6_we_n), .RDY_OUT(),
        .VPA(s6_vpa), .VDA(s6_vda), .MLB(), .VPB(s6_vp_n), .I_FLAG()
    );

    //---------------------------------------------------------------- socket nets
    logic ph2_bus;
    logic rdy_bus = 1'b1, irq_n_bus = 1'b1, nmi_n_bus = 1'b1, res_n_bus = 1'b0, abort_n_bus = 1'b1;
    logic be_dma = 1'b1, be_pulse_n = 1'b1;
    wire  be_bus = be_dma & be_pulse_n;

    logic        addr_en;
    logic [15:0] a_bus;
    logic        rw_bus, vp_bus;
    logic        cpu_drv;
    logic [7:0]  cpu_val;
    logic        rx_en;
    assign #(T_XEN)  addr_en = ~gs_addr_oe_n_f;
    assign #(T_XCVR) a_bus   = gs_a_f;
    assign #(T_XCVR) rw_bus  = gs_rw_f;
    assign #(T_XCVR) vp_bus  = gs_vp_f;
    assign #(T_XEN)  cpu_drv = ~gs_data_oe_n_f & gs_d_dir_f & gs_d_oe_f;
    assign #(T_XCVR) cpu_val = gs_d_o_f;
    assign #(T_XEN)  rx_en   = ~gs_data_oe_n_f & ~gs_d_dir_f;

    logic       mem_drv = 1'b0;
    logic [7:0] mem_val = 8'h00;

    logic [7:0] d_bus;
    always_comb d_bus = cpu_drv ? cpu_val : (mem_drv ? mem_val : 8'hFF);

    assign #(T_XCVR) gs_ph2_f     = ph2_bus;
    assign #(T_XCVR) gs_rdy_f     = rdy_bus;
    assign #(T_XCVR) gs_irq_n_f   = irq_n_bus;
    assign #(T_XCVR) gs_nmi_n_f   = nmi_n_bus;
    assign #(T_XCVR) gs_res_n_f   = res_n_bus;
    assign #(T_XCVR) gs_abort_n_f = abort_n_bus;
    assign #(T_XCVR) gs_be_f      = be_bus;
    assign #(T_XCVR) gs_d_i_f = rx_en ? d_bus : (gs_d_oe_f ? gs_d_o_f : 8'h5A);

    //---------------------------------------------------------------- FPI clock (tb_gs_socket.sv)
    bit  noturbo = 0;
    logic slow_mode = 1'b1;     // the machine comes out of reset at 1 MHz
    int  ph2_ctr = 0;
    int  ph0_ctr = 0;
    int  line_ctr = 0;
    int  refresh_ctr = 0;
    bit  cycle_is_refresh = 0;
    bit  fast_stretch = 0;
    bit  this_slow = 0;
    bit  this_rom  = 0;
    longint cyc_no = 0;
    bit  ph0_wrap;

    logic [7:0]  bank_l;
    logic [15:0] addr_l;
    logic        rw_l, vp_l;
    real         t_fall = 0, t_rise = 0, t_prev_fall = 0;

    logic ph2_int = 1'b0;
    assign #(32.0) ph2_bus = ph2_int;
    task automatic be_pulse();
        fork
            begin
                be_pulse_n = 1'b0;
                #(66.0);
                be_pulse_n = 1'b1;
            end
        join_none
    endtask

    always @(posedge tick) begin
        ph0_wrap = (ph0_ctr == ((line_ctr == 64) ? 15 : 13));
        if (ph0_wrap) begin
            ph0_ctr <= 0;
            if (line_ctr == 64) begin
                line_ctr <= 0;
                if (!slow_mode) fast_stretch <= 1'b1;
            end else line_ctr <= line_ctr + 1;
        end else ph0_ctr <= ph0_ctr + 1;

        ph2_ctr <= ph2_ctr + 1;

        if (ph2_ctr == 1) ph2_int <= 1'b1;

        begin
            bit end_now = 0;
            if (slow_mode) begin
                end_now = ph0_wrap && (ph2_ctr >= 4);
            end else if (this_slow && ph2_ctr >= 3) begin
                end_now = ph0_wrap && (ph2_ctr >= 13);
            end else if (cycle_is_refresh) begin
                end_now = (ph2_ctr >= (fast_stretch ? 11 : 9));
            end else begin
                end_now = (ph2_ctr >= (fast_stretch ? 6 : 4));
            end
            if (end_now && ph2_int) begin
                ph2_int <= 1'b0;
                ph2_ctr <= 0;
                be_pulse();
                if (!(this_slow || slow_mode)) fast_stretch <= 1'b0;
                if (this_rom) begin
                    refresh_ctr <= 0; cycle_is_refresh <= 1'b0;
                end else if (this_slow || slow_mode) begin
                    cycle_is_refresh <= 1'b0;
                    refresh_ctr <= (refresh_ctr >= 8) ? 0 : refresh_ctr + 1;
                end else if (refresh_ctr >= 8) begin
                    cycle_is_refresh <= 1'b1; refresh_ctr <= 0;
                end else begin
                    cycle_is_refresh <= 1'b0; refresh_ctr <= refresh_ctr + 1;
                end
            end
        end
    end

    //---------------------------------------------------------------- checkers
    int errors = 0;
    bit trace = 0;
    longint steps = 0;          // core steps (clock enables)
    real    t_run_start = 0, t_run_end = 0;   // reset release, and the step that ends the run
    int     irqs_done = 0;
    real st_max_tads = 0, st_max_tbas = 0, st_min_tah = 1e9, st_min_tbh = 1e9, st_max_tmds = 0, st_min_tdhw = 1e9, st_max_rel = 0;
    bit  bh_pending = 0, dhw_pending = 0;

    task automatic err(input string s);
        errors++;
        $display("[%0t] ERROR cyc=%0d step=%0d: %s", $realtime, cyc_no, steps, s);
        if (errors > 30) begin $display("too many errors"); $display("FAIL: %0d errors", errors); $finish; end
    endtask

    bit          wr_l_valid = 0;
    bit          stall_req = 0;

    // what the broker handed to the PHY for the cycle on the bus
    logic [23:0] iss_a;
    logic [7:0]  iss_d;
    logic        iss_we_n, iss_vp_n;
    logic        iss_hold = 1'b0;         // an idle cycle of a hold: a read the ROM copy asked for
    // (the PHY takes the write data again the clk after the issue: WDATA_LATE)
    logic issue_evt_q = 1'b0;
    always @(posedge clk) begin
        issue_evt_q <= issue_evt;
        if (issue_evt_q) iss_d <= phy_d_out;
    end
    // (the step in progress: a read or a write, not a vector pull, in a Mega II bank,
    // an expansion bank the card does not back, or any other non-ROM bank from $80 up)
    wire [7:0] step_bank = u_brk.ea_r[23:16];
    wire sock_only_step = !u_brk.pl_int && u_brk.pl_vp_n &&
                          (step_bank[7] ? (step_bank < 8'hFE) : (step_bank >= 8'd2 + 8'(cfg_exp)));
    logic   rdy_c_q = 1'b1, last_step_sock = 1'b0, last_iss_idle = 1'b0;
    longint n_ss = 0, n_ss_idle = 0;
    always @(posedge clk) begin
        rdy_c_q <= u_brk.rdy_c;
        if (cpu_ce) last_step_sock <= (u_brk.st == 2'd3) && !u_brk.held_r;
    end
    always @(posedge clk) if (issue_evt) begin
        iss_a <= phy_a; iss_d <= phy_d_out; iss_we_n <= phy_we_n; iss_vp_n <= phy_vp_n;
        iss_hold <= u_brk.held_r && (u_brk.sel == 2'd0);
        if (trace) $display("[%0t]   issue %06h rw%b kind %0d (0 idle, 1 core, 2 posted) core %s", $realtime, phy_a, phy_we_n,
                             u_brk.sel, cpu_rst_n ? "running" : "in reset");
        // the broker substitutes internal I/O cycles itself; the PHY must
        // never be asked to
        if (running && !phy_vpa && !phy_vda && phy_a[15:8] == 8'hC0 &&
            (phy_a[23:17] == 7'd0 || phy_a[23:17] == 7'h70))
            err($sformatf("internal I/O-space cycle handed to the PHY: %06h", phy_a));
        // Near memory, fast mode: a step that is a read or a write in a bank that is
        // never the card's has its request at the PHY by the issue point two clks
        // after the core stepped - no idle cycle goes out in front of it.  (The bank
        // test is the bench's own, not the decode's.)
        if (NEAR && SOCK_PRE && cpu_rst_n && !u_brk.mode_native && !u_brk.held_r && u_brk.st == 2'd1 && u_brk.ph == 4'd1 &&
            u_brk.sel == 2'd0 && !u_brk.fl_busy && u_brk.rdy_c && rdy_c_q && sock_only_step)
            err($sformatf("idle cycle issued in front of a socket-only step at %06h", u_brk.ea_r));
        // statistics: a core cycle issued for a step that follows a socket step
        if (cpu_rst_n && u_brk.sel == 2'd1 && !u_brk.fl_busy && last_step_sock) begin
            n_ss <= n_ss + 1;
            if (last_iss_idle) n_ss_idle <= n_ss_idle + 1;
        end
        if (!u_brk.fl_busy) last_iss_idle <= (u_brk.sel == 2'd0);
    end

    real t_addr_change = -1;
    logic [15:0] a_bus_p; logic rw_bus_p; logic addr_en_p;
    always @(a_bus or rw_bus or addr_en) begin
        if (addr_en && addr_en_p && ((a_bus != a_bus_p) || (rw_bus != rw_bus_p))) begin
            t_addr_change = $realtime;
            if (ph2_bus) err($sformatf("address/RWB changed while PHI2 high (%04h rw=%b)", a_bus, rw_bus));
            else begin
                if ($realtime - t_fall < T_AH) err($sformatf("tAH: address changed %.1f ns after the fall", $realtime - t_fall));
                if (running && ($realtime - t_fall) < st_min_tah) st_min_tah = $realtime - t_fall;
            end
        end
        a_bus_p = a_bus; rw_bus_p = rw_bus; addr_en_p = addr_en;
    end

    real t_cpu_d_change = -1;
    real t_cpu_release = -1;
    logic cpu_drv_p; logic [7:0] cpu_val_p;
    always @(cpu_drv or cpu_val or mem_drv) begin
        if (cpu_drv && mem_drv) err($sformatf("BUS CONTENTION: card and memory both driving D0-7 (%.1f ns after fall, %.1f ns after rise, ph2=%b)", $realtime - t_fall, $realtime - t_rise, ph2_bus));
        if ((cpu_drv != cpu_drv_p) || (cpu_drv && cpu_val != cpu_val_p)) begin
            t_cpu_d_change = $realtime;
            if (cpu_drv_p && !cpu_drv) t_cpu_release = $realtime;
            if (ph2_bus && ($realtime - t_rise) < T_BH && t_rise > t_fall)
                err($sformatf("tBH: bank byte changed/released %.1f ns after the rise", $realtime - t_rise));
            if (!ph2_bus && ($realtime - t_fall) < T_DHW && wr_l_valid)
                err($sformatf("tDHW: write data changed %.1f ns after the fall", $realtime - t_fall));
            if (running) begin
                if (ph2_bus && bh_pending && t_rise > t_fall) begin
                    if (($realtime - t_rise) < st_min_tbh) st_min_tbh = $realtime - t_rise;
                    bh_pending = 0;
                end
                if (!ph2_bus && dhw_pending && wr_l_valid) begin
                    if (($realtime - t_fall) < st_min_tdhw) st_min_tdhw = $realtime - t_fall;
                    dhw_pending = 0;
                end
            end
        end
        cpu_drv_p = cpu_drv; cpu_val_p = cpu_val;
    end

    logic [7:0] exp_rd;
    logic [15:0] prev_addr_l; logic [7:0] prev_bank_l; logic prev_rw_l;
    int   stall_checks = 0, be_checks = 0, sync_cycles = 0, refresh_cycles = 0, vp_fetches = 0;

    // ---- expected socket cycles, in program order (from the reference side)
    typedef struct packed { logic [31:0] step; logic [23:0] a; logic we; logic [7:0] d; } exp_t;
    exp_t   expq [$];
    longint n_real = 0, n_idle = 0, n_sock_wr = 0, n_wlog = 0;
    int     expq_max = 0;
    bit     seen_real = 0;

    // the FPI at the rise: latch bank/address/RWB, classify, start memory
    always @(posedge ph2_bus) begin
        int cls;
        t_rise = $realtime;
        bh_pending = 1;
        bank_l = d_bus; addr_l = a_bus; rw_l = rw_bus; vp_l = vp_bus;
        if (stall_req) bank_l = prev_bank_l;
        if (running && be_dma) begin
            if (!addr_en) err("address shifters not enabled at the rise");
            if (t_addr_change > t_fall && (t_addr_change - t_fall) > T_ADS)
                err($sformatf("tADS: address settled %.1f ns after the fall", t_addr_change - t_fall));
            if (t_addr_change > t_fall && (t_addr_change - t_fall) > st_max_tads) st_max_tads = t_addr_change - t_fall;
            if (addr_l != iss_a[15:0]) err($sformatf("latched address %04h != issued %06h", addr_l, iss_a));
            if (rw_l != iss_we_n) err($sformatf("latched RWB %b != issued %b", rw_l, iss_we_n));
            if (vp_l != iss_vp_n) err($sformatf("VP %b != issued %b", vp_l, iss_vp_n));
            if (!vp_l) vp_fetches++;
            if (!stall_req) begin
                if (!cpu_drv) err("bank byte not driven at the rise");
                if (t_cpu_d_change > t_fall && (t_cpu_d_change - t_fall) > T_BAS)
                    err($sformatf("tBAS: bank byte settled %.1f ns after the fall", t_cpu_d_change - t_fall));
                if (t_cpu_d_change > t_fall && (t_cpu_d_change - t_fall) > st_max_tbas) st_max_tbas = t_cpu_d_change - t_fall;
                if (bank_l != iss_a[23:16]) err($sformatf("latched bank %02h != issued %06h", bank_l, iss_a));
            end
        end
        cls = mach_class(0, {8'd0, bank_l, addr_l}, {31'd0, ~rw_l}, {31'd0, vp_l});
        this_slow = cls[1];
        this_rom  = cls[2];
        if (this_slow && !slow_mode) sync_cycles++;
        if (cycle_is_refresh) refresh_cycles++;
        if (rw_l) begin
            cls = mach_peek(0, {8'd0, bank_l, addr_l}, {31'd0, vp_l});
            exp_rd = cls[7:0];
            #(T_ACC);
            if (ph2_bus) begin
                mem_val = exp_rd;
                mem_drv = 1'b1;
            end
        end
    end

    // the bench's interrupting "device": releases /IRQ shortly after its
    // acknowledge register ($C047) is written
    task automatic irq_release();
        fork
            begin
                #20;
                irq_n_bus = 1'b1;
                irqs_done++;
            end
        join_none
    endtask

    // the fall: the cycle completes (or repeats)
    always @(negedge ph2_bus) begin
        logic [23:0] a24;
        bit          done, in_run;
        t_prev_fall = t_fall;
        t_fall = $realtime;
        cyc_no++;
        a24  = {bank_l, addr_l};
        done = rdy_bus;                     // RDY high at the fall: the cycle completes
        if (!res_n_bus) mach_reset(0);
        // a cycle that ends on the fall where /RES is sampled low is void
        if (running && be_dma && res_n_bus) begin
            if (!rw_l) begin
                if (!cpu_drv) err("write cycle: data not driven at the fall");
                if (t_cpu_d_change > t_rise + T_MDS)
                    err($sformatf("tMDS: write data settled %.1f ns after the rise", t_cpu_d_change - t_rise));
                if (t_cpu_d_change > t_rise && (t_cpu_d_change - t_rise) > st_max_tmds) st_max_tmds = t_cpu_d_change - t_rise;
                dhw_pending = 1;
                if (cpu_val != iss_d) err($sformatf("write data %02h != issued %02h", cpu_val, iss_d));
            end else begin
                if (cpu_drv) err("read cycle: card still driving D0-7 at the fall");
                if (!rx_en) err("read cycle: transceiver not in receive at the fall");
                if (!mem_drv) err("bench: memory not driving at a read fall");
                if (t_cpu_release > t_rise && (t_cpu_release - t_rise) > st_max_rel) st_max_rel = t_cpu_release - t_rise;
            end
            if (done) begin
                // ---- is this the cycle the program is owed, or an idle one?
                in_run = 1;
                if (iss_hold && !hold_cyc_q) n_copy_cur = 0;      // the first cycle of a hold: a new copy
                hold_cyc_q = iss_hold;
                if (iss_hold) begin
                    // the ROM copy: reads of the image's addresses, in order, nothing else
                    // (and while the near memory is emptied afterwards: reads of its first byte again)
                    if (n_copy_cur >= (1 << 17)) begin
                        if (!rw_l || a24 != 24'hFE0000)
                            err($sformatf("held after the copy: socket cycle %s %06h", rw_l ? "R" : "W", a24));
                        n_copy_tail++;
                    end else begin
                        if (!rw_l || a24 != 24'hFE0000 + 24'(n_copy_cur))
                            err($sformatf("held: socket cycle %s %06h is not the next byte of the ROM image (%0d read)", rw_l ? "R" : "W", a24, n_copy_cur));
                        n_copy++;
                        n_copy_cur++;
                    end
                end else if (expq.size() > 0 && expq[0].a == a24 && expq[0].we == ~rw_l &&
                    (rw_l || expq[0].d == cpu_val)) begin
                    in_run = (longint'(expq[0].step) < max_steps);   // owed by a step inside the run
                    void'(expq.pop_front());
                    n_real++;
                    seen_real = 1;
                    last_real_a = a24; last_real_r = rw_l;
                end else if (EXP_DDR && rw_l && last_real_r && a24 == last_real_a && u_brk.mode_native &&
                             a24[23:16] >= 8'h02 && a24[23:16] < 8'h02 + 8'(cfg_exp)) begin
                    // a native step waiting for its byte from the expansion memory: its
                    // socket cycle, a read of that RAM, issued again
                    n_xrep++;
                end else if (rw_l && a24 == PARK) begin
                    n_idle++;
                    if (seen_real && !cfg_toggle && cfg_native)
                        err("idle cycle on the socket in native mode");
                end else if (expq.size() > 0) begin
                    err($sformatf("socket cycle %s %06h %02h is not the next one owed (%s %06h %02h, %0d queued)",
                                  rw_l ? "R" : "W", a24, cpu_val, expq[0].we ? "W" : "R", expq[0].a, expq[0].d, expq.size()));
                end else begin
                    err($sformatf("socket cycle %s %06h %02h that the program never made", rw_l ? "R" : "W", a24, cpu_val));
                end
                // ---- the write stream the machine sees: I/O, Mega II, shadowed ranges, slots
                if (!rw_l) begin
                    int cls, ext;
                    n_sock_wr++;
                    cls = mach_class(0, {8'd0, a24}, 1, {31'd0, vp_l});
                    if (cls[0] || cls[3] || cls[4] || cls[5]) begin
                        if (in_run) begin
                            n_wlog++;
                            if (wlog != 0) $fdisplay(wlog, "%06h %02h", a24, cpu_val);
                        end
                    end else if (brk_fast) begin
                        // fast mode never sends the machine a write to memory the card owns
                        // unless the machine shadows it
                        ext = mach_ext(0, {8'd0, a24}, 1, {31'd0, vp_l}, cfg_cxrom, cfg_exp);
                        if (ext[0] && !ext[1])
                            err($sformatf("fast mode: write %06h %02h on the socket is card memory and not shadowed", a24, cpu_val));
                    end
                    if (a24[15:0] == 16'hC036 && cls[0] && !noturbo) slow_mode = ~cpu_val[7];
                    if (a24[15:0] == 16'hC047 && cls[0] && !irq_n_bus) irq_release();
                end
                mach_commit(0, {8'd0, a24}, {31'd0, ~rw_l}, {24'd0, cpu_val}, {31'd0, vp_l});
            end
            if (trace) $display("[%0t] cyc %0d %s %02h:%04h %s%02h%s%s%s", $realtime, cyc_no,
                                rw_l ? "R" : "W", bank_l, addr_l, rw_l ? "->" : "<-",
                                rw_l ? (mem_drv ? mem_val : 8'hxx) : cpu_val,
                                this_slow ? " sync" : "", cycle_is_refresh ? " refresh" : "",
                                done ? "" : " STALL");
        end
        wr_l_valid = running && !rw_l;
        stall_req = ~rdy_bus;
        prev_addr_l = addr_l; prev_bank_l = bank_l; prev_rw_l = rw_l;
    end

    always @(negedge ph2_bus) begin
        if (mem_drv) begin
            #(T_DHR);
            mem_val = ~mem_val;          // garbage
            #(T_GARB - T_DHR);
            mem_drv = 1'b0;
        end
    end

    always @(posedge ph2_bus) if (running && be_dma && stall_req) begin
        stall_checks++;
        if (addr_l != prev_addr_l || bank_l != prev_bank_l || rw_l != prev_rw_l)
            err($sformatf("stalled cycle did not repeat: %02h:%04h rw%b vs %02h:%04h rw%b", bank_l, addr_l, rw_l, prev_bank_l, prev_addr_l, prev_rw_l));
    end

    //---------------------------------------------------------------- lockstep with the reference
    bit          need_eval = 1;
    bit          ref_reset_done = 0;
    logic [23:0] r_eff_addr, r_prev_addr = 24'd0;
    logic        r_eff_we, r_eff_vp, r_internal;
    longint      hash = 64'hcbf29ce484222325;
    longint      n_cmp = 0, n_local_steps = 0, n_state_checks = 0;
    int          distinct_pcs = 0;
    bit          seen_pc [0:(1<<24)-1];
    logic [23:0] last_pcs [0:15];
    int          last_pcs_i = 0;
    bit          final_req = 0, final_done = 0;

    task automatic check_state_equal(input string why);
        int n;
        n = mach_diff(1, 0, 0);
        n_state_checks++;
        if (n != 0) begin
            int w;
            w = mach_diff_where();
            err($sformatf("%s: the motherboard's Mega II RAM / I/O / switches differ from the ideal machine in %0d places (first %05h: %02h vs %02h)",
                          why, n, w, w < 131072 ? mach_get(0, 1, w) : mach_get(0, 2, w - 131072),
                          w < 131072 ? mach_get(1, 1, w) : mach_get(1, 2, w - 131072)));
        end
    endtask

    // the access the reference core is about to make, what the broker owes
    // the socket for it, and the byte the ideal machine returns
    // end-of-run comparisons, taken between two steps with nothing outstanding
    task automatic final_checks();
        int n_ram, n_exp, n_mb, a, v;
        n_ram = 0; n_exp = 0;
        for (a = 0; a < (1<<17); a++) begin
            v = mach_get(1, 0, a);
            if (lram[a] != v[7:0]) begin
                if (n_ram < 4) $display("   card RAM %05h = %02h, ideal %02h", a, lram[a], v[7:0]);
                n_ram++;
            end
        end
        if (n_ram != 0) err($sformatf("card banks 00/01 differ from the ideal machine in %0d bytes", n_ram));
        if (NEAR) begin near_check(); step_lengths(); end
        for (a = 0; a < cfg_exp * 65536; a++) begin
            v = mach_get(1, 0, 24'h020000 + a);
            if (lexp[a] != v[7:0]) n_exp++;
        end
        if (n_exp != 0 && !(cfg_native && cfg_bypass))
            err($sformatf("card expansion RAM differs from the ideal machine in %0d bytes", n_exp));
        x_check = 1'b1;
        if (cfg_native && !cfg_toggle) begin
            // every write went out: the motherboard's fast RAM is complete too
            n_mb = mach_diff(0, 0, (2 + cfg_mbexp) * 65536);
            if (n_mb != 0) err($sformatf("motherboard fast RAM differs from the ideal machine in %0d bytes", n_mb));
        end
    endtask

    task automatic eval_step();
        int ext, pk;
        bit io_int;
        r_internal = ~ref_vpa & ~ref_vda;
        io_int     = r_internal && ref_a[15:8] == 8'hC0 && (ref_a[23:17] == 7'd0 || ref_a[23:17] == 7'h70);
        r_eff_addr = io_int ? r_prev_addr : ref_a;
        r_eff_we   = io_int ? 1'b0 : ~ref_we_n;
        r_eff_vp   = io_int ? 1'b1 : ref_vp_n;
        ext = mach_ext(1, {8'd0, r_eff_addr}, {31'd0, r_eff_we}, {31'd0, r_eff_vp}, cfg_cxrom, cfg_exp);
        pk  = mach_peek(1, {8'd0, r_eff_addr}, {31'd0, r_eff_vp});
        ref_din = pk[7:0];
        // nothing outstanding: the two machines must agree
        // (the final moment also wants no write of the card's memory in flight: with the
        // near memory the write of the step that just completed is made in this clk)
        if (expq.size() == 0 && (steps[7:0] == 8'd0 || (final_req && !final_done && !lm_wen && !xq_req))) begin
            check_state_equal("no socket cycle outstanding");
            if (final_req) begin final_checks(); final_done = 1; end
        end
        if (u_brk.mode_native) begin
            expq.push_back('{step: steps[31:0], a: r_eff_addr, we: r_eff_we, d: ref_dout});
        end else if (r_internal) begin
            if (ext[2]) expq.push_back('{step: steps[31:0], a: r_eff_addr, we: 1'b0, d: 8'h00});
        end else if (!ext[0]) begin
            expq.push_back('{step: steps[31:0], a: r_eff_addr, we: r_eff_we, d: ref_dout});
        end else begin
            n_local_steps++;
            if (ext[1]) expq.push_back('{step: steps[31:0], a: r_eff_addr, we: 1'b1, d: ref_dout});
        end
        if (expq.size() > expq_max) expq_max = expq.size();
    endtask

    // steps the core spent waiting in WAI (it does not take them)
    int n_wai = 0;
    always @(posedge clk) if (cpu_rst_n && cpu_ce && !cpu_rdy_out) n_wai++;

    // the local write of the step in progress, until the step completes
    logic        wr_pend = 1'b0;
    logic [23:0] wr_pa;
    logic [7:0]  wr_pd;
    always_ff @(posedge clk) begin
        if (cpu_ce || !cpu_rst_n) wr_pend <= 1'b0;
        // (near memory: the write is registered at the decision and made a clk later; a
        // step that completes at its decision is not "in progress" when it lands)
        else if (NEAR ? u_brk.wen_set : lm_wen) begin
            wr_pend <= 1'b1; wr_pa <= u_brk.eff_addr; wr_pd <= NEAR ? cpu_d_out : lm_wdata;
        end
    end

    always @(posedge clk) begin
        if (!cpu_rst_n) begin
            if (!ref_reset_done) begin
                // A posted write still in the broker's buffer when /RES falls is
                // dropped (the PHY cannot write during reset): at most one byte of
                // a shadowed page.  Count it and keep the two models comparable.
                int nd, e;
                nd = 0;
                for (int i = 0; i < expq.size(); i++)
                    if (expq[i].we && expq[i].step < steps[31:0]) begin
                        e = mach_ext(1, {8'd0, expq[i].a}, 1, 1, cfg_cxrom, cfg_exp);
                        if (e[0]) nd++;
                    end
                if (nd > 1) err($sformatf("%0d posted writes outstanding at reset", nd));
                if (nd == 1) begin n_dropped++; mach_sync_slow(); end
                // A step that had already written the card's memory when /RES cut it
                // short: the byte stays written (the same as the reset arriving a
                // step later).  Give the ideal machine the same write.
                if (wr_pend) begin
                    // (fast mode only: a native-mode write reaches the card's copy when
                    // its socket cycle completes, so the two cannot come apart)
                    if (u_brk.mode_native) err($sformatf("native-mode write at %06h reached the card's RAM, its socket cycle cut short by /RES", wr_pa));
                    mach_commit(1, {8'd0, wr_pa}, 1, {24'd0, wr_pd}, 1);
                    mach_sync_slow();       // (if it was a forwarded write, its socket half was dropped)
                    n_kept++;
                end
                mach_reset(1);
                ref_reset_done = 1;
            end
            expq.delete();
            need_eval = 1;
        end else begin
            ref_reset_done = 0;
            if (cpu_ce) begin
                n_cmp++;
                if (cpu_a != ref_a || cpu_we_n != ref_we_n || cpu_vp_n != ref_vp_n ||
                    cpu_vpa != ref_vpa || cpu_vda != ref_vda || (!cpu_we_n && cpu_d_out != ref_dout))
                    err($sformatf("DIVERGENCE from the reference core: dut %06h rw%b vp%b va%b%b d%02h  ref %06h rw%b vp%b va%b%b d%02h",
                                  cpu_a, cpu_we_n, cpu_vp_n, cpu_vpa, cpu_vda, cpu_d_out,
                                  ref_a, ref_we_n, ref_vp_n, ref_vpa, ref_vda, ref_dout));
                if (ref_we_n && !r_internal && cpu_d_in != ref_din)
                    err($sformatf("read data at %06h: the broker delivered %02h, the ideal machine holds %02h (%s)",
                                  r_eff_addr, cpu_d_in, ref_din, u_brk.use_lm_r ? "card memory" : "socket"));
                mach_commit(1, {8'd0, r_eff_addr}, {31'd0, r_eff_we}, {24'd0, ref_dout}, {31'd0, r_eff_vp});
                r_prev_addr = r_eff_addr;
                // every step of the run folded into one number: runs in
                // different modes must agree (the run is the first max_steps steps)
                if (steps < max_steps) begin
                    hash = (hash ^ {31'd0, ref_we_n, ref_vpa, ref_vda, ref_vp_n, ref_we_n ? ref_din : ref_dout, ref_a}) * 64'h100000001b3;
                    if (ref_vpa && ref_vda && ref_we_n) begin
                        if (!seen_pc[ref_a]) begin seen_pc[ref_a] = 1; distinct_pcs++; end
                        last_pcs[last_pcs_i] = ref_a; last_pcs_i = (last_pcs_i + 1) % 16;
                    end
                end
                steps++;
                if (steps == max_steps) t_run_end = $realtime;
                need_eval = 1;
            end
        end
    end
    always @(negedge clk) if (cpu_rst_n && need_eval) begin
        eval_step();
        need_eval = 0;
    end

    // verify mode must stay silent - as long as fast mode has never run: after
    // that the motherboard copy of banks 00/01 is stale by design (only shadowed
    // writes are forwarded), and a mismatch says nothing
    always @(posedge clk) if (verify_miss && !cfg_toggle)
        err($sformatf("verify: card memory and socket disagree at %06h", verify_addr));

    // ---- S6 beside the design: every pin, every clk (native modes)
    longint n_s6cmp = 0;
    always @(negedge clk) if (s6cmp && rst_n) begin
        n_s6cmp++;
        if (gs_a_f !== s6_a || gs_rw_f !== s6_rw || gs_vp_f !== s6_vp || gs_d_o_f !== s6_d_o ||
            gs_d_oe_f !== s6_d_oe || gs_d_dir_f !== s6_d_dir || gs_data_oe_n_f !== s6_data_oe_n ||
            gs_addr_oe_n_f !== s6_addr_oe_n || gs_ctl_oe_n_f !== s6_ctl_oe_n)
            err($sformatf("pins differ from S6: A %04h/%04h RW %b/%b VP %b/%b D %02h/%02h oe %b/%b dir %b/%b doe_n %b/%b aoe_n %b/%b",
                          gs_a_f, s6_a, gs_rw_f, s6_rw, gs_vp_f, s6_vp, gs_d_o_f, s6_d_o, gs_d_oe_f, s6_d_oe,
                          gs_d_dir_f, s6_d_dir, gs_data_oe_n_f, s6_data_oe_n, gs_addr_oe_n_f, s6_addr_oe_n));
    end

    //---------------------------------------------------------------- gs_accel beside the design
    // (ACCEL_SHADOW, near-memory builds) The accelerator domain as the board build has
    // it - one module, block-RAM-shaped memories, its own ROM copy - on the same socket
    // inputs and the same requests.  Every output pin must equal the hand-wired design's
    // in every clk.  Its expansion memory is a build parameter (ACC_EXP banks): it is
    // compared in the runs whose +exp is that.
    logic [7:0] rom_ref [0:(1<<17)-1];
    bit         rom_loaded = 0;
`ifdef ACCEL_SHADOW
    logic [7:0]  acc_d_o;
    logic        acc_d_oe, acc_rw, acc_vp, acc_rdy_out, acc_d_dir, acc_data_oe_n, acc_addr_oe_n, acc_ctl_oe_n;
    logic [15:0] acc_a;
    logic [7:0]  acc_status, acc_mode;
    logic [15:0] acc_verify;
    longint      n_acc_cmp = 0;
    logic        am_req, am_ready, am_we, am_rvalid;
    logic [22:0] am_addr;
    logic [7:0]  am_wdata, am_rdata;
    if (EXP_DDR) begin : g_am
        gs_exp_mem_sim #(.AW(23)) u_amem (
            .clk(clk), .rst_n(rst_n), .m_req_i(am_req), .m_ready_o(am_ready), .m_we_i(am_we), .m_addr_i(am_addr),
            .m_wdata_i(am_wdata), .m_rvalid_o(am_rvalid), .m_rdata_o(am_rdata)
        );
        initial begin #100; if (cfg_exp >= 126) u_amem.mem[TOP_A[22:0]] = TOP_D; end
    end else begin : g_noam
        assign {am_ready, am_rvalid} = '0; assign am_rdata = '0;
    end
    gs_accel #(.NEAR_KW(NEAR_KW), .EXP_BANKS(ACC_EXP), .EXP_DDR(EXP_DDR), .NEAR_SPLIT(NEAR_SPLIT), .SIM_ROM_VALID(ROM_PRESET)) u_acc (
        .exp_ready_i(1'b1), .m_req_o(am_req), .m_ready_i(am_ready), .m_we_o(am_we), .m_addr_o(am_addr),
        .m_wdata_o(am_wdata), .m_rvalid_i(am_rvalid), .m_rdata_i(am_rdata),
        .clk(clk), .rst_n(rst_n),
        .arm_i(armed), .listen_i(1'b0), .out_extra_i(4'd0),
        .cfg_fast_i(cfg_copy | ~native_i), .cfg_cardmem_i(cfg_copy | ~mem_bypass_i),
        .cfg_cxrom_i(cfg_cxrom[0]), .cfg_copy_i(copy_req), .clear_i(1'b0),
        .gs_ph2_i(gs_ph2_f), .gs_rdy_i(gs_rdy_f), .gs_irq_n_i(gs_irq_n_f), .gs_nmi_n_i(gs_nmi_n_f),
        .gs_res_n_i(gs_res_n_f), .gs_abort_n_i(gs_abort_n_f), .gs_be_i(gs_be_f), .gs_d_i(gs_d_i_f),
        .gs_d_o(acc_d_o), .gs_d_oe_o(acc_d_oe), .gs_a_o(acc_a), .gs_rw_o(acc_rw), .gs_vp_o(acc_vp),
        .gs_rdy_out_o(acc_rdy_out), .gs_d_dir_o(acc_d_dir), .gs_data_oe_n_o(acc_data_oe_n),
        .gs_addr_oe_n_o(acc_addr_oe_n), .gs_ctl_oe_n_o(acc_ctl_oe_n),
        .status_o(acc_status), .mode_o(acc_mode), .cycle_count_o(), .stall_count_o(), .be_count_o(),
        .ph2_period_o(), .ph2_high_o(), .last_addr_o(), .verify_count_o(acc_verify),
        .tele_idx_i(6'd0), .tele_word_o()
    );
    // the bench's ROM image into its block-shaped ROM memory
    for (genvar b = 0; b < 8; b++) begin : g_accb
        for (genvar k = 0; k < 8; k++) begin : g_acck
            initial begin
                wait (rom_loaded);
                #1;
                if (ROM_PRESET) for (int i = 0; i < 16384; i++) u_acc.g_bit[b].g_rblk[k].mrom[i] = rom_ref[k * 16384 + i][b];
            end
        end
    end
    always @(negedge clk) if (rst_n && cfg_exp == ACC_EXP && !wb_en) begin
        n_acc_cmp++;
        if (native_i == 1'b0 && mem_bypass_i == 1'b1 && !cfg_copy) begin
            $display("ERROR: bench: fast with bypass is not a request gs_accel has"); $finish;
        end
        if (gs_a_f !== acc_a || gs_rw_f !== acc_rw || gs_vp_f !== acc_vp || gs_d_o_f !== acc_d_o ||
            gs_d_oe_f !== acc_d_oe || gs_d_dir_f !== acc_d_dir || gs_data_oe_n_f !== acc_data_oe_n ||
            gs_addr_oe_n_f !== acc_addr_oe_n || gs_ctl_oe_n_f !== acc_ctl_oe_n || gs_rdy_out_f !== acc_rdy_out)
            err($sformatf("pins differ from gs_accel: A %04h/%04h RW %b/%b VP %b/%b D %02h/%02h oe %b/%b dir %b/%b doe_n %b/%b aoe_n %b/%b",
                          gs_a_f, acc_a, gs_rw_f, acc_rw, gs_vp_f, acc_vp, gs_d_o_f, acc_d_o, gs_d_oe_f, acc_d_oe,
                          gs_d_dir_f, acc_d_dir, gs_data_oe_n_f, acc_data_oe_n, gs_addr_oe_n_f, acc_addr_oe_n));
    end
`endif

    //---------------------------------------------------------------- stimulus
    task automatic wait_cycles(input int n);
        repeat (n) @(negedge ph2_bus);
    endtask

    task automatic stall_one();
        @(posedge ph2_bus); #20; rdy_bus = 1'b0;
        @(posedge ph2_bus); #20; rdy_bus = 1'b1;
    endtask

    // expected test-program results ($0300...): -1 = depends on the configuration
    int expect_tab [0:85] = '{
        'hFF, 'h00, 'h5C, 'h3F, 'h11, 'hC3, 'h3C, 'hA5, 'hA6, 'hA7,
        'h77, 'h5A, 'h5A, 'h00, 'h30, 'hEE, 'h00, 'h11, 'h00, 'hB1,
        'hB1, 'hB1, 'h00, 'hB2, 'h00, 'hB3, 'hC8, 'h00, 'hC9, 'hD1,
        'hE2, 'hD2, 'hD2, 'hD0, 'hD3, 'hD4, 'h00, 'h00, 'h0C, 'hD1,
        'h5E, 'hE1, 'hE2, 'hE1, -1,   -1,   'hFF, 'h05, 'hC3, 'hC1,
        'hC3, 'hC8, 'hCF, 'hFF, 'hC4, 'hC8, 'hFF, 'hC5, 'h1C, 'h1C,
        'h1C, 'h08, 'hA1, 'hA7, 'h28, 'h01, 'hA7, 'hA5, 'h5A, 'h5A,
        'h00, 'h22, 'h11, 'hE1, -1,   'hE1, 'hE2, 'h01, 'h36, 'h13, -1, 'h00, -1, -1, -1, -1 };

    initial begin
        string  rom_path, wpath;
        int     kind, i;
        longint next_stall, next_toggle, irq_at;
        bit     be_done, reset_done;
        int     lfsr;

        if ($test$plusargs("trace")) trace = 1;
        if ($test$plusargs("noturbo")) noturbo = 1;
        if ($test$plusargs("irq")) do_irq = 1;
        if ($test$plusargs("nostall")) do_stall = 0;
        void'($value$plusargs("stallp=%d", stall_period));
        if ($test$plusargs("wbforce")) wb_en = 1;
        if ($test$plusargs("nobe")) do_be = 0;
        if ($test$plusargs("expect")) do_expect = 1;
        if ($test$plusargs("reset")) do_reset = 1;
        if ($test$plusargs("resetw")) begin do_reset = 1; do_resetw = 1; end
        if ($test$plusargs("resetpw")) begin do_reset = 1; do_resetpw = 1; end
        if ($test$plusargs("resetx")) begin do_reset = 1; do_resetx = 1; end
        if ($test$plusargs("recopy")) begin do_recopy = 1; n_copies_want = 2; end
        void'($value$plusargs("recopyat=%d", recopy_at));
        void'($value$plusargs("mode=%s", mode_s));
        void'($value$plusargs("steps=%d", max_steps));
        void'($value$plusargs("exp=%d", cfg_exp));
        cfg_mbexp = cfg_exp;
        void'($value$plusargs("mbexp=%d", cfg_mbexp));
        void'($value$plusargs("cxrom=%d", cfg_cxrom));
        if ($test$plusargs("vcd")) begin $dumpfile("gs_broker.vcd"); $dumpvars(0, tb_gs_broker); end
        if ($value$plusargs("wlog=%s", wpath)) begin
            wlog = $fopen(wpath, "w");
            if (wlog == 0) begin $display("cannot open %s", wpath); $finish; end
        end
        case (mode_s)
            "native": begin cfg_native = 1; cfg_bypass = 1; s6cmp = 1; end
            // (EXP_DDR: a paced step may have its socket cycle issued again while its byte
            // comes from the expansion memory - S6 does not, so the pins are not S6's)
            "paced":  begin cfg_native = 1; cfg_bypass = 0; s6cmp = !EXP_DDR; end
            "fast":   begin cfg_native = 0; cfg_bypass = 0; end
            "toggle": begin cfg_native = 0; cfg_bypass = 0; cfg_toggle = 1; end
            "copy":   begin cfg_native = 0; cfg_bypass = 0; cfg_copy = 1; end
            default:  begin $display("unknown +mode=%s", mode_s); $finish; end
        endcase
        if (cfg_copy == ROM_PRESET) begin
            $display("+mode=%s needs a build with ROM_PRESET = %0d", mode_s, !cfg_copy); $finish;
        end
        if (cfg_exp > EXP_MAX || cfg_exp > cfg_mbexp) begin
            $display("+exp=%0d: at most %0d, and not more than +mbexp", cfg_exp, EXP_MAX); $finish;
        end
        if (!$value$plusargs("rom=%s", rom_path)) begin $display("+rom=<128 KB image> is required"); $finish; end
        kind = mach_load_rom(rom_path);
        if (kind != 1) begin $display("cannot load %s as a 128 KB ROM image", rom_path); $finish; end
        begin
            int fd, n;
            logic [7:0] buf8 [0:(1<<17)-1];
            fd = $fopen(rom_path, "rb");
            n = $fread(buf8, fd);
            $fclose(fd);
            for (i = 0; i < (1<<17); i++) begin
                rom_ref[i] = buf8[i];
                lrom[(1<<17) + i] = ROM_PRESET ? buf8[i] : 8'h00;           // banks FE/FF
            end
        end
        rom_loaded = 1;
        for (i = 0; i < (1<<17); i++) lram[i] = 8'h00;
        for (i = 0; i < EXP_MAX*65536; i++) lexp[i] = 8'h00;
        mach_config(2 + cfg_mbexp);
        native_i = cfg_native; mem_bypass_i = cfg_bypass;
        $display("---- gs_broker: mode %s, STEP_CLKS %0d at %.1f MHz (%.2f MHz steps), ADDR_CLKS %0d, core %s, card expansion %0d banks (machine %0d), cxrom_local %0d",
                 mode_s, STEP_CLKS, 1000.0 / TCLK, 1000.0 / TCLK / STEP_CLKS, ADDR_CLKS,
`ifdef FAST_CORE
                 "F65C816",
`else
                 "P65C816",
`endif
                 cfg_exp, cfg_mbexp, cfg_cxrom);

        cpu_drv_p = 0; cpu_val_p = 0; a_bus_p = 0; rw_bus_p = 1; addr_en_p = 0;

        if (cfg_mbexp >= 126) begin
            mach_poke({8'd0, TOP_A}, {24'd0, TOP_D});
            if (cfg_exp >= 126) lexp[23'(TOP_A - 24'h020000)] = TOP_D;
        end

        #200 rst_n = 1'b1;
        wait_cycles(20);
        if (addr_en || cpu_drv) err("unarmed card is driving the socket");
        armed = 1'b1;
        wait_cycles(10);
        if (!ph2_alive) err("PH2 not detected alive");
        if (cpu_drv) err("card drove data while /RES low");
        @(posedge ph2_bus); #30; res_n_bus = 1'b1;
        t_run_start = $realtime;

        next_stall = cyc_no + stall_period; next_toggle = cyc_no + 97; irq_at = 0; be_done = 0; reset_done = 0;
        lfsr = 32'h1ACE5;
        while (steps < max_steps) begin
            wait_cycles(1);
            if (do_stall && cyc_no >= next_stall) begin stall_one(); next_stall = cyc_no + stall_period; end
            if (do_be && !be_done && steps > max_steps / 3) begin
                be_done = 1;
                @(posedge ph2_bus); #20; rdy_bus = 1'b0; be_dma = 1'b0;
                #(T_BVD); be_checks++;
                if (addr_en) err("BE low: address shifters still enabled after tBVD");
                if (cpu_drv) err("BE low: data still driven after tBVD");
                wait_cycles(5);
                @(posedge ph2_bus); #20; be_dma = 1'b1; rdy_bus = 1'b1;
            end
            if (do_reset && !reset_done && steps > max_steps / 2 && irq_n_bus && (!do_irq || irqs_done >= 2)) begin
                reset_done = 1;
                if (do_resetw) begin
                    // +resetw: /RES falls in the middle of a write cycle on the socket
                    int g;
                    g = 0;
                    do begin @(posedge ph2_bus); g++; end while (rw_bus && g < 4000);
                    if (rw_bus) err("+resetw: no write cycle on the socket to drop the reset on");
                end else if (do_resetpw) begin
                    // +resetpw: /RES falls in the socket cycle BEFORE a native-mode write
                    // (the write step is then decided, and cut short before its cycle);
                    // needs the F65C816's next-step status
                    int g;
                    g = 0;
                    do begin @(posedge ph2_bus); g++; end
                    while (!(u_brk.mode_native && cpu_nst[1:0] == 2'b00) && g < 200000);
                    if (!(u_brk.mode_native && cpu_nst[1:0] == 2'b00)) err("+resetpw: no native step before a write found");
                end else if (do_resetx) begin
                    // +resetx (EXP_DDR): /RES falls while a step waits for its byte from the
                    // expansion memory - the byte still comes back, to nobody
                    int g;
                    g = 0;
                    // (in fast mode, where the loop's reads of the expansion bank miss the near
                    // memory: a toggling run stays fast until the reset has been dropped)
                    if (cfg_toggle) native_i = 1'b0;
                    do begin @(posedge clk); g++; end while (!xq_rwait && g < 4000000);
                    if (!xq_rwait) err("+resetx: no read of the expansion memory to drop the reset on");
                    n_resetx++;
                end else begin
                    @(posedge ph2_bus);
                end
                #30; res_n_bus = 1'b0;
                wait_cycles(12);
                if (cpu_drv && !rw_bus) err("card writing while /RES low");
                @(posedge ph2_bus); #30; res_n_bus = 1'b1;
                if (cfg_native && !cfg_toggle) begin
                    // native: release with RDY low across the first falls - the first
                    // cycle after reset must wait for it exactly as S6 does.  (Not in
                    // fast mode: this bench's FPI keeps the bank byte of the last
                    // completed cycle while RDY is low, so the first idle cycle would
                    // be classified with the reset-time bank instead of the park bank.)
                    rdy_bus = 1'b0;
                    wait_cycles(4);
                    @(posedge ph2_bus); #20; rdy_bus = 1'b1;
                end else if (next_stall < cyc_no + 8) begin
                    // ... so keep the periodic stall clear of the release too
                    next_stall = cyc_no + 8;
                end
                irqs_done = 0; irq_at = 0;          // the program starts over: interrupt it twice again
            end
            // +mode=copy: ask for the ROM image a little way into the program
            if (cfg_copy && !copy_req && steps > 3000 && !recopy_done) copy_req = 1'b1;
            // +recopy: and once more from fast mode, with idle cycles on the socket
            if (cfg_copy && do_recopy && !recopy_done && copy_valid && steps > recopy_at) begin
                recopy_done = 1;
                copy_req = 1'b0;
                wait_cycles(2);
                // (in the middle of a PHI2 cycle: an idle cycle that is not the copy's is on the bus)
                @(posedge ph2_bus); #50;
                copy_req = 1'b1;
            end
            if (cfg_toggle && cyc_no >= next_toggle) begin
                lfsr = (lfsr >> 1) ^ ((lfsr & 1) != 0 ? 32'h80200003 : 0);
                native_i = ~native_i;
                // native stretches are short (they are slow), fast ones longer
                next_toggle = cyc_no + (native_i ? 20 + (lfsr & 63) : 40 + (lfsr & 255));
            end
            if (do_irq && irq_n_bus && irqs_done < 2 && mach_get(1, 0, 24'h00037F) == 8'hA5) begin
                if (irq_at == 0) irq_at = cyc_no + 150;
                if (cyc_no >= irq_at) begin
                    @(posedge ph2_bus); #20; irq_n_bus = 1'b0;
                    irq_at = cyc_no + 600;
                end
            end
        end

        // ---- wind down: wait for a moment with nothing outstanding
        final_req = 1;
        i = 0;
        while (!final_done && i < 2000) begin @(posedge clk); i++; end
        if (!final_done) err("no quiet moment at the end of the run (socket cycles still outstanding)");

        if (do_expect) begin
            for (i = 0; i <= 85; i++) begin
                int want, got;
                want = expect_tab[i];
                if (i == 44) want = (cfg_mbexp >= 1) ? 'h21 : 'hFF;
                if (i == 45) want = (cfg_mbexp >= 2) ? 'h22 : 'hFF;
                if (i == 46) want = (cfg_mbexp >= 63) ? 'h00 : 'hFF;      // (bank 40)
                if (i == 80) want = (cfg_mbexp >= 1) ? 'h5A : 'h00;
                if (i == 82) want = (cfg_mbexp >= 1) ? 'h34 : 'h00;
                if (i == 83) want = (cfg_mbexp >= 3) ? 'h11 : 'h00;
                if (i == 84) want = (cfg_mbexp >= 7) ? 'hC3 : 'h00;
                if (i == 85) want = (cfg_mbexp >= 126) ? 'h7E : 'h00;
                got = mach_get(1, 0, 24'h000300 + i);
                if (want >= 0 && got != want) err($sformatf("test program result %0d ($%04h) = %02h, want %02h", i, 16'h0300 + i, got, want));
            end
            if (mach_get(1, 0, 24'h00037F) != 8'hA5) err("test program did not reach its loop (signature missing)");
            if (mach_get(1, 0, 24'h000390) == 8'h00 && mach_get(1, 0, 24'h000391) == 8'h00) err("test program loop not running");
            if (mach_get(1, 0, 24'h000381) != 8'h01) err("BRK handler did not run exactly once");
            if (do_irq && mach_get(1, 0, 24'h000380) != 8'h02)
                err($sformatf("IRQ handler ran %0d times, want 2", mach_get(1, 0, 24'h000380)));
            // the loop waits in WAI between the two interrupts: about 300 PHI2 cycles
            if (do_irq && (mach_get(1, 0, 24'h000382) != 8'h01 || n_wai < 100))
                err($sformatf("WAI: flag %02h, %0d steps waited (want 01, at least 100)", mach_get(1, 0, 24'h000382), n_wai));
            if (!cfg_native || cfg_toggle) begin
                if (stat_posted == 0) err("no posted write happened");
                // (+mode=copy runs the part of the program that forwards back to back in native mode, before the copy)
                if (stat_pwwait == 0 && !cfg_copy) err("the posted-write buffer was never full (back-to-back forwarding not exercised)");
                if (n_idle == 0) err("no idle cycle seen in fast mode");
            end
        end
        if (do_reset && !reset_done) err("the warm reset never happened");
        if (do_resetx && n_xskip == 0) err("+resetx: no byte of the expansion memory came back to a step that was gone");
        if (cfg_copy) begin
            int n_bad;
            n_bad = 0;
            for (i = 0; i < (1<<17); i++) if (lrom[(1<<17) + i] !== rom_ref[i]) n_bad++;
            if (!copy_valid || copy_busy || copy_copies != 8'(n_copies_want)) err($sformatf("ROM copy: valid %b busy %b copies %0d", copy_valid, copy_busy, copy_copies));
            if (n_bad != 0) err($sformatf("ROM copy: %0d bytes of the image differ from the machine's ROM", n_bad));
            if (n_copy != n_copies_want * (1 << 17)) err($sformatf("ROM copy: %0d socket reads, want %0d", n_copy, n_copies_want * (1 << 17)));
            if (!brk_fast) err("ROM copy: the design did not go on in fast mode");
            $display("---- ROM copy: %0d bytes through the socket, sum %04h, image identical to the machine's ROM: %s",
                     n_copy, copy_sum, n_bad == 0 ? "yes" : "NO");
        end
        if (verify_count != 0 && !cfg_toggle) err($sformatf("verify count %0d", verify_count));
        if (stall_checks == 0 && do_stall) err("no stalled cycle was checked");
        if (s6cmp && n_s6cmp == 0) err("S6 comparison did not run");
`ifdef ACCEL_SHADOW
        if (cfg_exp == ACC_EXP && !wb_en) begin
            if (n_acc_cmp == 0) err("gs_accel comparison did not run");
            if (acc_verify != verify_count) err($sformatf("gs_accel verify count %0d, the design's %0d", acc_verify, verify_count));
            if (acc_mode[7] != copy_valid || acc_mode[4] != brk_fast)
                err($sformatf("gs_accel mode %02h: ROM image valid %b, fast %b in the design", acc_mode, copy_valid, brk_fast));
            $display("---- gs_accel beside the design: %0d clks of pin comparison, mode %02h", n_acc_cmp, acc_mode);
        end
`endif
        if (wlog != 0) $fclose(wlog);

        $display("---- run: %0d core steps, %0d socket cycles (%0d for the program, %0d idle), %0d local steps; %.2f steps per PHI2 cycle",
                 steps, cyc_no, n_real, n_idle, n_local_steps, real'(steps) / real'(cyc_no));
        $display("---- time: %.3f ms from the reset release to step %0d: %.3f MHz average step rate",
                 (t_run_end - t_run_start) / 1.0e6, max_steps, real'(max_steps) * 1000.0 / (t_run_end - t_run_start));
        $display("---- socket steps behind a socket step: %0d, %0d of them behind an idle cycle", n_ss, n_ss_idle);
        if (EXP_DDR) $display("---- expansion memory: %0d reads behind the queue (%0d by native steps), %0d clks waited (%.1f per read), %0d native cycles issued again, %0d clks with the queue nearly full", n_xrd, n_xrd_nat, n_xwait,
                              n_xrd ? real'(n_xwait) / real'(n_xrd) : 0.0, n_xrep, n_xbusy);
        $display("---- broker: %0d synchronous socket cycles, %0d posted writes, %0d clks waiting for the write buffer, queue depth max %0d",
                 stat_sock, stat_posted, stat_pwwait, expq_max);
        $display("---- local reads: %0d served by a read launched ahead, %0d launched at the strobe (%.1f %% ahead); DATA_LATE %0d",
                 stat_rd_hit, stat_rd_miss,
                 (stat_rd_hit + stat_rd_miss) ? 100.0 * real'(stat_rd_hit) / real'(stat_rd_hit + stat_rd_miss) : 0.0, DATA_LATE);
        $display("---- socket: %0d stalls checked, %0d sync, %0d refresh, %0d VP fetches, %0d BE checks; FPI %s",
                 stall_checks, sync_cycles, refresh_cycles, vp_fetches, be_checks, slow_mode ? "slow" : "fast");
        $display("---- machine: %0d writes on the socket, %0d in the write stream (I/O, Mega II, shadowed, slots); model: %0d I/O writes, %0d shadow copies, %0d language-card accesses, %0d $C028",
                 n_sock_wr, n_wlog, mach_stat(0, 0), mach_stat(0, 1), mach_stat(0, 2), mach_stat(0, 3));
        $display("---- checks: %0d steps compared with the reference, %0d machine-state comparisons, %0d clks of S6 pin comparison, %0d posted writes dropped and %0d local writes kept by a reset",
                 n_cmp, n_state_checks, n_s6cmp, n_dropped, n_kept);
        $display("---- socket timing (ns): tADS max %.1f  tBAS max %.1f  tAH min %.1f  tBH min %.1f  tMDS max %.1f  tDHW min %.1f  read release after rise max %.1f",
                 st_max_tads, st_max_tbas, st_min_tah, st_min_tbh, st_max_tmds, st_min_tdhw, st_max_rel);
        $display("---- point reached: step hash %016h, %0d distinct opcode addresses, last %06h %06h %06h %06h",
                 hash, distinct_pcs, last_pcs[(last_pcs_i+12)%16], last_pcs[(last_pcs_i+13)%16],
                 last_pcs[(last_pcs_i+14)%16], last_pcs[(last_pcs_i+15)%16]);
        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end

    // global timeout: a step can take a whole slow cycle
    initial begin
        #1;
        #(2_000_000.0 + real'(max_steps) * 1300.0 + (cfg_copy ? 120_000_000.0 : 0.0));
        $display("TIMEOUT at step %0d", steps); $display("FAIL: timeout"); $finish;
    end

endmodule
