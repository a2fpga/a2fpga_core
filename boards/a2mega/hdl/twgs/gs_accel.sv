// A2MEGA - IIgs CPU socket accelerator: the accelerator domain
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
// Everything of the S7 accelerator that runs on the pin-sequencer clock, as
// one module (docs/gs_socket_s7_accelerator_scoping.md, and the exploration
// log's "Rung 5"): gs_socket_phy, gs_accel_broker with the near memory and
// the two-clk step, the F65C816 core with its microcode in block RAM (build
// with F65C816_MCODE_ROM), the near memory, the card's two memories of
// record - banks 00/01 and the ROM image, 128 KB each - and
// gs_accel_romcopy, which reads the image through the socket.  It is the
// wiring of the timing probe (accel_probe_138b/accel_probe_top.sv), which
// keeps its stand-ins; the broker bench runs this module beside its own
// hand-wired design, pin for pin (ACCEL_SHADOW).
//
// One clock (clk).  The control inputs are quasi-static and already in its
// domain.  What they ask for is granted only when it is safe:
//
//   cfg_cardmem_i  the card's memory is the memory of record (native mode:
//                  its byte goes to the core and is compared with the
//                  socket's - verify_count_o).  Needs a valid ROM image.
//   cfg_fast_i     local steps at the clock's rate.  Needs cfg_cardmem_i.
//   cfg_cxrom_i    internal $C100-$CFFF firmware served from the image.  Taken
//                  when the core is in reset or held (a ROM copy), not mid-run.
//   cfg_copy_i     a rising edge copies the ROM image through the socket
//                  (the core is held for about 46 ms).
//
// With all of them low the module is S6 on the broker: every step a socket
// cycle, every byte from the socket.
//
// Expansion memory (EXP_DDR = 1): EXP_BANKS banks from 02 up (126: to 7F) in a
// memory outside this module, behind gs_accel_exp's port (m_*: the DDR3,
// through whatever crosses to its clock).  The near memory then tags every
// bank it must (NEAR_KW = 9 for all of them), a near miss in those banks waits
// for the memory, and cfg_cardmem_i also needs exp_ready_i and a queue that
// never overflowed.  The tag is read whole with the core's next address, so a
// step in an expansion bank is a two-clk step like any other; or, with
// NEAR_SPLIT, its high address bits are read a clk late from blocks of their
// own (the broker's NEAR_SPLIT: fourteen blocks on the core's next address, as
// without the banks, and four clks for a step in them).  Or -
//
// Expansion memory (EXP_BANKS = 2): banks 02/03 in block RAM, beside banks
// 00/01 and on the same terms - the card's memory of record under
// cfg_cardmem_i, following every write of the core from the moment the socket
// is armed.  A stopgap for the DDR3 (scoping 7, S7d): two banks are what the
// near memory's tag reaches (NEAR_KW = 4: A14-A17).  The machine must have
// those banks itself.
//
// The far memories (the banks and the ROM image) are many blocks, anywhere on
// the die, and nothing reaches or leaves them in one clk: the read address is
// presented for two clks (the broker's far path), the data has two clks to the
// broker (FAR_CLKS = 2), each data bit's blocks have their own copy of the read
// and write enables (RA_COPIES = 8), and a RAM write goes through one more
// register per data bit here, a clk later than the broker makes it - three clks
// and more before the broker can launch a read (the bench checks that margin).
//
// Memories: block RAM, zero at power-up.  The near memory's tags are stored
// inverted so that zeros read as "no entry".  Banks 00/01 follow every write
// the core makes from the moment the socket is armed; nothing else loads
// them, so the card's memory matches the machine's only for bytes written
// since then (scoping 2.6).
//
module gs_accel #(
    parameter bit ROM3 = 1'b0,
    parameter int NEAR_KW = 4,           // address bits above A13 in a near-memory tag: 4 = banks 00/01 and the ROM
                                         // image, which is all this module has (the bench also runs it with 10)
    parameter int EXP_BANKS = 0,         // expansion banks held in block RAM: 0, or 2 (banks 02/03)
    parameter bit EXP_DDR   = 1'b0,      // 1 = the EXP_BANKS expansion banks (1..126) are in the memory at the m_* port
    parameter bit NEAR_SPLIT = 1'b0,     // EXP_DDR: the near-memory tag's address bits above A17 in blocks of their own
    parameter bit NEAR_LINE  = 1'b0,     // the near memory holds 16-byte lines under one tag, and every far read is a line:
                                         // the block memories sixteen bytes wide, m_rdata_i the DDR3's sixteen (not NEAR_SPLIT)
    parameter bit SLOW_COPY  = 1'b0,     // EXP_DDR: a copy of the Mega II's RAM below $C000 (banks E0/E1) in the expansion
                                         // memory, in the 128K below its bank 02 that nothing else uses; cfg_slow_i then
                                         // has reads of that RAM served from the copy (gs_accel_broker SLOW_COPY)
    parameter bit SIM_ROM_VALID = 1'b0   // SIMULATION ONLY: the bench loaded the ROM image (gs_accel_romcopy SIM_PRESET)
) (
    input  logic        clk,
    input  logic        rst_n,

    // control (clk domain, quasi-static)
    input  logic        arm_i,           // take the socket (gs_socket_phy armed_i)
    input  logic        listen_i,        // control-input shifter only
    input  logic [3:0]  out_extra_i,     // PHY address-delay sweep
    input  logic        cfg_fast_i,
    input  logic        cfg_cardmem_i,
    input  logic        cfg_cxrom_i,
    input  logic        cfg_copy_i,
    input  logic        cfg_slow_i,      // (SLOW_COPY) reads of banks E0/E1 below $C000 from the card's copy; any time, either way
    input  logic        clear_i,         // hold the PHI2 measurement at zero

    // expansion memory port (EXP_DDR; clk domain; else tie the inputs low): one
    // request at a time, reads answered in the order they were taken
    input  logic        exp_ready_i,     // the memory is initialised (quasi-static)
    output logic        m_req_o,
    input  logic        m_ready_i,
    output logic        m_we_o,
    output logic [22:0] m_addr_o,
    output logic [7:0]  m_wdata_o,
    input  logic        m_rvalid_i,
    input  logic [(NEAR_LINE ? 128 : 8)-1:0] m_rdata_i,   // (NEAR_LINE: the read's 16-byte line, byte k in bits 8k+7..8k)

    // socket pins
    input  logic        gs_ph2_i,
    input  logic        gs_rdy_i,
    input  logic        gs_irq_n_i,
    input  logic        gs_nmi_n_i,
    input  logic        gs_res_n_i,
    input  logic        gs_abort_n_i,
    input  logic        gs_be_i,
    input  logic [7:0]  gs_d_i,
    output logic [7:0]  gs_d_o,
    output logic        gs_d_oe_o,
    output logic [15:0] gs_a_o,
    output logic        gs_rw_o,
    output logic        gs_vp_o,
    output logic        gs_rdy_out_o,
    output logic        gs_d_dir_o,
    output logic        gs_data_oe_n_o,
    output logic        gs_addr_oe_n_o,
    output logic        gs_ctl_oe_n_o,

    // telemetry (clk domain)
    output logic [7:0]  status_o,        // {ph2_alive, running, enabled, be_ok, res_n, rdy, 0, 0} (as gs_socket_ctl)
    output logic [7:0]  mode_o,          // {rom_valid, copy_busy, held, fast, cardmem, cxrom, slow, 0}: what is in effect
    output logic [31:0] cycle_count_o,   // PHY: bus cycles
    output logic [15:0] stall_count_o,
    output logic [15:0] be_count_o,
    output logic [15:0] ph2_period_o,    // clk ticks per 256 PHI2 cycles
    output logic [15:0] ph2_high_o,
    output logic [23:0] last_addr_o,     // address of the last cycle put on the bus
    output logic [15:0] verify_count_o,
    input  logic [5:0]  tele_idx_i,      // quasi-static: selects tele_word_o
    output logic [31:0] tele_word_o      // 0 steps, 1 socket cycles for the core, 2 posted writes, 3 clks waited for
                                         // the write buffer, 4 local reads in place, 5 local reads that waited,
                                         // 6 {verify_count, 8'h00, mode}, 7 {8'h00, verify_addr},
                                         // 8 {copies, 8'h00, ROM image sum}, 9 {shadow, cyareg, sltromsel, statereg},
                                         // 10 {24'h0, switch misc}, 11 PHY bus cycles, 12 {.., EXP_DDR, its queue overflowed, its memory ready, EXP_BANKS},
                                         // 13 {E0/E1 verify count, 8'h00, 4'h0, SLOW_COPY, the copy is whole, asked for, in effect},
                                         // 14 {8'h00, address of the last E0/E1 verify mismatch}; others 0
);
    localparam int STEP_CLKS = 2, ADDR_CLKS = 2, SLOW_CLKS = 3;
    localparam int NEAR_AW = 14, NTW = NEAR_KW + 2;
    localparam int ROM_BLKS = ROM3 ? 16 : 8;
    localparam int ROM_SELW = $clog2(ROM_BLKS);
    localparam int RAM_BLKS = (EXP_BANKS == 2 && !EXP_DDR) ? 16 : 8;      // 16K x 1 blocks per data bit: banks 00/01 (and 02/03)
    localparam int RAM_SELW = $clog2(RAM_BLKS);
    initial if (!EXP_DDR && EXP_BANKS != 0 && EXP_BANKS != 2) $fatal(1, "gs_accel: EXP_BANKS in block RAM must be 0 or 2");
    initial if (EXP_DDR && !(EXP_BANKS >= 1 && EXP_BANKS <= 126 && NEAR_KW >= 5 && NEAR_KW <= 9 && (2 + EXP_BANKS) <= (1 << (NEAR_KW - 2))))
        $fatal(1, "gs_accel: EXP_DDR needs 1..126 EXP_BANKS and a NEAR_KW (5..9) that reaches them");
    initial if (NEAR_SPLIT && !EXP_DDR) $fatal(1, "gs_accel: NEAR_SPLIT is for EXP_DDR");
    initial if (NEAR_LINE && NEAR_SPLIT) $fatal(1, "gs_accel: NEAR_LINE is not for NEAR_SPLIT");
    initial if (SLOW_COPY && !(EXP_DDR && NEAR_LINE)) $fatal(1, "gs_accel: SLOW_COPY is for EXP_DDR with NEAR_LINE (the only way it has been run)");
    localparam int NM_LO = NEAR_SPLIT ? 14 : 8 + NTW;         // near-memory entry bits read with the core's next address
    localparam int NM_HI = NEAR_SPLIT ? NEAR_KW - 4 : 0;      // ... and a clk later, at the step's address (NEAR_SPLIT)

    // ---- socket PHY
    logic [23:0] phy_a;
    logic [7:0]  phy_d_out;
    logic        phy_we_n, phy_vpa, phy_vda, phy_vp_n;
    logic        enabled, running, fall_evt, issue_evt, ph2_alive, be_ok;

    gs_socket_phy #(.CORE_SUBST(1'b0), .WDATA_LATE(1'b1)) u_phy (  // the broker substitutes internal I/O cycles itself
        .force_slow_i(1'b0),
        .clk(clk), .rst_n(rst_n), .armed_i(arm_i), .listen_i(listen_i), .out_extra_i(out_extra_i),
        .cpu_clk_o(), .cpu_rst_n_o(),
        .cpu_a_i(phy_a), .cpu_d_out_i(phy_d_out), .cpu_we_n_i(phy_we_n), .cpu_vp_n_i(phy_vp_n),
        .cpu_vpa_i(phy_vpa), .cpu_vda_i(phy_vda),
        .gs_ph2_i(gs_ph2_i), .gs_rdy_i(gs_rdy_i), .gs_res_n_i(gs_res_n_i), .gs_be_i(gs_be_i),
        .gs_d_o(gs_d_o), .gs_d_oe_o(gs_d_oe_o),
        .gs_a_o(gs_a_o), .gs_rw_o(gs_rw_o), .gs_vp_o(gs_vp_o), .gs_rdy_out_o(gs_rdy_out_o),
        .gs_d_dir_o(gs_d_dir_o), .gs_data_oe_n_o(gs_data_oe_n_o), .gs_addr_oe_n_o(gs_addr_oe_n_o),
        .gs_ctl_oe_n_o(gs_ctl_oe_n_o),
        .ph2_alive_o(ph2_alive), .running_o(running), .enabled_o(enabled), .be_ok_o(be_ok),
        .fall_evt_o(fall_evt), .issue_evt_o(issue_evt), .ended_read_o(),
        .cycle_count_o(cycle_count_o), .stall_count_o(stall_count_o), .be_count_o(be_count_o)
    );

    // ---- what the control inputs are granted
    logic        rom_valid, rom_ok, copy_busy, copy_start, cfg_copy_q;
    logic        x_ovf, x_rwait, x_rsel, x_wbusy;
    logic [7:0]  x_rdata;
    wire         cardmem = cfg_cardmem_i & rom_ok & (~EXP_DDR | (exp_ready_i & ~x_ovf));
    wire         fast    = cfg_fast_i & cardmem;
    // (SLOW_COPY) The copy of Mega II RAM is whole - it has every byte the machine was
    // given since its last reset - if that reset found the expansion memory ready and
    // nothing has been lost from its queue since.  (What the machine's RAM held from
    // before that reset the copy does not have.  Nothing but this card's core writes
    // the machine's RAM, so that is what was there at power-up - or what the machine
    // was given while the card was being loaded again without a power cycle.)
    // Reads come from the copy when asked, where card memory is in effect - in fast
    // mode, and in paced mode, where each is compared with the socket's byte.
    logic        slow_whole;
    wire         slow    = SLOW_COPY & cfg_slow_i & slow_whole & ~x_ovf & cardmem;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          slow_whole <= 1'b0;
        else if (x_ovf)      slow_whole <= 1'b0;
        else if (!cpu_rst_n) slow_whole <= SLOW_COPY & exp_ready_i;
    end
    // (cxrom goes straight into the decode of the step in progress: it is taken only
    // while no step is, with the core in reset or held - so at /RES and at a ROM copy)
    logic        cxrom;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cfg_copy_q <= 1'b0; copy_start <= 1'b0; cxrom <= 1'b0; end
        else begin
            cfg_copy_q <= cfg_copy_i; copy_start <= cfg_copy_i & ~cfg_copy_q;
            if (!cpu_rst_n | held) cxrom <= cfg_cxrom_i & rom_ok;
        end
    end

    // ---- broker
    logic        cpu_rst_n, cpu_ce, cpu_irq_n, cpu_nmi_n, cpu_abort_n;
    logic [3:0]  cpu_ce_c;
    logic [7:0]  cpu_d_in, cpu_d_out;
    logic [23:0] cpu_a, cpu_na;
    logic [13:0] cpu_na_b;
    logic [2:0]  cpu_nst;
    logic        cpu_we_n, cpu_vp_n, cpu_vpa, cpu_vda, cpu_mlb, cpu_iflag, cpu_rdyo;
    logic [7:0]  lm_ren, lm_wen;                 // (one copy per data bit: RA_COPIES)
    logic [8*17-1:0] lm_ram_ra_c;
    logic [8*18-1:0] lm_rom_ra_c;
    logic [23:0] lm_raddr, lm_waddr;
    logic [16:0] lm_ram_ra;
    logic [17:0] lm_rom_ra;
    logic [7:0]  lm_wdata, lm_ram_rdata, lm_rom_rdata;
    logic               nm_ren, nm_wen;
    logic [NEAR_AW-1:0] nm_ra, nm_wa;
    logic [7:0]         nm_rdata, nm_wdata;
    logic [NTW-1:0]     nm_rtag, nm_wtag;
    logic        nm_ren_hi, lm_rexp;
    logic [NEAR_AW-1:0] nm_ra_hi;
    logic        nm_dwen, nm_lfill, lm_risrom;   // (NEAR_LINE)
    logic [127:0] far_line, x_rline;             // ... the line of the last far read; the expansion memory's
    logic        brk_fast, held, idle_stb, hold, nm_flush;
    logic [7:0]  idle_d;
    logic [23:0] idle_a, verify_addr, verify_saddr;
    logic [15:0] verify_scount;
    logic        lm_wfwd, brk_slow;
    logic [NEAR_AW-1:0] nm_flush_idx;
    logic [31:0] stat_steps, stat_sock, stat_posted, stat_pwwait, stat_rd_hit, stat_rd_miss;
    logic [7:0]  r_shadow, r_cyareg, r_sltromsel, r_statereg, r_misc;

    gs_accel_broker #(.STEP_CLKS(STEP_CLKS), .ADDR_CLKS(ADDR_CLKS), .SLOW_CLKS(SLOW_CLKS), .DATA_LATE(1'b1), .RA_COPIES(8), .CE_COPIES(4),
                      .NEAR(1'b1), .NEAR_AW(NEAR_AW), .NEAR_KW(NEAR_KW), .ROM3(ROM3), .FAR_CLKS(2), .WEN_ONE(1'b1),
                      .EXP_WAIT(EXP_DDR), .NEAR_SPLIT(NEAR_SPLIT), .NEAR_LINE(NEAR_LINE), .SLOW_COPY(SLOW_COPY)) u_brk (
        .clk(clk), .rst_n(rst_n),
        .native_i(~fast), .mem_bypass_i(~cardmem),
        .cxrom_local_i(cxrom), .exp_banks_i(7'(EXP_BANKS)), .slow_local_i(slow),
        .hold_i(hold), .idle_a_i(idle_a), .held_o(held), .idle_stb_o(idle_stb), .idle_d_o(idle_d),
        .nm_flush_i(nm_flush), .nm_flush_idx_i(nm_flush_idx),
        .phy_enabled_i(enabled), .phy_running_i(running),
        .phy_fall_evt_i(fall_evt), .phy_issue_evt_i(issue_evt),
        .phy_a_o(phy_a), .phy_d_out_o(phy_d_out), .phy_we_n_o(phy_we_n),
        .phy_vpa_o(phy_vpa), .phy_vda_o(phy_vda), .phy_vp_n_o(phy_vp_n),
        .gs_ph2_i(gs_ph2_i), .gs_d_i(gs_d_i), .gs_rdy_i(gs_rdy_i),
        .gs_irq_n_i(gs_irq_n_i), .gs_nmi_n_i(gs_nmi_n_i), .gs_abort_n_i(gs_abort_n_i),
        .cpu_rst_n_o(cpu_rst_n), .cpu_ce_o(cpu_ce), .cpu_ce_c_o(cpu_ce_c), .cpu_d_in_o(cpu_d_in),
        .cpu_irq_n_o(cpu_irq_n), .cpu_nmi_n_o(cpu_nmi_n), .cpu_abort_n_o(cpu_abort_n),
        .cpu_a_i(cpu_a), .cpu_d_out_i(cpu_d_out), .cpu_we_n_i(cpu_we_n),
        .cpu_vpa_i(cpu_vpa), .cpu_vda_i(cpu_vda), .cpu_vp_n_i(cpu_vp_n), .cpu_na_i(cpu_na), .cpu_nst_i(cpu_nst), .cpu_rdy_i(cpu_rdyo),
        .lm_ren_o(lm_ren), .lm_ram_ra_o(lm_ram_ra_c), .lm_rom_ra_o(lm_rom_ra_c), .lm_raddr_o(lm_raddr),
        .lm_ram_rdata_i(lm_ram_rdata), .lm_rom_rdata_i(lm_rom_rdata),
        .lm_wen_o(lm_wen), .lm_waddr_o(lm_waddr), .lm_wdata_o(lm_wdata), .lm_wfwd_o(lm_wfwd),
        .nm_ren_o(nm_ren), .nm_ra_o(nm_ra), .nm_rdata_i(nm_rdata), .nm_rtag_i(nm_rtag),
        .nm_wen_o(nm_wen), .nm_wa_o(nm_wa), .nm_wdata_o(nm_wdata), .nm_wtag_o(nm_wtag),
        .nm_ren_hi_o(nm_ren_hi), .nm_ra_hi_o(nm_ra_hi),
        .nm_dwen_o(nm_dwen), .nm_lfill_o(nm_lfill), .lm_risrom_o(lm_risrom),
        .lm_rexp_o(lm_rexp), .lm_rwait_i(x_rwait), .lm_wbusy_i(x_wbusy),
        .fast_o(brk_fast), .step_evt_o(), .sock_evt_o(), .sock_idle_o(), .pw_busy_o(),
        .verify_miss_o(), .verify_addr_o(verify_addr), .verify_count_o(verify_count_o),
        .slow_o(brk_slow), .verify_scount_o(verify_scount), .verify_saddr_o(verify_saddr),
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

    // ---- the ROM image, through the socket
    logic        rom_we;
    logic [17:0] rom_wa;
    logic [7:0]  rom_wd;
    logic [15:0] rom_sum;
    logic [7:0]  rom_copies;
    gs_accel_romcopy #(.ROM3(ROM3), .NEAR_AW(NEAR_AW), .SIM_PRESET(SIM_ROM_VALID)) u_copy (
        .clk(clk), .rst_n(rst_n),
        .start_i(copy_start), .ready_i(enabled & running),
        .hold_o(hold), .idle_a_o(idle_a), .held_i(held), .idle_stb_i(idle_stb), .idle_d_i(idle_d),
        .nm_flush_o(nm_flush), .nm_flush_idx_o(nm_flush_idx),
        .rom_we_o(rom_we), .rom_wa_o(rom_wa), .rom_wd_o(rom_wd),
        .busy_o(copy_busy), .valid_o(rom_valid), .usable_o(rom_ok), .sum_o(rom_sum), .copies_o(rom_copies)
    );

    // ---- the card's memories of record: for every data bit eight blocks of
    // 16K x 1 for banks 00/01 (sixteen with banks 02/03) and eight (ROM 3: sixteen)
    // for the ROM image, all read at once, a registered block select picking one of
    // each.  They are read only from registers (the broker's far path), so they
    // need no floorplan.  (The RAM's block select is from the full physical address,
    // lm_raddr: its low 17 bits are lm_ram_ra, the same registers.)
    wire ram_bank = (lm_waddr[23:14+RAM_SELW] == '0);      // a write to a bank the card holds
    assign lm_ram_ra = lm_ram_ra_c[16:0];
    assign lm_rom_ra = lm_rom_ra_c[17:0];
    // (simulation: the far data reads WRONG in the clk after its launch - it has two
    // clks, and anything that looked at it sooner would show)
    logic far_bad;
`ifdef VERILATOR
    always_ff @(posedge clk) far_bad <= lm_ren[0];
`else
    assign far_bad = 1'b0;
`endif
    for (genvar b = 0; b < (NEAR_LINE ? 0 : 8); b++) begin : g_bit
        logic [RAM_SELW-1:0] ram_sel;
        logic [ROM_SELW-1:0] rom_sel;
        logic [RAM_BLKS-1:0] ram_q;
        logic [ROM_BLKS-1:0] rom_q;
        // this bit's copy of a RAM write, a clk after the broker's
        logic                   wq_we /* synthesis syn_preserve = 1 */;
        logic [13+RAM_SELW:0]   wq_a  /* synthesis syn_preserve = 1 */;
        logic                   wq_d;
        always_ff @(posedge clk) begin
            wq_we <= lm_wen[b] & ram_bank;
            wq_a  <= lm_waddr[13+RAM_SELW:0];
            wq_d  <= lm_wdata[b];
        end
        always_ff @(posedge clk) if (lm_ren[b]) begin
            ram_sel <= lm_raddr[14 +: RAM_SELW];
            rom_sel <= lm_rom_ra[14 +: ROM_SELW];
        end
        for (genvar k = 0; k < RAM_BLKS; k++) begin : g_blk
            logic mram [0:16383];
            always_ff @(posedge clk) if (lm_ren[b]) ram_q[k] <= mram[lm_ram_ra[13:0]];
            always_ff @(posedge clk) if (wq_we && wq_a[14 +: RAM_SELW] == RAM_SELW'(k)) mram[wq_a[13:0]] <= wq_d;
`ifdef VERILATOR
            initial for (int i = 0; i < 16384; i++) mram[i] = 1'b0;
`endif
        end
        for (genvar k = 0; k < ROM_BLKS; k++) begin : g_rblk
            logic mrom [0:16383];
            always_ff @(posedge clk) if (lm_ren[b]) rom_q[k] <= mrom[lm_rom_ra[13:0]];
            always_ff @(posedge clk) if (rom_we && rom_wa[14 +: ROM_SELW] == ROM_SELW'(k)) mrom[rom_wa[13:0]] <= rom_wd[b];
`ifdef VERILATOR
            initial for (int i = 0; i < 16384; i++) mrom[i] = 1'b0;
`endif
        end
        assign lm_ram_rdata[b] = x_rsel ? x_rdata[b] : (ram_q[ram_sel] ^ far_bad);
        assign lm_rom_rdata[b] = rom_q[rom_sel] ^ far_bad;
    end
    // (NEAR_LINE) The same memories sixteen bytes wide: for each of the eight 16-bit
    // words of a line, the same number of blocks, 1K x 16 with a write enable for
    // each byte - block k holds the words of the 16K bytes block k held above.  A read
    // is of all eight words: the line, of which the broker's byte is one; the line is
    // what a near-memory miss is filled with.  (As many blocks as before, and as
    // free to be anywhere.)
    if (NEAR_LINE) begin : g_far16
        logic [3:0]   far_lo;                // the byte of the line that was asked for
        logic [127:0] ram_line, rom_line;
        always_ff @(posedge clk) if (lm_ren[0]) far_lo <= lm_ram_ra[3:0];
        for (genvar w = 0; w < 8; w++) begin : g_w
            logic [RAM_SELW-1:0] ram_sel;
            logic [ROM_SELW-1:0] rom_sel;
            logic [15:0]         ram_q [0:RAM_BLKS-1];
            logic [15:0]         rom_q [0:ROM_BLKS-1];
            // this word's copy of a RAM write, a clk after the broker's
            logic                   wq_we /* synthesis syn_preserve = 1 */;
            logic [13+RAM_SELW:0]   wq_a  /* synthesis syn_preserve = 1 */;
            logic [7:0]             wq_d  /* synthesis syn_preserve = 1 */;
            always_ff @(posedge clk) begin
                wq_we <= lm_wen[w] & ram_bank & (lm_waddr[3:1] == 3'(w));
                wq_a  <= lm_waddr[13+RAM_SELW:0];
                wq_d  <= lm_wdata;
            end
            always_ff @(posedge clk) if (lm_ren[w]) begin
                ram_sel <= lm_raddr[14 +: RAM_SELW];
                rom_sel <= lm_rom_ra[14 +: ROM_SELW];
            end
            for (genvar k = 0; k < RAM_BLKS; k++) begin : g_blk
                wire we = wq_we && wq_a[14 +: RAM_SELW] == RAM_SELW'(k);
                gs_bram16be mram (.clk(clk), .wa_i(wq_a[13:4]), .we_i({we & wq_a[0], we & ~wq_a[0]}), .wd_i({2{wq_d}}),
                                  .re_i(lm_ren[w]), .ra_i({lm_ram_ra[13:4], 1'b0}), .q_o(ram_q[k]));
            end
            for (genvar k = 0; k < ROM_BLKS; k++) begin : g_rblk
                wire we = rom_we && rom_wa[14 +: ROM_SELW] == ROM_SELW'(k) && rom_wa[3:1] == 3'(w);
                gs_bram16be mrom (.clk(clk), .wa_i(rom_wa[13:4]), .we_i({we & rom_wa[0], we & ~rom_wa[0]}), .wd_i({2{rom_wd}}),
                                  .re_i(lm_ren[w]), .ra_i({lm_rom_ra[13:4], 1'b0}), .q_o(rom_q[k]));
            end
            assign ram_line[16*w +: 16] = ram_q[ram_sel];
            assign rom_line[16*w +: 16] = rom_q[rom_sel];
        end
        assign lm_ram_rdata = x_rsel ? x_rdata : (ram_line[8*far_lo +: 8] ^ {8{far_bad}});
        assign lm_rom_rdata = rom_line[8*far_lo +: 8] ^ {8{far_bad}};
        // The line a miss is filled with, through a register: the far memories' two
        // thousand outputs are muxed wherever they are, and what reaches the near
        // memory's blocks, beside the core, is 128 registers' worth.  The far data has
        // its two clks to this register as it has to the broker's alt_q, and the fill is
        // a clk and more after that (it is made the clk before the step ends).
        logic [127:0] fline_q;
        always_ff @(posedge clk) fline_q <= (lm_risrom ? rom_line : x_rsel ? x_rline : ram_line) ^ {128{far_bad}};
        assign far_line = fline_q;
    end else begin : g_far8
        assign far_line = '0;
    end

    // ---- near memory: one 16K x 1 block per entry bit, no output mux.  The read
    // address is the core's next address, its latest output; the blocks sit in two
    // rows of block RAM, and those of the second take the core's second copy of it
    // (NA_OUT_B) so that neither copy's net spans both rows.
    localparam logic [18:0] ROW_B = 19'b100_1111_0000_1100_1100;     // entry bits placed in the second row (up to 19)
    // With NEAR_SPLIT the entry is {high address bits (A18 up) | ROM, A12, A14-A17, byte}: the
    // fourteen bits after the bar are exactly the entry of a build without it, read as
    // before, and are all the cheap view needs (the broker marks a tag with a high
    // address bit in them: nm_tag); the high address bits are in blocks of their own,
    // read a clk later at the step's address (a register), and need no floorplan.
    // The fourteen are stored inverted and the high address bits as they are: a block
    // RAM powers up all zeros, and that must read as the broker's empty entry
    // (NM_EMPTY: the mark of a high address bit, with none set).  Stored inverted too,
    // the zeros read as RAM at the top of bank 7F: a byte there was read out of an
    // entry that held nothing, after power-up and after every ROM copy.
    // (Without it the entry is {tag, byte}, the tag inverted: the zeros read as all
    // ones, the empty entry of a whole tag.)
    wire [NM_LO-1:0]  nm_wv  = NEAR_SPLIT ? {~nm_wtag[NTW-1:NTW-2], ~nm_wtag[3:0], nm_wdata}
                                          : (NM_LO)'({~nm_wtag, nm_wdata});
    logic [NM_LO-1:0] nm_q;
    for (genvar b = 0; b < (NEAR_LINE ? 0 : NM_LO); b++) begin : g_nb
        localparam bit SECOND = (NM_LO <= 19) ? ROW_B[b] : ((b % 4) >= 2);
        logic nmem [0:(1<<NEAR_AW)-1];
        wire [NEAR_AW-1:0] ra = SECOND ? cpu_na_b[NEAR_AW-1:0] : nm_ra;
        always_ff @(posedge clk) if (nm_ren) nm_q[b] <= nmem[ra];
        always_ff @(posedge clk) if (nm_wen) nmem[nm_wa] <= nm_wv[b];
`ifdef VERILATOR
        initial begin for (int i = 0; i < (1<<NEAR_AW); i++) nmem[i] = 1'b0; nm_q[b] = 1'b0; end
`endif
    end
    // (NEAR_LINE) Lines of sixteen bytes: eight blocks of 1K x 16, one for each word of
    // a line, with a write enable for each byte - a write of the core's is one byte of
    // one of them, a fill is all of all eight in one clk, from the far memories' line -
    // and ONE block of tags, a tag for a line.  Nine blocks where the entries above
    // are nineteen, each with ten address bits where those have fourteen: that is
    // what the core's next address has to reach.  Each block's read port is a byte
    // wide and gives its word's byte of the address; which word's is picked by the
    // address's bits 3 to 1, a register, on the way to the core (a path with the
    // step's two clks).  The tag is stored inverted: zeros read as empty.
    if (NEAR_LINE) begin : g_line
        logic [3:1]  nlo;
        logic [15:0] nq [0:7];
        always_ff @(posedge clk) if (nm_ren) nlo <= nm_ra[3:1];
        initial if (NEAR_AW != 14) $fatal(1, "gs_accel: NEAR_LINE is 1K lines of sixteen bytes (NEAR_AW = 14)");
        for (genvar w = 0; w < 8; w++) begin : g_nb
            wire [NEAR_AW-1:0] ra = (w % 2) ? cpu_na_b[NEAR_AW-1:0] : nm_ra;
            wire         wsel = nm_lfill | (nm_dwen & (nm_wa[3:1] == 3'(w)));
            wire [15:0]  wd   = nm_lfill ? far_line[16*w +: 16] : {2{nm_wdata}};
            wire [1:0]   be   = nm_lfill ? 2'b11 : nm_wa[0] ? 2'b10 : 2'b01;
            gs_bram16be #(.RD8(1'b1)) nmem (.clk(clk), .wa_i(nm_wa[13:4]), .we_i({2{wsel}} & be), .wd_i(wd),
                                            .re_i(nm_ren), .ra_i({ra[13:4], ra[0]}), .q_o(nq[w]));
        end
        assign nm_rdata = nq[nlo][7:0];
        begin : g_nt
            logic [NTW-1:0] nmem [0:(1<<(NEAR_AW-4))-1];
            logic [NTW-1:0] ntq;
            // (in the second row, with the odd words, on the core's second copy of its next
            // address: the row the broker's compare of it is placed beside)
            always_ff @(posedge clk) if (nm_ren) ntq <= nmem[cpu_na_b[NEAR_AW-1:4]];
            always_ff @(posedge clk) if (nm_wen) nmem[nm_wa[NEAR_AW-1:4]] <= ~nm_wtag;
`ifdef VERILATOR
            initial begin for (int i = 0; i < (1<<(NEAR_AW-4)); i++) nmem[i] = '0; ntq = '0; end
`endif
            assign nm_rtag = ~ntq;
        end
    end else begin : g_byte
        assign nm_rdata = nm_q[7:0];
    end
    if (NEAR_LINE) begin : g_noq
    end else if (NEAR_SPLIT) begin : g_split
        logic [NM_HI-1:0] nh_q;
        // (their write a clk after the rest of the entry's, from a register of its own:
        // they are read a clk after the rest, and an entry written in or since the clk
        // of its launch is not used at all)
        logic               hq_we;
        logic [NEAR_AW-1:0] hq_a;
        logic [NM_HI-1:0]   hq_d;
        always_ff @(posedge clk) begin hq_we <= nm_wen; hq_a <= nm_wa; hq_d <= nm_wtag[NEAR_KW-1:4]; end
        for (genvar b = 0; b < NM_HI; b++) begin : g_nh
            logic nmemh [0:(1<<NEAR_AW)-1];
            always_ff @(posedge clk) if (nm_ren_hi) nh_q[b] <= nmemh[nm_ra_hi];
            always_ff @(posedge clk) if (hq_we) nmemh[hq_a] <= hq_d[b];
`ifdef VERILATOR
            initial begin for (int i = 0; i < (1<<NEAR_AW); i++) nmemh[i] = 1'b0; nh_q[b] = 1'b0; end
`endif
        end
        assign nm_rtag = {~nm_q[13:12], nh_q, ~nm_q[11:8]};
    end else begin : g_whole
        assign nm_rtag = ~nm_q[8 +: NTW];
    end

    // ---- expansion memory (EXP_DDR): the queue the far path waits on
    // (SLOW_COPY) The copy of Mega II RAM is the memory's first 128K - banks 00/01 of
    // its address space, which the card holds in block RAM: E0/E1 + A16-A0 is there at
    // A16-A0.  A forwarded write (lm_wfwd: the FPI shadows it into E0/E1) is made in the
    // copy the clk after the broker makes it - that clk is free: a step is two clks and
    // more, and no read is launched within two clks of a write - so a write that is
    // also the expansion memory's own (a shadowed write in an expansion bank, CYAREG[4])
    // is two writes in two clks.
    if (EXP_DDR) begin : g_exp
        logic        mir_q;
        logic [16:0] mir_a;
        logic [7:0]  mir_d;
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin mir_q <= 1'b0; mir_a <= '0; mir_d <= '0; end
            else begin
                mir_q <= SLOW_COPY & lm_wen[0] & lm_wfwd;
                mir_a <= lm_waddr[16:0];
                mir_d <= lm_wdata;
            end
        end
        wire        x_slow_r = SLOW_COPY & lm_raddr[23];
        wire        x_slow_w = SLOW_COPY & lm_waddr[23];
        wire        x_wr     = lm_wen[0] & (|lm_waddr[23:17]);
        wire [22:0] x_ra     = x_slow_r ? {6'd0, lm_raddr[16:0]} : lm_raddr[22:0];
        wire [22:0] x_wa     = mir_q ? {6'd0, mir_a} : x_slow_w ? {6'd0, lm_waddr[16:0]} : lm_waddr[22:0];
`ifdef VERILATOR
        always @(posedge clk) if (rst_n && mir_q && (x_wr || (lm_ren[0] & lm_rexp))) begin
            $display("ERROR: gs_accel: the Mega II copy's forwarded write met another request of the expansion memory @%0t", $time); $finish;
        end
`endif
        gs_accel_exp #(.AW(23), .LINE(NEAR_LINE)) u_exp (
            .clk(clk), .rst_n(rst_n), .run_i(cpu_rst_n),
            .rd_i(lm_ren[0] & lm_rexp), .rnx_i(lm_ren[0] & ~lm_rexp), .raddr_i(x_ra),
            .wr_i(x_wr | mir_q), .waddr_i(x_wa), .wdata_i(mir_q ? mir_d : lm_wdata),
            .rwait_o(x_rwait), .rsel_o(x_rsel), .rdata_o(x_rdata), .rline_o(x_rline), .wbusy_o(x_wbusy), .ovf_o(x_ovf), .busy_o(),
            .m_req_o(m_req_o), .m_ready_i(m_ready_i), .m_we_o(m_we_o), .m_addr_o(m_addr_o), .m_wdata_o(m_wdata_o),
            .m_rvalid_i(m_rvalid_i), .m_rdata_i(m_rdata_i)
        );
    end else begin : g_noexp
        assign {x_rwait, x_rsel, x_wbusy, x_ovf} = '0;
        assign x_rdata = '0; assign x_rline = '0;
        assign m_req_o = 1'b0; assign m_we_o = 1'b0; assign m_addr_o = '0; assign m_wdata_o = '0;
    end

    // ---- telemetry
    // PHI2 period / duty: clk ticks per 256 cycles (as gs_socket_ctl).  per_acc
    // counts from 1, so the period is the register itself and not its increment
    // (that adder into ph2_period_o was the worst path of a placement, 2026-11-14)
    logic [1:0]  ph2_s;
    logic [15:0] per_acc, hi_acc;
    logic [7:0]  cyc256;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph2_s <= '0; per_acc <= 16'd1; hi_acc <= '0; ph2_period_o <= '0; ph2_high_o <= '0; cyc256 <= '0;
            last_addr_o <= '0;
        end else begin
            ph2_s <= {ph2_s[0], gs_ph2_i};
            if (issue_evt) last_addr_o <= phy_a;
            if (clear_i) begin
                per_acc <= 16'd1; hi_acc <= '0; ph2_period_o <= '0; ph2_high_o <= '0; cyc256 <= '0;
            end else if (fall_evt) begin
                if (cyc256 == 8'hFF) begin
                    ph2_period_o <= per_acc;
                    ph2_high_o   <= hi_acc + {15'd0, ph2_s[1]};
                    per_acc <= 16'd1;
                    hi_acc  <= '0;
                end else begin
                    per_acc <= per_acc + 1'b1;
                    hi_acc  <= hi_acc + {15'd0, ph2_s[1]};
                end
                cyc256 <= cyc256 + 1'b1;
            end else begin
                per_acc <= per_acc + 1'b1;
                hi_acc  <= hi_acc + {15'd0, ph2_s[1]};
            end
        end
    end

    assign status_o = {ph2_alive, running, enabled, be_ok, gs_res_n_i, gs_rdy_i, 2'b00};
    assign mode_o   = {rom_valid, copy_busy, held, brk_fast, cardmem, cxrom, brk_slow, 1'b0};
    always_ff @(posedge clk) begin
        unique case (tele_idx_i)
            6'd0:    tele_word_o <= stat_steps;
            6'd1:    tele_word_o <= stat_sock;
            6'd2:    tele_word_o <= stat_posted;
            6'd3:    tele_word_o <= stat_pwwait;
            6'd4:    tele_word_o <= stat_rd_hit;
            6'd5:    tele_word_o <= stat_rd_miss;
            6'd6:    tele_word_o <= {verify_count_o, 8'h00, mode_o};
            6'd7:    tele_word_o <= {8'h00, verify_addr};
            6'd8:    tele_word_o <= {rom_copies, 8'h00, rom_sum};
            6'd9:    tele_word_o <= {r_shadow, r_cyareg, r_sltromsel, r_statereg};
            6'd10:   tele_word_o <= {24'h0, r_misc};
            6'd11:   tele_word_o <= cycle_count_o;
            6'd12:   tele_word_o <= {21'h0, EXP_DDR, x_ovf, exp_ready_i, 8'(EXP_BANKS)};
            6'd13:   tele_word_o <= {verify_scount, 8'h00, 4'h0, SLOW_COPY, slow_whole, cfg_slow_i, brk_slow};
            6'd14:   tele_word_o <= {8'h00, verify_saddr};
            default: tele_word_o <= 32'h0;
        endcase
    end
endmodule
