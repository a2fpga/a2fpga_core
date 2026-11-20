//
// Apple IIgs runtime detector
//
// (c) 2023,2024,2025,2026 Ed Anuff <ed@a2fpga.com>
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
// Detects whether the host machine is an Apple IIgs by watching for
// read-modify-write access pairs to the NEWVIDEO register ($C029) on the
// slot bus.
//
// The IIgs ROM reset handler at $FA62 begins with TSB $C029 (NEWVIDEO),
// which the slot sees as a read of $C029 immediately followed by a write
// to $C029 — the first slot-visible CPU activity after /RES deasserts.
// $C029 is a VGC (Mega II side) register, so both halves of the R-M-W
// synchronize to 1.024 MHz Mega II cycles and appear at the slots; any
// later GS software R-M-W of NEWVIDEO (e.g. turning SHR on) re-fires the
// signature at runtime.
//
// The comparator watches $C029, plus $C036 for accelerator cards. From
// the motherboard CPU, per the Apple IIgs Hardware Reference (pp. 15, 25),
// the Speed ($C036), Shadow ($C035), and DMA registers are FPI-internal
// and are read AND written at high speed with no Mega II cycle — the
// monitor's GOTOBANKFF $C036 speed save/restore never reaches the slot
// bus. The State register ($C068) and Slot ROM Select ($C02D) exist in
// both ICs: writes cross at 1.024 MHz (slot-visible — which is why
// apple_memory's $C068 write capture works) but reads are satisfied by
// the FPI at 2.8 MHz, so a read-then-write pair on $C068 can never be
// observed; $C068 stays out of the comparator. A DMA bus master, however,
// has no FPI: an accelerator's speed-register accesses must cross the
// slot bus, and the TransWarp GS emits $C036 pairs before drawing its
// SHR splash — see the comparator comment in the body for why catching
// those early matters.
//
// No IIe/II+ firmware or software generates a read of $C029 followed
// within a few cycles by a write to the same address: on an 8-bit machine
// $C029 is an unassigned location that reads floating bus, and the
// paired-access qualifier rejects both stray reads and blind writes.
// The comparator also deliberately excludes $C100-$C7FF, which the slot
// ID boot scan touches on all machines.
//
// A second, independent signature fingerprints the ROM itself from the
// reset-vector fetch sequence (all machines exit reset at 1.024 MHz — the
// GS Speed register is hardware-cleared on reset, HW Ref p. 22 — so the
// fetch stream is slow on every machine). See the FSM comment in the body
// for the byte table, which was verified against ROM01/ROM03/IIe/II+ dumps
// rather than source listings.
//
// The fingerprint is deliberately asymmetric: the goal is only ever to
// positively identify a GS. Swapped/custom ROMs and clones (common on the
// II/II+/IIe) simply never complete the sequence or return an unknown
// byte, leaving both outputs unlatched — the machine is treated as 8-bit
// by default, which is the safe fallback. Such machines just don't get
// the iie_detected pair-matcher lockout; that lockout is opportunistic
// hardening, never load-bearing for correctness.
//
// Accelerators (verified against the TransWarp GS 1.8s ROM disassembly):
// the TWGS boots its own CPU from card-local ROM at bank $BC (invisible),
// then reads the real $00FFFC/$00FFFD over the bus and chains into the
// motherboard ROM reset at $FA62, which runs on the card CPU with I/O
// uncacheable — so the TSB $C029 pair still crosses the bus as DMA cycles
// and pair detection works. The fingerprint FSM stays benignly silent
// there (the TWGS reads $FFFC twice, breaking the sequence) and cannot
// false-latch the IIe lockout (bus data at $FA62 is $A9 on any GS).
// Crucially, that ROM chain happens AFTER the TWGS has already drawn its
// SHR splash into bank $E1 — detection must latch before those writes so
// m2b0 bank qualification shadows them correctly. The splash path itself
// provides the trigger: Play_Startup_Intro calls GS_FAST (LDAL/STAL
// $E0C036, a slot-visible $C036 pair) before Init_Intro_Graphics touches
// $C029 or bank $E1, which is why $C036 is in the comparator.
//
// Detection is sticky until FPGA reset (the host machine cannot change
// while powered) — reset_n_i must be the board's device_reset_n, never a
// reset that folds in the Apple /RES line (see apple_bus). Sampling follows the soft-switch capture idiom in
// apple_memory.sv: at phi1_posedge, addr/rw_n describe the bus cycle that
// just completed. The detector must see the bus unqualified by M2SEL
// (m2sel_n gating is itself enabled by the sw_gs this module helps derive),
// so it takes the raw latched address/rw lines from the bus module.
//

module gs_detector #(
    // Max bus cycles between the read and the write of an R-M-W pair.
    // On the GS both halves of TSB/LDA-STA sync to consecutive 1MHz
    // Mega II cycles, but allow slack for interleaved non-CPU cycles.
    parameter int PAIR_WINDOW = 4
) (
    input clk_i,
    input reset_n_i,

    input phi1_posedge_i,      // sample strobe: addr/rw/data reflect completed cycle
    input [15:0] addr_i,
    input rw_n_i,
    input [7:0] data_i,

    output reg gs_detected_o,  // sticky: IIgs signature seen
    output reg iie_detected_o, // sticky: 8-bit (IIe/II+ autostart) ROM fingerprinted
    output reg gs_event_o      // single-clock strobe per detection event (debug)
);

    // $C029 NEWVIDEO — the only GS-only register whose reads AND writes
    // both generate slot-visible Mega II cycles from the motherboard CPU
    // (see header). Any WRITE to it is accepted as GS evidence, not just
    // R-M-W pairs: no 8-bit machine writes $C029 (the SHRG_MODE capture in
    // apple_memory* has relied on exactly that for years), and hardware
    // testing on a TransWarp GS showed the blind-write path is essential —
    // the TWGS splash opens with STAL $E0C029 (data $41) BEFORE clearing
    // bank $E1, and that write is the earliest slot-visible GS evidence on
    // that machine, so sw_gs/m2b0 must latch on it for the splash to
    // shadow correctly. The same hardware test showed NO $C036 traffic
    // from the TWGS: it evidently virtualizes CYAREG in its on-card
    // hardware (speed management is the card's core function), so the
    // GS_FAST LDAL/STAL pairs from the ROM listing never reach the bus.
    // $C036 stays in the pair matcher anyway — it is free, harmless on
    // stock machines (FPI-internal, never seen), and may help other
    // accelerators that do pass it through.
    // On an 8-bit machine the ROM fingerprint's iie_detected lockout
    // (below) suppresses the residual false-positive paths (GS-probing
    // software poking these registers on a IIe); the uncovered corner is
    // FPGA power-up into an already-running IIe (no reset observed) plus
    // such software — accepted as rare, and no worse than the existing
    // $C029 SHRG capture's exposure.
    wire addr_is_gs_reg = (addr_i == 16'hC029) ||
                          (addr_i == 16'hC036);

    reg [15:0] pending_addr_r;
    reg [$clog2(PAIR_WINDOW+1)-1:0] window_r;

    // ROM reset fingerprint: the reset (or JMP ($FFFC)) sequence is three
    // consecutive read cycles — $FFFC data $62, $FFFD data $FA, then the
    // opcode fetch at $FA62. Every slot machine's ROM vectors to $FA62
    // (IIgs ROM01/ROM03, IIe enhanced/unenhanced, II+ autostart; verified
    // from ROM dumps), and the first opcode byte discriminates:
    //   $A9 (LDA #$01, leading into TSB $C029) -> IIgs
    //   $D8 (CLD)                              -> IIe / II+ autostart
    // On 8-bit machines every fetch is slot-visible, so this positively
    // identifies them at each reset and locks out the R-M-W pair matcher
    // (GS-probing software poking $C029 on a IIe can no longer false-latch).
    // On a GS it only fires if slow-mode ROM fetches reach the slot bus
    // (open hardware question); if they don't, the pair matcher still
    // detects via the TSB $C029 I/O cycles, which always cross.
    // A repeat of the previous matched cycle holds state rather than
    // aborting, tolerating double-fired phi1_posedge on II+ choppy-edge
    // machines.
    localparam [1:0] FP_IDLE = 2'd0;
    localparam [1:0] FP_VECLO = 2'd1;   // seen ($FFFC, $62)
    localparam [1:0] FP_VECHI = 2'd2;   // seen ($FFFD, $FA)
    reg [1:0] fp_state_r;

    wire fp_arm = rw_n_i && (addr_i == 16'hFFFC) && (data_i == 8'h62);

    always @(posedge clk_i or negedge reset_n_i) begin
        if (!reset_n_i) begin
            gs_detected_o <= 1'b0;
            iie_detected_o <= 1'b0;
            gs_event_o <= 1'b0;
            pending_addr_r <= 16'h0000;
            window_r <= '0;
            fp_state_r <= FP_IDLE;
        end else begin
            gs_event_o <= 1'b0;
            if (phi1_posedge_i) begin

                // Blind-write trigger (suppressed once an 8-bit ROM is
                // fingerprinted): any write to $C029 is GS evidence — the
                // earliest available on a TransWarp (splash STAL $E0C029).
                if (!rw_n_i && (addr_i == 16'hC029) && !iie_detected_o) begin
                    gs_detected_o <= 1'b1;
                    gs_event_o <= 1'b1;
                end

                // R-M-W pair matcher (suppressed once an 8-bit ROM is fingerprinted)
                if (rw_n_i && addr_is_gs_reg) begin
                    // read of a GS-only register arms (or re-arms) the window
                    pending_addr_r <= addr_i;
                    window_r <= PAIR_WINDOW[$clog2(PAIR_WINDOW+1)-1:0];
                end else begin
                    if (window_r != '0) begin
                        window_r <= window_r - 1'b1;
                        if (!rw_n_i && (addr_i == pending_addr_r) && !iie_detected_o) begin
                            gs_detected_o <= 1'b1;
                            gs_event_o <= 1'b1;
                            window_r <= '0;
                        end
                    end
                end

                // ROM reset fingerprint
                case (fp_state_r)
                    FP_VECLO: begin
                        if (rw_n_i && (addr_i == 16'hFFFD) && (data_i == 8'hFA))
                            fp_state_r <= FP_VECHI;
                        else if (!fp_arm)   // repeat of ($FFFC,$62) holds state
                            fp_state_r <= FP_IDLE;
                    end
                    FP_VECHI: begin
                        if (rw_n_i && (addr_i == 16'hFA62)) begin
                            if (data_i == 8'hA9) begin
                                gs_detected_o <= 1'b1;
                                gs_event_o <= 1'b1;
                            end else if (data_i == 8'hD8) begin
                                iie_detected_o <= 1'b1;
                                gs_event_o <= 1'b1;
                            end
                            fp_state_r <= FP_IDLE;
                        end else if (!(rw_n_i && (addr_i == 16'hFFFD) && (data_i == 8'hFA))) begin
                            fp_state_r <= fp_arm ? FP_VECLO : FP_IDLE;
                        end
                    end
                    default: begin  // FP_IDLE
                        if (fp_arm) fp_state_r <= FP_VECLO;
                    end
                endcase
            end
        end
    end

endmodule
