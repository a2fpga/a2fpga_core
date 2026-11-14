//============================================================================
//  A2MEGA S7 accelerator - Apple IIgs memory-map replica (S7a)
//
//  Soft-switch tracker derived from the I/O handling of rtl/iigs.sv in the
//  MiSTer Apple IIgs core (https://github.com/MiSTer-devel/Apple-IIgs_MiSTer),
//  wrapped around gs_mmu_decode.sv (the port of its rtl/mmu.sv):
//
//  Copyright (c) Pierre Cornier
//  Copyright (c) Steven A. Wilson
//  Copyright (c) Alan Steremberg
//  a2mega replica (c) 2026 Ed Anuff <ed@a2fpga.com>
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program. If not, see <https://www.gnu.org/licenses/>.
//============================================================================
//
// Description
// -----------
// The card's copy of the machine's memory map
// (docs/gs_socket_s7_accelerator_scoping.md 2.3).  Two halves:
//
//  * Tracker (clocked).  Every soft switch that moves the map is written or
//    read through I/O space, and I/O space is never local, so every access
//    that changes the map is a socket cycle.  The broker reports each
//    COMPLETED socket cycle here (cyc_stb_i with the address, direction and
//    write data the FPI and the Mega II saw), and the tracker follows the
//    same rules they do.  It never looks at the core's local accesses, so
//    its state is by construction a function of what the motherboard saw.
//
//      $C000/1 80STORE   $C002/3 RAMRD    $C004/5 RAMWRT   $C006/7 INTCXROM
//      $C008/9 ALTZP     $C00A/B SLOTC3ROM                      (writes)
//      $C028   ROMBANK toggle, any access (ROM 01 only)
//      $C029   NEWVIDEO bit 0 = bank latch                      (write)
//      $C02D   SLTROMSEL   $C035 SHADOW   $C036 CYAREG          (writes)
//      $C054/5 PAGE2       $C056/7 HIRES                        (any access)
//      $C068   STATEREG = {ALTZP,PAGE2,RAMRD,RAMWRT,RDROM,LCBNK2,ROMBANK,INTCXROM}
//      $C080-$C08F language card: bank / ROM-read from the address; an even
//              access write-protects; two successive odd READS write-enable;
//              any write clears the pre-write latch
//      $C3xx   with SLOTC3ROM = 0 sets INTC8ROM; $CFFF clears it (any access)
//
//    Reset state (sw_reset_i, = the machine's /RESET): the IIe switches
//    clear, the language card reads ROM / bank 2 / write-enabled, SHADOW =
//    $08, CYAREG = $80, bank latch set, SLTROMSEL = 0 - the MiSTer model's
//    reset values.
//
//    Differences from the MiSTer tracker, chosen to match the machine: the
//    $C000-$C00B switches respond in every bank where the address decodes
//    as I/O (MiSTer restricts them to banks 00/E0; the machine has one I/O
//    space), HIRES is cleared by reset, INTC8ROM and ROMBANK exist.
//
//  * Decode (combinational): gs_mmu_decode on the access the core is about
//    to make, with the tracked state.  A second instance translates the
//    address of the NEXT step as a read (pf_*), for the data-late broker's
//    speculative memory read; only its address outputs are used.
//
module gs_mmu_replica #(
    parameter bit ROM3 = 1'b0          // 0 = ROM 01 machine, 1 = ROM 3
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sw_reset_i,          // machine reset: switches to their reset state

    // configuration (quasi-static)
    input  logic        cxrom_local_i,       // serve internal $C100-$CFFF firmware locally
    input  logic [6:0]  exp_banks_i,         // expansion banks backed by the card
    input  logic        slow_copy_i,         // the card keeps a copy of Mega II RAM below $C000 (gs_mmu_decode)
    input  logic        slow_local_i,        // ... and reads of it are the card's

    // a completed socket cycle (what the motherboard saw)
    input  logic        cyc_stb_i,
    input  logic [23:0] cyc_addr_i,
    input  logic        cyc_we_i,            // 1 = write
    input  logic [7:0]  cyc_wdata_i,

    // the access to classify (combinational)
    input  logic [23:0] acc_addr_i,
    input  logic        acc_we_i,            // 1 = write
    input  logic        acc_vpb_n_i,
    output logic [2:0]  acc_region_o,
    output logic [23:0] acc_phys_o,          // RAM address after aux / language-card translation
    output logic        acc_local_o,
    output logic        acc_forward_write_o,
    output logic        acc_local_we_o,
    output logic        acc_local_rom_o,
    output logic [17:0] acc_rom_addr_o,
    output logic        acc_side_effect_o,
    output logic        acc_slow_only_o,     // a socket write stored in the copy of Mega II RAM alone
    // ... and gs_mmu_decode's cheap view (near memory: the first clk of a step) of the
    // access at acc_faddr_i, the step's address before any substitution
    input  logic [23:0] acc_faddr_i,
    output logic        acc_fast_rw_o,
    output logic        acc_fast_int_o,
    output logic        acc_fast_rom_o,
    output logic [1:0]  acc_fast_rbank_o,
    output logic        acc_fast_aux_o,
    output logic        acc_fast_fold_o,
    output logic        acc_fast_exp_o,
    output logic        acc_fast_sock_o,

    // prefetch view (S7 data-late step): the same decode of pf_addr_i - the core's
    // NEXT-step address - as a read and as a write, with the tracked state, for the
    // broker to register a step ahead.
    input  logic [23:0] pf_addr_i,
    output logic [23:0] pf_phys_o,           // read: RAM address
    output logic [17:0] pf_rom_addr_o,       // read: ROM-image address
    output logic        pf_local_o,          // read: served by the card
    output logic        pf_local_rom_o,      // read: ... from the ROM image
    output logic        pf_side_o,           // an access there can change machine state (I/O, Cx)
    output logic [16:0] pf_ram_ra_o,         // read: address for the bank-00/01 RAM itself (below)
    output logic [17:0] pf_rom_ra_o,         // read: address for the ROM image itself (below)
    output logic [23:0] pfw_phys_o,          // write: RAM address
    output logic        pfw_local_o,         // write: goes to the card's memory
    output logic        pfw_local_we_o,      // write: ... and is stored
    output logic        pfw_forward_o,       // write: ... and must also go to the socket
    output logic        sw_touch_o,          // this clk a socket cycle may have moved the map

    // tracked state (telemetry, tests)
    output logic [7:0]  shadow_o,            // $C035
    output logic [7:0]  cyareg_o,            // $C036
    output logic [7:0]  sltromsel_o,         // $C02D
    output logic [7:0]  statereg_o,          // $C068 view
    output logic [7:0]  misc_o               // {0, bank_latch, INTC8ROM, SLOTC3ROM, 80STORE, HIRES, LC_WE, LC_WE_PRE}
);

    logic       store80, ramrd, ramwrt, intcxrom, altzp, slotc3rom;
    logic       page2, hires, rdrom, lcram2, lc_we, lc_we_pre, rombank, intc8rom;
    logic       bank_latch;
    logic [7:0] shadow, cyareg, sltromsel;

    // ------------------------------------------------------------------ tracker
    wire [7:0]  cb = cyc_addr_i[23:16];
    wire [15:0] ca = cyc_addr_i[15:0];
    wire cyc_main = (cb == 8'h00) || (cb == 8'h01);
    wire cyc_mega = (cb == 8'hE0) || (cb == 8'hE1);
    wire cyc_iolc = (cyc_main && !shadow[6]) || cyc_mega;
    // $C000-$C0FF where it decodes as I/O (gs_mmu_decode: IO | EXTERNAL_IO)
    wire cyc_io   = (ca[15:8] == 8'hC0) &&
                    (cyc_iolc || (cyareg[4] && cb >= 8'h02 && cb <= 8'h7F));
    // $C100-$CFFF slot space
    wire cyc_cx   = (ca[15:12] == 4'hC) && (ca[11:8] != 4'h0) && cyc_iolc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            store80 <= 1'b0; ramrd <= 1'b0; ramwrt <= 1'b0; intcxrom <= 1'b0;
            altzp <= 1'b0; slotc3rom <= 1'b0; page2 <= 1'b0; hires <= 1'b0;
            rdrom <= 1'b1; lcram2 <= 1'b1; lc_we <= 1'b1; lc_we_pre <= 1'b0;
            rombank <= 1'b0; intc8rom <= 1'b0; bank_latch <= 1'b1;
            shadow <= 8'h08; cyareg <= 8'h80; sltromsel <= 8'h00;
        end else if (sw_reset_i) begin
            store80 <= 1'b0; ramrd <= 1'b0; ramwrt <= 1'b0; intcxrom <= 1'b0;
            altzp <= 1'b0; slotc3rom <= 1'b0; page2 <= 1'b0; hires <= 1'b0;
            rdrom <= 1'b1; lcram2 <= 1'b1; lc_we <= 1'b1; lc_we_pre <= 1'b0;
            rombank <= 1'b0; intc8rom <= 1'b0; bank_latch <= 1'b1;
            shadow <= 8'h08; cyareg <= 8'h80; sltromsel <= 8'h00;
        end else if (cyc_stb_i) begin
            if (cyc_io) begin
                // ---- switches that respond to writes only
                if (cyc_we_i) begin
                    unique case (ca[7:0])
                        8'h00: store80   <= 1'b0;
                        8'h01: store80   <= 1'b1;
                        8'h02: ramrd     <= 1'b0;
                        8'h03: ramrd     <= 1'b1;
                        8'h04: ramwrt    <= 1'b0;
                        8'h05: ramwrt    <= 1'b1;
                        8'h06: intcxrom  <= 1'b0;
                        8'h07: intcxrom  <= 1'b1;
                        8'h08: altzp     <= 1'b0;
                        8'h09: altzp     <= 1'b1;
                        8'h0A: slotc3rom <= 1'b0;
                        8'h0B: slotc3rom <= 1'b1;
                        8'h29: bank_latch <= cyc_wdata_i[0];
                        8'h2D: sltromsel <= cyc_wdata_i;
                        8'h35: shadow    <= cyc_wdata_i;
                        8'h36: cyareg    <= cyc_wdata_i;
                        8'h68: {altzp, page2, ramrd, ramwrt, rdrom, lcram2, rombank, intcxrom} <= cyc_wdata_i;
                        default: ;
                    endcase
                end
                // ---- switches that respond to any access
                if (ca[7:2] == 6'b0101_01) begin               // $C054-$C057
                    if (!ca[1]) page2 <= ca[0];
                    else        hires <= ca[0];
                end
                if (ca[7:0] == 8'h28 && !ROM3)                 // ROMBANK toggle (ROM 01)
                    rombank <= ~rombank;
                if (ca[7:4] == 4'h8) begin                     // $C080-$C08F language card
                    lcram2 <= ~ca[3];
                    rdrom  <= ca[0] ^ ca[1];
                    if (!ca[0]) begin
                        // even: write-protect, pre-write cleared
                        lc_we     <= 1'b0;
                        lc_we_pre <= 1'b0;
                    end else if (cyc_we_i) begin
                        // odd write: never changes write-enable; clears pre-write
                        lc_we_pre <= 1'b0;
                    end else begin
                        // odd read: the second in succession write-enables
                        if (lc_we_pre) lc_we <= 1'b1;
                        lc_we_pre <= 1'b1;
                    end
                end
            end else if (cyc_cx) begin
                if (ca[11:8] == 4'h3 && !slotc3rom) intc8rom <= 1'b1;
                if (ca[11:0] == 12'hFFF)            intc8rom <= 1'b0;
            end
        end
    end

    assign shadow_o    = shadow;
    assign cyareg_o    = cyareg;
    assign sltromsel_o = sltromsel;
    assign statereg_o  = {altzp, page2, ramrd, ramwrt, rdrom, lcram2, rombank, intcxrom};
    assign misc_o      = {1'b0, bank_latch, intc8rom, slotc3rom, store80, hires, lc_we, lc_we_pre};

    // ------------------------------------------------------------------ decode
    gs_mmu_decode u_decode (
        .bank_log(acc_addr_i[23:16]), .addr_log(acc_addr_i[15:0]),
        .we(acc_we_i), .vpb_n(acc_vpb_n_i), .rom_select(~ROM3),
        .LCRAM2(lcram2), .RDROM(rdrom), .LC_WE(lc_we), .shadow(shadow),
        .ALTZP(altzp), .RAMRD(ramrd), .RAMWRT(ramwrt), .STORE80(store80),
        .PAGE2(page2), .HIRES_MODE(hires), .bank_latch(bank_latch),
        .shadow_all(cyareg[4]), .SLTROMSEL(sltromsel),
        .INTCXROM(intcxrom), .SLOTC3ROM(slotc3rom), .INTC8ROM(intc8rom), .ROMBANK(rombank),
        .cxrom_local(cxrom_local_i), .exp_banks(exp_banks_i), .slow_copy(slow_copy_i), .slow_local(slow_local_i),
        .addr_bus(acc_phys_o),
        .aux(), .lcram2_sel(), .inhibit_cxxx(), .IO(), .EXTERNAL_IO(),
        .is_internal_io(), .is_internal(), .fastram_ce(), .slowram_ce(), .slowram_we(),
        .rom1_ce(), .rom2_ce(), .romc_ce(), .romd_ce(), .slot_ce(), .slot_internalrom_ce(),
        .rom_writethrough(),
        .region(acc_region_o), .is_local(acc_local_o), .forward_write(acc_forward_write_o),
        .local_we(acc_local_we_o), .local_rom(acc_local_rom_o), .rom_addr(acc_rom_addr_o),
        .side_effect(acc_side_effect_o), .slow_only(acc_slow_only_o),
        .fast_rw(), .fast_int(), .fast_rom(), .fast_rbank(), .fast_aux(), .fast_fold(), .fast_exp(), .fast_sock()
    );

    // (the cheap view only: everything else of this instance is unconnected)
    gs_mmu_decode u_decode_f (
        .bank_log(acc_faddr_i[23:16]), .addr_log(acc_faddr_i[15:0]),
        .we(acc_we_i), .vpb_n(acc_vpb_n_i), .rom_select(~ROM3),
        .LCRAM2(lcram2), .RDROM(rdrom), .LC_WE(lc_we), .shadow(shadow),
        .ALTZP(altzp), .RAMRD(ramrd), .RAMWRT(ramwrt), .STORE80(store80),
        .PAGE2(page2), .HIRES_MODE(hires), .bank_latch(bank_latch),
        .shadow_all(cyareg[4]), .SLTROMSEL(sltromsel),
        .INTCXROM(intcxrom), .SLOTC3ROM(slotc3rom), .INTC8ROM(intc8rom), .ROMBANK(rombank),
        .cxrom_local(cxrom_local_i), .exp_banks(exp_banks_i), .slow_copy(slow_copy_i), .slow_local(slow_local_i),
        .addr_bus(),
        .aux(), .lcram2_sel(), .inhibit_cxxx(), .IO(), .EXTERNAL_IO(),
        .is_internal_io(), .is_internal(), .fastram_ce(), .slowram_ce(), .slowram_we(),
        .rom1_ce(), .rom2_ce(), .romc_ce(), .romd_ce(), .slot_ce(), .slot_internalrom_ce(),
        .rom_writethrough(),
        .region(), .is_local(), .forward_write(), .local_we(), .local_rom(), .rom_addr(),
        .side_effect(), .slow_only(),
        .fast_rw(acc_fast_rw_o), .fast_int(acc_fast_int_o), .fast_rom(acc_fast_rom_o),
        .fast_rbank(acc_fast_rbank_o), .fast_aux(acc_fast_aux_o), .fast_fold(acc_fast_fold_o),
        .fast_exp(acc_fast_exp_o), .fast_sock(acc_fast_sock_o)
    );

    // ------------------------------------------------------------------ prefetch translation
    gs_mmu_decode u_decode_pf (
        .bank_log(pf_addr_i[23:16]), .addr_log(pf_addr_i[15:0]),
        .we(1'b0), .vpb_n(1'b1), .rom_select(~ROM3),
        .LCRAM2(lcram2), .RDROM(rdrom), .LC_WE(lc_we), .shadow(shadow),
        .ALTZP(altzp), .RAMRD(ramrd), .RAMWRT(ramwrt), .STORE80(store80),
        .PAGE2(page2), .HIRES_MODE(hires), .bank_latch(bank_latch),
        .shadow_all(cyareg[4]), .SLTROMSEL(sltromsel),
        .INTCXROM(intcxrom), .SLOTC3ROM(slotc3rom), .INTC8ROM(intc8rom), .ROMBANK(rombank),
        .cxrom_local(cxrom_local_i), .exp_banks(exp_banks_i), .slow_copy(slow_copy_i), .slow_local(slow_local_i),
        .addr_bus(pf_phys_o),
        .aux(), .lcram2_sel(), .inhibit_cxxx(), .IO(), .EXTERNAL_IO(),
        .is_internal_io(), .is_internal(), .fastram_ce(), .slowram_ce(), .slowram_we(),
        .rom1_ce(), .rom2_ce(), .romc_ce(), .romd_ce(), .slot_ce(), .slot_internalrom_ce(),
        .rom_writethrough(),
        .region(), .is_local(pf_local_o), .forward_write(), .local_we(), .local_rom(pf_local_rom_o), .rom_addr(pf_rom_addr_o),
        .side_effect(pf_side_o), .slow_only(),
        .fast_rw(), .fast_int(), .fast_rom(), .fast_rbank(), .fast_aux(), .fast_fold(), .fast_exp(), .fast_sock()
    );

    gs_mmu_decode u_decode_pfw (
        .bank_log(pf_addr_i[23:16]), .addr_log(pf_addr_i[15:0]),
        .we(1'b1), .vpb_n(1'b1), .rom_select(~ROM3),
        .LCRAM2(lcram2), .RDROM(rdrom), .LC_WE(lc_we), .shadow(shadow),
        .ALTZP(altzp), .RAMRD(ramrd), .RAMWRT(ramwrt), .STORE80(store80),
        .PAGE2(page2), .HIRES_MODE(hires), .bank_latch(bank_latch),
        .shadow_all(cyareg[4]), .SLTROMSEL(sltromsel),
        .INTCXROM(intcxrom), .SLOTC3ROM(slotc3rom), .INTC8ROM(intc8rom), .ROMBANK(rombank),
        .cxrom_local(cxrom_local_i), .exp_banks(exp_banks_i), .slow_copy(slow_copy_i), .slow_local(slow_local_i),
        .addr_bus(pfw_phys_o),
        .aux(), .lcram2_sel(), .inhibit_cxxx(), .IO(), .EXTERNAL_IO(),
        .is_internal_io(), .is_internal(), .fastram_ce(), .slowram_ce(), .slowram_we(),
        .rom1_ce(), .rom2_ce(), .romc_ce(), .romd_ce(), .slot_ce(), .slot_internalrom_ce(),
        .rom_writethrough(),
        .region(), .is_local(pfw_local_o), .forward_write(pfw_forward_o), .local_we(pfw_local_we_o),
        .local_rom(), .rom_addr(), .side_effect(), .slow_only(),
        .fast_rw(), .fast_int(), .fast_rom(), .fast_rbank(), .fast_aux(), .fast_fold(), .fast_exp(), .fast_sock()
    );

    // The addresses the two local memories are read at, for the speculative
    // launch.  They carry only what each memory needs: the 128 KB RAM is only
    // ever USED for banks 00/01 and the ROM image for banks 00/01 and the ROM
    // banks, so the bank byte is not compared - for those banks the result is
    // exactly pf_phys_o[16:0] / pf_rom_addr_o (gs_mmu_decode: the language-card
    // $Dxxx bank-1 fold of A12, the main/aux select as bank bit 0, the ROM
    // bank), for any other bank it is a don't-care.  This keeps the late bank
    // bits of the core's next address off all but one address bit of each
    // memory.  The broker checks, in simulation, every use against the full
    // decode.
    wire fold_en  = ~lcram2 & ~rdrom & ~shadow[6];
    wire [15:0] pa = pf_addr_i[15:0];
    wire aux00_rd = ((pa[15:9] == 7'b0000000) | (pa[15:14] == 2'b11)) ? altzp :
                    (pa[15:10] == 6'b000001) ? ((store80 & page2) | (~store80 & ramrd)) :
                    (pa[15:13] == 3'b001)    ? ((store80 & page2 & hires) | ((~store80 | ~hires) & ramrd)) :
                                               ramrd;
    assign pf_ram_ra_o = {pf_addr_i[16] | aux00_rd, pa[15:13], pa[12] & ~((pa[15:13] == 3'b110) & fold_en), pa[11:0]};
    assign pf_rom_ra_o = {pf_addr_i[17] | ~pf_addr_i[23], pf_addr_i[16] | ~pf_addr_i[23], pa};

    // every switch the tracker holds changes only in a clk with this strobe
    assign sw_touch_o = cyc_stb_i & (cyc_io | cyc_cx);

endmodule
