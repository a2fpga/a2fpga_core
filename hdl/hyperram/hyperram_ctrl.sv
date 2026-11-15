//
// HyperRAM controller — low-latency, short-burst, x8 HyperBus
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
// Replaces the Gowin HyperRAM IP (IPUG944) for the a2p25. The IP imposes a
// 15-user-clock minimum command interval even for a 16-byte burst, which
// makes the 4-byte random accesses that dominate Apple II traffic cost ~3x
// what the bandwidth budget assumed. This controller issues a transaction
// of 1..MAX_BURST 32-bit words with only the HyperBus protocol overhead
// (CS# lead + 3 CA clocks + initial latency + tRWR recovery).
//
// Measured in simulation (L = 6 variable, 108 MHz, requests issued as
// soon as ready, user handshake included), clk cycles per transaction:
//   read  1 / 4 / 16 words: 14 / 17.1 / 29
//   write 1 / 4 / 16 words: 10 / 13.1 / 25.1
// A read's last byte reaches the FSM ~9 clk_mem after its CK (IDDR +
// capture pipeline) and the next request waits for done; letting the next
// command start while a read drains (a pipelined user port) is the next
// step if random-read throughput needs to go further.
//
// Lineage: the ODDR/IDDR + phase-shifted-CK structure follows nand2mario's
// psram-tang-nano-9k controller. Differences: 2:1 clocking (HyperBus at
// clk_mem = 2 x clk, user side on clk with no async CDC), variable
// latency with RWDS-at-CA sampling, linear bursts, RWDS-framed read
// capture, and a trainable input delay with boot-time calibration.
//
// Verified in simulation against the Infineon S27KL0642 Verilog model
// (boards/a2p25/tests/test_hyperram_ctrl.sv, `make hyperram`), with the
// Gowin GW5A ODDR/IDDR/IODELAY simulation primitives and 0..4 ns of
// symmetric board delay.
//
// Clocks (all from one PLL, rising edges aligned):
//   clk         user / arbiter clock (54 MHz on a2p25)
//   clk_mem     2 x clk — HyperBus CK rate (108 MHz)
//   clk_mem_90  clk_mem + 90 deg — drives CK
//   clk_cap     read capture clock, normally = clk_mem
//
// One 32-bit user word = 2 CK cycles (4 bytes, x8 DDR) = 1 clk cycle, so a
// burst streams at one word per user clock.
//
// User interface (clk domain), one transaction at a time:
//   ready      high when a request can be accepted
//   req        1-cycle pulse (while ready) with we/addr/len/wdata/wbe valid
//   addr       32-bit word address
//   len        words, 1..MAX_BURST
//   wdata/wbe  word 0 of a write; words 1..len-1 come from the write buffer
//              (wbuf_* with wbuf_idx = 1..15), loaded while ready, before
//              req. wbe bit k = byte k written.
//   rvalid     one pulse per read word, in address order
//   done       pulse when the transaction is complete (after last rvalid);
//              xfer_lat2x / rd_err are valid with it
//   cfg_cr0 / cfg_cr0_write  reprogram CR0 at runtime (latency, fixed/
//              variable, drive strength); timing follows the live value.
//              Accepted only while ready.
//   rd_err     with done: the read timed out (missing RWDS-framed data);
//              missing words were still delivered (as 32'hBEEFBEEF) so
//              clients never hang
//
// Byte order: user byte k of a word is the k-th byte on the wire. Writes
// and reads use the same mapping, so storage order is self-consistent.
//
// ---------------------------------------------------------------------------
// Bus timing (all verified against the vendor model, see the testbench)
// ---------------------------------------------------------------------------
// Cycle numbering: cyc = 0 is the first S_XFER cycle. A value the core
// assigns in cycle c is on the pins during pin-cycle c+3 (ODDR: first byte
// while clk_mem is high, second while low); CK for that cycle rises at
// c+3.25 and falls at c+3.75 (centre of each byte). CS# falls at pin 3.
//
//   CK#1 (first CA clock) is issued at cyc = CS_LEAD (tCSS = (CS_LEAD +
//   0.25) * tCK >= 3 ns). CA occupies CK#1..#3.
//
//   Data start (1x): the first data word is clocked by CK#(3+L), i.e.
//   after LAT1 = 2+L CK pulses (CA + L-1 further clocks). Without pauses
//   that is cyc = CS_LEAD + 2 + L — the "CA0 + 2 + latency" assumption of
//   the first draft is correct; WR_ADJ is gone.
//
//   Data start (2x): after LAT2 = 2 + 2L + LAT2X_ADJ CK pulses, i.e.
//   CK#(3+2L). Datasheet, the vendor model (fixed-latency path) and
//   nand2mario's hardware-proven Winbond controller agree: 2x adds
//   exactly L clocks (LAT2X_ADJ = 0, kept only as a bring-up knob). Reads
//   are RWDS-framed and issue one spare CK in 2x, so only writes depend
//   on the exact count. (The stock model never applies 2x latency on a
//   variable-latency refresh collision although it signals it on RWDS;
//   the testbench patches that.)
//
//   Latency sample: the device signals 2x by driving RWDS high during CA.
//   Silicon makes it valid tDSV (<=12 ns) after CS#; the model only after
//   CK#1 rise + tCKDSR (7 ns), and for reads it drops it at CK#3 rise +
//   tCKDSR (1..7 ns). RWDS comes back through the same pads, IODELAY and
//   board delay as read data, so the controller samples it at the
//   "CK#2-equivalent" point: the IDDR edge at which a byte launched by
//   CK#2 would be captured. That point is derived from the measured read
//   arrival (arr_cyc/arr_half, see below): sample = IDDR output read
//   directly (Q0 if arr_half = 0 else Q1) at cyc = CS_LEAD + arr_cyc. It
//   sits one full CK from either end of the indication window for any
//   board delay. The first draft's fixed LATSAMPLE_CYC = 9 sampled ~2 CK
//   before the model drives the indication.
//
//   The decision is known at cyc = CS_LEAD + arr_cyc + 1 (~ 9..11), later
//   than the 1x write data start for L <= 7 at the reachable arr values.
//   HyperBus allows the clock to be stopped (held LOW) during any part of
//   a transaction, so writes simply pause CK after LAT1 pulses until the
//   decision is in (0..3 cycles at L = 5..7). Reads never need to pause.
//
//   Read arrival: the first byte (RWDS high) of a read clocked by data
//   CK issued at cycle D appears in the rx registers at cycle D + arr_cyc,
//   in the rising (arr_half = 0) or falling (1) IDDR half. arr_cyc is
//   ~7..9 at 108 MHz for 0..4 ns board delay. It is measured on the
//   calibration verify reads ("probe" reads) and initialised to
//   ARR_INIT/ARR_INIT_HALF.
//
//   Read CS# release: CS# is raised as soon as the last byte has been
//   sampled at the IDDR (predicted from arr_cyc, one cycle of margin), not
//   when the FSM has seen it, which saves ~5 cycles per read. Read data
//   stays latched on the bus while CK is stopped (active clock stop).
//
//   2x fallback for reads: if no RWDS-framed data has arrived by
//   D1 + arr_cyc + 2 while CS# is still low, the read is extended to 2x
//   (only matters if the CA sample was wrong; counted in
//   stat_lat_mismatch, which compares the CA-sampled latency with the
//   observed data arrival on every read — the bring-up check for the
//   write-path latency sample).
//
//   tRWR (CS# rise to CK#2 fall of the next transaction, model $recovery
//   check) >= TRWR_NS, tCSHI >= 6 ns: GAP_CYCLES of CS# high.
//
//   Requires L >= 5 at 108 MHz (tACC = 36 ns; the read framing window
//   also opens after the CA-phase RWDS indication has drained).
//
// ---------------------------------------------------------------------------
// Boot / calibration
// ---------------------------------------------------------------------------
// ⚠ NEVER WRITE CR1. CR1[6] (master clock type) resets to 1 = single-ended;
// in that mode the CK# input is disabled and may float (S27KL0642 DS
// §6.3.3.1). Both a2p25 and a2mega 1.0a5 leave CK# (ball B1) unconnected,
// so selecting differential clocking would leave CK# floating on an
// ENABLED input. This controller only ever writes CR0.
//
// Wait tVCS (POR_US), write CR0 (latency, variable/fixed, drive strength),
// then calibrate the input delay: write a 16-word pattern at CAL_ADDR
// (twice, so a refresh collision on the first write cannot poison it),
// sweep the IODELAY code in steps of 2^CAL_STEP_LOG2, read back
// CAL_REPEATS times per step and record pass/fail in cal_map. The tap
// chosen is the centre of the longest passing run (largest guaranteed
// margin; at 108 MHz the 3.2 ns delay line is shorter than the 4.6 ns bit
// time, so the eye often touches one end of the range). Then CAL_REPEATS
// verify reads at the chosen tap (probe reads: they also measure
// arr_cyc). Retried up to CAL_RETRIES times. init_done rises after
// calibration regardless of outcome; cal_ok says whether it passed.
// The MAX_BURST words at CAL_ADDR are reserved (overwritten at boot and on
// recal).
//
// Timing closure (108 MHz core on a C1 GW5A-25). Standalone P&R of
// hyperram_ctrl + hyperram_bist on GW5A-LV25MG121NC1/I0 (Gowin 1.9.x):
// clk_mem 116.8 MHz (WNS +0.70 ns), clk 73.9 MHz, no hold violations.
//   - clk <-> clk_mem paths are synchronous single-clk_mem-period paths
//     (the toggle handshakes, c_* command registers, read queue). The SDC
//     must declare clk_mem / clk as related PLL outputs.
//   - REQUIRED false path: the IODELAY code is quasi-static (changed only
//     between transactions, with settle time) but STA times DLYSTEP ->
//     IDDR as a half-cycle clk -> clk_mem(F) path and fails it:
//       set_false_path -from [get_regs {<inst>/dly_code*}]
//   - Per-cycle decisions use only registered targets / incrementally
//     maintained flags (no adders or magnitude compares in front of the
//     CK, write-data or capture logic); the write-buffer read mux is
//     registered a halfword ahead (wr_ent), leaving the byte select in
//     front of p_dq.
//   - The request-time constants (CA frame, CK counts, cycle targets,
//     release / timeout offsets) are computed on clk in the cycle that
//     issues the request (task issue(), the c_* registers) and the core
//     reads them as registers, so the clk -> clk_mem request-accept cone
//     is a copy or one mux. The done handshake (done_tgl_m / rq_wp_m /
//     err_m -> clk) only ever gates fstate, done_seen and the done
//     outputs; boot-probe decisions and the Xccela MR4 half of a config
//     write take one more clk, and the calibration compare runs one clk
//     behind the read-queue drain. (Before this, in the a2p25 full core at
//     97 % CLS, those crossings missed 108 MHz by up to 0.8 ns.)
//   - The latency sample reads the IDDR output directly (IOB register ->
//     fabric register), one level of mux.
//   - Write buffer: 16 x 36 bits of FFs (the GW5A-25 has no LUT RAM).
//   - ck_en goes clk_mem posedge -> clk_mem_90 negedge (3T/4, the long
//     fabric hop from the FSM to the PHY) -> clk_mem_90 ODDR (T/2, local).
//
// ---------------------------------------------------------------------------
// Xccela / OPI PSRAM (PROTOCOL = 1 or 2)
// ---------------------------------------------------------------------------
// The AP Memory APS6408L-3OBM-BA sits on the same 24-ball footprint as the
// HyperRAM but speaks the Xccela protocol. Same PHY, clocking, calibration,
// write buffer and strobe-framed read capture; the differences are all in
// the command layer and are selected per request by c_xc / x_xc:
//   - CA: INST byte held for CK#1 (both halves), then the 32-bit BYTE
//     address A3..A0. Linear write A0h, linear read 20h, MRW C0h, MRR 40h,
//     Global Reset FFh (MA in the A0 slot for MRW/MRR). Note the read/write
//     bit is inverted relative to HyperBus (HyperBus A0h = linear read).
//   - No latency indication during CA: DQS is Hi-Z through CA, driven low
//     after CK#3 (preamble), and the first DQS rising edge is D0. In
//     variable mode a refresh collision pushes data out by anything from
//     LC to 2*LC. Reads therefore clock the worst case (2 + 2*LC + hw + 1)
//     and, once the strobe arrives, the CK total is trimmed to the CKs still
//     needed; CS# is released on the observed last byte (relobs), not on a
//     prediction. Extra CKs before CS# rises are harmless.
//   - Writes use a separate, fixed write latency WLC (MR4[7:5]); no
//     pushout, no 2x, no CK pause. Data starts at CK#(3 + WLC).
//   - Registers are 8-bit MR0..MR8. cfg_cr0 / cr0_active carry {MR4, MR0};
//     a cfg_cr0_write issues MRW MR0 then MRW MR4. MRW data rides on CK#4
//     (fixed latency 1), so MR writes are valid whatever latency the
//     device currently holds.
//   - Boot: tPU, then the probe sequence below, then MRW MR0 / MR4
//     (XC_RLC, XC_WLC, XC_DRIVE, XC_FIXED), then the usual calibration.
//   - Bursts wrap inside the device's 1 KB page: callers must not issue a
//     burst that crosses a 1 KB boundary (hyperram_ports' size-aligned
//     bursts never do).
//   - xfer_lat2x / stat_lat2x on Xccela reads mean "data arrived later
//     than the 1x window", stat_lat_mismatch stays 0.
//
// PROTOCOL = 2 detects the device at boot (front-end states F_DET_*):
//   1. Xccela MRR of MR1 (frame 40 40 00 00 00 01). A HyperRAM decodes it
//      as a register write to the read-only ID1 (its CR0/CR1 decode needs
//      CA[24] = 1) and drives nothing: the read times out.
//   2. No valid answer (vendor != 0x0D or timeout): one Global Reset frame
//      (FF FF ..., 4 CKs; a HyperRAM sees an aborted register read), tRST,
//      and the MRR again. This is what a cold APS part needs before it
//      answers anything.
//   3. Still nothing: HyperBus ID0 read (E0 ...). Never sent before steps
//      1-2, because INST E0 is undefined on an Xccela part.
// Each step is tried at four input-delay taps (the probe runs before
// calibration; the ID check rejects a capture at a bad tap). Result on
// proto_xccela / dev_id (ID0, or {MR2, MR1}) / det_fail. With PROTOCOL = 1
// steps 1-2 run as a liveness check and the Xccela init proceeds
// regardless. Boot cost on a HyperRAM: 8 timed-out probes + tRST, ~6 us.
// PROTOCOL = 0 is the original HyperBus controller, unchanged.
//

module hyperram_ctrl #(
    parameter CLK_HZ          = 54_000_000,
    parameter ADDR_WIDTH      = 21,         // 32-bit words (2M = 8 MB)
    parameter MAX_BURST       = 16,         // words per transaction (<= 16)
    parameter LATENCY         = 6,          // initial latency clocks (CR0), 5..7
    parameter FIXED_LATENCY   = 0,          // CR0[3] at boot
    parameter [2:0] DRIVE     = 3'b000,     // CR0[14:12] drive strength
    parameter CS_LEAD         = 1,          // clk_mem cycles of CS# low before CK#1
    parameter LAT2X_ADJ       = 0,          // extra 2x-latency clocks (0 = datasheet)
    parameter ARR_INIT        = 8,          // read arrival before the first probe
    parameter ARR_INIT_HALF   = 0,
    parameter RD_TIMEOUT      = 16,         // clk_mem cycles past expected end
    parameter POR_US          = 160,        // tVCS = 150 us
    parameter TRWR_NS         = 36,         // tRWR (166 MHz grade)
    parameter CAL_ENABLE      = 1,
    parameter CAL_STEP_LOG2   = 3,          // sweep step (>= 3: at most 32 bins)
    parameter CAL_REPEATS     = 4,          // reads per bin, all must pass
    parameter CAL_RETRIES     = 3,
    parameter [ADDR_WIDTH-1:0] CAL_ADDR = {ADDR_WIDTH{1'b1}} - (MAX_BURST - 1),
    parameter [7:0] DLY_DEFAULT = 8'd0,
    // Device protocol: 0 = HyperBus (HyperRAM), 1 = Xccela / OPI PSRAM
    // (AP Memory APS6408L), 2 = detect at boot (see "Xccela" in the header)
    parameter PROTOCOL        = 0,
    parameter XC_RLC          = 5,          // Xccela read latency code 3..7 (MR0[4:2])
    parameter XC_WLC          = 5,          // Xccela write latency code 3..7 (MR4[7:5])
    parameter [1:0] XC_DRIVE  = 2'b00,      // MR0[1:0]: 00 = 50, 01 = 100, 10 = 200, 11 = 400 ohm
    parameter XC_FIXED        = 0           // MR0[5]: 1 = fixed (2x) read latency
) (
    input  wire                      clk,
    input  wire                      clk_mem,
    input  wire                      clk_mem_90,
    input  wire                      clk_cap,
    input  wire                      rst_n,        // clk domain

    // User interface (clk)
    output wire                      ready,
    output wire                      init_done,
    input  wire                      req,
    input  wire                      we,
    input  wire [ADDR_WIDTH-1:0]     addr,
    input  wire [4:0]                len,
    input  wire [31:0]               wdata,
    input  wire [3:0]                wbe,
    input  wire                      wbuf_we,
    input  wire [3:0]                wbuf_idx,
    input  wire [31:0]               wbuf_data,
    input  wire [3:0]                wbuf_be,
    output logic                     rvalid,
    output logic [31:0]              rdata,
    output logic                     done,
    output logic                     rd_err,
    output logic                     xfer_lat2x,   // with done: 2x latency

    // Calibration control / status (clk)
    input  wire                      recal,        // pulse: re-run calibration
    input  wire [15:0]               cfg_cr0,      // CR0 to program on cfg_cr0_write
    input  wire                      cfg_cr0_write,
    output wire [15:0]               cr0_active,
    input  wire                      dly_force,    // hold dly_force_code
    input  wire [7:0]                dly_force_code,
    output logic [7:0]               dly_code,     // live input-delay code
    output logic [7:0]               cal_tap,      // calibrated code (restored when
                                                   // dly_force drops)
    output logic [31:0]              cal_map,      // bit b = bin b passed
    output logic                     cal_ok,
    output wire  [4:0]               rd_arrival,   // {arr_cyc, arr_half}
    output logic [31:0]              stat_xfers,
    output logic [31:0]              stat_lat2x,
    output logic [31:0]              stat_rd_timeouts,
    output logic [31:0]              stat_lat_mismatch,

    // Device / protocol (clk), valid once init_done
    output logic                     proto_xccela, // 1 = Xccela PSRAM, 0 = HyperBus
    output logic [15:0]              dev_id,       // HyperBus: ID0; Xccela: {MR2, MR1}
    output logic                     det_fail,     // boot probe got no valid answer

    // Pins
    output wire                      hr_ck,
    output wire                      hr_cs_n,
    inout  wire                      hr_rwds,
    inout  wire [7:0]                hr_dq
);

    localparam integer CLK_MEM_HZ = CLK_HZ * 2;
    localparam integer POR_CYCLES = (CLK_MEM_HZ / 1000) * POR_US / 1000;
    // tRWR in quarter clk_mem cycles, rounded up. CS# rise (pin) to CK#2
    // fall of the next transaction = (gap + CS_LEAD + 1.75) cycles.
    localparam integer TRWR_Q     = (4 * TRWR_NS * (CLK_MEM_HZ / 1000) + 999_999) / 1_000_000;
    localparam integer GAP_RAW    = (TRWR_Q - 4 * CS_LEAD - 7 + 3) / 4;
    localparam integer GAP_CYCLES = (GAP_RAW < 1) ? 1 : GAP_RAW;
    localparam integer GAP_LOAD   = (GAP_CYCLES < 2) ? 0 : GAP_CYCLES - 2;
    localparam [3:0] LAT_CODE = (LATENCY == 3) ? 4'b1110 :
                                (LATENCY == 4) ? 4'b1111 :
                                (LATENCY == 5) ? 4'b0000 :
                                (LATENCY == 6) ? 4'b0001 : 4'b0010;
    // CR0: DPD off, drive, reserved 1111, latency, fixed/variable, legacy
    // wrap (1), 32-byte wrap (11 — irrelevant, we use linear bursts)
    localparam [15:0] CR0_VALUE = {1'b1, DRIVE, 4'b1111, LAT_CODE,
                                   FIXED_LATENCY[0], 1'b1, 2'b11};
    localparam [7:0]  CA0 = 8'(CS_LEAD);
    localparam integer NBINS = 256 >> CAL_STEP_LOG2;
    // Xccela mode registers programmed at boot (cfg_cr0 = {MR4, MR0} there)
    localparam [2:0] XC_RLC_CODE = (XC_RLC == 3) ? 3'b000 : (XC_RLC == 4) ? 3'b001 :
                                   (XC_RLC == 5) ? 3'b010 : (XC_RLC == 6) ? 3'b011 : 3'b100;
    localparam [2:0] XC_WLC_CODE = (XC_WLC == 3) ? 3'b000 : (XC_WLC == 4) ? 3'b100 :
                                   (XC_WLC == 5) ? 3'b010 : (XC_WLC == 6) ? 3'b110 : 3'b001;
    localparam [7:0]  XC_MR0 = {2'b00, XC_FIXED[0], XC_RLC_CODE, XC_DRIVE};
    localparam [7:0]  XC_MR4 = {XC_WLC_CODE, 1'b0, 1'b0, 3'b000};   // fast refresh, full array
    localparam [15:0] XC_CFG = {XC_MR4, XC_MR0};
    localparam integer TRST_CYCLES = (CLK_HZ / 1_000_000) * 2 + 4;   // tRST = 2 us
    // Xccela / detection logic present at all. PROTOCOL 0 builds tie every
    // protocol select off at the wire (not just at a register with a
    // constant input) so synthesis drops the Xccela command layer and the
    // boot probe outright.
    localparam         XC_EN = (PROTOCOL != 0);

    // =====================================================================
    // clk domain: command registers shared with the core
    // =====================================================================
    logic                    c_we;
    logic                    c_reg;           // register write (CR0 / MRx), or Global Reset
    logic                    c_det;           // boot probe: wide read window, worst-case clocks
    logic                    c_xc;            // frame this request as Xccela (else HyperBus)
    logic [15:0]             c_regdata;       // register write data as sent on DQ (CR0, or
                                              // the MR byte in both halves for Xccela)
    logic                    c_cal;           // write data = calibration pattern
    logic                    c_probe;         // read: measure arrival
    logic [31:0]             c_w0;            // word 0 of a write
    logic [3:0]              c_be0;
    logic [35:0]             c_wbuf [0:15];   // words 1..15 {be, data} (FFs: GW5A-25 has no LUT RAM)
    logic                    req_tgl;
    logic [15:0]             c_cr0;           // live CR0 (HyperBus) or {MR4, MR0} (Xccela)
    // PROTOCOL 0 never leaves HyperBus mode: the protocol select is tied off
    // so the Xccela command layer and the detect requests fold away there.
    wire                     proto_q  = XC_EN && proto_xccela;
    // Request-time constants, computed on clk in the cycle that issues the
    // request (task issue(), below) from the request fields, the registered
    // latency constants and the read arrival. The core latches or compares
    // against these registers only: it used to do the muxes and adders
    // itself in the request-accept cycle, a one-clk_mem-period clk ->
    // clk_mem path that missed 108 MHz by 0.8 ns in the a2p25 full core at
    // 97 % CLS. All of them are static from the request until the next
    // issue(), like the other c_* registers.
    logic [47:0]             c_ca;            // command/address frame as sent on DQ
    logic [5:0]              c_hw_m1;         // halfwords to transfer - 1
    logic [7:0]              c_hw_m5;         // halfwords - 5 (CS# release offset from the first strobe)
    logic                    c_hw_le5;        // halfwords <= 5
    logic [7:0]              c_lat1;          // CKs before the 1x data CK (2 + L)
    logic [7:0]              c_lat2p1;        // 2x data CK + spare (2 + 2L + 1)
    logic [7:0]              c_lat1_m1, c_lat2_m1;
    logic [7:0]              c_end_m1;        // write latency clocks - 1 at request time
    logic [7:0]              c_rd_dat_ck;     // read data CK index at request time
    logic [7:0]              c_rd_ck_last;    // read: index of the last CK at request time
    logic [7:0]              c_tot1_m1, c_tot2_m1; // read: last CK index, 1x / 2x (+spare)
    logic [7:0]              c_lat_smp_cyc;   // RWDS latency sample cycle
    logic [7:0]              c_data1_cyc;     // 1x data CK cycle
    logic [7:0]              c_d2_to, c_d2_rel;   // timeout / release cycles rebased on the 2x data CK
    logic [7:0]              c_rd_open_cyc;   // read framing window opens (1 early)
    logic [7:0]              c_rd_2x_cyc;     // no data by then -> 2x
    logic [7:0]              c_off_to, c_off_rel; // hw + arr + RD_TIMEOUT, hw + arr - 5
    logic                    c_off_rel_z;     // c_off_rel == 0
    logic [7:0]              c_xc_trim_m1;    // Xccela: CKs still needed once the strobe arrives, - 1
    logic                    c_xc_trim_gt1;   // ... more than one
    logic                    c_lat2x0;        // lat2x at request time
    logic                    c_lat_known0;    // lat_known at request time
    wire  [3:0]              lat_code = c_cr0[7:4];
    wire  [7:0]              hb_lat   = (lat_code == 4'b1110) ? 8'd3 :
                                        (lat_code == 4'b1111) ? 8'd4 :
                                        (lat_code == 4'b0000) ? 8'd5 :
                                        (lat_code == 4'b0001) ? 8'd6 : 8'd7;
    wire  [7:0]              xc_rlat  = (c_cr0[4:2] == 3'b000) ? 8'd3 :
                                        (c_cr0[4:2] == 3'b001) ? 8'd4 :
                                        (c_cr0[4:2] == 3'b010) ? 8'd5 :
                                        (c_cr0[4:2] == 3'b011) ? 8'd6 : 8'd7;
    wire  [7:0]              xc_wlat  = (c_cr0[15:13] == 3'b000) ? 8'd3 :
                                        (c_cr0[15:13] == 3'b100) ? 8'd4 :
                                        (c_cr0[15:13] == 3'b010) ? 8'd5 :
                                        (c_cr0[15:13] == 3'b110) ? 8'd6 : 8'd7;
    wire  [7:0]              c_lat    = proto_q ? xc_rlat : hb_lat;
    wire  [7:0]              c_wlat   = proto_q ? xc_wlat : hb_lat;
    wire                     c_fixed  = proto_q ? c_cr0[5] : c_cr0[3];
    // Registered copies and the derived CK counts (2 + L, 2 + 2L + adj).
    // proto_xccela and c_cr0 change only in a clk cycle that issues a
    // register write, and register writes use none of these, so the one
    // cycle of delay is invisible. It keeps the clk -> clk_mem request-
    // time cone (lat1/lat2 -> the read CK total etc.) to one mux and one
    // adder: fed straight from proto_xccela it missed 108 MHz by 1.4 ns.
    logic [7:0]              lat_r, wlat_r;
    logic                    fixed_r;
    logic [7:0]              rlat1_r, rlat2_r, wlat1_r, wlat2_r;
    always_ff @(posedge clk) begin
        lat_r   <= c_lat;
        wlat_r  <= c_wlat;
        fixed_r <= c_fixed;
        rlat1_r <= 8'd2 + c_lat;
        rlat2_r <= 8'd2 + c_lat + c_lat + 8'(LAT2X_ADJ);
        wlat1_r <= 8'd2 + c_wlat;
        wlat2_r <= 8'd2 + c_wlat + c_wlat + 8'(LAT2X_ADJ);
    end

    // core -> clk
    logic                    done_tgl_m = 1'b0;
    logic                    err_m;
    logic                    lat2x_m;
    logic                    mism_m;
    logic [31:0]             rq_data_m [0:3];
    logic [1:0]              rq_wp_m;
    logic                    por_done_m;

    // Calibration pattern: dense transitions on every DQ bit and both
    // halves of each CK cycle.
    function automatic [31:0] cal_pattern(input [3:0] i);
        case (i)
            4'd0:  cal_pattern = 32'h00FF00FF;
            4'd1:  cal_pattern = 32'hFF00FF00;
            4'd2:  cal_pattern = 32'hAA55AA55;
            4'd3:  cal_pattern = 32'h55AA55AA;
            4'd4:  cal_pattern = 32'h0F0FF0F0;
            4'd5:  cal_pattern = 32'hF0F00F0F;
            4'd6:  cal_pattern = 32'h01020408;
            4'd7:  cal_pattern = 32'h10204080;
            4'd8:  cal_pattern = 32'hFEFDFBF7;
            4'd9:  cal_pattern = 32'hEFDFBF7F;
            4'd10: cal_pattern = 32'h3CC3A55A;
            4'd11: cal_pattern = 32'hC33C5AA5;
            4'd12: cal_pattern = 32'h12345678;
            4'd13: cal_pattern = 32'h9ABCDEF0;
            4'd14: cal_pattern = 32'hFFFFFFFF;
            default: cal_pattern = 32'h00000000;
        endcase
    endfunction

    // =====================================================================
    // clk_mem domain: core FSM
    // =====================================================================
    localparam [1:0] S_POR   = 2'd0;
    localparam [1:0] S_IDLE  = 2'd1;
    localparam [1:0] S_XFER  = 2'd2;
    localparam [1:0] S_DRAIN = 2'd3;

    logic [1:0]   state = S_POR;
    logic [17:0]  por_cnt;
    logic [7:0]   cyc;
    logic [7:0]   ck_cnt;            // CK pulses issued
    logic         req_seen;
    logic         x_we, x_reg, x_cal, x_probe, x_xc_r, x_det_r;
    wire          x_xc  = XC_EN && x_xc_r;   // Xccela framing / boot probe for this
    wire          x_det = XC_EN && x_det_r;  // transaction (constant 0 in PROTOCOL 0)
    logic [5:0]   hw_out;            // write halfwords sent
    logic [5:0]   hw_in;             // read halfwords received
    logic         lat_known, lat2x, lat_ca;
    logic [3:0]   gap_cnt;
    logic         rst_n_m;

    // Read arrival (persistent across transactions)
    logic [3:0]   arr_cyc  = 4'(ARR_INIT);
    logic         arr_half = ARR_INIT_HALF[0];

    // Read framing
    logic         rd_started, rd_align, rd_pad;
    logic [7:0]   rd_hold;
    logic         have_hw0;
    logic [15:0]  hw0;

    // PHY drive (registered)
    logic         p_cs_n = 1'b1;
    logic         p_ck_en = 1'b0;
    logic         p_dq_oe = 1'b0;
    logic         p_rwds_oe = 1'b0;
    logic [7:0]   p_dq_r, p_dq_f;
    logic         p_rwds_r, p_rwds_f;

    // PHY capture
    wire  [7:0]   i_dq_r, i_dq_f;
    wire          i_rwds_r, i_rwds_f;
    logic [7:0]   rx_dq_r, rx_dq_f;
    logic         rx_rwds_r, rx_rwds_f;

    always_ff @(posedge clk_mem) begin
        rst_n_m   <= rst_n;
        rx_dq_r   <= i_dq_r;
        rx_dq_f   <= i_dq_f;
        rx_rwds_r <= i_rwds_r;
        rx_rwds_f <= i_rwds_f;
    end

    // ---- Write data for the current halfword ----
    // c_* are static during a transaction (clk -> clk_mem paths are
    // synchronous, one clk_mem period). The word-level read of the write
    // buffer (16:1 x 36, plus the word-0 / calibration-pattern select) is
    // registered one cycle ahead: a word covers two halfword cycles, so the
    // entry for the halfword sent in the NEXT cycle is word (hw_out + 1) / 2.
    // Loaded every cycle; the CA / latency cycles (hw_out = 0) prime word 0.
    // Leaves one mux level (byte select) in front of p_dq; the direct form
    // was the controller's worst internal path (6 levels, +0.10 ns in the
    // a2p25 full core at 97 % CLS).
    wire  [3:0]   wr_nidx  = hw_out[4:1] + {3'b0, hw_out[0]};
    logic [35:0]  wr_ent;
    always_ff @(posedge clk_mem)
        wr_ent <= x_cal          ? {4'hF, cal_pattern(wr_nidx)} :
                  (wr_nidx == 0) ? {c_be0, c_w0} : c_wbuf[wr_nidx];
    wire  [31:0]  wr_word  = wr_ent[31:0];
    wire  [3:0]   wr_be    = wr_ent[35:32];
    wire  [7:0]   wr_b0    = hw_out[0] ? wr_word[23:16] : wr_word[7:0];
    wire  [7:0]   wr_b1    = hw_out[0] ? wr_word[31:24] : wr_word[15:8];
    wire          wr_m0    = hw_out[0] ? ~wr_be[2]      : ~wr_be[0];
    wire          wr_m1    = hw_out[0] ? ~wr_be[3]      : ~wr_be[1];

    // ---- Per-transaction timing (cycles relative to cyc = 0) ----
    // Every value the per-cycle logic compares against is a register: a
    // request-time constant (c_*, computed on clk when the request was
    // issued) or a clk_mem register set when the read data CK is issued;
    // "cycle reached" tests are equality compares feeding sticky flags. No
    // adder sits in front of the capture / push / CK logic.
    logic [7:0]   to_cyc, rel_cyc, rel_obs_cyc;
    logic         rd_open, past_2x, to_hit, rel_hit, rel_obs_hit;
    logic [7:0]   arr_meas;
    logic         obs2x;

    // Latency-dependent targets, re-registered whenever lat2x changes
    // (request latch, CA sample, read fallback). Before the decision a
    // variable-latency transaction assumes 1x, which is also the read CK
    // limit while the decision is pending.
    // Write sequencing flags, maintained incrementally so the write data /
    // CK decision is a few registered terms (no magnitude compares):
    logic         in_ca;                     // cyc < CA0 + 3
    logic         w_tail;                    // Xccela: extra CS#-low cycle after the last write CK
    logic         w_lt_lat1;                 // ck_cnt < lat1_ck_r
    logic         w_lt_end;                  // ck_cnt < wr_lat_end
    logic         w_more;                    // hw_out != x_hw
    logic [7:0]   end_m1;                    // write latency clocks - 1 (lat1 or lat2)
    logic [5:0]   x_hw_m1;                   // c_hw_m1, clk_mem copy for the capture path
    logic [7:0]   rd_dat_ck;                 // reads: data CK index (2x: spare)
    // Reads: CKs still to issue. rd_ck_more is the registered form of
    // ck_cnt < total (ck_cnt never passes the total, which only ever grows
    // past it: 2x, Xccela trim); it is cleared by the equality against the
    // last CK index and re-armed by every update of that index.
    logic         rd_ck_more;
    logic [7:0]   rd_ck_last;                // reads: index of the last CK (total - 1)
    wire          lat_smp    = arr_half ? i_rwds_f : i_rwds_r;
    wire          open_now   = rd_open;      // set one cycle ahead (rd_open_cyc - 1)
    logic         rd_more;                   // hw_in != x_hw (reads)
    wire          rel_now    = rel_hit || (cyc == rel_cyc);
    wire          relobs_now = rel_obs_hit || (cyc == rel_obs_cyc);
    logic         cap_active;
    // First strobe of an Xccela read (the rd_ck_last trim in the capture
    // block); the matching rd_ck_more re-arm sits after the FSM.
    wire          xc_strobe  = cap_active && !(rd_pad || to_hit) && open_now && !rd_started &&
                               (rx_rwds_r || rx_rwds_f) && x_xc;

    // tRWR gap counter. At 108 MHz with CS_LEAD = 1 the CS# high time of the
    // state machine itself covers tRWR (GAP_LOAD = 0) and the counter is
    // compiled out of the request-accept condition.
    wire          gap_ok     = (GAP_LOAD == 0) || (gap_cnt == 4'd0);

    // ---- Read capture (combinational next step) ----
    // Per clk_mem cycle the IDDR gives the rising sample (earlier) then
    // the falling sample. The first byte with RWDS high is byte A of the
    // first HyperBus word; from then on the stream is contiguous (CK does
    // not pause in the data phase).
    logic         push_en;
    logic [7:0]   push_a, push_b;     // first, second byte of the halfword
    always_comb begin
        cap_active = (state == S_XFER || state == S_DRAIN) && !x_we && rd_more;
        push_en    = 1'b0;
        push_a     = rx_dq_r;
        push_b     = rx_dq_f;
        if (cap_active) begin
            if (rd_pad || to_hit) begin
                push_en = 1'b1;
                push_a  = 8'hEF;
                push_b  = 8'hBE;
            end else if (open_now) begin
                if (!rd_started) begin
                    push_en = rx_rwds_r;            // aligned: A,B in this cycle
                end else if (!rd_align) begin
                    push_en = 1'b1;
                end else begin
                    push_en = 1'b1;
                    push_a  = rd_hold;
                    push_b  = rx_dq_r;
                end
            end
        end
    end

    always_ff @(posedge clk_mem) begin
        p_ck_en <= 1'b0;
        if (GAP_LOAD != 0 && gap_cnt != 4'd0)
            gap_cnt <= gap_cnt - 4'd1;

        // ---- cycle-reached flags ----
        if (state == S_XFER || state == S_DRAIN) begin
            if (cyc == c_rd_open_cyc) rd_open   <= 1'b1;   // c_rd_open_cyc is 1 early
            if (cyc == c_rd_2x_cyc)   past_2x   <= 1'b1;
            if (cyc == to_cyc)      to_hit      <= 1'b1;
            if (cyc == rel_cyc)     rel_hit     <= 1'b1;
            if (cyc == rel_obs_cyc) rel_obs_hit <= 1'b1;
        end

        // ---- read capture ----
        if (cap_active) begin
            if (rd_pad || to_hit) begin
                rd_pad <= 1'b1;
            end else if (open_now) begin
                if (!rd_started) begin
                    if (rx_rwds_r || rx_rwds_f) begin
                        rd_started  <= 1'b1;
                        rd_align    <= !rx_rwds_r;
                        rd_hold     <= rx_dq_f;
                        arr_meas    <= cyc - c_data1_cyc;
                        obs2x       <= past_2x;
                        rel_obs_cyc <= cyc + c_hw_m5;
                        rel_obs_hit <= c_hw_le5;
                        // Xccela: the CK that produced this byte went out
                        // ~arr cycles ago; x_hw - 1 more data CKs are
                        // needed (+2 margin). Never below the CK issued
                        // this cycle. Extra CKs are harmless (the device
                        // keeps bursting inside the page until CE# rises).
                        if (x_xc)
                            rd_ck_last <= ck_cnt + c_xc_trim_m1;
                    end
                end else if (rd_align) begin
                    rd_hold <= rx_dq_f;
                end
            end
        end
        if (push_en) begin
            if (!have_hw0) begin
                hw0      <= {push_b, push_a};
                have_hw0 <= 1'b1;
            end else begin
                rq_data_m[rq_wp_m] <= {push_b, push_a, hw0};
                rq_wp_m            <= rq_wp_m + 2'd1;
                have_hw0           <= 1'b0;
            end
            hw_in <= hw_in + 6'd1;
            if (hw_in == x_hw_m1) rd_more <= 1'b0;
        end

        case (state)
        S_POR: begin
            p_cs_n    <= 1'b1;
            p_dq_oe   <= 1'b0;
            p_rwds_oe <= 1'b0;
            if (por_cnt == 18'(POR_CYCLES)) begin
                por_done_m <= 1'b1;
                state      <= S_IDLE;
            end else begin
                por_cnt <= por_cnt + 18'd1;
            end
        end

        S_IDLE: begin
            p_cs_n    <= 1'b1;
            p_dq_oe   <= 1'b0;
            p_rwds_oe <= 1'b0;
            if (req_tgl != req_seen && gap_ok) begin
                req_seen    <= req_tgl;
                x_we        <= c_we | c_reg;
                x_reg       <= c_reg;
                x_xc_r      <= c_xc;
                x_det_r     <= c_det;
                x_cal       <= c_cal;
                x_probe     <= c_probe;
                x_hw_m1     <= c_hw_m1;
                // The request-time constants this transaction later modifies
                // start from their clk-side values; everything static is
                // read from the c_* registers directly.
                end_m1      <= c_end_m1;
                rd_dat_ck   <= c_rd_dat_ck;
                rd_ck_more  <= 1'b1;
                rd_ck_last  <= c_rd_ck_last;
                lat2x       <= c_lat2x0;
                lat_known   <= c_lat_known0;
                in_ca       <= 1'b1;
                w_tail      <= 1'b0;
                w_lt_lat1   <= 1'b1;
                w_lt_end    <= 1'b1;
                w_more      <= 1'b1;
                rd_more     <= 1'b1;
                to_cyc      <= 8'hFF;     // armed when the data CK goes out
                rel_cyc     <= 8'hFF;
                rel_obs_cyc <= 8'hFF;
                rd_open     <= 1'b0;
                past_2x     <= 1'b0;
                to_hit      <= 1'b0;
                rel_hit     <= 1'b0;
                rel_obs_hit <= 1'b0;
                hw_out      <= 6'd0;
                hw_in       <= 6'd0;
                ck_cnt      <= 8'd0;
                cyc         <= 8'd0;
                have_hw0    <= 1'b0;
                rd_started  <= 1'b0;
                rd_align    <= 1'b0;
                rd_pad      <= 1'b0;
                obs2x       <= 1'b0;
                lat_ca      <= 1'b0;
                state       <= S_XFER;
            end
        end

        S_XFER: begin
            cyc    <= cyc + 8'd1;
            p_cs_n <= 1'b0;

            if (cyc == CA0 + 8'd2)
                in_ca <= 1'b0;

            if (in_ca) begin
                // ---- Command / address ----
                p_dq_oe   <= 1'b1;
                p_rwds_oe <= 1'b0;
                if (cyc >= CA0) begin
                    p_ck_en <= 1'b1;
                    ck_cnt  <= ck_cnt + 8'd1;
                end
                if (cyc == CA0 + 8'd1) begin
                    p_dq_r <= c_ca[31:24]; p_dq_f <= c_ca[23:16];
                end else if (cyc == CA0 + 8'd2) begin
                    p_dq_r <= c_ca[15:8];  p_dq_f <= c_ca[7:0];
                end else begin
                    p_dq_r <= c_ca[47:40]; p_dq_f <= c_ca[39:32];
                end
            end else if (x_reg) begin
                // ---- Register write: one data clock right after CA ----
                if (cyc == CA0 + 8'd3) begin
                    p_dq_oe <= 1'b1;
                    p_dq_r  <= c_regdata[15:8];
                    p_dq_f  <= c_regdata[7:0];
                    p_ck_en <= 1'b1;
                end else if (x_xc && !w_tail) begin
                    // Xccela tCHD: CE# must stay low >= 2.5 ns after the
                    // last CLK falling edge (one more cycle; HyperBus
                    // tCSH is 0)
                    p_dq_oe <= 1'b0;
                    w_tail  <= 1'b1;
                end else begin
                    p_cs_n     <= 1'b1;
                    p_dq_oe    <= 1'b0;
                    gap_cnt    <= 4'(GAP_LOAD);
                    err_m      <= 1'b0;
                    lat2x_m    <= 1'b0;
                    mism_m     <= 1'b0;
                    done_tgl_m <= ~done_tgl_m;
                    state      <= S_IDLE;
                end
            end else if (x_we) begin
                // ---- Memory write ----
                p_dq_oe   <= 1'b0;
                p_rwds_oe <= 1'b0;
                if (w_lt_lat1) begin
                    p_ck_en <= 1'b1;                    // 1x latency clocks
                    ck_cnt  <= ck_cnt + 8'd1;
                    if (ck_cnt == c_lat1_m1) w_lt_lat1 <= 1'b0;
                    if (ck_cnt == end_m1)  w_lt_end  <= 1'b0;
                end else if (!lat_known) begin
                    // CK paused (LOW) until the latency decision is in
                end else if (w_lt_end) begin
                    p_ck_en <= 1'b1;                    // 2x extra latency
                    ck_cnt  <= ck_cnt + 8'd1;
                    if (ck_cnt == end_m1) w_lt_end <= 1'b0;
                end else if (w_more) begin
                    p_ck_en   <= 1'b1;
                    ck_cnt    <= ck_cnt + 8'd1;
                    if (hw_out == x_hw_m1) w_more <= 1'b0;
                    p_dq_oe   <= 1'b1;
                    p_rwds_oe <= 1'b1;
                    p_dq_r    <= wr_b0;
                    p_dq_f    <= wr_b1;
                    p_rwds_r  <= wr_m0;
                    p_rwds_f  <= wr_m1;
                    hw_out    <= hw_out + 6'd1;
                end else if (x_xc && !w_tail) begin
                    w_tail    <= 1'b1;              // Xccela tCHD (see register write)
                end else begin
                    p_cs_n     <= 1'b1;
                    gap_cnt    <= 4'(GAP_LOAD);
                    err_m      <= 1'b0;
                    lat2x_m    <= lat2x;
                    mism_m     <= 1'b0;
                    done_tgl_m <= ~done_tgl_m;
                    state      <= S_IDLE;
                end
            end else begin
                // ---- Memory read ----
                p_dq_oe   <= 1'b0;
                p_rwds_oe <= 1'b0;
                if (rd_ck_more) begin
                    p_ck_en <= 1'b1;
                    ck_cnt  <= ck_cnt + 8'd1;
                    w_tail  <= 1'b0;                // tail counts from the last CK
                    if (ck_cnt == rd_ck_last) rd_ck_more <= 1'b0;
                    if (ck_cnt == rd_dat_ck) begin
                        // (re)base the end-of-read predictions on the
                        // actual data CK (moves for 2x reads)
                        to_cyc  <= cyc + c_off_to;
                        rel_cyc <= cyc + c_off_rel;
                        to_hit  <= 1'b0;
                        rel_hit <= c_off_rel_z;
                    end
                end else if (lat_known &&
                             ((x_xc || x_det) ? (rd_started ? relobs_now : rel_now)
                                              : (rel_now && (!rd_started || relobs_now)))) begin
                    // All CKs out and the last byte is sampled at the IDDR
                    // by now: release CS#. Xccela reads and boot probes
                    // release on the observed arrival only: the prediction
                    // (rel_now) assumes the calibrated arr, which a boot
                    // probe does not have yet. (Xccela: one cycle after the
                    // last CK, tCHD >= 2.5 ns)
                    if (x_xc && !w_tail) begin
                        w_tail  <= 1'b1;
                    end else begin
                        p_cs_n  <= 1'b1;
                        gap_cnt <= 4'(GAP_LOAD);
                        state   <= S_DRAIN;
                    end
                end
                // 2x fallback: no data where 1x data should be. If the 2x
                // data CK has already gone out (long burst, CK never
                // paused), rebase the predictions on it here. After the CK
                // block so its rd_ck_more re-arm wins over a same-cycle
                // last-1x-CK clear (never the same cycle as the data CK:
                // this is arr + 2 cycles after it).
                if (lat_known && !lat2x && !rd_started && cyc == c_rd_2x_cyc) begin
                    lat2x      <= 1'b1;
                    rd_dat_ck  <= c_lat2p1;
                    rd_ck_last <= c_tot2_m1;
                    rd_ck_more <= 1'b1;
                    if (ck_cnt > c_lat2p1) begin
                        to_cyc  <= c_d2_to;
                        rel_cyc <= c_d2_rel;
                        to_hit  <= 1'b0;
                        rel_hit <= 1'b0;
                    end
                end
            end
        end

        S_DRAIN: begin
            // CS# is high; the capture pipeline finishes (or times out)
            cyc       <= cyc + 8'd1;
            p_cs_n    <= 1'b1;
            p_dq_oe   <= 1'b0;
            p_rwds_oe <= 1'b0;
            if (!rd_more) begin
                err_m      <= rd_pad;
                lat2x_m    <= rd_started ? obs2x : lat2x;
                mism_m     <= !x_xc && rd_started && !rd_pad && (obs2x != lat_ca);
                done_tgl_m <= ~done_tgl_m;
                state      <= S_IDLE;
                if (x_probe && rd_started && !rd_pad && !obs2x &&
                    arr_meas >= 8'd3 && arr_meas <= 8'd14) begin
                    arr_cyc  <= arr_meas[3:0];
                    arr_half <= rd_align;
                end
            end
        end

        default: state <= S_POR;
        endcase

        // ---- latency sample (RWDS during CA) ----
        // After the FSM so a 2x decision overrides a same-cycle w_lt_end
        // clear from the last 1x latency clock.
        if (state == S_XFER && !x_reg && !x_xc && cyc == c_lat_smp_cyc) begin
            lat_ca <= lat_smp;
            if (!lat_known) begin
                lat2x      <= lat_smp;
                lat_known  <= 1'b1;
                end_m1     <= lat_smp ? c_lat2_m1 : c_lat1_m1;
                if (lat_smp) w_lt_end <= 1'b1;   // writes wait at ck_cnt = lat1
                rd_dat_ck  <= lat_smp ? c_lat2p1  : c_lat1;
                rd_ck_last <= lat_smp ? c_tot2_m1 : c_tot1_m1;
                if (lat_smp) rd_ck_more <= 1'b1;   // 2x: more CKs than the 1x total armed
            end
        end

        // ---- Xccela strobe arrival: CKs still needed ----
        // rd_ck_last was trimmed in the capture block to ck_cnt + trim - 1;
        // the new total is above the CK issued this cycle (if one was) only
        // if trim > 1. After the FSM so this wins over its clear.
        if (xc_strobe)
            rd_ck_more <= !rd_ck_more || c_xc_trim_gt1;

        if (!rst_n_m) begin
            state      <= S_POR;
            por_cnt    <= 18'd0;
            por_done_m <= 1'b0;
            req_seen   <= req_tgl;
            p_cs_n     <= 1'b1;
            p_ck_en    <= 1'b0;
            p_dq_oe    <= 1'b0;
            p_rwds_oe  <= 1'b0;
            rq_wp_m    <= 2'd0;
            gap_cnt    <= 4'd0;
            hw_in      <= 6'd0;
            x_we       <= 1'b1;
            rd_more    <= 1'b0;
            rd_ck_more <= 1'b0;
        end
    end

    // =====================================================================
    // PHY
    // =====================================================================
    logic dly_load_r;
    hyperram_phy_gw5a u_phy (
        .clk_mem    (clk_mem),
        .clk_mem_90 (clk_mem_90),
        .clk_cap    (clk_cap),
        .cs_n       (p_cs_n),
        .ck_en      (p_ck_en),
        .dq_oe      (p_dq_oe),
        .dq_o_r     (p_dq_r),
        .dq_o_f     (p_dq_f),
        .rwds_oe    (p_rwds_oe),
        .rwds_o_r   (p_rwds_r),
        .rwds_o_f   (p_rwds_f),
        .dq_i_r     (i_dq_r),
        .dq_i_f     (i_dq_f),
        .rwds_i_r   (i_rwds_r),
        .rwds_i_f   (i_rwds_f),
        .dly_code   (dly_code),
        .dly_load   (dly_load_r),
        .hr_ck      (hr_ck),
        .hr_cs_n    (hr_cs_n),
        .hr_rwds    (hr_rwds),
        .hr_dq      (hr_dq)
    );

    // =====================================================================
    // clk domain: front end — boot sequence, calibration, user requests
    // =====================================================================
    localparam [4:0] F_POR      = 5'd0;
    localparam [4:0] F_CR0      = 5'd1;
    localparam [4:0] F_CR0_WAIT = 5'd2;
    localparam [4:0] F_CAL_WR   = 5'd3;
    localparam [4:0] F_CAL_WRW  = 5'd4;
    localparam [4:0] F_CAL_SET  = 5'd5;
    localparam [4:0] F_CAL_RD   = 5'd6;
    localparam [4:0] F_CAL_RDW  = 5'd7;
    localparam [4:0] F_CAL_SCAN = 5'd8;
    localparam [4:0] F_READY    = 5'd9;
    localparam [4:0] F_BUSY     = 5'd10;
    localparam [4:0] F_CFG_WAIT = 5'd11;
    localparam [4:0] F_CAL_RDD  = 5'd12;
    localparam [4:0] F_CR0_DONE = 5'd13;
    localparam [4:0] F_CAL_WRD  = 5'd14;
    // Boot probe / Xccela init (PROTOCOL != 0)
    localparam [4:0] F_DET_XC   = 5'd15;   // Xccela MRR MA=1 -> {MR2, MR1}
    localparam [4:0] F_DET_XCW  = 5'd16;
    localparam [4:0] F_DET_GBR  = 5'd17;   // Xccela Global Reset frame
    localparam [4:0] F_DET_GBRW = 5'd18;
    localparam [4:0] F_DET_TRST = 5'd19;   // tRST
    localparam [4:0] F_DET_HB   = 5'd20;   // HyperBus ID0 read
    localparam [4:0] F_DET_HBW  = 5'd21;
    localparam [4:0] F_XC_MR0   = 5'd22;
    localparam [4:0] F_XC_MR0W  = 5'd23;
    localparam [4:0] F_XC_MR4   = 5'd24;
    localparam [4:0] F_XC_MR4W  = 5'd25;
    localparam [4:0] F_CFG_WAIT2 = 5'd26;  // second MRW of a cfg_cr0_write
    localparam [4:0] F_DET_SET  = 5'd27;   // set the probe's input-delay tap
    localparam [4:0] F_DET_SETW = 5'd28;
    localparam [4:0] F_CFG_MR4  = 5'd29;   // second MRW of a cfg_cr0_write: issue
    localparam [4:0] F_DET_XCD  = 5'd30;   // probe result decisions, one clk after done
    localparam [4:0] F_DET_HBD  = 5'd31;

    logic [4:0]  fstate;
    logic        done_seen;
    logic [1:0]  rq_rp;
    logic        init_done_r;
    logic [5:0]  cal_bin;
    logic [3:0]  cal_rep;
    logic [4:0]  cal_word;
    logic        cal_fail;
    logic        cal_err;
    logic        det_err;            // rd_err of the last boot probe
    // Calibration compare, one clk behind the read-queue drain
    logic        cmp_v;
    logic [31:0] cmp_word, cmp_pat;
    // Read arrival as seen from clk. arr_cyc changes at the clk_mem edge
    // that toggles done_tgl_m, and the next issue() comes at least one clk
    // after the front end has seen that done, so this copy is current then.
    logic [3:0]  arr_c;
    always_ff @(posedge clk) arr_c <= arr_cyc;
    logic        cal_vfy;            // verify reads at the chosen tap
    logic        cal_wr2;            // second pattern write
    logic [1:0]  cal_try;
    logic [3:0]  settle;
    // run scan
    logic [5:0]  sc_b, sc_s;
    logic        sc_in;
    logic [6:0]  sc_best;
    logic [7:0]  sc_tap;

    wire         done_evt = (done_tgl_m != done_seen) && (rq_rp == rq_wp_m);
    wire         rq_avail = (rq_rp != rq_wp_m);
    wire         cal_cmp  = (fstate == F_CAL_RDW);
    wire         det_cmp  = XC_EN && ((fstate == F_DET_XCW) || (fstate == F_DET_HBW));

    // Boot probe state. The probe runs before calibration, so the input
    // delay tap is still the default and may sit outside the eye for this
    // board: each probe is tried at four taps (default, 128, 64, 192;
    // 0.8 ns apart on a 3.2 ns line against a 4.6 ns bit) before the next
    // phase. Phases: 0 Xccela MRR, 1 Global Reset then Xccela MRR again,
    // 2 HyperBus ID0. The ID check rejects a capture at a bad tap.
    logic [1:0]  det_phase;
    logic [1:0]  det_tap;
    wire  [7:0]  det_tap_code = (det_tap == 2'd0) ? DLY_DEFAULT :
                                (det_tap == 2'd1) ? 8'd128 :
                                (det_tap == 2'd2) ? 8'd64 : 8'd192;
    logic [15:0] det_word;           // first halfword of the probe read
    logic [15:0] trst_cnt;
    // Xccela: MR1[4:0] vendor = 0x0D (APM), MR2[2:0] a defined density
    wire         xc_id_ok = (det_word[4:0] == 5'h0D) &&
                            (det_word[10:8] == 3'b001 || det_word[10:8] == 3'b011 ||
                             det_word[10:8] == 3'b101 || det_word[10:8] == 3'b111 ||
                             det_word[10:8] == 3'b110);
    // HyperBus: ID0 arrives byte A first; manufacturer in [3:0]
    // (1 Infineon/Cypress, 3 ISSI, 6 Winbond)
    wire  [15:0] hb_id0   = {det_word[7:0], det_word[15:8]};
    wire         hb_id_ok = (hb_id0[3:0] == 4'h1) || (hb_id0[3:0] == 4'h3) || (hb_id0[3:0] == 4'h6);

    assign init_done  = init_done_r;
    assign cr0_active = c_cr0;
    assign ready      = (fstate == F_READY);
    assign rd_arrival = {arr_cyc, arr_half};

    // Run scan helpers (one bin per clk)
    wire         sc_pass  = (sc_b < 6'(NBINS)) && cal_map[sc_b[4:0]];
    wire  [5:0]  sc_e     = sc_b - 6'd1;
    wire  [5:0]  sc_len   = sc_b - sc_s;
    wire         sc_lo    = (sc_s == 6'd0);
    wire         sc_hi    = (sc_e == 6'(NBINS - 1));
    // Longest passing run wins; its centre is the tap with the largest
    // guaranteed margin (a run touching tap 0 or the top may extend past
    // the end of the delay line, but that margin is not observable).
    wire  [6:0]  sc_score = (sc_lo && sc_hi) ? 7'd127 : {1'b0, sc_len};
    wire  [7:0]  sc_ptap  = (sc_lo && sc_hi) ? 8'd128 :
                            8'(({2'b0, sc_s} + {2'b0, sc_e}) << (CAL_STEP_LOG2 - 1));

    wire  [7:0]  sc_pick  = (sc_in && sc_score > sc_best) ? sc_ptap : sc_tap;
    wire  [7:0]  dly_target = dly_force ? dly_force_code : cal_tap;

    // Issue a request: latch the command fields and, in the same clk cycle,
    // the request-time constants the core needs (c_*, see their
    // declarations). The latency terms come from the registered lat_r /
    // rlat*_r / wlat*_r / fixed_r copies; a register write uses none of them.
    // In PROTOCOL 0 builds is_xc / is_det / is_rreg / is_gbrst fold to 0.
    task automatic issue(input is_we, input is_reg, input is_rreg, input is_gbrst,
                         input is_det, input is_xc, input is_cal, input is_probe,
                         input [ADDR_WIDTH-1:0] a, input [4:0] n,
                         input [7:0] ma, input [15:0] regdata);
        logic        xc, det, rreg, gbrst, xcwr, sel2, endsel;
        logic [7:0]  hw, arr, rlat, lat1, lat2;
        logic [31:0] xc_addr, hw_addr;
        begin
            xc      = XC_EN && is_xc;
            det     = XC_EN && is_det;
            rreg    = XC_EN && is_rreg;
            gbrst   = XC_EN && is_gbrst;
            xcwr    = xc && is_we && !is_reg;              // Xccela memory write: WLC
            hw      = is_reg ? 8'd1 : rreg ? 8'd2 : {2'b0, n, 1'b0};
            arr     = {4'b0, arr_c};
            // Boot probes assume latency 5 for the read window and clock out
            // to 2 + 2*7 (the device's latency is unknown then; reads are
            // framed).
            rlat    = det ? 8'd5  : lat_r;
            lat1    = det ? 8'd7  : xcwr ? wlat1_r : rlat1_r;
            lat2    = det ? 8'd16 : xcwr ? wlat2_r : rlat2_r;
            // Xccela reads and boot probes clock the worst case (2x);
            // Xccela writes always use WLC (no 2x, even in fixed mode).
            sel2    = fixed_r || xc || det;
            endsel  = fixed_r && !(xc && is_we);
            xc_addr = 32'({a, 2'b00});                      // Xccela byte address
            hw_addr = {{(31-ADDR_WIDTH){1'b0}}, a, 1'b0};   // HyperBus halfword address

            c_we      <= is_we;
            c_reg     <= is_reg;
            c_det     <= det;
            c_xc      <= xc;
            c_cal     <= is_cal;
            c_probe   <= is_probe;
            // Xccela MRW data byte rides on CK#4 rising (falling half: don't care)
            c_regdata <= xc ? {regdata[7:0], regdata[7:0]} : regdata;
            req_tgl   <= ~req_tgl;

            // Command/address frame. Xccela: INST held for the whole first
            // clock, then the 32-bit byte address A3..A0; MRW/MRR/Global
            // Reset carry MA in the A0 slot. HyperBus: CA0..CA5.
            c_ca <= xc ? (is_reg ? {gbrst ? 16'hFFFF : 16'hC0C0, 16'h0000, 8'h00, ma} :
                          rreg   ? {16'h4040, 16'h0000, 8'h00, ma} :
                          is_we  ? {16'hA0A0, xc_addr} : {16'h2020, xc_addr})
                       : (is_reg ? 48'h60_0001_00_0000 :
                          rreg   ? 48'hE0_0000_00_0000 :
                                   {~is_we, 1'b0, 1'b1, hw_addr[31:3], 13'd0, hw_addr[2:0]});
            c_hw_m1       <= hw[5:0] - 6'd1;
            c_hw_m5       <= hw - 8'd5;
            c_hw_le5      <= (hw <= 8'd5);
            c_lat1        <= lat1;
            c_lat2p1      <= lat2 + 8'd1;
            c_lat1_m1     <= lat1 - 8'd1;
            c_lat2_m1     <= lat2 - 8'd1;
            c_end_m1      <= endsel ? lat2 - 8'd1 : lat1 - 8'd1;
            c_rd_dat_ck   <= sel2 ? lat2 + 8'd1 : lat1;
            // last CK index = total - 1 (read totals: 1x lat1 + hw, 2x
            // lat2 + hw + 1 spare)
            c_rd_ck_last  <= sel2 ? lat2 + hw : lat1 + hw - 8'd1;
            c_tot1_m1     <= lat1 + hw - 8'd1;
            c_tot2_m1     <= lat2 + hw;
            c_lat_smp_cyc <= CA0 + arr;
            c_data1_cyc   <= CA0 + lat1;
            // 2x (+spare) data CK cycle without a pause, plus the timeout /
            // release offsets (the read fallback rebases on it)
            c_d2_to       <= CA0 + lat2 + 8'd1 + hw + arr + 8'(RD_TIMEOUT);
            c_d2_rel      <= CA0 + lat2 + 8'd1 + hw + arr - 8'd5;
            c_rd_open_cyc <= CA0 + rlat + arr - 8'd1;        // data1 + arr - 2, -1 for the flag
            c_rd_2x_cyc   <= CA0 + 8'd4 + rlat + arr;        // data1 + arr + 2
            c_off_to      <= hw + arr + 8'(RD_TIMEOUT);
            c_off_rel     <= hw + arr - 8'd5;                // arr >= 3, hw >= 2
            c_off_rel_z   <= (hw + arr == 8'd5);
            // Xccela strobe-arrival trim (see the rd_ck_last update on the
            // first strobe): trim = hw + 2 - arr CKs still to issue, never
            // below the CK issued that cycle (trim >= 1). Stored as trim - 1
            // and "trim > 1" (= hw + 1 > arr).
            c_xc_trim_m1  <= (hw + 8'd2 > arr + 8'd1) ? hw + 8'd1 - arr : 8'd0;
            c_xc_trim_gt1 <= (hw + 8'd1 > arr);
            // Xccela: no latency indication during CA. Reads clock the worst
            // case and are strobe-framed; writes are never 2x.
            c_lat2x0      <= xc ? !is_we : (fixed_r || det);
            c_lat_known0  <= fixed_r || xc || det;
        end
    endtask

    always_ff @(posedge clk) begin
        if (wbuf_we && fstate == F_READY)
            c_wbuf[wbuf_idx] <= {wbuf_be, wbuf_data};
    end

    // Statistics, one clk after done (keeps the done handshake crossing
    // narrow)
    logic xfer_mism;
    always_ff @(posedge clk) begin
        if (done) begin
            stat_xfers <= stat_xfers + 32'd1;
            if (xfer_lat2x) stat_lat2x        <= stat_lat2x + 32'd1;
            if (rd_err)     stat_rd_timeouts  <= stat_rd_timeouts + 32'd1;
            if (xfer_mism)  stat_lat_mismatch <= stat_lat_mismatch + 32'd1;
        end
        if (!rst_n) begin
            stat_xfers        <= 32'd0;
            stat_lat2x        <= 32'd0;
            stat_rd_timeouts  <= 32'd0;
            stat_lat_mismatch <= 32'd0;
        end
    end

    always_ff @(posedge clk) begin
        rvalid     <= 1'b0;
        done       <= 1'b0;
        dly_load_r <= 1'b0;

        // Read data queue drain (user reads and calibration reads). The
        // calibration compare runs one clk behind the drain: rq_data_m is a
        // clk_mem register and the 32-bit compare did not fit the
        // one-clk_mem-period crossing in the a2p25 full core. cal_fail is
        // still set before F_CAL_RDD looks at it: done_evt needs rq_rp to
        // have caught up with rq_wp_m, which is the clk after the last drain.
        cmp_v <= 1'b0;
        if (rq_avail) begin
            rq_rp    <= rq_rp + 2'd1;
            cmp_word <= rq_data_m[rq_rp];
            cmp_pat  <= cal_pattern(cal_word[3:0]);
            if (cal_cmp) begin
                cmp_v    <= 1'b1;
                cal_word <= cal_word + 5'd1;
            end else if (det_cmp) begin
                det_word <= rq_data_m[rq_rp][15:0];
            end else begin
                rvalid <= 1'b1;
                rdata  <= rq_data_m[rq_rp];
            end
        end
        if (cmp_v && cmp_word != cmp_pat)
            cal_fail <= 1'b1;
        // synthesis translate_off
        if (cmp_v && (cmp_word !== cmp_pat))   // X/Z sampled: a fail in sim
            cal_fail <= 1'b1;
        // synthesis translate_on

        case (fstate)
        F_POR:
            if (por_done_m) begin
                det_phase <= 2'd0;
                det_tap   <= 2'd0;
                fstate    <= (PROTOCOL == 0) ? F_CR0 : F_DET_SET;
            end

        // ---- Boot probe. Xccela frames first: they are harmless to a
        // HyperRAM (its register decode ignores addresses outside CR0/CR1
        // and the ID registers are read-only), while the HyperBus ID read
        // (INST E0) is undefined on an Xccela part. A device that does not
        // answer at any tap gets one Global Reset (harmless to a HyperRAM
        // too: an aborted register read) and a second round, which covers
        // a cold APS part waiting for its Phase-2 reset. Only then is
        // HyperBus tried. Probe reads are strobe-framed with a wide window
        // and release CS# on the observed arrival, so neither the device's
        // current latency nor the calibrated arrival matters.
        F_DET_SET: if (XC_EN) begin
            dly_code   <= det_tap_code;
            dly_load_r <= 1'b1;
            settle     <= 4'd8;
            fstate     <= F_DET_SETW;
        end

        F_DET_SETW: if (XC_EN) begin
            if (settle != 4'd0) settle <= settle - 4'd1;
            else                fstate <= (det_phase == 2'd2) ? F_DET_HB : F_DET_XC;
        end

        F_DET_XC: if (XC_EN) begin
            issue(1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, '0, 5'd1, 8'h01, c_cr0);
            fstate <= F_DET_XCW;
        end

        // The probe's outcome is decided one clk after the done handshake
        // (done_tgl_m / rq_wp_m / err_m are one-clk_mem-period crossings; the
        // decision cone stays off them)
        F_DET_XCW: if (XC_EN) begin
            if (done_evt) begin
                done_seen <= done_tgl_m;
                det_err   <= err_m;
                fstate    <= F_DET_XCD;
            end
        end

        F_DET_XCD: if (XC_EN) begin
            if (!det_err && xc_id_ok) begin
                proto_xccela <= 1'b1;
                dev_id       <= det_word;
                fstate       <= F_XC_MR0;
            end else if (det_tap != 2'd3) begin
                det_tap <= det_tap + 2'd1;
                fstate  <= F_DET_SET;
            end else if (det_phase == 2'd0) begin
                det_phase <= 2'd1;
                det_tap   <= 2'd0;
                fstate    <= F_DET_GBR;
            end else if (PROTOCOL == 1) begin
                proto_xccela <= 1'b1;        // forced: proceed blind
                det_fail     <= 1'b1;
                dev_id       <= det_word;
                fstate       <= F_XC_MR0;
            end else begin
                det_phase <= 2'd2;
                det_tap   <= 2'd0;
                fstate    <= F_DET_SET;
            end
        end

        F_DET_GBR: if (XC_EN) begin
            issue(1'b1, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, '0, 5'd1, 8'h00, 16'h0000);
            fstate <= F_DET_GBRW;
        end

        F_DET_GBRW: if (XC_EN) begin
            if (done_evt) begin
                done_seen <= done_tgl_m;
                trst_cnt  <= 16'(TRST_CYCLES);
                fstate    <= F_DET_TRST;
            end
        end

        F_DET_TRST: if (XC_EN) begin
            if (trst_cnt == 16'd0) fstate <= F_DET_SET;
            else                   trst_cnt <= trst_cnt - 16'd1;
        end

        F_DET_HB: if (XC_EN) begin
            issue(1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, '0, 5'd1, 8'h00, c_cr0);
            fstate <= F_DET_HBW;
        end

        F_DET_HBW: if (XC_EN) begin
            if (done_evt) begin
                done_seen <= done_tgl_m;
                det_err   <= err_m;
                fstate    <= F_DET_HBD;
            end
        end

        F_DET_HBD: if (XC_EN) begin
            if (!det_err && hb_id_ok) begin
                proto_xccela <= 1'b0;
                dev_id       <= hb_id0;
                fstate       <= F_CR0;
            end else if (det_tap != 2'd3) begin
                det_tap <= det_tap + 2'd1;
                fstate  <= F_DET_SET;
            end else begin
                proto_xccela <= 1'b0;        // nothing identified: HyperBus, flagged
                dev_id       <= hb_id0;
                det_fail     <= 1'b1;
                fstate       <= F_CR0;
            end
        end

        // ---- Xccela init: MR0 (latency, drive) then MR4 (write latency).
        // MR writes have fixed latency 1, so they are valid whatever the
        // device currently holds (warm reload without a reset).
        F_XC_MR0: if (XC_EN) begin
            c_cr0 <= XC_CFG;
            issue(1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, '0, 5'd1, 8'h00, {8'h00, XC_MR0});
            fstate <= F_XC_MR0W;
        end

        F_XC_MR0W: if (XC_EN) begin
            if (done_evt) begin
                done_seen <= done_tgl_m;
                fstate    <= F_XC_MR4;
            end
        end

        F_XC_MR4: if (XC_EN) begin
            issue(1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, '0, 5'd1, 8'h04, {8'h00, XC_MR4});
            fstate <= F_XC_MR4W;
        end

        F_XC_MR4W: if (XC_EN) begin
            if (done_evt) begin
                done_seen <= done_tgl_m;
                fstate    <= F_CR0_DONE;
            end
        end

        F_CR0: begin
            issue(1'b1, 1'b1, 1'b0, 1'b0, 1'b0, proto_q, 1'b0, 1'b0, '0, 5'd1, 8'h00, c_cr0);
            fstate <= F_CR0_WAIT;
        end

        F_CR0_WAIT:
            if (done_evt) begin
                done_seen <= done_tgl_m;
                fstate    <= F_CR0_DONE;
            end

        F_CR0_DONE: begin
            if (CAL_ENABLE) begin
                cal_try <= 2'd0;
                cal_wr2 <= 1'b0;
                fstate  <= F_CAL_WR;
            end else begin
                dly_code    <= dly_force ? dly_force_code : DLY_DEFAULT;
                cal_tap     <= DLY_DEFAULT;
                dly_load_r  <= 1'b1;
                cal_ok      <= 1'b1;
                init_done_r <= 1'b1;
                fstate      <= F_READY;
            end
        end

        F_CAL_WR: begin
            issue(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, proto_q, 1'b1, 1'b0, CAL_ADDR, 5'(MAX_BURST), 8'h00, c_cr0);
            fstate <= F_CAL_WRW;
        end

        F_CAL_WRW:
            if (done_evt) begin
                done_seen <= done_tgl_m;
                fstate    <= F_CAL_WRD;
            end

        F_CAL_WRD: begin
            if (cal_wr2) begin
                cal_bin <= 6'd0;
                cal_map <= 32'd0;
                cal_vfy <= 1'b0;
                fstate  <= F_CAL_SET;
            end else begin
                cal_wr2 <= 1'b1;
                fstate  <= F_CAL_WR;
            end
        end

        F_CAL_SET: begin
            if (!cal_vfy) begin
                dly_code   <= 8'({cal_bin[4:0], 3'b000} << (CAL_STEP_LOG2 - 3));
                dly_load_r <= 1'b1;
            end
            cal_rep  <= 4'd0;
            cal_fail <= 1'b0;
            settle   <= 4'd8;
            fstate   <= F_CAL_RD;
        end

        F_CAL_RD:
            if (settle != 4'd0) begin
                settle <= settle - 4'd1;
            end else begin
                cal_word <= 5'd0;
                issue(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, proto_q, 1'b0, cal_vfy, CAL_ADDR, 5'(MAX_BURST), 8'h00, c_cr0);
                fstate <= F_CAL_RDW;
            end

        F_CAL_RDW:
            // Only the handshake here (done_tgl_m is a one-clk_mem-period
            // crossing); the bookkeeping happens in F_CAL_RDD.
            if (done_evt) begin
                done_seen <= done_tgl_m;
                cal_err   <= err_m;
                fstate    <= F_CAL_RDD;
            end

        F_CAL_RDD: begin
            if (cal_rep == 4'(CAL_REPEATS - 1)) begin
                if (cal_vfy) begin
                    if (cal_fail || cal_err || cal_word != 5'(MAX_BURST)) begin
                        fstate <= F_CAL_SCAN;   // retry path below
                        sc_b   <= 6'd63;
                    end else begin
                        cal_ok      <= 1'b1;
                        init_done_r <= 1'b1;
                        fstate      <= F_READY;
                    end
                end else begin
                    cal_map[cal_bin[4:0]] <= !(cal_fail || cal_err || cal_word != 5'(MAX_BURST));
                    if (cal_bin == 6'(NBINS - 1)) begin
                        sc_b    <= 6'd0;
                        sc_s    <= 6'd0;
                        sc_in   <= 1'b0;
                        sc_best <= 7'd0;
                        sc_tap  <= 8'd0;
                        fstate  <= F_CAL_SCAN;
                    end else begin
                        cal_bin <= cal_bin + 6'd1;
                        fstate  <= F_CAL_SET;
                    end
                end
            end else begin
                if (cal_err || cal_word != 5'(MAX_BURST)) cal_fail <= 1'b1;
                cal_rep  <= cal_rep + 4'd1;
                cal_word <= 5'd0;
                settle   <= 4'd0;
                fstate   <= F_CAL_RD;
            end
        end

        F_CAL_SCAN: begin
            if (sc_b == 6'd63) begin
                // verify failed / no window: retry or give up
                if (cal_try != 2'(CAL_RETRIES - 1)) begin
                    cal_try <= cal_try + 2'd1;
                    cal_wr2 <= 1'b0;
                    fstate  <= F_CAL_WR;
                end else begin
                    cal_ok      <= 1'b0;
                    dly_code    <= dly_force ? dly_force_code : DLY_DEFAULT;
                    cal_tap     <= DLY_DEFAULT;
                    dly_load_r  <= 1'b1;
                    init_done_r <= 1'b1;
                    fstate      <= F_READY;
                end
            end else begin
                if (sc_pass && !sc_in) begin
                    sc_s  <= sc_b;
                    sc_in <= 1'b1;
                end else if (!sc_pass && sc_in) begin
                    sc_in <= 1'b0;
                    if (sc_score > sc_best) begin
                        sc_best <= sc_score;
                        sc_tap  <= sc_ptap;
                    end
                end
                if (sc_b == 6'(NBINS)) begin
                    if (sc_best == 7'd0 && !(sc_in && sc_score != 7'd0)) begin
                        sc_b <= 6'd63;
                    end else begin
                        dly_code   <= dly_force ? dly_force_code : sc_pick;
                        cal_tap    <= sc_pick;
                        dly_load_r <= 1'b1;
                        cal_vfy    <= 1'b1;
                        fstate     <= F_CAL_SET;
                    end
                end else begin
                    sc_b <= sc_b + 6'd1;
                end
            end
        end

        F_READY: begin
            if (recal && CAL_ENABLE) begin
                init_done_r <= 1'b0;
                cal_ok      <= 1'b0;
                cal_try     <= 2'd0;
                cal_wr2     <= 1'b0;
                fstate      <= F_CAL_WR;
            end else if (cfg_cr0_write) begin
                // HyperBus: one CR0 write. Xccela: MRW MR0 now, MR4 next.
                c_cr0  <= cfg_cr0;
                issue(1'b1, 1'b1, 1'b0, 1'b0, 1'b0, proto_q, 1'b0, 1'b0, '0, 5'd1, 8'h00,
                      proto_q ? {8'h00, cfg_cr0[7:0]} : cfg_cr0);
                fstate <= F_CFG_WAIT;
            end else if (req) begin
                c_w0  <= wdata;
                c_be0 <= wbe;
                issue(we, 1'b0, 1'b0, 1'b0, 1'b0, proto_q, 1'b0, 1'b0, addr, len, 8'h00, c_cr0);
                fstate <= F_BUSY;
            end else if (dly_code != dly_target) begin
                dly_code   <= dly_target;
                dly_load_r <= 1'b1;
            end
        end

        F_BUSY:
            if (done_evt) begin
                done_seen  <= done_tgl_m;
                done       <= 1'b1;
                rd_err     <= err_m;
                xfer_lat2x <= lat2x_m;
                xfer_mism  <= mism_m;
                fstate     <= F_READY;
            end

        F_CFG_WAIT:
            if (done_evt) begin
                done_seen <= done_tgl_m;
                fstate    <= proto_q ? F_CFG_MR4 : F_READY;
            end

        // Xccela: the MR4 half of a cfg_cr0_write, issued one clk after the
        // MR0 write's done so the done handshake does not gate the command
        // registers
        F_CFG_MR4: if (XC_EN) begin
            issue(1'b1, 1'b1, 1'b0, 1'b0, 1'b0, proto_q, 1'b0, 1'b0, '0, 5'd1, 8'h04, {8'h00, c_cr0[15:8]});
            fstate <= F_CFG_WAIT2;
        end

        F_CFG_WAIT2: if (XC_EN) begin
            if (done_evt) begin
                done_seen <= done_tgl_m;
                fstate    <= F_READY;
            end
        end

        default: fstate <= F_POR;
        endcase

        if (!rst_n) begin
            fstate            <= F_POR;
            c_cr0             <= (PROTOCOL == 1) ? XC_CFG : CR0_VALUE;
            c_reg             <= 1'b0;
            c_we              <= 1'b0;
            c_cal             <= 1'b0;
            c_probe           <= 1'b0;
            c_det             <= 1'b0;
            c_xc              <= (PROTOCOL == 1);
            c_regdata         <= (PROTOCOL == 1) ? XC_CFG : CR0_VALUE;
            cmp_v             <= 1'b0;
            proto_xccela      <= (PROTOCOL == 1);
            dev_id            <= 16'h0000;
            det_fail          <= 1'b0;
            det_phase         <= 2'd0;
            det_tap           <= 2'd0;
            req_tgl           <= 1'b0;
            done_seen         <= done_tgl_m;
            rq_rp             <= 2'd0;
            init_done_r       <= 1'b0;
            cal_ok            <= 1'b0;
            cal_map           <= 32'd0;
            cal_vfy           <= 1'b0;
            dly_code          <= DLY_DEFAULT;
            cal_tap           <= DLY_DEFAULT;
            dly_load_r        <= 1'b1;
            rd_err            <= 1'b0;
            xfer_lat2x        <= 1'b0;
        end
    end

endmodule
