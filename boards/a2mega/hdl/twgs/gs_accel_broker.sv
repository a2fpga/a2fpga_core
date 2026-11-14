// A2MEGA - S7 accelerator: bus-cycle broker between the 65C816 core and the
// IIgs CPU-socket PHY (S7b)
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
// S2-S6 clock the core with PHI2: one core step per motherboard cycle.  Here
// the core lives in the accelerator's own clock domain (clk, the PHY's pin-
// sequencer clock) and is stepped with a clock enable; this module decides,
// step by step, where the step's bus cycle is performed
// (docs/gs_socket_s7_accelerator_scoping.md 2.1-2.4, 9):
//
//  * LOCAL: the memory-map replica (gs_mmu_replica) says the access belongs
//    to the card - banks 00/01, the ROM image, backed expansion banks.  The
//    local memory port is strobed ADDR_CLKS clocks into the step and the
//    core steps STEP_CLKS clocks after the previous step.  The socket shows
//    an idle cycle (below).
//  * SOCKET: everything else - I/O, slot space, banks E0/E1, unbacked banks.
//    The core is held (no clock enable), the cycle is handed to the PHY at
//    its next issue point, runs as exactly one PHI2 cycle with the PHY's
//    timing, and the core steps on the PHI2 fall that completes it, taking
//    the byte the socket pads held at that fall.  RDY low at the fall
//    repeats the cycle, as the PHY and a real 65816 do.
//  * POSTED WRITE: a local RAM write the machine shadows into E0/E1
//    (replica: forward_write) is stored locally at once AND queued in a
//    one-deep buffer to be run on the socket as an ordinary bank-00/01
//    write, so the FPI does its shadow copy.  The core does not wait for
//    it; a second forwarded write waits until the buffer is free.  Order on
//    the socket is program order: the buffer always goes out before any
//    later socket cycle of the core (which is necessarily younger, because
//    the core stops at the first one it needs).  A read of a just-posted
//    location is a local read of the byte just stored.
//  * IDLE: a PHI2 cycle with nothing to carry is a read of PARK_ADDR (a ROM
//    address in bank FF: a fast cycle, no refresh interplay, no side effect
//    anywhere in the machine) with VDA = VPA = 0.  Departure from the
//    scoping doc's "previous address repeated": repeating a previous I/O or
//    slot address would repeat its side effects (9).
//  * HOLD (hold_i): the core is not stepped past the step in progress.  The
//    sequencer waits in ST_SOCK with no request; the socket's idle cycles are
//    then reads of idle_a_i, each reported when it completes (idle_stb_o).
//    gs_accel_romcopy uses it to read the ROM image through the socket; with
//    nm_flush_i it also empties the near memory.  The step that was held makes
//    no use of the near-memory byte launched for it.
//
// Internal cycles of the core (VDA = VPA = 0) carry no data.  In fast mode
// they reach the socket only when their address could matter to the machine
// (I/O or slot space), exactly as S6 would have shown them: an internal
// cycle aimed at $C0xx of banks 00/01/E0/E1 repeats the previous step's
// address as a read (the S5 phantom-$C028 rule, gs_socket_65816_scoping 4.5;
// the broker does the substitution itself, because the PHY's "previous
// address" would be the park address), elsewhere the core's own address.
//
// Modes (runtime, taken at step boundaries):
//  * native_i = 1: every step is a socket cycle, one per PHI2 cycle, issued
//    and completed exactly as S6 does it - pin for pin (the bench compares
//    against an S6 PHY + PHI2-clocked core running beside it).
//      - mem_bypass_i = 1: read data comes from the socket for everything,
//        i.e. S6.  Writes are still copied into the card's memory, so the
//        card's copy of banks 00/01 stays current.
//      - mem_bypass_i = 0: the card's memory is still the memory of record
//        (reads of local regions use it; every write also goes out on the
//        socket), so native and fast can be switched in either direction at
//        any time.  Each local read is also compared with the byte the
//        socket returned (verify_*: the scoping doc's "verify mode").  The
//        comparison means something only until fast mode first runs: after
//        that the motherboard's copy of banks 00/01 is stale by design.
//    Clearing mem_bypass_i is only coherent while the card's memory is a
//    complete copy; setting it is only coherent while the motherboard's is,
//    i.e. as long as fast mode has not run since power-up.
//  * native_i = 0: fast mode, as above.  RDY low at the last PHI2 fall also
//    holds local steps (the TransWarp's GS_PAUSE).
//
// Reset.  The core's reset is the PHY's (the machine's /RES, held until it
// has been high at two PHI2 falls), re-registered here.  While it is low the
// replica's switches take their reset values, the core is in reset, and the
// socket shows what S6 shows: the core's reset-state address as a read.  A
// posted write that is still in the buffer when /RES falls is dropped (the
// PHY cannot write during reset): at most one byte of a shadowed page, which
// the card's own memory still holds.  The card's memory is kept (warm reset).
//
// Clocking / CDC.  One domain: clk.  The socket pads (D0-7, RDY, /IRQ, /NMI,
// /ABORT) are sampled by flops clocked on the PHI2 fall (the instant a 65816
// samples them) and read here only at or after phy_fall_evt_i, at least one
// clk later - the same quasi-static crossing gs_socket_phy uses for the
// core's outputs.  A native step uses exactly those samples.  In fast mode
// the three interrupt lines go through ordinary two-flop synchronisers
// instead, so the core never acts on a level that is a PHI2 cycle old.  The
// PHY reads this module's phy_* outputs only in its issue clock
// (phy_issue_evt_i).  In native mode the next request must be presented by
// that clock: ADDR_CLKS <= OUT_DELAY + out_extra of the PHY.
//
// The core is taken through its port list (CLK = clk, RST_N, CE, RDY_IN tied
// high, IRQ/NMI/ABORT, D_IN, and its bus outputs), so P65C816 and F65C816
// are interchangeable.
//
// Local memory and the data-late step (DATA_LATE = 1, F65C816 only).  The
// memories are synchronous: a read is LAUNCHED (lm_ren_o registers the RAM
// and the ROM-image address, both memories read) and its data is used
// STEP_CLKS later.  Without DATA_LATE every local read is launched at the
// step's strobe from the core's address (two-edge step: ADDR_CLKS to form the
// address, the rest of the step for the data).  With DATA_LATE the broker also
// launches a read at the clock-enable edge of every local step, at the core's
// NEXT-step address (cpu_na_i = F65C816.NA_OUT, translated as a read by the
// replica's pf_ port), so that the following step finds its data already
// there and the whole step is one STEP_CLKS-long path.  The launch is a
// speculation and it is checked, not assumed: the broker remembers what the
// memories' output registers hold (ld_*), and when the step runs it compares
// that with the address the step really needs on the memory it really uses.
// A match uses the data; anything else - the step after a socket cycle (no
// launch: the socket data arrives too late to form the next address), a soft
// switch that moved the map, a vector pull, a local write since the launch -
// launches the read again, one clk after the strobe and from registers
// (ml_*), and waits a full STEP_CLKS for it.  The select of the core's data
// source (card RAM, card ROM, socket) is speculated and checked the same way:
// it is set at the launch from the replica's view of the next address, and a
// step that needs a different source sets it one clk after the strobe and
// waits.  Correctness therefore never rests on the guess, only speed.
// Timing shape this gives a build: core registers reach the memories'
// read-address pins and the data-source select only through the next-address
// path, once per step (a STEP_CLKS-cycle path, like memory data -> core and
// core -> core); everything else the broker registers from the core's outputs
// is captured at the strobe (an ADDR_CLKS-cycle path), and the select changes
// at least STEP_CLKS before the core takes the data.
// A write goes to the RAM at the strobe, always at least one clock before the
// next launch, so a launch never coincides with a write.
//
// Near memory (NEAR = 1; with DATA_LATE, ADDR_CLKS = 2): the two-clk step.
// The banks and the ROM image are too many blocks to sit close to one core,
// and a decode of the core's NEXT address is too much logic to hang behind it.
// So the core's next address drives two things only: ea_r (with the status,
// the step's address as a register from the moment the core steps) and the
// read address of a small memory of its own, a direct-mapped cache of single
// bytes, read at every core step.  An entry is {tag, byte}; the index is the
// low NEAR_AW bits of the address, untranslated; the tag is what else
// identifies the physical byte - ROM or RAM, the address bits above the index,
// and whether the language card moved A12.
//   Two tiers of decode, both from those registers, neither ahead.  In the
// step's FIRST clk a cheap view (gs_mmu_decode fast_*: bank, page, a few
// switches - a subset of "the card's alone", proven against the full decode on
// every vector of the decode sweep) says whether the step is one of the common
// ones: a read in banks 00/01 outside $Cxxx or in a ROM bank, a write in banks
// 00/01 where nothing is shadowed, an internal cycle outside $Cxxx.  For those
// the same view gives the tag and the tag read at the launch is compared with
// it.  Three registers come out of that clk - completes anyway (fa_q: a write
// or an internal cycle), completes if the byte is there (fb_q: a read), the
// byte is there (fh_q) - and in the SECOND clk the core's clock enable is one
// gate behind them: ce_r | fa_q | (fb_q & fh_q).  Such a step is two clks, the
// step after a socket cycle included.  Everything else - a socket cycle, a
// near miss, an expansion bank, a forwarded or language-card write, $Cxxx,
// a vector pull, RDY low - is the sequencer as it was, deciding from the
// registered copy of the FULL decode (aq_*), which has two clks to settle:
// from the third clk.  Nothing is decoded ahead (pl_fresh is never set).
//   A miss is the "read not there yet" path (ml_*), the ONLY way the big
// memories ("far") are read: registered address, their data into alt_q, and
// the byte is also written into the near memory before the step ends.  The
// core's data is the near memory's byte or alt_q (far data, or the socket
// byte): one mux.  A local write is registered when the step is decided and
// made in the clk after, from registers, to both memories; a near entry
// written at or after the launch of the read that follows it is not used
// (nl_ok).  So the far memories are reached and left only through registers
// and can be placed anywhere, and the near memory never holds anything the far
// memory does not, whatever the map does (a tag names a physical byte, not an
// address).  A miss costs wall time, never a step.
//
//   One physical byte must live under one index.  The only local bytes with
// two addresses that differ below A14 are $C000-$CFFF of banks 00/01: the
// language card's bank 1 (read and written as $Dxxx) and, with I/O and
// language-card shadowing inhibited, plain RAM at $Cxxx.  They are kept under
// the $Dxxx index only: a write through $Cxxx goes to that entry, a read
// through $Cxxx is always served by the far memory.
//
module gs_accel_broker #(
    parameter int          STEP_CLKS = 4,            // fast mode: clks per local step (>= ADDR_CLKS + 1)
    parameter int          ADDR_CLKS = 1,            // clks from the step edge to the memory / request strobe
    parameter int          SLOW_CLKS = 3,            // DATA_LATE: ... for a step whose decode was not registered ahead (>= 2, >= ADDR_CLKS)
    parameter logic [23:0] PARK_ADDR = 24'hFF0000,   // idle-cycle read address (must be ROM)
    parameter bit          DATA_LATE = 1'b0,         // 1 = launch the next step's read one step ahead (needs cpu_na_i)
    parameter int          RA_COPIES = 1,            // copies of the two memories' read addresses (one per group of blocks a
                                                     // build places together; each copy has its own last mux)
    parameter int          CE_COPIES = 1,            // extra copies of the core's clock enable (F65C816 CE_X)
    parameter bit          NEAR      = 1'b0,         // 1 = near memory and the two-clk step (needs DATA_LATE, ADDR_CLKS = 2)
    parameter int          NEAR_AW   = 14,           // ... its index bits (>= 14: the tag starts at A14)
    parameter int          NEAR_KW   = 10,           // ... RAM address bits above the index its tag holds (4..10;
                                                     //     10 = all 24 bits; fewer: banks out of reach are never cached)
    parameter bit          ROM3      = 1'b0,         // 0 = ROM 01 machine, 1 = ROM 3
    parameter bit          WEN_ONE   = 1'b0,         // lm_wen_o's copies are registered again by what takes them: all from one register
    parameter bit          SOCK_PRE  = 1'b1,         // NEAR, fast mode: raise the request of a step that is certainly a
                                                     // socket cycle in its first clk (0 = at the strobe, for comparison)
    parameter int          FAR_CLKS  = 1,            // NEAR: clks from the far memories' read ports to alt_q (1 or 2).  With 2
                                                     // a far read waits a clk longer and the data is not looked at in the
                                                     // clk after its launch: a two-clk path, the blocks can be anywhere
    parameter bit          EXP_WAIT  = 1'b0,         // NEAR: the expansion banks are in a memory that makes a far read wait
                                                     // (lm_rwait_i).  A fast step waits in place; a native step's socket
                                                     // cycle is not taken as complete until the byte is there (the cycle,
                                                     // a read of RAM, is issued again meanwhile)
    parameter bit          NEAR_SPLIT = 1'b0         // NEAR, NEAR_KW > 4: the tag's address bits above the low four are read a
                                                     // clk after the rest, at the step's own address (nm_ren_hi_o), and a
                                                     // tag with one of them set is marked in the low part - see nm_tag
) (
    input  logic        clk,
    input  logic        rst_n,

    // control (quasi-static; taken at step boundaries)
    input  logic        native_i,        // 1 = PHI2-paced, every step a socket cycle (S6)
    input  logic        mem_bypass_i,    // native only: 1 = read data from the socket for everything
    input  logic        cxrom_local_i,   // replica: internal $C100-$CFFF firmware served locally
    input  logic [6:0]  exp_banks_i,     // replica: expansion banks backed by the card

    // hold (clk domain; for whatever loads the card's memories through the socket:
    // the ROM image).  With hold_i the core is not stepped past the step in progress.
    // While it is held (held_o) the socket's idle cycles are reads of idle_a_i
    // instead of PARK_ADDR, and each one that completes is reported: idle_stb_o for
    // one clk, the byte on idle_d_o.  With nm_flush_i (only while held) the near
    // memory's entry nm_flush_idx_i is made empty.  The step that was held does not
    // use the near memory's byte.  Tie hold_i and nm_flush_i low if unused.
    input  logic        hold_i,
    input  logic [23:0] idle_a_i,
    output logic        held_o,
    output logic        idle_stb_o,
    output logic [7:0]  idle_d_o,
    input  logic        nm_flush_i,
    input  logic [NEAR_AW-1:0] nm_flush_idx_i,

    // PHY side (gs_socket_phy)
    input  logic        phy_enabled_i,   // enabled_o: the pins are ours
    input  logic        phy_running_i,   // running_o: /RES released (PH2 domain, changes at a fall)
    input  logic        phy_fall_evt_i,  // fall_evt_o
    input  logic        phy_issue_evt_i, // issue_evt_o: the PHY registers the cycle in this clk
    output logic [23:0] phy_a_o,         // -> cpu_a_i
    output logic [7:0]  phy_d_out_o,     // -> cpu_d_out_i
    output logic        phy_we_n_o,      // -> cpu_we_n_i (1 = read)
    output logic        phy_vpa_o,
    output logic        phy_vda_o,
    output logic        phy_vp_n_o,

    // socket pads, sampled here at the PHI2 fall
    input  logic        gs_ph2_i,
    input  logic [7:0]  gs_d_i,
    input  logic        gs_rdy_i,
    input  logic        gs_irq_n_i,
    input  logic        gs_nmi_n_i,
    input  logic        gs_abort_n_i,

    // core side (P65C816 / F65C816 port list; tie the core's RDY_IN high)
    output logic        cpu_rst_n_o,
    output logic        cpu_ce_o,
    output logic [CE_COPIES-1:0] cpu_ce_c_o,     // the same, CE_COPIES more registers
    output logic [7:0]  cpu_d_in_o,
    output logic        cpu_irq_n_o,
    output logic        cpu_nmi_n_o,
    output logic        cpu_abort_n_o,
    input  logic [23:0] cpu_a_i,
    input  logic [7:0]  cpu_d_out_i,
    input  logic        cpu_we_n_i,      // 1 = read
    input  logic        cpu_vpa_i,
    input  logic        cpu_vda_i,
    input  logic        cpu_vp_n_i,
    input  logic [23:0] cpu_na_i,        // F65C816.NA_OUT: address of the next step (tie 0 without DATA_LATE)
    input  logic [2:0]  cpu_nst_i,       // F65C816.NST_OUT: its bus status {VPB, WE (1 = read), internal}
    input  logic        cpu_rdy_i,       // the core's RDY_OUT: in a clk with cpu_ce_o, the core takes the step
                                         // (it does not while it waits in WAI / STP); tie 1 without DATA_LATE

    // local memory, synchronous.  Read: lm_ren_o registers the addresses and
    // the memories read; the data is valid from the next clk and held until
    // the next lm_ren_o.  Write: RAM only, at lm_wen_o; never in the same clk
    // as a read launch.
    output logic [RA_COPIES-1:0] lm_ren_o,          // (RA_COPIES identical copies, registers with DATA_LATE)
    output logic [RA_COPIES*17-1:0] lm_ram_ra_o,   // read address of the bank-00/01 RAM (RA_COPIES identical copies)
    output logic [RA_COPIES*18-1:0] lm_rom_ra_o,   // read address of the ROM image
    output logic [23:0] lm_raddr_o,      // RAM physical address, all banks (expansion memory)
    input  logic [7:0]  lm_ram_rdata_i,
    input  logic [7:0]  lm_rom_rdata_i,
    output logic [RA_COPIES-1:0] lm_wen_o,          // (likewise)
    output logic [23:0] lm_waddr_o,
    output logic [7:0]  lm_wdata_o,

    // near memory (NEAR), synchronous, two ports.  Read: nm_ren_o (= the core's
    // clock enable) registers nm_ra_o (the core's next address, low bits) and
    // the entry there is valid from the next clk until the next nm_ren_o.
    // Write: at nm_wen_o, from registers.  A launch in the clk of a write to the
    // same index is not used.  Its tags must power up all ones (no entry).
    output logic                 nm_ren_o,
    output logic [NEAR_AW-1:0]   nm_ra_o,
    input  logic [7:0]           nm_rdata_i,
    input  logic [NEAR_KW+1:0]   nm_rtag_i,
    output logic                 nm_wen_o,
    output logic [NEAR_AW-1:0]   nm_wa_o,
    output logic [7:0]           nm_wdata_o,
    output logic [NEAR_KW+1:0]   nm_wtag_o,
    // (NEAR_SPLIT) nm_rtag_i[NEAR_KW-1:4] is read by nm_ren_hi_o at nm_ra_hi_o, in the
    // first clk of the step the launch was for, and is valid from its second.
    output logic                 nm_ren_hi_o,
    output logic [NEAR_AW-1:0]   nm_ra_hi_o,

    // expansion memory behind the far path, of any latency (NEAR, FAR_CLKS = 2; tie
    // the two inputs low if unused).  lm_rexp_o with lm_ren_o: the read launched is of
    // RAM above bank 01 (lm_raddr_o), not of the ROM image.  lm_rwait_i, from the clk
    // after such a launch: the byte is not there yet; in the clk it is low the byte is
    // valid at lm_ram_rdata_i from the next clk on, as a far read's is in its second
    // clk.  lm_wbusy_i: the memory's write queue is nearly full - fast-mode steps that
    // are not the cheap view's wait at the strobe (each may still make its one write).
    output logic                 lm_rexp_o,
    input  logic                 lm_rwait_i,
    input  logic                 lm_wbusy_i,

    // status / telemetry (clk domain)
    output logic        fast_o,          // the step in progress is a fast-mode step
    output logic        step_evt_o,      // = cpu_ce_o: one core step
    output logic        sock_evt_o,      // a non-idle socket cycle completed
    output logic        sock_idle_o,     // the cycle the PHY issued last is an idle cycle
    output logic        pw_busy_o,       // a posted write is waiting or on the bus
    output logic        verify_miss_o,   // native, card memory of record: local byte != socket byte
    output logic [23:0] verify_addr_o,   // address of the last mismatch
    output logic [15:0] verify_count_o,
    output logic [31:0] stat_steps_o,    // core steps
    output logic [31:0] stat_sock_o,     // socket cycles run for the core (reads, synchronous writes)
    output logic [31:0] stat_posted_o,   // posted writes completed
    output logic [31:0] stat_pwwait_o,   // clks a forwarded write waited for the buffer
    output logic [31:0] stat_rd_hit_o,   // local reads whose data and select were already in place
    output logic [31:0] stat_rd_miss_o,  // local reads that launched or re-selected at the strobe and waited
    output logic [7:0]  shadow_o,        // replica state
    output logic [7:0]  cyareg_o,
    output logic [7:0]  sltromsel_o,
    output logic [7:0]  statereg_o,
    output logic [7:0]  sw_misc_o
);

    //=========================================================================
    // PH2 domain: the pads at the fall
    //=========================================================================
    logic [7:0] d_f     = 8'h00;
    logic       rdy_f   = 1'b1;
    logic       irq_f   = 1'b1;
    logic       nmi_f   = 1'b1;
    logic       abort_f = 1'b1;

    always_ff @(negedge gs_ph2_i) begin
        d_f     <= gs_d_i;
        rdy_f   <= gs_rdy_i;
        irq_f   <= gs_irq_n_i;
        nmi_f   <= gs_nmi_n_i;
        abort_f <= gs_abort_n_i;
    end

    // clk-domain copies, loaded at the fall event; in the fall-event clk
    // itself the PH2-domain flops are read directly (they have been stable
    // for at least a clk), so a native step sees the pads of ITS fall.
    logic rdy_c, irq_c, nmi_c, abort_c;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdy_c <= 1'b1; irq_c <= 1'b1; nmi_c <= 1'b1; abort_c <= 1'b1;
        end else if (phy_fall_evt_i) begin
            rdy_c <= rdy_f; irq_c <= irq_f; nmi_c <= nmi_f; abort_c <= abort_f;
        end
    end

    // rdy_c and "the expansion memory's write queue has room" (EXP_WAIT; lm_wbusy_i is
    // a register that is a clk and more behind the queue already, and its margin is
    // entries, not clks) as one register, for the strobe.  The queue does not hold a
    // step whose socket request was raised ahead (pre_q): that step writes nothing
    // to it, and its cycle may already be on the bus - held past the end of that
    // cycle the step would have it issued a second time.
    logic rw_c;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rw_c <= 1'b1;
        else        rw_c <= (phy_fall_evt_i ? rdy_f : rdy_c) & ~lm_wbusy_i;
    end

    // Fast mode takes the interrupt lines through ordinary two-flop
    // synchronisers instead: a sample that is up to a whole PHI2 cycle old
    // would still show /IRQ low after the handler's acknowledging write has
    // released it, and a core that runs a dozen local steps per PHI2 cycle
    // would reach RTI and take the same interrupt again.
    logic [1:0] irq_s, nmi_s, abort_s;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_s <= 2'b11; nmi_s <= 2'b11; abort_s <= 2'b11;
        end else begin
            irq_s   <= {irq_s[0],   gs_irq_n_i};
            nmi_s   <= {nmi_s[0],   gs_nmi_n_i};
            abort_s <= {abort_s[0], gs_abort_n_i};
        end
    end

    logic mode_native, mode_bypass;      // mode of the step in progress (below)
    // (a native step completes the clk after the fall event, when the clk-domain
    // copies hold the pads of its fall)
    // (near memory: ... and held from one core step to the next, irq_h below - the
    // core's next status hangs off the lines, and the step registers off that)
    // (near memory, native: irq_e - the PH2-domain flops registered in every clk,
    // like alt_q for the data byte.  They show the pads of a fall from the second
    // clk edge after it, the fall event is the clk after that and the step the clk
    // after the event: the same sample irq_c has at the step, two clks sooner.)
    logic irq_h, nmi_h, abort_h;
    logic irq_e, nmi_e, abort_e;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin irq_e <= 1'b1; nmi_e <= 1'b1; abort_e <= 1'b1; end
        else        begin irq_e <= irq_f; nmi_e <= nmi_f; abort_e <= abort_f; end
    end
    assign cpu_irq_n_o   = NEAR ? (mode_native ? irq_e   : irq_h)   : mode_native ? irq_c   : irq_s[1];
    assign cpu_nmi_n_o   = NEAR ? (mode_native ? nmi_e   : nmi_h)   : mode_native ? nmi_c   : nmi_s[1];
    assign cpu_abort_n_o = NEAR ? (mode_native ? abort_e : abort_h) : mode_native ? abort_c : abort_s[1];

    //=========================================================================
    // Reset: follow the PHY's view of /RES, re-registered at the fall event
    //=========================================================================
    logic run_c;
    logic run_rst /* synthesis syn_preserve = 1 */;     // its own copy for the core's reset net
    wire  run_now = phy_enabled_i & (phy_fall_evt_i ? phy_running_i : run_c);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin run_c <= 1'b0; run_rst <= 1'b0; end
        else        begin run_c <= run_now; run_rst <= run_now; end
    end
    assign cpu_rst_n_o = run_rst;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin irq_h <= 1'b1; nmi_h <= 1'b1; abort_h <= 1'b1; end
        else if (!run_now | cpu_ce_o) begin irq_h <= irq_s[1]; nmi_h <= nmi_s[1]; abort_h <= abort_s[1]; end
    end

    // mode inputs: two flops, then taken at step boundaries
    logic [1:0] native_s, bypass_s;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            native_s <= 2'b11; bypass_s <= 2'b11;
        end else begin
            native_s <= {native_s[0], native_i};
            bypass_s <= {bypass_s[0], mem_bypass_i};
        end
    end

    //=========================================================================
    // The step in progress: effective access and its classification
    //=========================================================================
    typedef enum logic [1:0] { ST_RESET, ST_ADDR, ST_DATA, ST_SOCK } st_t;
    st_t         st;
    logic [3:0]  ph;                 // clks spent in ST_ADDR / left in ST_DATA
    logic        held_r;             // the core is held between two steps (st = ST_SOCK, no request)
    logic        fl_hold;            // the cycle the PHY issued last is an idle cycle of the hold
    logic [23:0] prev_addr;          // effective address of the previous step

    // internal cycle aimed at I/O space (the PHY's condition): repeat the
    // previous step's address as a read instead of presenting a new I/O
    // address the real chip would not have put on the bus
    // Live view, from the core's outputs of this step: what the replica's
    // direct decode and the cross-checks see.
    wire        internal_l = ~cpu_vpa_i & ~cpu_vda_i;
    wire        io_int_l   = internal_l & (cpu_a_i[15:8] == 8'hC0) &
                             ((cpu_a_i[23:17] == 7'd0) | (cpu_a_i[23:17] == 7'h70));
    wire [23:0] eff_addr_l = io_int_l ? prev_addr : cpu_a_i;
    wire        eff_we_l   = ~io_int_l & ~cpu_we_n_i;        // 1 = write

    // The view the sequencer runs the step with.  Two-edge step: the live one.
    // Data-late step: registers only - the status the core announced a step
    // ahead (cpu_nst_i, with the next address), taken every time the core
    // steps (pl_int, pl_we, pl_vp_n, pl_io_int).  Nothing the sequencer
    // decides hangs off the core's outputs within the step; only the address
    // and data it passes on do.  (A core waiting in WAI / STP does not take
    // the step: the status stands, and nothing is treated as decoded ahead.)
    logic        pl_fresh;
    logic        pl_int, pl_we, pl_vp_n, pl_io_int;
    wire         fresh_ok = DATA_LATE & pl_fresh & pl_vp_n & ~pl_io_int;
    wire         internal = !DATA_LATE ? internal_l : pl_int;
    wire         io_int   = !DATA_LATE ? io_int_l   : pl_io_int;
    wire         eff_we   = !DATA_LATE ? eff_we_l   : pl_we;
    // The step's effective address, from registers loaded when the core steps:
    // ea_r is the next address as the core gives it; a step that is an internal
    // cycle aimed at I/O space (pl_io_int) repeats the address of the step before
    // it, which ea_k keeps.  With the status registers it IS a data-late step's
    // socket request.  (The choice is made here, behind registers, and not in what
    // ea_r loads: that put the I/O-space compare of the core's next address, its
    // latest output, in front of 24 enables.)
    logic [23:0] ea_r, ea_k;
    logic        ea_kfi;             // ea_k is not in $Cxxx
    wire [23:0]  eff_addr = !DATA_LATE ? (io_int ? prev_addr : cpu_a_i) : pl_io_int ? ea_k : ea_r;
    // the next step's address aims an internal cycle at I/O space
    wire         nx_io_int = cpu_nst_i[0] & (cpu_na_i[15:8] == 8'hC0) &
                             ((cpu_na_i[23:17] == 7'd0) | (cpu_na_i[23:17] == 7'h70));

    logic [2:0]  r_region;
    logic [23:0] r_phys;
    logic [17:0] r_rom_addr;
    logic        r_local, r_fwd, r_local_we, r_local_rom, r_side;
    logic        r_fast_rw, r_fast_int_a, r_fast_rom, r_fast_aux, r_fast_fold, r_fast_exp, r_fast_sock;
    logic [1:0]  r_fast_rbank;
    logic [23:0] pf_phys;
    logic [17:0] pf_rom_addr;
    logic        pf_local, pf_local_rom, pf_side, pfw_local, pfw_local_we, pfw_fwd, sw_touch;
    logic [23:0] pfw_phys;
    logic [16:0] pf_ram_ra;
    logic [17:0] pf_rom_ra;
    logic        cyc_stb, cyc_stb_q;
    logic [23:0] fl_addr;
    logic        fl_we;
    logic [7:0]  fl_data;

    gs_mmu_replica #(.ROM3(ROM3)) u_replica (
        .clk(clk), .rst_n(rst_n), .sw_reset_i(~run_c),
        .cxrom_local_i(cxrom_local_i), .exp_banks_i(exp_banks_i),
        // data-late: the switches take a socket cycle's effect the clk after it completes
        // (the step that follows is decoded two clks later at the soonest), and the
        // direct decode is made from the registered status, not the core's outputs
        .cyc_stb_i(DATA_LATE ? cyc_stb_q : cyc_stb), .cyc_addr_i(fl_addr), .cyc_we_i(fl_we), .cyc_wdata_i(fl_data),
        .acc_addr_i(DATA_LATE ? eff_addr : eff_addr_l), .acc_we_i(DATA_LATE ? eff_we : eff_we_l),
        .acc_faddr_i(ea_r),
        .acc_vpb_n_i(DATA_LATE ? (pl_vp_n | pl_io_int) : (cpu_vp_n_i | io_int_l)),
        .acc_region_o(r_region), .acc_phys_o(r_phys), .acc_local_o(r_local),
        .acc_forward_write_o(r_fwd), .acc_local_we_o(r_local_we), .acc_local_rom_o(r_local_rom),
        .acc_rom_addr_o(r_rom_addr), .acc_side_effect_o(r_side),
        .acc_fast_rw_o(r_fast_rw), .acc_fast_int_o(r_fast_int_a), .acc_fast_rom_o(r_fast_rom),
        .acc_fast_rbank_o(r_fast_rbank), .acc_fast_aux_o(r_fast_aux), .acc_fast_fold_o(r_fast_fold),
        .acc_fast_exp_o(r_fast_exp), .acc_fast_sock_o(r_fast_sock),
        .pf_addr_i(cpu_na_i), .pf_phys_o(pf_phys), .pf_rom_addr_o(pf_rom_addr),
        .pf_local_o(pf_local), .pf_local_rom_o(pf_local_rom), .pf_side_o(pf_side),
        .pf_ram_ra_o(pf_ram_ra), .pf_rom_ra_o(pf_rom_ra),
        .pfw_phys_o(pfw_phys), .pfw_local_o(pfw_local), .pfw_local_we_o(pfw_local_we), .pfw_forward_o(pfw_fwd),
        .sw_touch_o(sw_touch),
        .shadow_o(shadow_o), .cyareg_o(cyareg_o), .sltromsel_o(sltromsel_o),
        .statereg_o(statereg_o), .misc_o(sw_misc_o)
    );

    // ---- the decode view the step is run with
    // Two-edge step: the replica's combinational decode (r_*), used at the strobe.
    // Data-late step: nothing the sequencer registers hangs off that decode
    // directly.  A step that follows a local step uses the decode of its own
    // address made a step ahead (pl_*: the replica's pf_ views of the core's
    // next-step address, as a read and as a write, registered at the launch);
    // any other step uses the registered copy of r_* (aq_*), which it gives
    // SLOW_CLKS - 1 clks to settle.  pl_* is the same function of the same
    // address and switch state as r_* as long as the switches have not been
    // touched since (sw_touch), the step is not a vector pull and its address
    // is not substituted (io_int) - cross-checked in simulation below.
    logic        pl_r_local, pl_r_rom, pl_side, pl_w_local, pl_w_we, pl_w_fwd;
    logic [23:0] pl_w_phys;
    logic        aq_local, aq_fwd, aq_local_we, aq_local_rom, aq_side, aq_hit;
    logic [23:0] aq_phys;
    logic [17:0] aq_rom_addr;
    logic [7:0]  cfg_q;
    logic        sw_touch_q;
    logic        ev_hit, ev_miss, ev_pww;    // statistics events, registered

    // (SLOW: clks from the core's step to a decision made from the registered copy)
    localparam int SLOW  = (SLOW_CLKS > ADDR_CLKS) ? ((SLOW_CLKS > 2) ? SLOW_CLKS : 2) : ((ADDR_CLKS > 2) ? ADDR_CLKS : 2);
    // In simulation the registered copy reads WRONG until it has had the clks its
    // timing contract gives it (aq_bad: fewer than SLOW - 1 clks since the core
    // stepped), so that anything that uses it sooner shows up as a failure instead
    // of working by the grace of a zero-delay decode.
    logic [3:0] sc;                                               // clks since the core stepped
    logic       aq_bad;
`ifdef VERILATOR
    assign aq_bad = DATA_LATE & (st != ST_RESET) & (sc < 4'(SLOW - 1));
`else
    assign aq_bad = 1'b0;
`endif
    wire        d_local     = !DATA_LATE ? r_local     : fresh_ok ? (eff_we ? pl_w_local : pl_r_local) : aq_local ^ aq_bad;
    wire        d_local_we  = !DATA_LATE ? r_local_we  : fresh_ok ? pl_w_we  : aq_local_we ^ aq_bad;
    wire        d_fwd       = !DATA_LATE ? r_fwd       : fresh_ok ? pl_w_fwd : aq_fwd ^ aq_bad;
    wire        d_local_rom = !DATA_LATE ? r_local_rom : fresh_ok ? pl_r_rom : aq_local_rom ^ aq_bad;
    wire        d_side      = !DATA_LATE ? r_side      : fresh_ok ? pl_side  : aq_side ^ aq_bad;
    wire [23:0] d_phys      = !DATA_LATE ? r_phys      : fresh_ok ? pl_w_phys : aq_phys ^ {24{aq_bad}};
    wire [17:0] d_rom_addr  = !DATA_LATE ? r_rom_addr  : aq_rom_addr ^ {18{aq_bad}};

    // what this step needs
    wire need_sock = mode_native | (internal ? d_side : ~d_local);
    wire lm_read   = ~internal & d_local & ~eff_we;
    wire lm_write  = ~internal & eff_we & d_local & d_local_we;
    wire post      = ~mode_native & ~internal & eff_we & d_fwd;
    wire use_lm    = lm_read & ~(mode_native & mode_bypass);
    wire ld_hit;                         // (assigned below)
    logic xw_r, xl_r, xq1, xq2;          // EXP_WAIT: a native step waits for its byte (below)

    //=========================================================================
    // Socket side: one request at a time, posted write first
    //=========================================================================
    typedef enum logic [1:0] { K_IDLE, K_SYNC, K_PW } kind_t;

    logic        sreq_valid;              // the step's own socket cycle
    logic [23:0] sreq_addr;
    logic        sreq_we, sreq_vpa, sreq_vda, sreq_vp_n;
    logic [7:0]  sreq_data;

    logic        pw_valid;                // one-deep posted-write buffer
    logic [23:0] pw_addr;
    logic [7:0]  pw_data;

    kind_t       fl_kind;                 // the cycle the PHY issued last
    logic        fl_busy;                 // ... and it has not completed
    logic        fl_run;                  // ... and the core was running when it was issued
    logic        fl_issue_q;              // the clk after an issue
                                          // (the PHY repeats a cycle on RDY low only then)

    kind_t sel;
    always_comb begin
        if (fl_busy)         sel = fl_kind;     // RDY held it: the PHY repeats it
        else if (pw_valid)   sel = K_PW;        // older than anything the core is waiting for
        else if (sreq_valid) sel = K_SYNC;
        else                 sel = K_IDLE;
    end

    // What goes to the PHY is picked by a registered one-hot copy of `sel`
    // (sel_pw_r / sel_sync_r, made from the next values of the four registers
    // above), so the path to the pin registers is one mux deep.
    logic sel_pw_r, sel_sync_r;
    always_comb begin
        unique case ({sel_pw_r, sel_sync_r})
            2'b10: begin
                phy_a_o = pw_addr;  phy_d_out_o = pw_data;  phy_we_n_o = 1'b0;
                phy_vpa_o = 1'b0;   phy_vda_o = 1'b1;       phy_vp_n_o = 1'b1;
            end
            2'b01: if (DATA_LATE) begin
                // (VPA / VDA: only "internal or not" matters to the PHY)
                // (ea_k: the effective address from a register - it is that from the
                // step's second clk, and the request is not raised before then)
                phy_a_o = ea_k;     phy_d_out_o = sreq_data;  phy_we_n_o = ~pl_we;
                phy_vpa_o = ~pl_io_int & ~pl_int;  phy_vda_o = pl_io_int | ~pl_int;
                phy_vp_n_o = pl_io_int | pl_vp_n;
            end else begin
                phy_a_o = sreq_addr; phy_d_out_o = sreq_data; phy_we_n_o = ~sreq_we;
                phy_vpa_o = sreq_vpa; phy_vda_o = sreq_vda;   phy_vp_n_o = sreq_vp_n;
            end
            default: begin
                // idle: park; while the core is in reset show its reset-state
                // address, as S6 does
                // (held: the address the hold asks for)
                phy_a_o = held_r ? idle_a_i : run_c ? PARK_ADDR : cpu_a_i;
                phy_d_out_o = 8'h00; phy_we_n_o = 1'b1;
                phy_vpa_o = 1'b0;    phy_vda_o = 1'b0;      phy_vp_n_o = 1'b1;
            end
        endcase
    end

    // (EXP_WAIT, native: not while the step's byte is still on its way from the
    // expansion memory - the cycle is then issued again, as after RDY low)
    // (The fall event comes through the PHY's synchroniser and a gate, and everything
    // the sequencer does at the end of a socket cycle is behind it.  What else these
    // need is registers, and none of them moves in the clk before a fall event: the
    // cycle in flight was issued a PHI2 cycle before, its step was decided - or
    // its read of expansion memory launched - within a few clks of that, and rdy_f
    // has been steady since the fall itself, two clks before the event.  So that
    // part is registered a clk ahead (*_arm) and the event is one gate from a
    // register.  The one input that moves at any time is xw_r, falling when the
    // byte arrives: a clk late here, the cycle is issued once more, as it would
    // have been had the byte come a clk later.  Checked at every fall event in
    // simulation.)
    wire  fl_ok    = fl_busy & (rdy_f | ~fl_run);
    wire  cd_arm_n = fl_ok & ~(xw_r & (fl_kind == K_SYNC));
    wire  sd_arm_n = fl_ok & ~xw_r & (fl_kind == K_SYNC) & (st == ST_SOCK);
    wire  pd_arm_n = fl_ok & (fl_kind == K_PW);
    logic cd_arm, sd_arm, pd_arm;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cd_arm <= 1'b0; sd_arm <= 1'b0; pd_arm <= 1'b0; end
        else        begin cd_arm <= cd_arm_n; sd_arm <= sd_arm_n; pd_arm <= pd_arm_n; end
    end
    wire cyc_done  = phy_fall_evt_i & cd_arm;                         // the issued cycle completed
    wire sync_done = phy_fall_evt_i & sd_arm;
    wire pw_done   = phy_fall_evt_i & pd_arm;
`ifdef VERILATOR
    always @(posedge clk) if (rst_n && phy_fall_evt_i) begin
        if (pd_arm !== pd_arm_n || (cd_arm !== cd_arm_n && !(cd_arm_n && !cd_arm && fl_kind == K_SYNC)) ||
            (sd_arm !== sd_arm_n && !(sd_arm_n && !sd_arm && !cd_arm))) begin
            $display("ERROR: broker: what a socket cycle's end depends on moved in the clk before the fall event (%b%b%b, now %b%b%b) @%0t",
                     cd_arm, sd_arm, pd_arm, cd_arm_n, sd_arm_n, pd_arm_n, $time);
            $finish;
        end
    end
`endif
    assign cyc_stb = cyc_done & (fl_kind != K_IDLE);

    //=========================================================================
    // Step sequencer
    //=========================================================================
    // strobe: the step's decision.  ADDR_CLKS into the step; in the data-late
    // step SLOW_CLKS for a fast-mode step whose decode was not registered
    // ahead (a native step needs no decode to go to the socket).  A forwarded
    // write waits for the buffer, a fast step waits while RDY is low.  Nothing
    // the broker's sequencer registers from the core's outputs is captured
    // before the strobe.  One exception: the PHY's issue point is two clks
    // after the core steps, so with ADDR_CLKS = 2 a native step's request is
    // registered a clk early, in the first clk of the step: its address (the
    // core's address register) and status (registers).  The write data follows
    // at the strobe; the PHY takes it a clk after the issue (WDATA_LATE).
    localparam int PH_ON = (STEP_CLKS > ADDR_CLKS + 1) ? STEP_CLKS - ADDR_CLKS - 1 : 0;   // clks left after a strobe at ADDR_CLKS
    localparam int PH_SL = (STEP_CLKS > SLOW + 2)      ? STEP_CLKS - SLOW - 2      : 0;   // ... at SLOW (+ 1 for a write)
    // (near memory: a write is made from registers, its address needs no clk of its own)
    wire [3:0] t_dec  = (!DATA_LATE | mode_native | fresh_ok) ? 4'(ADDR_CLKS - 1) :
                        (eff_we & ~NEAR) ? 4'(SLOW) : 4'(SLOW - 1);   // (a write's registered address: two clks to the RAM)
    // dec_ok: a register that is low in the first clk of a step and nowhere else.
    // With ADDR_CLKS >= 2 nothing is decided in that clk anyway (t_dec >= 1); the
    // explicit factor keeps every decision register's input steady while the
    // registers a step's decision is made from (two-clk paths) are still settling.
    logic dec_ok;
    wire  dec_g  = !(DATA_LATE && ADDR_CLKS >= 2) | dec_ok;
    // Near memory: the step was decided in its first clk from the cheap view (fa_q:
    // it completes; fb_q: it completes if its byte is in the near memory; fh_q: it
    // is) and completes in this, its second: fast_q.  The strobe is the other steps'
    // and never comes before the third clk in fast mode.
    logic fa_q, fb_q, fh_q;
    logic [CE_COPIES-1:0] fa_c /* synthesis syn_preserve = 1 */;
    logic [CE_COPIES-1:0] fb_c /* synthesis syn_preserve = 1 */;
    logic [CE_COPIES-1:0] fh_c /* synthesis syn_preserve = 1 */;
    wire  fast_q = fa_q | (fb_q & fh_q);
    logic pre_q;                 // the step's socket request was raised in its first clk (fast_pre, below)
    wire strobe = dec_g & (st == ST_ADDR) & (ph >= t_dec) &
                  ~(post & pw_valid) & (mode_native | rw_c | (rdy_c & pre_q));
    // a native step's request, registered in the first clk of the step (above)
    wire  nat_pre = DATA_LATE & (ADDR_CLKS >= 2) & mode_native & (st == ST_ADDR) & (ph == 4'd0);
    // Near memory, fast mode: the same for a step that is certainly a socket cycle
    // of its own address - a read or a write (not an internal cycle, not a vector
    // pull) in a bank that is never the card's (the cheap view's fast_sock, from
    // ea_r).  The sequencer's own decision comes in the third clk, a clk after the
    // PHY's issue point: a socket step right behind a socket step then found an
    // idle cycle already issued and waited a whole PHI2 cycle for the next one -
    // code or data in an expansion bank the card does not back, or in a Mega II
    // bank, ran at half the socket's rate.  Raised here, the request is the
    // registers a native step's is (ea_k, the status, the write data a clk after
    // the issue) and makes that issue point.  What the step does is unchanged: the
    // strobe still decides it from the full decode, which must agree (checked in
    // simulation), and no cycle reaches the socket that would not have.  RDY needs
    // no term here: while it is low the cycle on the bus is being repeated, so the
    // request cannot be issued before the fall that finds RDY high - the fall that
    // lets the strobe go, a clk later, long before the cycle can complete.
    wire  fast_pre = NEAR & SOCK_PRE & ~mode_native & (st == ST_ADDR) & (ph == 4'd0) &
                     r_fast_sock & ~pl_int & pl_vp_n;

    // mem_evt: the step's memory actions (the write, a read that has to be
    // launched now, the verify flag).  With the strobe - except in the
    // data-late native step, whose strobe comes before the decode it needs.
    wire  mem_evt = (DATA_LATE & mode_native) ? ((st != ST_RESET) & (sc == 4'(SLOW))) : strobe;

    logic use_lm_r, rom_r, vfy_r;

    // what the memories' output registers hold: the addresses of the last
    // launch, valid until a write (which may have changed that RAM byte)
    logic        ld_valid;
    logic [23:0] ld_phys;                 // expansion memory: physical address
    logic [16:0] ld_ram;                  // bank-00/01 RAM: the address it was read at
    logic [17:0] ld_rom;                  // ROM image: the address it was read at
    // (the comparison for a step that was not decoded ahead is made on the direct
    // decode and registered with its copy: aq_hit)
    wire  r_hit     = ld_valid & (r_local_rom       ? (ld_rom == r_rom_addr) :
                                  ~|r_phys[23:17]   ? (ld_ram == r_phys[16:0]) :
                                                      (ld_phys == r_phys));
    // near memory: tag = {ROM, A12 moved by the language card, address bits above the index}
    localparam int NTW = NEAR_KW + 2;
    function automatic logic [NTW-1:0] nm_tag(input logic rom, input logic [23:0] phys,
                                              input logic [3:0] romhi, input logic a12);
        // (NEAR_SPLIT: RAM above bank 03 - an address bit above A17 - is marked {1, 1}
        // where the ROM has {1, 0} and other RAM {0, A12 moved}.  Nothing moves A12 up
        // there, so the bit is free; and no tag of the cheap view has {1, 1}, so its
        // compare of the low part alone can never take such an entry for one of its own.)
        logic hi;
        hi = NEAR_SPLIT & (|phys[23:18]);
        nm_tag = rom ? {1'b1, 1'b0, NEAR_KW'(romhi)} :
                 hi  ? {2'b11, phys[14 +: NEAR_KW]} : {1'b0, phys[12] ^ a12, phys[14 +: NEAR_KW]};
    endfunction
    function automatic logic nm_far_only(input logic [23:0] phys);      // a RAM byte the tag cannot name
        nm_far_only = (NEAR_KW < 10) ? |(phys >> (14 + NEAR_KW)) : 1'b0;
    endfunction
    // An entry that holds nothing has a tag no byte has.  All ones, where that is one:
    // not with NEAR_SPLIT, where all ones is RAM in the top 16K of the last bank the tag
    // reaches (bank 7F with NEAR_KW = 9).  There the mark {1, 1} is only ever on RAM with
    // an address bit above A17, so {1, 1} with none of them is free: the empty entry, its
    // low four address bits ones.  (The cheap view never takes it: no tag of its own has
    // {1, 1}.  The memory that holds the entries must power up with it: gs_accel.)
    localparam logic [NTW-1:0] NM_EMPTY = NEAR_SPLIT ? NTW'((3 << NEAR_KW) | 15) : '1;
    logic              near_r;            // the core's data is the near memory's (else alt_q)
    logic [7:0]        alt_q;             // far-memory data or the socket byte, registered
    logic              fill_pend, fill_ok, nfill_r;
    logic [NEAR_AW-1:0] fill_idx;
    logic [NTW-1:0]    fill_tag;
    // The entry read against the step's own decode, in its first clk.  nl_ok: the
    // entry read at the launch is still what the near memory holds at that index
    // (no write to it at or since the launch) and the core took the step it was for.
    logic                 nl_ok;
    logic [NEAR_AW-1:0]   nl_idx;
    wire  [NTW-1:0]       r_tag  = r_local_rom ? nm_tag(1'b1, 24'd0, r_rom_addr[17:14], 1'b0)
                                               : nm_tag(1'b0, r_phys, 4'd0, eff_addr[12]);
    wire                  r_nc   = ~r_local_rom & (((eff_addr[15:12] == 4'hC) & ~|r_phys[23:17]) | nm_far_only(r_phys));
    // (a write to the launched index: the core's, in the clk after it was registered,
    // or a fill - compared register against register, not through the write port's mux)
    wire                  nl_wr;            // (assigned below, with the write registers)
    // (a write made in the very clk of the launch: its index is kept with the
    // launch's and compared in the step's first clk, not behind the core's next address)
    logic                 lw_r;
    logic [NEAR_AW-1:0]   lwa_r;
    wire                  nl_good = nl_ok & ~nl_wr & ~(lw_r & (lwa_r == nl_idx));
    // (NEAR_SPLIT: the high address bits of the entry are read a clk after the rest and
    // have one clk to nh_dq where the rest has two, so their compare is made on its
    // own, two gates deep, and joins the rest last - the nets are kept for that)
    localparam logic [NTW-1:0] NH_MASK = NEAR_SPLIT ? NTW'(((1 << NEAR_KW) - 1) & ~15) : '0;
    logic                 nh_lo /* synthesis syn_keep = 1 */;
    logic                 nh_hi /* synthesis syn_keep = 1 */;
    assign                nh_lo  = nl_good & ~r_nc & (((nm_rtag_i ^ r_tag) & ~NH_MASK) == '0);
    assign                nh_hi  = (((nm_rtag_i ^ r_tag) & NH_MASK) == '0);
    wire                  nh_d   = nh_lo & nh_hi;
    logic                 nh_dq;            // ... registered for the sequencer (the full decode's tag)
    // the cheap view's tag for the step: ROM bank and A14-A15, or RAM bank bit 0,
    // A14-A15 and the language-card fold (banks 00/01 only, never $Cxxx)
    // (the cheap view is of ea_r itself: a read or a write is never the repeated
    // address; an internal cycle that is has ea_r in $C0xx, and the cheap view of
    // the address it repeats is the one bit ea_kfi)
    wire                  r_fast_int = r_fast_int_a | (pl_io_int & ea_kfi);
    // (an expansion bank: the address itself - the cheap view gives no fold there,
    // and the bank's own bit 0.  Such a step is the cheap view's only where the whole
    // tag is compared in the first clk - not NEAR_SPLIT - and the tag can name the
    // byte.)
    wire                  f_xok  = !NEAR_SPLIT & ~nm_far_only(ea_r);
    wire  [23:0]          f_phys = {ea_r[23:17] & {7{r_fast_exp}}, r_fast_aux, ea_r[15:13], ea_r[12] ^ r_fast_fold, ea_r[11:0]};
    wire  [NTW-1:0]       f_tag_m = r_fast_rom ? nm_tag(1'b1, 24'd0, {r_fast_rbank, ea_r[15:14]}, 1'b0)
                                               : nm_tag(1'b0, f_phys, 4'd0, ea_r[12]);
    // The tag's address bits above A17 are the address's own in every step the cheap
    // view takes: a RAM step's as they stand (banks 00/01 have none), a ROM step's
    // none - its bank has bit 23 set, or is 00/01.  They are taken from the address
    // register and not through the cheap view: these are the bits a whole tag adds to
    // the first-clk compare, and they cost it a gate, not a decode.  (Checked below.)
    wire  [NTW-1:0]       f_tag;
    if (NEAR_KW > 4) begin : g_ft
        assign f_tag = {f_tag_m[NTW-1:NTW-2], ea_r[18 +: NEAR_KW-4] & {(NEAR_KW-4){~ea_r[23]}}, f_tag_m[3:0]};
    end else begin : g_ftm
        assign f_tag = f_tag_m;
    end
    // (near memory: the far memories' output registers are not reused - a write
    // may still be on its way to them when the next step is decoded)
    assign ld_hit   = NEAR ? ((nh_dq ^ aq_bad) & near_r) : (fresh_ok | (DATA_LATE ? aq_hit ^ aq_bad : r_hit));
    wire  rd_launch = lm_read & ~ld_hit;                          // this step's read is not there yet
    // data-late: the data-source select the step needs, against what was set
    // ahead.  It matters on steps whose data the core uses: reads.
    wire  rd_step   = ~internal & ~eff_we;
    // (near memory: a hit wants the near memory, a far read the right far memory
    // in alt_q, a socket read the socket byte in alt_q)
    wire  sel_ok    = !NEAR ? (fresh_ok | ((use_lm_r == use_lm) & (~use_lm | (rom_r == d_local_rom)))) :
                      (use_lm_r == use_lm) & (~use_lm ? ~near_r : ld_hit ? 1'b1 : (~near_r & (rom_r == d_local_rom)));
    wire  sel_fix   = DATA_LATE & rd_step & ~sel_ok;
    wire  rd_slow   = DATA_LATE & (rd_launch | (lm_read & ~sel_ok));   // a local read that has to wait

    // The core's clock enable is a register: a local step's is known a clk
    // ahead, a socket step completes the clk AFTER the PHI2 fall that ends its
    // cycle (the data byte then has three clks from the fall to the core).
    logic ce_r;
    logic [CE_COPIES-1:0] ce_c /* synthesis syn_preserve = 1 */;
    // (near memory: far data goes through alt_q, one clk more)
    wire [3:0] ph_i = rd_slow ? 4'(STEP_CLKS + int'(NEAR) + FAR_CLKS) : !DATA_LATE ? 4'(STEP_CLKS - ADDR_CLKS - 1) :
                      fresh_ok ? 4'(PH_ON) : 4'(PH_SL);           // clks a local step still takes after the strobe
    wire  local_ce  = ce_r & (st == ST_DATA);                     // a local step completes
    wire  pf_launch = DATA_LATE & local_ce;                       // launch the next step's read

    assign cpu_ce_o = ce_r | fast_q;
    assign cpu_ce_c_o = ce_c | fa_c | (fb_c & fh_c);
    wire  ce_n = sync_done | (strobe & ~need_sock & (ph_i == 4'd0)) | ((st == ST_DATA) & (ph == 4'd1));
    // Near memory: the first clk of the step.  The cheap view says the step is the
    // card's alone; a read also needs the entry launched for it to be the byte.
    wire  first     = (st == ST_ADDR) & (ph == 4'd0);
    // (a step in an expansion bank may write to the expansion memory: where such steps
    // are the cheap view's, every step of it waits for room in the queue, as at the
    // strobe - rw_c)
    wire  go_rdy    = NEAR_SPLIT ? rdy_c : rw_c;
    wire  go0       = NEAR & first & ~mode_native & go_rdy & use_lm_r & near_r &
                      (internal ? r_fast_int : (r_fast_rw & (f_xok | ~r_fast_exp)));
    wire  fa0       = go0 & (internal | eff_we);
    wire  fb0       = go0 & ~internal & ~eff_we;
    // (NEAR_SPLIT: the cheap view's tag has no address bit above the low four set, and an
    // entry that has one is marked in the low part - nm_tag - so the low part decides)
    wire  fh0       = nl_good & (!NEAR_SPLIT ? (nm_rtag_i == f_tag) :
                                 ({nm_rtag_i[NTW-1:NTW-2], nm_rtag_i[3:0]} == {f_tag[NTW-1:NTW-2], f_tag[3:0]}));
    wire [7:0] far_rdata = rom_r ? lm_rom_rdata_i : lm_ram_rdata_i;
    wire [7:0] lm_rdata  = !NEAR ? far_rdata : near_r ? nm_rdata_i : alt_q;
    assign cpu_d_in_o = NEAR ? lm_rdata : use_lm_r ? far_rdata : d_f;

    // a missing read: two-edge step - launched at the strobe from the decode;
    // data-late - its addresses are registered at mem_evt, presented to the
    // memories for two clks (ml_sel_r) and launched in the second (ml_go).
    // The memories' read address is otherwise always the next-step address,
    // so nothing switches it in the clk of an ordinary launch.
    logic        ml_sel_r, ml_go, ml_apply, ml_use, ml_romsel;
    logic        ml_isrom, rexp_r;           // the read being launched is of the ROM image; ... of expansion RAM
    logic [23:0] ml_phys;
    logic [17:0] ml_rom;
    // The read launch and the RAM write enable go to every block: with DATA_LATE they are
    // registers set the clk before, RA_COPIES of each.  (A launch does not depend on
    // the core taking the step; what is registered about it does.)
    logic                 ren_r, wen_r;
    logic [RA_COPIES-1:0] ren_c /* synthesis syn_preserve = 1 */;
    logic [RA_COPIES-1:0] wen_c /* synthesis syn_preserve = 1 */;
    wire  lm_ren   = DATA_LATE ? ren_r : (strobe & rd_launch);
    wire  ren_local = (strobe & ~need_sock & (ph_i == 4'd0)) | ((st == ST_DATA) & (ph == 4'd1));   // a local step completes
    wire  ren_ml    = ml_sel_r & ~ml_go;                                                           // a read launched late
    wire  ren_next  = NEAR ? ren_ml : (ren_local | ren_ml);    // (near memory: the launch ahead is the near memory's)
    assign lm_ren_o = DATA_LATE ? ren_c : {RA_COPIES{strobe & rd_launch}};
    assign lm_raddr_o  = !DATA_LATE ? r_phys            : (NEAR | ml_sel_r) ? ml_phys : pf_phys;
    // The memories are many blocks and their read-address nets are long: each
    // copy of the address has its own last mux (its own copy of the select
    // register, so the copies are not merged) for a build to place near its blocks.
    logic [RA_COPIES-1:0] ml_sel_c /* synthesis syn_preserve = 1 */;
    wire  [16:0] lm_ram_ra0 = !DATA_LATE ? r_phys[16:0] : (NEAR | ml_sel_r) ? ml_phys[16:0] : pf_ram_ra;
    wire  [17:0] lm_rom_ra0 = !DATA_LATE ? r_rom_addr   : (NEAR | ml_sel_r) ? ml_rom        : pf_rom_ra;
    for (genvar c = 0; c < RA_COPIES; c++) begin : g_ra
        assign lm_ram_ra_o[c*17 +: 17] = !DATA_LATE ? r_phys[16:0] : (NEAR | ml_sel_c[c]) ? ml_phys[16:0] : pf_ram_ra;
        assign lm_rom_ra_o[c*18 +: 18] = !DATA_LATE ? r_rom_addr   : (NEAR | ml_sel_c[c]) ? ml_rom        : pf_rom_ra;
    end

    // The RAM write.  Two-edge step: with the memory actions.  Data-late step
    // (ADDR_CLKS >= 2): at a fixed clk of the step - the second for a step decoded
    // ahead, the one after the registered decode is good otherwise - with the
    // enable a register set the clk before, so the enable net to the blocks has a
    // whole clk.  It does not wait for the strobe (a forwarded write waiting for
    // the buffer, a step held by RDY, still writes the card's memory once, then).
    // In native mode the socket cycle is the write of record and the card's copy
    // follows it: written when that cycle completes, so a step /RESET cuts short
    // writes neither memory and the copy cannot come apart from the motherboard.
    localparam bit WREG = DATA_LATE && (ADDR_CLKS >= 2);
    wire  wen_nat = sync_done & lm_write & run_now;      // (not the fall that finds /RES low: that cycle was not performed)
    // Near memory: registered in the step's second clk (the decode is good, the write
    // data has had the step), performed in the clk after from registers (wa_r ...):
    // the first clk of the next step if this one completed at once.
    logic [23:0]        wa_r;
    logic [7:0]         wd_r;
    logic [NEAR_AW-1:0] widx_r;
    logic [NTW-1:0]     wtag_r;
    // (a step of the cheap view: in its second clk, with the cheap view's address;
    // any other: in the clk the registered decode is good)
    wire  wen_fast = fast_q & eff_we & ~internal;
    wire  wen_set = mode_native ? wen_nat :
                    NEAR ? (wen_fast | ((st == ST_ADDR) & (ph == 4'(SLOW - 1)) & lm_write)) :
                    ((st != ST_RESET) & ~cpu_ce_o & lm_write &
                     (sc == (fresh_ok ? 4'(ADDR_CLKS - 2) : 4'(SLOW - 1))));
    wire   lm_wen         = WREG ? wen_r : mode_native ? wen_nat : (mem_evt & lm_write);
    assign lm_wen_o       = !WREG ? {RA_COPIES{lm_wen}} : WEN_ONE ? {RA_COPIES{wen_r}} : wen_c;
    assign nl_wr          = (lm_wen & (widx_r == nl_idx)) | (nfill_r & (fill_idx == nl_idx));
    assign lm_waddr_o     = NEAR ? wa_r : d_phys;
    assign lm_wdata_o     = NEAR ? wd_r : cpu_d_out_i;

    // Near memory ports.  A write of the core's goes to the byte's entry (for RAM
    // at $Cxxx of banks 00/01 that is the $Dxxx one); a far read that completes
    // fills its entry the clk before the step ends (alt_q has been good since the
    // clk before that), unless the byte is never served from the near memory.
    wire                w_calias = (eff_addr[15:12] == 4'hC) & ~|d_phys[23:17];
    wire [NEAR_AW-1:0]  w_idx    = {eff_addr[NEAR_AW-1:13], eff_addr[12] | w_calias, eff_addr[11:0]};
    wire [NTW-1:0]      w_tag    = nm_far_only(d_phys) ? NM_EMPTY : nm_tag(1'b0, d_phys, 4'd0, w_idx[12]);
    assign nm_ren_o   = NEAR & cpu_ce_o;
    assign nm_ra_o    = cpu_na_i[NEAR_AW-1:0];
    // (held, nm_flush_i: the entry is made empty)
    wire   nm_flush   = nm_flush_i & held_r;
    assign nm_wen_o   = NEAR & (lm_wen | nfill_r | nm_flush);
    assign nm_wa_o    = nm_flush ? nm_flush_idx_i : nfill_r ? fill_idx : widx_r;
    assign nm_wtag_o  = nm_flush ? NM_EMPTY : nfill_r ? fill_tag : wtag_r;
    assign nm_wdata_o = nfill_r ? alt_q    : wd_r;

    // next values of the registers `sel` is made of (the same as in the block below;
    // compared with `sel` every clk in simulation)
    wire   pw_done_w    = pw_done;
    wire   fl_busy_n    = !run_now ? (phy_issue_evt_i | (fl_busy & ~phy_fall_evt_i))
                                   : (~cyc_done & (phy_issue_evt_i | fl_busy));
    kind_t fl_kind_n;
    assign fl_kind_n    = !phy_issue_evt_i ? fl_kind : run_now ? sel : K_IDLE;
    wire   pw_valid_n   = run_now & ((strobe & post) | (pw_valid & ~pw_done_w));
    wire   sreq_valid_n = run_now & ~cpu_ce_o & (nat_pre | fast_pre | (strobe & need_sock) | sreq_valid);
    kind_t sel_n;
    assign sel_n        = fl_busy_n ? fl_kind_n : pw_valid_n ? K_PW : sreq_valid_n ? K_SYNC : K_IDLE;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sel_pw_r <= 1'b0; sel_sync_r <= 1'b0; cyc_stb_q <= 1'b0; dec_ok <= 1'b1; end
        else begin
            dec_ok     <= ~cpu_ce_o;
            sel_pw_r   <= (sel_n == K_PW);
            sel_sync_r <= (sel_n == K_SYNC);
            cyc_stb_q  <= cyc_stb;
        end
    end

    // ea_r and the next step's status: loaded at every step the core takes.  Out of
    // reset: the core's address, and the status of its first step - a read, not
    // internal.  (On run_c, the registered view of the reset, not run_now: these
    // registers then hang off the core alone and not off the PHY's fall event too.
    // They are a clk later into their reset values than the sequencer, in a clk in
    // which nothing uses them.)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ea_r <= '0;
            pl_int <= 1'b0; pl_we <= 1'b0; pl_vp_n <= 1'b1; pl_io_int <= 1'b0;
        end else if (!run_c) begin
            ea_r <= cpu_a_i;
            pl_int <= 1'b0; pl_we <= 1'b0; pl_vp_n <= 1'b1; pl_io_int <= 1'b0;
        end else if (DATA_LATE & cpu_ce_o & cpu_rdy_i) begin
            ea_r      <= cpu_na_i;
            pl_int    <= cpu_nst_i[0];
            pl_we     <= ~cpu_nst_i[1] & ~nx_io_int;
            pl_vp_n   <= cpu_nst_i[2];
            pl_io_int <= nx_io_int;
        end
    end
    // ea_k follows the effective address in every clk, with no enable: in a step
    // that repeats an address that is ea_k itself (a run of internal cycles aimed at
    // I/O space keeps repeating the address before the first of them), in any other
    // it is ea_r, a clk behind - and a step is never shorter than two clks.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin ea_k <= '0; ea_kfi <= 1'b0; end
        else        begin ea_k <= eff_addr; ea_kfi <= (eff_addr[15:12] != 4'hC); end
    end

    // Registers that only carry data, each qualified by a flag the block below
    // clears in reset (pl_fresh, ld_valid, ml_sel_r): kept out of that block so
    // that its reset condition is not on their enables.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ld_phys <= '0; ld_ram <= '0; ld_rom <= '0; ml_phys <= '0; ml_rom <= '0; ml_isrom <= 1'b0;
            pl_r_local <= 1'b0; pl_r_rom <= 1'b0; pl_side <= 1'b0;
            pl_w_local <= 1'b0; pl_w_we <= 1'b0; pl_w_fwd <= 1'b0; pl_w_phys <= '0;
            aq_local <= 1'b0; aq_fwd <= 1'b0; aq_local_we <= 1'b0; aq_local_rom <= 1'b0; aq_side <= 1'b0;
            aq_phys <= '0; aq_rom_addr <= '0; aq_hit <= 1'b0;
            alt_q <= '0;
            fill_idx <= '0; fill_tag <= '0; fill_ok <= 1'b0;
            wa_r <= '0; wd_r <= '0; widx_r <= '0; wtag_r <= '0; nl_idx <= '0; lw_r <= 1'b0; lwa_r <= '0;
        end else begin
            // the decode of the next step, registered with the launch of its read
            if (pf_launch) begin
                pl_r_local <= pf_local;   pl_r_rom <= pf_local_rom;   pl_side  <= pf_side;
                pl_w_local <= pfw_local;  pl_w_we  <= pfw_local_we;   pl_w_fwd <= pfw_fwd;
                pl_w_phys  <= pfw_phys;
            end
            // the registered copy of the combinational decode
            if (DATA_LATE) begin
                aq_local <= r_local; aq_fwd <= r_fwd; aq_local_we <= r_local_we;
                aq_local_rom <= r_local_rom; aq_side <= r_side;
                aq_phys <= r_phys; aq_rom_addr <= r_rom_addr; aq_hit <= r_hit;
            end
            // the addresses of a read that was not launched ahead (near memory: one
            // it did not have), and its near-memory entry
            if (DATA_LATE & mem_evt & rd_launch) begin
                ml_phys  <= d_phys;
                ml_rom   <= d_rom_addr;
                ml_isrom <= d_local_rom;
                fill_idx <= eff_addr[NEAR_AW-1:0];
                fill_tag <= nm_tag(d_local_rom, d_phys, d_rom_addr[17:14], eff_addr[12]);
                fill_ok  <= ~(~d_local_rom & (((eff_addr[15:12] == 4'hC) & ~|d_phys[23:17]) | nm_far_only(d_phys)));
            end
            // the core's other data source: far memory data, or the socket byte (d_f:
            // PHI2-fall flops, steady for a clk and more before the core takes it)
            alt_q <= use_lm_r ? far_rdata : d_f;
            // (loaded in every clk: they are used in the clk after wen_set alone, with
            // wen_r, so the write decision - the PHY's fall event in native mode, the
            // sequencer otherwise - is on one register and not on these enables)
            if (NEAR) begin
                wd_r <= cpu_d_out_i;
                if (wen_fast) begin wa_r <= f_phys; widx_r <= ea_r[NEAR_AW-1:0];     wtag_r <= f_tag; end
                else          begin wa_r <= d_phys; widx_r <= w_idx;                 wtag_r <= w_tag; end
            end
            if (NEAR & cpu_ce_o) begin
                nl_idx <= cpu_na_i[NEAR_AW-1:0];
                lw_r   <= nm_wen_o;
                lwa_r  <= nm_wa_o;
            end
            // what the memories' output registers hold
            if (lm_ren) begin
                ld_phys <= lm_raddr_o;
                ld_ram  <= lm_ram_ra0;
                ld_rom  <= lm_rom_ra0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_RESET; ph <= '0;
            mode_native <= 1'b1; mode_bypass <= 1'b1;
            prev_addr <= '0;
            sreq_valid <= 1'b0; sreq_addr <= '0; sreq_we <= 1'b0; sreq_data <= '0;
            sreq_vpa <= 1'b0; sreq_vda <= 1'b0; sreq_vp_n <= 1'b1;
            pw_valid <= 1'b0; pw_addr <= '0; pw_data <= '0;
            fl_kind <= K_IDLE; fl_busy <= 1'b0; fl_run <= 1'b0; fl_issue_q <= 1'b0;
            fl_addr <= '0; fl_we <= 1'b0; fl_data <= '0;
            held_r <= 1'b0; fl_hold <= 1'b0; pre_q <= 1'b0;
            xw_r <= 1'b0; xl_r <= 1'b0; xq1 <= 1'b0; xq2 <= 1'b0;
            use_lm_r <= 1'b0; rom_r <= 1'b0; vfy_r <= 1'b0;
            ld_valid <= 1'b0;
            ml_go <= 1'b0; ml_sel_r <= 1'b0; ml_sel_c <= '0; wen_r <= 1'b0; wen_c <= '0; ren_r <= 1'b0; ren_c <= '0; rexp_r <= 1'b0;
            ml_apply <= 1'b0; ml_use <= 1'b0; ml_romsel <= 1'b0;
            ce_r <= 1'b0; ce_c <= '0; sc <= '0; pl_fresh <= 1'b0; cfg_q <= '0; sw_touch_q <= 1'b0;
            ev_hit <= 1'b0; ev_miss <= 1'b0; ev_pww <= 1'b0;
            near_r <= 1'b0; fill_pend <= 1'b0; nfill_r <= 1'b0;
            fa_q <= 1'b0; fb_q <= 1'b0; fh_q <= 1'b0; fa_c <= '0; fb_c <= '0; fh_c <= '0; nh_dq <= 1'b0; nl_ok <= 1'b0;
        end else if (!run_now) begin
            // core in reset (or the socket is not ours): nothing pending
            st <= ST_RESET; ph <= '0;
            mode_native <= native_s[1]; mode_bypass <= bypass_s[1];
            prev_addr <= cpu_a_i;
            sreq_valid <= 1'b0; pw_valid <= 1'b0;
            use_lm_r <= 1'b0; vfy_r <= 1'b0;
            ld_valid <= 1'b0; ml_go <= 1'b0; ml_sel_r <= 1'b0; ml_sel_c <= '0; ml_apply <= 1'b0;
            // (near memory: a write registered in this very clk is still made - its step may
            // be completing now; if it is not, it is a write of a step /RESET cuts short)
            wen_r <= NEAR & wen_set;  wen_c <= WEN_ONE ? '0 : {RA_COPIES{NEAR & wen_set}};
            ren_r <= 1'b0; ren_c <= '0; rexp_r <= 1'b0;
            fa_q <= 1'b0; fb_q <= 1'b0; fh_q <= 1'b0; fa_c <= '0; fb_c <= '0; fh_c <= '0; nh_dq <= 1'b0; nl_ok <= 1'b0;
            ce_r <= 1'b0; ce_c <= '0; sc <= '0; pl_fresh <= 1'b0; sw_touch_q <= 1'b0;
            ev_hit <= 1'b0; ev_miss <= 1'b0; ev_pww <= 1'b0;
            near_r <= 1'b0; fill_pend <= 1'b0; nfill_r <= 1'b0;
            held_r <= 1'b0; fl_hold <= 1'b0; pre_q <= 1'b0;
            xw_r <= 1'b0; xl_r <= 1'b0; xq1 <= 1'b0; xq2 <= 1'b0;
            // the PHY keeps issuing (idle) cycles during reset
            if (phy_issue_evt_i) begin fl_kind <= K_IDLE; fl_busy <= 1'b1; fl_run <= 1'b0; end
            else if (phy_fall_evt_i) fl_busy <= 1'b0;
        end else begin
            // ---- socket bookkeeping
            if (phy_issue_evt_i) begin
                fl_kind <= sel;
                fl_busy <= 1'b1;
                fl_run  <= 1'b1;
                fl_hold <= held_r & (sel == K_IDLE);
                fl_addr <= phy_a_o;
                fl_we   <= ~phy_we_n_o;
                fl_data <= phy_d_out_o;
            end
            // (a native step's write data is registered in the issue clk itself and the
            // PHY takes it a clk later: so does this record of what went out)
            fl_issue_q <= phy_issue_evt_i;
            if (fl_issue_q) fl_data <= phy_d_out_o;
            if (cyc_done) fl_busy <= 1'b0;
            if (pw_done)  pw_valid <= 1'b0;

            ml_go    <= ml_sel_r & ~ml_go;
            ml_sel_r <= ml_sel_r & ~ml_go;
            ml_sel_c <= NEAR ? '0 : {RA_COPIES{ml_sel_r & ~ml_go}};   // (near memory: the address is ml_phys always, nothing selects)
            wen_r    <= WREG & wen_set;
            wen_c    <= WEN_ONE ? '0 : {RA_COPIES{WREG & wen_set}};
            ren_r    <= DATA_LATE & ren_next;
            ren_c    <= {RA_COPIES{DATA_LATE & ren_next}};
            rexp_r   <= NEAR & ren_next & ~ml_isrom & (|ml_phys[23:17]) & ~(mode_native & mode_bypass);
            fa_q     <= fa0;  fa_c <= {CE_COPIES{fa0}};
            fb_q     <= fb0;  fb_c <= {CE_COPIES{fb0}};
            fh_q     <= fh0;  fh_c <= {CE_COPIES{fh0}};
            nh_dq    <= nh_d;
            // what the near memory's output register holds: good from a launch the
            // core took, until that index is written
            if (cpu_ce_o)                                  nl_ok <= NEAR & cpu_rdy_i;
            else if (NEAR & (nl_wr | held_r))              nl_ok <= 1'b0;
            nfill_r  <= NEAR & fill_pend & fill_ok & (st == ST_DATA) & (ph == 4'd2);
            if (nfill_r | cpu_ce_o) fill_pend <= 1'b0;
            ml_apply <= 1'b0;
            sc       <= cpu_ce_o ? 4'd0 : (sc != 4'd15) ? sc + 4'd1 : sc;
            sw_touch_q <= sw_touch;
            ce_r     <= ce_n;
            ce_c     <= {CE_COPIES{ce_n}};

            // data-late: at the launch of the next step's read, the decode of
            // that step and its data-source select are registered with it; the
            // select is otherwise corrected one clk after mem_evt
            if (NEAR ? cpu_ce_o : pf_launch) begin
                // (near memory: every step starts on the near memory, whatever it turns out to need)
                use_lm_r   <= (NEAR | pf_local) & ~(native_s[1] & bypass_s[1]);
                if (!NEAR) rom_r <= pf_local_rom;
                near_r     <= NEAR & ~(native_s[1] & bypass_s[1]);
            end else if (ml_apply) begin
                use_lm_r <= ml_use;
                rom_r    <= ml_romsel;
                near_r   <= 1'b0;
            end
            // ... and is good for the one step that follows, unless the map is touched
            // or the core did not take the step
            cfg_q <= {cxrom_local_i, exp_banks_i};
            if (sw_touch_q | (cfg_q != {cxrom_local_i, exp_banks_i})) pl_fresh <= 1'b0;
            else if (pf_launch)                                     pl_fresh <= cpu_rdy_i & ~NEAR;
            else if (cpu_ce_o)                                      pl_fresh <= 1'b0;
            // (the next step's status: with ea_r, above)

            ev_hit  <= (mem_evt & lm_read & ~(DATA_LATE ? rd_slow : rd_launch)) | (fast_q & ~internal & ~eff_we);
            ev_miss <= mem_evt & lm_read &  (DATA_LATE ? rd_slow : rd_launch);
            ev_pww  <= dec_g & (st == ST_ADDR) & (ph >= t_dec) & post & pw_valid;

            // ---- memory actions of the step
            if (mem_evt) begin
                vfy_r <= mode_native & ~mode_bypass & lm_read;
                if (DATA_LATE) begin
                    if (rd_launch) begin
                        ml_sel_r <= 1'b1;
                        if (!NEAR) ml_sel_c <= '1;
                        fill_pend <= NEAR;
                    end
                    if (sel_fix) begin
                        ml_apply  <= 1'b1;
                        ml_use    <= use_lm;
                        ml_romsel <= d_local_rom;
                    end
                end
            end

            // ---- EXP_WAIT, native (card memory of record): the step's read of expansion
            // RAM is launched like any far read; its socket cycle may not complete until
            // the byte has been in alt_q for a clk (rwait low, then two clks)
            // (set in the clk the launch is registered, from the same registers)
            if (EXP_WAIT & mode_native & NEAR & ren_next & ~ml_isrom & (|ml_phys[23:17]) & ~mode_bypass) xw_r <= 1'b1;
            if (rexp_r) xl_r <= 1'b1;
            xq1 <= xl_r & ~lm_rwait_i;
            xq2 <= xq1;
            if (xq2) xw_r <= 1'b0;

            // ---- what the memory output registers hold
            if (lm_ren) begin
                ld_valid <= 1'b1;
            end else if (lm_wen) begin
                ld_valid <= 1'b0;
            end

            // ---- a native step's request, a clk ahead of its strobe
            // (the request itself is ea_r and the status registers)
            if (nat_pre) sreq_valid <= 1'b1;
            // ---- fast mode: a step that is certainly a socket cycle, likewise.  Its
            // write data is registered in the step's second clk, as a native step's
            // is at its strobe: the PHY takes it a clk after the issue.
            if (fast_pre) begin sreq_valid <= 1'b1; pre_q <= 1'b1; end
            if (pre_q & (st == ST_ADDR) & (ph == 4'd1)) sreq_data <= cpu_d_out_i;

            // ---- step sequencer
            unique case (st)
                ST_RESET: begin
                    st <= ST_ADDR; ph <= '0;
                end

                ST_ADDR: begin
                    if (strobe) begin
                        if (!DATA_LATE) begin
                            use_lm_r <= use_lm;
                            rom_r    <= r_local_rom;
                        end
                        if (post) begin
                            pw_valid <= 1'b1;
                            pw_addr  <= eff_addr;
                            pw_data  <= cpu_d_out_i;
                        end
                        if (need_sock) begin
                            sreq_valid <= 1'b1;
                            sreq_addr  <= eff_addr;
                            sreq_we    <= eff_we;
                            sreq_data  <= cpu_d_out_i;
                            // a substituted internal I/O cycle goes out as a
                            // plain read (the PHY must not substitute again)
                            sreq_vpa   <= io_int ? 1'b0 : cpu_vpa_i;
                            sreq_vda   <= io_int ? 1'b1 : cpu_vda_i;
                            sreq_vp_n  <= io_int ? 1'b1 : cpu_vp_n_i;
                            st <= ST_SOCK;
                        end else begin
                            st <= ST_DATA;
                            // data-late: a read that has to be launched now
                            // (next clk) gets a whole STEP_CLKS for memory ->
                            // core; everything else ends the step STEP_CLKS
                            // after the previous one (or as soon as it is decided)
                            ph <= ph_i;
                        end
                    end else if (ph != 4'd15) begin
                        ph <= ph + 4'd1;
                    end
                end

                ST_DATA: begin
                    // (a far read of expansion memory: the count stands while its byte is on the way)
                    if (ph != 4'd0 && !lm_rwait_i) ph <= ph - 4'd1;
                end

                default: begin   // ST_SOCK: wait for sync_done; or the core is held
                    if (held_r & ~hold_i) begin
                        st <= ST_ADDR; ph <= '0; held_r <= 1'b0;
                    end
                end
            endcase

            // ---- the step completes (and the next one waits if the core is to be held)
            if (cpu_ce_o) begin
                st          <= hold_i ? ST_SOCK : ST_ADDR;
                held_r      <= hold_i;
                ph          <= '0;
                prev_addr   <= eff_addr;
                sreq_valid  <= 1'b0;
                pre_q       <= 1'b0;
                xw_r <= 1'b0; xl_r <= 1'b0; xq1 <= 1'b0; xq2 <= 1'b0;
                mode_native <= native_s[1];
                mode_bypass <= bypass_s[1];
            end
        end
    end

    //=========================================================================
    // Verify (native, card memory of record) and statistics
    //=========================================================================
    // (the card's byte is registered for the compare: it has been steady since long
    // before the PHI2 fall, and the compare hangs off the near memory's output otherwise)
    logic [7:0] vfy_d;
    always_ff @(posedge clk) vfy_d <= lm_rdata;
    wire vfy_miss = sync_done & vfy_r & (d_f != vfy_d);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            verify_miss_o <= 1'b0; verify_addr_o <= '0; verify_count_o <= '0;
            stat_steps_o <= '0; stat_sock_o <= '0; stat_posted_o <= '0; stat_pwwait_o <= '0;
            stat_rd_hit_o <= '0; stat_rd_miss_o <= '0;
        end else begin
            verify_miss_o <= vfy_miss;
            if (vfy_miss) begin
                verify_addr_o <= DATA_LATE ? eff_addr : sreq_addr;
                if (verify_count_o != 16'hFFFF) verify_count_o <= verify_count_o + 16'd1;
            end
            if (cpu_ce_o)  stat_steps_o  <= stat_steps_o + 32'd1;
            if (sync_done) stat_sock_o   <= stat_sock_o + 32'd1;
            if (pw_done)   stat_posted_o <= stat_posted_o + 32'd1;
            if (ev_hit)  stat_rd_hit_o  <= stat_rd_hit_o + 32'd1;
            if (ev_miss) stat_rd_miss_o <= stat_rd_miss_o + 32'd1;
            if (ev_pww) stat_pwwait_o <= stat_pwwait_o + 32'd1;
        end
    end

`ifdef VERILATOR
    // Near memory: a step completed from the cheap view is one the full decode
    // completes too, with the same byte, and a write of it goes where the full
    // decode says.  (The cheap view itself is proven in the decode sweep.)
    always @(posedge clk) if (rst_n && run_c && fast_q) begin
        if (mode_native || st != ST_ADDR || ph != 4'd1 || ce_r ||
            (internal ? r_side : !r_local) || (!internal && eff_we && (r_fwd || !r_local_we || r_phys !== f_phys)) ||
            (!internal && !eff_we && !(near_r && use_lm_r && !r_nc && f_tag === r_tag)) ||
            (!internal && eff_we && f_tag !== (nm_far_only(r_phys) ? NM_EMPTY : nm_tag(1'b0, r_phys, 4'd0, w_idx[12])))) begin
            $display("ERROR: the cheap view completed a step the full decode would not: a=%06h int %b we %b local %b side %b fwd %b @%0t",
                     eff_addr, internal, eff_we, r_local, r_side, r_fwd, $time);
            $finish;
        end
    end
    // The cheap view is taken of ea_r, the full decode of the effective address:
    // the two addresses differ only on an internal cycle that repeats an address,
    // and there the one thing the cheap view is asked is the same.
    always @(posedge clk) if (rst_n && run_c && DATA_LATE) begin
        if ((!pl_io_int && eff_addr !== ea_r) || (pl_io_int && (!pl_int || pl_we || ea_r[15:8] !== 8'hC0)) ||
            r_fast_int !== (eff_addr[15:12] != 4'hC)) begin
            $display("ERROR: the cheap view's address: ea_r %06h ea_k %06h io_int %b int %b we %b fast_int %b @%0t",
                     ea_r, ea_k, pl_io_int, pl_int, pl_we, r_fast_int, $time);
            $finish;
        end
    end
    initial if (NEAR && (!DATA_LATE || ADDR_CLKS != 2 || STEP_CLKS < 2 || NEAR_AW < 14 || NEAR_KW < 4 || NEAR_KW > 10)) begin
        $display("ERROR: NEAR needs DATA_LATE, ADDR_CLKS = 2, STEP_CLKS >= 2, NEAR_AW >= 14 and 4 <= NEAR_KW <= 10"); $finish;
    end
    // The decode registered a step ahead must be the decode of the step: every
    // time it is used, compare it with the replica's combinational view.
    always @(posedge clk) if (rst_n && run_c && strobe && DATA_LATE && ADDR_CLKS >= 2 && mode_native) begin
        if (!sreq_valid) begin
            $display("ERROR: native request not raised a clk before the strobe @%0t", $time); $finish;
        end
    end
    always @(posedge clk) if (rst_n && {sel_pw_r, sel_sync_r} !== {sel == K_PW, sel == K_SYNC}) begin
        $display("ERROR: registered PHY select %b%b differs from sel %0d @%0t", sel_pw_r, sel_sync_r, sel, $time); $finish;
    end
    always @(posedge clk) if (rst_n && run_c && (strobe || mem_evt)) begin
        if (internal !== internal_l || io_int !== io_int_l || eff_we !== eff_we_l ||
            (DATA_LATE && (pl_vp_n | pl_io_int) !== (cpu_vp_n_i | io_int_l)) ||
            (DATA_LATE && eff_addr !== eff_addr_l) ||
            (fresh_ok && !cpu_vp_n_i)) begin
            $display("ERROR: broker step status differs from the core's: int %b/%b io_int %b/%b we %b/%b vp_n %b fresh %b @%0t",
                     internal, internal_l, io_int, io_int_l, eff_we, eff_we_l, cpu_vp_n_i, fresh_ok, $time);
            $finish;
        end
    end
    // a step whose socket request was raised ahead is that socket cycle and nothing else
    logic sync_done_q;
    always @(posedge clk) sync_done_q <= sync_done;
    // a socket cycle that was performed is the step's: it never ends with the step
    // still undecided (it would be issued a second time)
    always @(posedge clk) if (rst_n && run_now && cyc_done && fl_kind == K_SYNC && fl_run && !sync_done) begin
        $display("ERROR: a step's socket cycle completed before the step was decided: a=%06h st=%0d ph=%0d pre=%b @%0t",
                 eff_addr, st, ph, pre_q, $time);
        $finish;
    end
    always @(posedge clk) if (rst_n && run_now && pre_q) begin
        if (strobe && !(need_sock && !post && !internal && !lm_write)) begin
            $display("ERROR: broker raised a socket request ahead for a step that is not one: a=%06h we=%b @%0t",
                     eff_addr, eff_we, $time);
            $finish;
        end
        if (cpu_ce_o && !sync_done_q) begin
            $display("ERROR: a step with a socket request raised ahead completed without its socket cycle: a=%06h @%0t",
                     eff_addr, $time);
            $finish;
        end
    end
    always @(posedge clk) if (rst_n && run_c && fresh_ok && (strobe || mem_evt)) begin
        if (internal ? (pl_side !== r_side) :
            eff_we   ? (pl_w_local !== r_local || pl_w_we !== r_local_we || pl_w_fwd !== r_fwd ||
                        (r_local && pl_w_phys !== r_phys)) :
                       (pl_r_local !== r_local || (r_local && pl_r_rom !== r_local_rom) ||
                        (r_local && !ld_valid) ||
                        (r_local && (r_local_rom       ? (ld_rom !== r_rom_addr) :
                                     ~|r_phys[23:17]   ? (ld_ram !== r_phys[16:0]) : (ld_phys !== r_phys))))) begin
            $display("ERROR: broker step-ahead decode differs from the step's: a=%06h we=%b int=%b @%0t",
                     eff_addr, eff_we, internal, $time);
            $finish;
        end
    end
`endif

    initial if (FAR_CLKS != 1 && !(NEAR && FAR_CLKS == 2)) $fatal(1, "gs_accel_broker: FAR_CLKS is 1, or 2 with NEAR");

    assign lm_rexp_o   = rexp_r;
    assign nm_ren_hi_o = NEAR & NEAR_SPLIT & ~dec_ok;         // the first clk of a step
    assign nm_ra_hi_o  = ea_r[NEAR_AW-1:0];
    initial if (NEAR_SPLIT && !(NEAR && NEAR_KW > 4 && ADDR_CLKS >= 2)) $fatal(1, "gs_accel_broker: NEAR_SPLIT needs NEAR, NEAR_KW > 4, ADDR_CLKS >= 2");
`ifdef VERILATOR
    // (NEAR_SPLIT) the cheap view's tag never has an address bit above the low four, nor the mark of one
    always @(posedge clk) if (rst_n && NEAR && NEAR_SPLIT && (fa0 | fb0) && !internal && ((|f_tag[NTW-3:4]) || (&f_tag[NTW-1:NTW-2]))) begin
        $display("ERROR: broker cheap-view tag with a high address bit: %h @%0t", f_tag, $time); $finish;
    end
    // the cheap view's tag, its high address bits taken from the address register, is the tag the functions give
    always @(posedge clk) if (rst_n && NEAR && (fa0 | fb0) && !internal && f_tag !== f_tag_m) begin
        $display("ERROR: broker cheap-view tag %h, the functions give %h (ea_r %06h) @%0t", f_tag, f_tag_m, ea_r, $time); $finish;
    end
    // the empty entry's tag is no byte's: not any RAM's the tag can name, nor any ROM's
    initial if (NEAR) begin
        for (int k = 0; k < (1 << (10 + 1)); k++) begin
            logic [23:0] ph;
            ph = 24'(k >> 1) << 14;
            if (!nm_far_only(ph) && nm_tag(1'b0, ph, 4'd0, k[0]) === NM_EMPTY)
                $fatal(1, "gs_accel_broker: the empty near-memory tag is RAM %06h's", ph);
        end
        for (int k = 0; k < 16; k++)
            if (nm_tag(1'b1, 24'd0, 4'(k), 1'b0) === NM_EMPTY) $fatal(1, "gs_accel_broker: the empty near-memory tag is a ROM tag");
    end
    // an entry is never written with the empty tag but to empty it
    // (or for a byte the tag cannot name, whose entry is emptied by its write)
    always @(posedge clk) if (rst_n && nm_wen_o && !nm_flush && nm_wtag_o === NM_EMPTY &&
                              (nfill_r || !nm_far_only(wa_r))) begin
        $display("ERROR: broker: a near-memory entry written with the empty tag: index %h @%0t", nm_wa_o, $time); $finish;
    end
    // nothing moves A12 in RAM above bank 03 (the mark takes that bit's place)
    always @(posedge clk) if (rst_n && NEAR_SPLIT && mem_evt && (lm_read | lm_write) && ~d_local_rom && (|d_phys[23:18]) &&
                              (d_phys[12] != eff_addr[12])) begin
        $display("ERROR: broker: A12 moved in RAM above bank 03: %06h -> %06h @%0t", eff_addr, d_phys, $time); $finish;
    end
`endif
    assign fast_o      = run_c & ~mode_native;
    assign step_evt_o  = cpu_ce_o;
    assign held_o      = held_r;
    assign idle_stb_o  = cyc_done & (fl_kind == K_IDLE) & fl_hold & held_r;
    assign idle_d_o    = d_f;
    assign sock_evt_o  = cyc_stb;
    assign sock_idle_o = fl_busy & (fl_kind == K_IDLE);
    assign pw_busy_o   = pw_valid;

endmodule
