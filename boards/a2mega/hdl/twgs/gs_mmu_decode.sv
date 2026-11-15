//============================================================================
//  A2MEGA S7 accelerator - Apple IIgs memory-map decode (replica, S7a)
//
//  Ported from rtl/mmu.sv of the MiSTer Apple IIgs core
//  (https://github.com/MiSTer-devel/Apple-IIgs_MiSTer):
//
//  Copyright (c) Pierre Cornier
//  Copyright (c) Steven A. Wilson
//  Copyright (c) Alan Steremberg
//  a2mega port and accelerator outputs (c) 2026 Ed Anuff <ed@a2fpga.com>
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
// Logical (CPU-side) address + soft-switch state -> physical region, exactly
// as the FPI (banks 00-7F, ROM, shadowing) and the Mega II (banks E0/E1, IIe
// soft switches, language card, I/O, slots) decode it.  Pure combinational
// function of {bank_log, addr_log, we, vpb_n} and register state: no clock,
// no state.  The first half of the file is the MiSTer decode, unchanged in
// function (its outputs keep their names and are swept against the MiSTer
// golden model in sim/mmu/); the second half adds what the S7 broker needs
// (docs/gs_socket_s7_accelerator_scoping.md 2.2-2.4):
//
//   is_local       the access is served entirely from the card's own memory
//                  (banks 00/01 fast RAM incl. language-card RAM, the ROM
//                  image, the expansion banks the card backs); everything
//                  else is a socket cycle
//   forward_write  a local RAM write that the machine shadows into E0/E1 and
//                  that must therefore ALSO be run on the socket as an
//                  ordinary write, so the FPI performs the shadow copy
//   local_we       the local write is stored (0 = discarded: write-protected
//                  language card, ROM)
//   region / rom_addr / addr_bus   where the byte lives
//
// Rules that are ours, not MiSTer's (each recorded in the scoping doc, 9):
//
//   * $C000-$C0FF I/O is never local, in any bank where it decodes as I/O.
//     One exception, which is ROM and not I/O: reads of $C071-$C07F in bank
//     00 are the FPI's interrupt-dispatch ROM bytes (MiSTer "IRQ dispatch
//     ROM", a fast cycle in its clock model; bench G27 saw the BRK vector
//     land at $C074) and come from the image.
//   * $C100-$CFFF of the I/O-shadowed banks ("Cx space") is a socket cycle
//     unless cxrom_local is set AND the page is internal firmware
//     (INTCXROM, or the slot's SLTROMSEL bit clear; slot 3: SLOTC3ROM clear;
//     $C800-$CFFF: INTCXROM or INTC8ROM).  $C3xx and $CFFF are ALWAYS socket
//     cycles: they change INTC8ROM / the slot cards' expansion-ROM latches,
//     so the motherboard and the cards must see them.  Writes to Cx space
//     are always socket cycles.  Banks E0/E1 are always socket cycles.
//   * ROM 01 only: while ROMBANK ($C028 toggle) is set the bank-00/01 ROM
//     windows are socket cycles - the motherboard decides which half of the
//     ROM appears there (bench finding G21, gs_socket_65816_scoping.md 4.5).
//     Banks FE/FF are unaffected and stay local.
//   * Expansion banks 02-7F are local only below 02 + exp_banks; the rest go
//     to the socket (the machine's own memory card, or nothing).
//   * ROM banks FC/FD exist only on ROM 3 (rom_select = 0).
//   * slow_copy: the card keeps a copy of the Mega II's RAM below $C000 of
//     banks E0/E1 (where there is no I/O and no language card), at its
//     physical address (addr_bus).  Every write the machine stores there is
//     stored in the copy too - local_we WITHOUT is_local: the write is still a
//     socket cycle and nothing else changes about it.  That is a write to
//     E0/E1 itself; a write the FPI shadows from a bank the card holds
//     (forward_write: the broker repeats the byte at E0 + addr_bus[16:0]);
//     and a write the FPI shadows from an expansion bank the card does not
//     hold (CYAREG[4]) - slow_only: a socket cycle whose byte goes to the
//     copy alone.  With slow_local a READ of that RAM is the card's
//     (is_local).  The copy is the same whether slow_local is set or not, so
//     it can be set and cleared at any step.  Docs: accel-only build 3h.
//
module gs_mmu_decode #(
    parameter RAMSIZE = 128           // number of 64K fast-RAM banks (MiSTer parameter)
)(
    // Logical address (CPU view)
    input  wire [7:0]  bank_log,
    input  wire [15:0] addr_log,
    input  wire        we,            // 1 = write cycle
    input  wire        vpb_n,         // 65C816 vector pull, active low
    input  wire        rom_select,    // 1 = ROM 01 machine (no TEXT2 shadow, 128 KB ROM, ROMBANK toggle)

    // Soft-switch / register state
    input  wire        LCRAM2,        // LC $Dxxx bank 2 selected
    input  wire        RDROM,         // LC reads come from ROM
    input  wire        LC_WE,         // LC write enable
    input  wire [7:0]  shadow,        // $C035 shadow register (bits are inhibits)
    input  wire        ALTZP,
    input  wire        RAMRD,
    input  wire        RAMWRT,
    input  wire        STORE80,
    input  wire        PAGE2,
    input  wire        HIRES_MODE,
    input  wire        bank_latch,    // NEWVIDEO[0]: 1 = E1 distinct from E0
    input  wire        shadow_all,    // CYAREG[4]: shadow video pages in all banks
    input  wire [7:0]  SLTROMSEL,     // $C02D slot ROM select

    // S7 additions: state and configuration
    input  wire        INTCXROM,      // $C006/$C007, STATEREG bit 0
    input  wire        SLOTC3ROM,     // $C00A/$C00B
    input  wire        INTC8ROM,      // set by $C3xx with SLOTC3ROM = 0, cleared by $CFFF
    input  wire        ROMBANK,       // ROM 01: $C028 toggle / STATEREG bit 1
    input  wire        cxrom_local,   // 1 = serve internal $C100-$CFFF firmware from the ROM image
    input  wire [6:0]  exp_banks,     // expansion banks backed by the card (02 .. 01+exp_banks)
    input  wire        slow_copy,     // the card keeps a copy of Mega II RAM below $C000 (quasi-static)
    input  wire        slow_local,    // ... and reads of it are the card's

    // Physical address & decode (MiSTer outputs)
    output wire [23:0] addr_bus,      // translated physical address
    output reg         aux,           // main/aux select (ORed into bank bit 0)
    output wire        lcram2_sel,    // LC RAM window active (feeds inhibit_cxxx)
    output wire        inhibit_cxxx,  // suppress $Cxxx slot/ROM decode
    output wire        IO,            // internal I/O space $C000-$C0FF
    output wire        EXTERNAL_IO,   // slot I/O $C090-$C0FF routed off-chip
    output wire        is_internal_io,
    output wire        is_internal,   // $CNxx slot ROM mapped to internal firmware
    output reg         fastram_ce,
    output reg         slowram_ce,
    output wire        slowram_we,
    output wire        rom1_ce,       // bank FE
    output wire        rom2_ce,       // bank FF + IIe-style windows in bank 00
    output wire        romc_ce,       // bank FC
    output wire        romd_ce,       // bank FD
    output wire        slot_ce,
    output wire        slot_internalrom_ce,
    output wire        rom_writethrough,

    // S7 additions: what the broker acts on
    output reg  [2:0]  region,        // REGION_* below
    output reg         is_local,      // served from the card's own memory
    output reg         forward_write, // local write that must also go to the socket
    output reg         local_we,      // local write is stored
    output reg         local_rom,     // local read comes from the ROM image (else RAM at addr_bus)
    output wire [17:0] rom_addr,      // ROM image address {bank[1:0], addr}: FC0000-FFFFFF -> 0-3FFFF
    output wire        side_effect,   // I/O or Cx space: a read here can change machine state
    output wire        slow_only,     // a socket write whose byte the card stores at E0 + addr_bus[16:0] and nowhere else

    // S7 near memory (gs_accel_broker NEAR): a cheap view of the common cases, for
    // the first clk of a step - a few levels of logic from the address, `we`, /VP
    // and a handful of switches, with no bank arithmetic.  fast_rw is a SUBSET of
    // "is_local, no side effect, nothing to forward"; the fields beside it are the
    // full decode's answers for the accesses in that subset (the decode sweep
    // checks all of it against the outputs above, on every vector).
    output wire        fast_rw,       // this read / write is certainly the card's alone
    output wire        fast_int,      // an internal cycle at this address certainly has no side effect
    output wire        fast_rom,      // fast_rw read: the byte is in the ROM image ...
    output wire [1:0]  fast_rbank,    // ... in its bank rom_addr[17:16]
    output wire        fast_aux,      // fast_rw, RAM: bank bit 0 of the physical address
    output wire        fast_fold,     // fast_rw read, RAM: the language card moves A12
    output wire        fast_exp,      // fast_rw, RAM of an expansion bank: the physical address is the logical one
    // ... and the opposite certainty, from the bank alone: a read or a write here
    // is a cycle on the socket and nothing else (never local, nothing stored,
    // nothing to forward), whatever the switches say
    output wire        fast_sock
);

  localparam [2:0] REGION_RAM  = 3'd0;   // banks 00/01 fast RAM (incl. language-card RAM)
  localparam [2:0] REGION_ROM  = 3'd1;   // ROM image
  localparam [2:0] REGION_EXP  = 3'd2;   // expansion RAM, banks 02-7F
  localparam [2:0] REGION_SLOW = 3'd3;   // Mega II RAM, banks E0/E1
  localparam [2:0] REGION_IO   = 3'd4;   // $C000-$C0FF
  localparam [2:0] REGION_CX   = 3'd5;   // $C100-$CFFF slot / internal firmware space
  localparam [2:0] REGION_NONE = 3'd6;   // nothing the card knows about (motherboard decides)

  // ==========================================================================
  // MiSTer decode (rtl/mmu.sv), function unchanged
  // ==========================================================================

  // --------------------------------------------------------------------------
  // Main/aux select (IIe soft-switch model, extended to the IIgs banks)
  // --------------------------------------------------------------------------

  // All-bank shadow: When CYAREG[4]=1, even banks (02-7E) act like bank 00 for RAMRD/RAMWRT
  wire all_bank_shadow_even = shadow_all && (bank_log >= 8'h02 && bank_log <= 8'h7e) && ~bank_log[0];

  always @(*)
    begin: aux_ctrl
      aux = 1'b0;
      if ((bank_log==0 || bank_log==8'he0 || (bank_log==8'he1 && ~bank_latch)) && (addr_log[15:9] == 7'b0000000 | addr_log[15:14] == 2'b11))		// Page 00,01,C0-FF
        aux = ALTZP;
      else if ((bank_log==0 || bank_log==1 || bank_log==8'he0 || bank_log==8'he1) &&  addr_log[15:10] == 6'b000001)		// Page 04-07
        aux = ((bank_log==1 || (bank_log==8'he1 && bank_latch)) || ((bank_log==0 || bank_log==8'he0 || (bank_log==8'he1 && ~bank_latch)) &&   ( (STORE80 & PAGE2) | ((~STORE80) & ((RAMRD & (~we)) | (RAMWRT & we))))));
      else if (addr_log[15:13] == 3'b001)		// Page 20-3F
        aux = ((bank_log==1 || (bank_log==8'he1 && bank_latch)) || ((bank_log==0 || bank_log==8'he0 || (bank_log==8'he1 && ~bank_latch)) &&    ((STORE80 & PAGE2 & HIRES_MODE) | (((~STORE80) | (~HIRES_MODE)) & ((RAMRD & (~we)) | (RAMWRT & we))))));
      else if (all_bank_shadow_even)
        // All-bank shadow: RAMRD/RAMWRT redirects even banks to odd banks
        aux = ((RAMRD & ~we) | (RAMWRT & we));
      else
        aux = ((bank_log==1 || (bank_log==8'he1 && bank_latch)) || ((bank_log==0 || bank_log==8'he0 || (bank_log==8'he1 && ~bank_latch)) && ((RAMRD & (~we)) | (RAMWRT & we))));
    end

  // --------------------------------------------------------------------------
  // Logical -> physical address translation
  // --------------------------------------------------------------------------

  // The guards ensure addr_log is in $D000-$DFFF wherever the A12 fold applies,
  // so this concatenation is exactly "addr_log - 16'h1000".
  wire [15:0] addr_lc_fold = {addr_log[15:13], 1'b0, addr_log[11:0]};

  // Language-card $Dxxx bank-1 window active: fold A12 (bank 2 is the primary
  // bank and stays at physical $Dxxx - Sather / HW Ref / all ref emulators).
  // Mega II side (E0/E1): IOLC is always present. FPI side (00/01): only when
  // shadow[6]=0. On both sides, under RDROM the fold still applies to
  // language-card WRITES (write RAM while reading ROM) via LC_WE && we.
  wire lc_dxxx_fold =
      (addr_log[15:12] == 4'hD) && ~LCRAM2 && (~RDROM || (LC_WE && we)) &&
      ( (bank_log == 8'he0 || bank_log == 8'he1) ||
        ((bank_log == 8'h00 || bank_log == 8'h01) && ~shadow[6]) );

  // Language-card $E000-$FFFF RAM selected (no fold needed; feeds lcram2_sel /
  // inhibit_cxxx only).
  wire lc_exxx_ram =
      (addr_log[15:13] == 3'b111) && ~RDROM &&
      ( bank_log == 8'he0 || bank_log == 8'he1 ||
        ((bank_log == 8'h00 || bank_log == 8'h01) && ~shadow[6]) );

  assign lcram2_sel = lc_dxxx_fold | lc_exxx_ram;

  // Bank latch disabled (NEWVIDEO[0]=0): E1 behaves as E0 (IIe memory model).
  wire [7:0] bank_eff  = (bank_log == 8'he1 && ~bank_latch) ? 8'he0 : bank_log;

  // Main/aux select is bank bit 0 (slow-RAM A16 / odd fast bank). aux is only
  // ever asserted for banks 00/01/E0/E1 and, under CYAREG[4] all-bank shadow,
  // for even banks 02-7E - so this OR is the whole aux redirect.
  wire [7:0] bank_phys = {bank_eff[7:1], bank_eff[0] | aux};

  assign addr_bus = {bank_phys, lc_dxxx_fold ? addr_lc_fold : addr_log};

  wire [15:0] addr_phys = addr_bus[15:0];

  // --------------------------------------------------------------------------
  // I/O and slot decode
  // --------------------------------------------------------------------------

  assign slowram_we = we && (
    // For E0/E1 Language Card areas ($D000-$FFFF), require LC_WE
    ((bank_log == 8'he0 || bank_log == 8'he1) && addr_log >= 16'hd000) ? LC_WE :
    // For all other slowram areas, allow normal writes
    1'b1
  );

  assign is_internal_io = ~SLTROMSEL[addr_phys[6:4]];

  assign EXTERNAL_IO = ((((bank_log == 8'h0 || bank_log == 8'h1) && !shadow[6]) || bank_log == 8'he0 || bank_log == 8'he1) && addr_log >= 'hc090 && addr_log < 'hc100 && ~is_internal_io);

  assign inhibit_cxxx = lcram2_sel | ((bank_log == 8'h0 | bank_log == 8'h1) & shadow[6]);

  // I/O space ($C000-$C0FF) mapping per Apple IIgs Hardware Reference:
  // - Banks E0/E1: I/O always accessible (no shadow register check)
  // - Banks 00/01: I/O accessible only when shadow[6]=0
  // - All-bank shadow: When CYAREG[4]=1, I/O space appears in banks 02-7F too
  wire all_bank_io = shadow_all && (bank_log >= 8'h02 && bank_log <= 8'h7f);
  assign IO = ~EXTERNAL_IO & addr_log[15:8] == 8'hC0 &
              (((bank_log == 8'h00 | bank_log == 8'h01) && !shadow[6]) | bank_log == 8'he0 | bank_log == 8'he1 | all_bank_io);

  assign is_internal = ~SLTROMSEL[addr_phys[10:8]];
  assign slot_ce             = (bank_phys == 8'h0 || bank_phys == 8'h1 || bank_phys == 8'he0 || bank_phys == 8'he1) && addr_phys >= 'hc100 && addr_phys < 'hc800 && ~is_internal && ~inhibit_cxxx;
  assign slot_internalrom_ce = (bank_phys == 8'h0 || bank_phys == 8'h1 || bank_phys == 8'he0 || bank_phys == 8'he1) && addr_phys >= 'hc100 && addr_phys < 'hc800 &&  is_internal && ~inhibit_cxxx;

  // --------------------------------------------------------------------------
  // ROM chip enables
  // --------------------------------------------------------------------------

  assign romc_ce = bank_log == 8'hfc;
  assign romd_ce = bank_log == 8'hfd;
  assign rom1_ce = bank_log == 8'hfe;

  // Force ROM2 on IRQ/BRK vector fetch cycles (VPB low) to return correct vectors from ROM bank FF
  wire vec_fetch_force_rom_ce = (~vpb_n) && (bank_log == 8'h00) &&
                                ((addr_log == 16'hFFEE) || (addr_log == 16'hFFEF) ||
                                 (addr_log == 16'hFFFE) || (addr_log == 16'hFFFF));

  // rom2_ce enables reading from ROM bank $FF (see the MiSTer source for the
  // history of each term; the $C000-$CFFF terms are superseded by the I/O
  // and Cx-space rules of the accelerator outputs below).
  wire lc_rom_bank = (bank_log == 8'h00 || bank_log == 8'h01);
  assign rom2_ce = (bank_log == 8'hff) || vec_fetch_force_rom_ce ||
                   (lc_rom_bank & addr_log >= 16'hd000 & addr_log <= 16'hdfff && (RDROM | ~vpb_n) && !shadow[6]) ||
                   (bank_log == 8'h0 & addr_log >= 16'hc000 & addr_log < 16'hc100 && (RDROM | ~vpb_n) && !shadow[6]) ||
                   (bank_log == 8'h0 & addr_log >= 16'hc800 & addr_log <= 16'hcfff && !shadow[6]) ||
                   (lc_rom_bank & addr_log >= 16'he000 &                          (RDROM | ~vpb_n) && !shadow[6]) ||
                   (bank_log == 8'h0 & addr_log >= 16'hc070 & addr_log <= 16'hc07f && !shadow[6]) ||
                   ((bank_log == 8'he0 || bank_log == 8'he1) && addr_log >= 16'hd000 && RDROM);

  // ROM write-through for language card
  assign rom_writethrough = ((bank_log == 8'h00 || bank_log == 8'h01) && addr_log >= 16'hd000 && LC_WE && we);

  // --------------------------------------------------------------------------
  // Memory controller: fast/slow RAM chip enables
  // --------------------------------------------------------------------------

  wire [3:0] page = addr_log[15:12];

  // Shadow region detection (when shadow bit = 0, shadowing is ACTIVE)
  wire txt1_shadow  = ~shadow[0] && (page == 4'h0 && addr_log[11:8] >= 4'h4 && addr_log[11:8] <= 4'h7);  // $0400-$07FF
  wire txt2_shadow  = rom_select ? 1'b0: ~shadow[5] && (page == 4'h0 && addr_log[11:8] >= 4'h8 && addr_log[11:8] <= 4'hB);  // $0800-$0BFF (ROM3+ only)

  wire hgr1_shadow  = ~shadow[1] && (page >= 4'h2 && page <= 4'h3);          // $2000-$3FFF
  wire hgr2_shadow  = ~shadow[2] && (page >= 4'h4 && page <= 4'h5);          // $4000-$5FFF
  // SHR shadow bit 3: When 0, entire $2000-$9FFF shadows (master enable for SHR mode)
  wire shr_master_shadow = ~shadow[3] && (bank_phys == 8'h01) && (page >= 4'h2 && page <= 4'h9);     // $2000-$9FFF when bit3=0
  wire aux_disable  = shadow[4];   // When set, disable auxiliary shadowing for bank 01

  always_comb begin
    fastram_ce = 0;
    slowram_ce = 0;

    if (IO || EXTERNAL_IO) begin
      // I/O space - no RAM access (see the MiSTer source: slot I/O $C090-$C0FF
      // can alias the language-card bank-1 window and must not touch RAM).
      fastram_ce = 0;
      slowram_ce = 0;
    end else begin
      case (bank_log)
        // Bank 00: Main memory with shadow regions
        8'h00: begin
          // Language-card write-protect: with the LC active (shadow[6]=0) and
          // LC_WE=0, writes to $D000-$FFFF are discarded on real hardware
          if (we && !LC_WE && addr_log >= 16'hD000 && !shadow[6]) begin
            fastram_ce = 0;
            slowram_ce = 0;
          // In ROM shadow mode, $E000-$FFFF are ROM reads, do not access RAM
          // When shadow[6]=1 (IOLC inhibited), $E000-$FFFF is contiguous RAM, not ROM
          end else if (RDROM && addr_log >= 16'hE000 && !rom_writethrough && !shadow[6]) begin
            fastram_ce = 0;
            slowram_ce = 0;
          end else if (txt1_shadow || txt2_shadow || shr_master_shadow || hgr1_shadow || hgr2_shadow) begin
            // Shadowed regions: both enabled (fastram takes priority in the read mux)
            fastram_ce = 1;
            slowram_ce = 1;
          end else begin
            fastram_ce = 1;  // Normal Bank 00 RAM (non-shadowed)
          end
        end

        // Bank 01: Auxiliary memory with conditional shadow regions
        8'h01: begin
          // Language-card write-protect (same as bank 00)
          if (we && !LC_WE && addr_log >= 16'hD000 && !shadow[6]) begin
            fastram_ce = 0;
            slowram_ce = 0;
          end else if (RDROM && addr_log >= 16'hE000 && !rom_writethrough && !shadow[6]) begin
            fastram_ce = 0;
            slowram_ce = 0;
          end else if (shr_master_shadow) begin
            // SHR master shadow (bit3=0): entire $2000-$9FFF shadows to E1
            fastram_ce = 1;
            slowram_ce = 1;
          end else if (txt1_shadow || txt2_shadow) begin
            // Text pages ALWAYS shadow in bank 01 (bit 4 only affects the
            // auxiliary Hi-Res graphics pages, not the text pages)
            fastram_ce = 1;
            if (we) begin
              slowram_ce = 1;
            end
          end else if (!aux_disable && (hgr1_shadow || hgr2_shadow)) begin
            // Hi-Res pages shadow only when aux_disable=0 (bit 4 controls this)
            fastram_ce = 1;
            if (we) begin
              slowram_ce = 1;
            end
          end else begin
            fastram_ce = 1;  // Normal Bank 01 RAM (including LC area)
          end
        end

        // Banks E0/E1: Shadow memory - always SLOWRAM
        8'hE0, 8'hE1: begin
          slowram_ce = 1;
        end

        // Banks FC-FF: ROM banks - writes are discarded
        8'hFC, 8'hFD, 8'hFE, 8'hFF: begin
          fastram_ce = 0;
          slowram_ce = 0;
        end

        // All other banks: Normal RAM (if within RAMSIZE)
        // CYAREG bit 4 (shadow all banks): When set, video page writes in ANY bank shadow to E0/E1
        default: begin
          if ((bank_log < RAMSIZE) && ~rom1_ce && ~rom2_ce) begin
            fastram_ce = 1;
            // Even banks shadow to E0, odd banks shadow to E1 (via bank[0] bit in slowram address)
            if (shadow_all && we) begin
              if (txt1_shadow || txt2_shadow || hgr1_shadow || hgr2_shadow || shr_master_shadow) begin
                slowram_ce = 1;
              end
            end
          end
        end
      endcase
    end
  end

  // ==========================================================================
  // S7 accelerator outputs
  // ==========================================================================

  wire bank_main  = (bank_log == 8'h00) || (bank_log == 8'h01);
  wire bank_mega  = (bank_log == 8'he0) || (bank_log == 8'he1);
  wire bank_rom   = (bank_log == 8'hfe) || (bank_log == 8'hff) ||
                    (~rom_select && ((bank_log == 8'hfc) || (bank_log == 8'hfd)));
  wire bank_exp   = (bank_log >= 8'h02) && (bank_log <= 8'h7f);

  // $C071-$C07F of bank 00: interrupt-dispatch ROM (reads), not I/O
  wire irq_rom    = (bank_log == 8'h00) && (addr_log >= 16'hC071) && (addr_log <= 16'hC07F) &&
                    ~shadow[6] && ~we;

  wire io_any     = (IO | EXTERNAL_IO) & ~irq_rom;

  // Cx space: $C100-$CFFF in the banks where the I/O-and-language-card
  // shadow puts the slots (00/01 with shadow[6] = 0; E0/E1 always).
  wire cx_page    = (addr_log[15:12] == 4'hC) && (addr_log[11:8] != 4'h0);
  wire cx_space   = cx_page && ((bank_main && ~shadow[6]) || bank_mega);
  wire [2:0] cx_slot = addr_log[10:8];
  wire cx_internal = addr_log[11]
                     ? (INTCXROM | INTC8ROM)                                    // $C800-$CFFF
                     : (INTCXROM | ((cx_slot == 3'd3) ? ~SLOTC3ROM : ~SLTROMSEL[cx_slot]));
  wire cx_always_bus = (~addr_log[11] && cx_slot == 3'd3) || (addr_log[11:0] == 12'hFFF);
  wire cx_local   = cx_space && bank_main && cxrom_local && cx_internal && ~cx_always_bus &&
                    ~we && ~(rom_select && ROMBANK);

  assign side_effect = io_any | cx_space;

  // Local expansion RAM: both the logical bank and the bank the all-bank
  // shadow redirects to must be backed by the card.
  wire [7:0] exp_top = 8'h02 + {1'b0, exp_banks};
  wire exp_local  = bank_exp && fastram_ce && (bank_log < exp_top) && (addr_bus[23:16] < exp_top);

  // ROM read window in banks 00/01 (language card under RDROM, vector pulls)
  wire main_rom_rd = bank_main && ~we && rom2_ce;

  assign rom_addr = {(bank_rom ? bank_log[1:0] : 2'b11), addr_log};

  // Mega II RAM the card keeps a copy of: below $C000 (no I/O, no slot space,
  // no language card there)
  wire mega_lo  = (addr_log[15:14] != 2'b11);
  // a write to an expansion bank the card does not hold, which the FPI shadows
  wire exp_slow = slow_copy & bank_exp & ~exp_local & slowram_ce & we & ~io_any & ~cx_space;
  assign slow_only = exp_slow;

  always_comb begin
    region        = REGION_NONE;
    is_local         = 1'b0;
    forward_write = 1'b0;
    local_we      = 1'b0;
    local_rom     = 1'b0;

    if (irq_rom) begin
      region    = REGION_ROM;
      is_local  = ~(rom_select && ROMBANK);
      local_rom = ~(rom_select && ROMBANK);
    end else if (io_any) begin
      region = REGION_IO;
    end else if (cx_space) begin
      region    = REGION_CX;
      is_local     = cx_local;
      local_rom = cx_local;
    end else if (bank_mega) begin
      region = REGION_SLOW;
      // RAM below $C000: the card's copy follows every write; a read is the
      // card's when it is asked to be
      if (slow_copy && mega_lo) begin
        is_local = slow_local & ~we;
        local_we = we;
      end
    end else if (bank_rom) begin
      // reads from the image; writes to ROM do nothing anywhere
      region    = REGION_ROM;
      is_local     = 1'b1;
      local_rom = ~we;
    end else if (bank_main) begin
      if (main_rom_rd) begin
        region    = REGION_ROM;
        is_local     = ~(rom_select && ROMBANK);
        local_rom = ~(rom_select && ROMBANK);
      end else begin
        // fast RAM; a write that the map discards (write-protected language
        // card) is still ours to discard
        region        = REGION_RAM;
        is_local         = 1'b1;
        local_we      = we & fastram_ce;
        forward_write = we & fastram_ce & slowram_ce;
      end
    end else if (bank_exp) begin
      region        = REGION_EXP;
      is_local         = exp_local;
      local_we      = we & (exp_local | exp_slow);
      forward_write = we & exp_local & slowram_ce;
    end
  end

  // ==========================================================================
  // S7 near memory: the cheap view
  // ==========================================================================
  //   reads   banks 00/01 below $C000 (always RAM of the card);
  //           banks 00/01 at $D000-$FFFF (language-card RAM or the ROM image,
  //           both the card's - unless a ROM 01's ROMBANK is set);
  //           the ROM banks
  //   writes  banks 00/01 below $C000 outside every page that can be shadowed:
  //           the text pages ($0400-$07FF, $0800-$0BFF on a ROM 3) whatever the
  //           shadow register says, and $2000-$9FFF unless that register inhibits
  //           hi-res 1, hi-res 2 and super hi-res all three (bits 1, 2, 3: nothing
  //           is shadowed there then, in either bank, whatever bit 4 says - the
  //           register of a machine in a desktop program, whose stack and direct
  //           page are often in that range)
  //   both    an expansion bank the card backs, while only banks 00/01 shadow
  //           (CYAREG[4] clear): plain RAM, all of it, at its own address
  //   never a vector pull; never $Cxxx of banks 00/01; never a Mega II bank
  wire f_main = (bank_log[7:1] == 7'd0);
  wire f_romb = (bank_log[7:1] == 7'h7F) | (~rom_select & (bank_log[7:1] == 7'h7E));
  wire f_lo   = (addr_log[15:14] != 2'b11);                                  // below $C000
  wire f_lc   = (addr_log[15:14] == 2'b11) & (addr_log[13:12] != 2'b00);     // $D000-$FFFF
  wire f_hgrq = shadow[1] & shadow[2] & shadow[3];
  wire f_shw  = (addr_log[15:10] == 6'b000001) |
                (~rom_select & (addr_log[15:10] == 6'b000010)) |
                (((~addr_log[15] & (addr_log[14] | addr_log[13])) | (addr_log[15:13] == 3'b100)) & ~f_hgrq);
  wire f_rw   = we ? RAMWRT : RAMRD;
  wire f_aux0 = ((addr_log[15:9] == 7'b0000000) | (addr_log[15:14] == 2'b11)) ? ALTZP :
                (addr_log[15:10] == 6'b000001) ? ((STORE80 & PAGE2) | (~STORE80 & f_rw)) :
                (addr_log[15:13] == 3'b001)    ? ((STORE80 & PAGE2 & HIRES_MODE) | ((~STORE80 | ~HIRES_MODE) & f_rw)) :
                                                 f_rw;
  wire f_exp  = ~bank_log[7] & (|bank_log[6:1]) & (bank_log < exp_top) & ~shadow_all;
  assign fast_rw    = vpb_n & (f_exp | (we ? (f_main & f_lo & ~f_shw)
                                           : ((f_main & (f_lo | (f_lc & ~(rom_select & ROMBANK)))) | f_romb)));
  assign fast_exp   = f_exp;
  assign fast_int   = (addr_log[15:12] != 4'hC);
  assign fast_rom   = f_romb | (f_main & f_lc & RDROM & ~shadow[6]);
  assign fast_rbank = f_romb ? bank_log[1:0] : 2'b11;
  assign fast_aux   = bank_log[0] | (f_main & f_aux0);        // (an expansion bank: its own bit 0)
  assign fast_fold  = f_main & (addr_log[15:12] == 4'hD) & ~LCRAM2 & ~RDROM & ~shadow[6];
  //   the socket's alone: a Mega II bank, an expansion bank the card does not
  //   back, any other bank from $80 up that is not a ROM bank
  //   (slow_copy: a write there may still be stored in the copy - it is a socket
  //   cycle of its own address all the same, which is all this is used for; a READ
  //   of Mega II RAM the card serves is not one)
  wire f_megab = (bank_log[7:1] == 7'h70);
  assign fast_sock  = bank_log[7] ? (~f_romb & ~(f_megab & slow_copy & slow_local & ~we & f_lo))
                                  : (bank_log >= exp_top);

`ifdef VERILATOR
  // ----------------------------------------------------------------------------
  // Structural invariants the surrounding decode depends on (from the MiSTer
  // source, plus the accelerator's own).
  // ----------------------------------------------------------------------------
  always @(*) begin
    // Translation never touches the low 12 address bits
    if (addr_bus[11:0] != addr_log[11:0])
      $fatal(1, "gs_mmu_decode: translation changed A[11:0]: %02x/%04x -> %06x",
             bank_log, addr_log, addr_bus);
    // The A12 fold only ever applies inside $Dxxx
    if (lc_dxxx_fold && addr_log[15:12] != 4'hD)
      $fatal(1, "gs_mmu_decode: LC fold outside $Dxxx: %02x/%04x", bank_log, addr_log);
    // Physical bank only ever differs from logical in bit 0 (aux) or via the
    // E1->E0 bank-latch redirect
    if (bank_phys[7:1] != bank_log[7:1] && !(bank_log == 8'he1 && ~bank_latch))
      $fatal(1, "gs_mmu_decode: unexpected bank translation: %02x -> %02x", bank_log, bank_phys);
    // Mega II banks never enable fast RAM
    if (fastram_ce && (bank_log == 8'he0 || bank_log == 8'he1))
      $fatal(1, "gs_mmu_decode: fastram_ce for Mega II bank: %02x/%04x", bank_log, addr_log);
    // Accelerator invariants: I/O and the Mega II banks are never local; a
    // forwarded write is a stored local write; local RAM of banks 00/01
    // stays inside banks 00/01
    if (is_local && (io_any || (bank_mega && !(slow_copy && slow_local && !we && mega_lo))))
      $fatal(1, "gs_mmu_decode: local I/O or Mega II access: %02x/%04x", bank_log, addr_log);
    // a write stored without being local: only the copy of Mega II RAM
    if (local_we && !is_local && !(slow_copy && we && ((bank_mega && mega_lo) || slow_only)))
      $fatal(1, "gs_mmu_decode: a stored write that is not local: %02x/%04x", bank_log, addr_log);
    if (slow_only && (is_local || forward_write || !slowram_ce || addr_bus[23]))
      $fatal(1, "gs_mmu_decode: slow_only: %02x/%04x", bank_log, addr_log);
    // the copy's address: a Mega II access names it, a shadowed write's is E0 + addr_bus[16:0]
    if (bank_mega && mega_lo && addr_bus[23:17] != 7'h70)
      $fatal(1, "gs_mmu_decode: Mega II RAM outside E0/E1: %02x/%04x -> %06x", bank_log, addr_log, addr_bus);
    if (forward_write && !(is_local && local_we && we))
      $fatal(1, "gs_mmu_decode: forward_write without a stored local write: %02x/%04x", bank_log, addr_log);
    if (fast_sock && (is_local || forward_write || (local_we && !slow_copy)))
      $fatal(1, "gs_mmu_decode: fast_sock for an access the card has a part in: %02x/%04x", bank_log, addr_log);
    if (is_local && region == REGION_RAM && addr_bus[23:17] != 7'd0)
      $fatal(1, "gs_mmu_decode: local RAM outside banks 00/01: %02x/%04x -> %06x", bank_log, addr_log, addr_bus);
  end
`endif

endmodule
