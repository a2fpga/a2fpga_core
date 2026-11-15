// ============================================================================
// iigs_mmu_model.h - C++ golden model of the Apple IIgs memory map
//
// Ported from vsim/mmu_tb.cpp of the MiSTer Apple IIgs core
// (https://github.com/MiSTer-devel/Apple-IIgs_MiSTer; GPL-3, Copyright (c)
// Pierre Cornier, Steven A. Wilson, Alan Steremberg) and extended for the
// a2mega S7 accelerator (c) 2026 Ed Anuff <ed@a2fpga.com>.
//
// This program is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation; either version 3 of the License, or (at your option)
// any later version.  It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License for more details: <https://www.gnu.org/licenses/>.
//
// Three layers, each written region-first (like an emulator's memory map),
// deliberately NOT signal-first like the RTL, so a typo in one is unlikely
// to be reproduced in the other:
//
//   ref_mmu()   the MiSTer golden model of rtl/mmu.sv, unchanged
//   ref_ext()   the accelerator's two questions (local? forward-write?) and
//               the region, for hdl/twgs/gs_mmu_decode.sv
//   SoftSw      the soft-switch tracker, for hdl/twgs/gs_mmu_replica.sv
//   Machine     a whole machine's memory side (switches + fast RAM + slow
//               RAM + ROM + an I/O register file), used by the socket
//               benches as the motherboard and as the ideal reference
// ============================================================================
#ifndef IIGS_MMU_MODEL_H
#define IIGS_MMU_MODEL_H

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace iigs {

// --- Known-divergence toggles of the MiSTer model (all fixed in the RTL) ----
static const bool FIX_BANK01_LC_ROM      = true;   // D1: LC ROM windows apply to bank 01
static const bool FIX_E0E1_RDROM_READS   = true;   // D2: E0/E1 $D000-$FFFF read ROM under RDROM
static const bool FIX_E0E1_LC_WRITE_FOLD = true;   // D3: E0/E1 $Dxxx writes under RDROM fold A12
static const bool FIX_LC_BANK1_FOLD      = true;   // D4: the A12 fold applies to LC bank 1
static const bool FIX_LC_WRITE_PROTECT   = true;   // D5: LC_WE = 0 discards $D000-$FFFF writes

struct In {
    uint8_t  bank; uint16_t addr;
    bool we, vpb_n, rom_select;
    bool LCRAM2, RDROM, LC_WE;
    uint8_t shadow;
    bool ALTZP, RAMRD, RAMWRT, STORE80, PAGE2, HIRES;
    bool bank_latch, shadow_all;
    uint8_t SLTROMSEL;
    // accelerator additions
    bool INTCXROM, SLOTC3ROM, INTC8ROM, ROMBANK;
    bool cxrom_local;
    uint8_t exp_banks;
    // the card's copy of Mega II RAM below $C000 (gs_mmu_decode slow_copy / slow_local)
    bool slow_copy, slow_local;
};

struct Out {
    uint32_t addr_bus;
    bool aux, lcram2_sel, inhibit_cxxx, IO, EXTERNAL_IO;
    bool is_internal, is_internal_io;
    bool fastram_ce, slowram_ce, slowram_we;
    bool rom1_ce, rom2_ce, romc_ce, romd_ce;
    bool slot_ce, slot_internalrom_ce, rom_writethrough;
};

enum Region { R_RAM = 0, R_ROM = 1, R_EXP = 2, R_SLOW = 3, R_IO = 4, R_CX = 5, R_NONE = 6 };

struct Ext {
    int      region;
    bool     local, forward_write, local_we, local_rom, side_effect;
    uint32_t rom_addr;      // {bank[1:0], addr}; meaningful when local_rom
    bool     slow_only;     // a socket write stored in the card's copy of Mega II RAM alone
};

static const int RAMSIZE = 128;

// ---------------------------------------------------------------------------
// MiSTer golden model (vsim/mmu_tb.cpp ref_mmu, unchanged)
// ---------------------------------------------------------------------------
static inline Out ref_mmu(const In& s)
{
    Out o{};
    const uint8_t  b  = s.bank;
    const uint16_t a  = s.addr;
    const bool     we = s.we;
    const bool sh0 = s.shadow & 0x01, sh1 = s.shadow & 0x02, sh2 = s.shadow & 0x04;
    const bool sh3 = s.shadow & 0x08, sh4 = s.shadow & 0x10, sh5 = s.shadow & 0x20;
    const bool sh6 = s.shadow & 0x40;

    // --- main/aux select (IIe soft switches, IIgs bank rules) --------------
    const bool mainGrp = (b == 0x00 || b == 0xE0 || (b == 0xE1 && !s.bank_latch));
    const bool auxGrp  = (b == 0x01 || (b == 0xE1 && s.bank_latch));
    const bool rw      = we ? s.RAMWRT : s.RAMRD;   // RAMWRT for writes, RAMRD for reads

    bool aux;
    if (mainGrp && (a < 0x0200 || a >= 0xC000))
        aux = s.ALTZP;                              // ZP/stack + $C000-$FFFF follow ALTZP
    else if ((mainGrp || auxGrp) && a >= 0x0400 && a < 0x0800)
        aux = auxGrp || (s.STORE80 ? s.PAGE2 : rw); // text page 1: 80STORE overrides
    else if (a >= 0x2000 && a < 0x4000)
        aux = auxGrp || (mainGrp && ((s.STORE80 && s.HIRES) ? s.PAGE2 : rw)); // HGR page 1
    else if (s.shadow_all && b >= 0x02 && b <= 0x7E && !(b & 1))
        aux = rw;                                   // all-bank shadow: even->odd redirect
    else
        aux = auxGrp || (mainGrp && rw);
    o.aux = aux;

    // --- logical -> physical translation -----------------------------------
    const bool lc_wr_exc = !s.RDROM || (s.LC_WE && we);
    const bool fold =
        (a >> 12) == 0xD && (FIX_LC_BANK1_FOLD ? !s.LCRAM2 : s.LCRAM2) &&
        ( ((b == 0xE0 || b == 0xE1) && (FIX_E0E1_LC_WRITE_FOLD ? lc_wr_exc : !s.RDROM)) ||
          ((b == 0x00 || b == 0x01) && !sh6 && lc_wr_exc) );

    const bool lc_exxx =
        a >= 0xE000 && !s.RDROM &&
        ( b == 0xE0 || b == 0xE1 || ((b == 0x00 || b == 0x01) && !sh6) );

    o.lcram2_sel = fold || lc_exxx;

    const uint8_t  beff  = (b == 0xE1 && !s.bank_latch) ? 0xE0 : b;   // bank latch off: E1 == E0
    const uint8_t  bphys = (beff & 0xFE) | ((beff & 1) | (aux ? 1 : 0));
    const uint16_t aphys = fold ? (a & ~0x1000) : a;
    o.addr_bus = ((uint32_t)bphys << 16) | aphys;

    // --- write gating -------------------------------------------------------
    o.slowram_we = we && (((b == 0xE0 || b == 0xE1) && a >= 0xD000) ? s.LC_WE : true);
    o.rom_writethrough = (b == 0x00 || b == 0x01) && a >= 0xD000 && s.LC_WE && we;

    // --- I/O and slot decode ------------------------------------------------
    o.is_internal_io = !((s.SLTROMSEL >> ((aphys >> 4) & 7)) & 1);
    o.is_internal    = !((s.SLTROMSEL >> ((aphys >> 8) & 7)) & 1);

    o.EXTERNAL_IO = ((((b == 0x00 || b == 0x01) && !sh6) || b == 0xE0 || b == 0xE1)
                     && a >= 0xC090 && a < 0xC100 && !o.is_internal_io);

    o.inhibit_cxxx = o.lcram2_sel || ((b == 0x00 || b == 0x01) && sh6);

    const bool all_bank_io = s.shadow_all && b >= 0x02 && b <= 0x7F;
    o.IO = !o.EXTERNAL_IO && (a >> 8) == 0xC0 &&
           (((b == 0x00 || b == 0x01) && !sh6) || b == 0xE0 || b == 0xE1 || all_bank_io);

    const bool slot_window =
        (bphys == 0x00 || bphys == 0x01 || bphys == 0xE0 || bphys == 0xE1) &&
        aphys >= 0xC100 && aphys < 0xC800 && !o.inhibit_cxxx;
    o.slot_ce             = slot_window && !o.is_internal;
    o.slot_internalrom_ce = slot_window &&  o.is_internal;

    // --- ROM chip enables ---------------------------------------------------
    o.romc_ce = (b == 0xFC);
    o.romd_ce = (b == 0xFD);
    o.rom1_ce = (b == 0xFE);

    const bool vec = !s.vpb_n && b == 0x00 &&
                     (a == 0xFFEE || a == 0xFFEF || a == 0xFFFE || a == 0xFFFF);
    const bool rd_or_vec = s.RDROM || !s.vpb_n;
    const bool lc_rom_bank = (b == 0x00) || (FIX_BANK01_LC_ROM && b == 0x01);

    o.rom2_ce = (b == 0xFF) || vec
        || (lc_rom_bank && a >= 0xD000 && a <= 0xDFFF && rd_or_vec && !sh6)
        || (b == 0x00 && a >= 0xC000 && a <  0xC100 && rd_or_vec && !sh6)
        || (b == 0x00 && a >= 0xC800 && a <= 0xCFFF && !sh6)
        || (lc_rom_bank && a >= 0xE000 && rd_or_vec && !sh6)
        || (b == 0x00 && a >= 0xC070 && a <= 0xC07F && !sh6)
        || (FIX_E0E1_RDROM_READS && (b == 0xE0 || b == 0xE1) && a >= 0xD000 && s.RDROM);

    // --- fast/slow RAM chip enables (memory controller) ---------------------
    const bool txt1 = !sh0 && a >= 0x0400 && a <= 0x07FF;
    const bool txt2 = !s.rom_select && !sh5 && a >= 0x0800 && a <= 0x0BFF;   // ROM3 only
    const bool hgr1 = !sh1 && a >= 0x2000 && a <= 0x3FFF;
    const bool hgr2 = !sh2 && a >= 0x4000 && a <= 0x5FFF;
    const bool shr  = !sh3 && bphys == 0x01 && a >= 0x2000 && a <= 0x9FFF;

    bool fast = false, slow = false;
    if (!o.IO && !o.EXTERNAL_IO) {
        if (b == 0x00) {
            if (FIX_LC_WRITE_PROTECT && we && !s.LC_WE && a >= 0xD000 && !sh6) {
                // LC write-protected: write discarded
            } else if (s.RDROM && a >= 0xE000 && !o.rom_writethrough && !sh6) {
                // ROM window: no RAM
            } else if (txt1 || txt2 || shr || hgr1 || hgr2) {
                fast = slow = true;             // dual write into the shadow bank
            } else {
                fast = true;
            }
        } else if (b == 0x01) {
            if (FIX_LC_WRITE_PROTECT && we && !s.LC_WE && a >= 0xD000 && !sh6) {
                // LC write-protected: write discarded
            } else if (s.RDROM && a >= 0xE000 && !o.rom_writethrough && !sh6) {
                // ROM window: no RAM
            } else if (shr) {
                fast = slow = true;
            } else if (txt1 || txt2) {
                fast = true; slow = we;         // text pages always shadow in bank 01
            } else if (!sh4 && (hgr1 || hgr2)) {
                fast = true; slow = we;         // HGR shadows unless inhibited by bit 4
            } else {
                fast = true;
            }
        } else if (b == 0xE0 || b == 0xE1) {
            slow = true;
        } else if (b >= 0xFC) {
            // ROM banks: reads via rom CEs, writes discarded
        } else if (b < RAMSIZE && !o.rom1_ce && !o.rom2_ce) {
            fast = true;
            if (s.shadow_all && we && (txt1 || txt2 || hgr1 || hgr2 || shr))
                slow = true;                    // all-bank shadow write to E0/E1
        }
    }
    o.fastram_ce = fast;
    o.slowram_ce = slow;
    return o;
}

// ---------------------------------------------------------------------------
// Accelerator golden model: where does this access live, is it the card's,
// and does a write also have to reach the socket?  Region by region; uses
// ref_mmu only for the main/aux answer (o.aux).
// ---------------------------------------------------------------------------
static inline Ext ref_ext(const In& s, const Out& o)
{
    Ext e{};
    e.region = R_NONE;
    const uint8_t  b  = s.bank;
    const uint16_t a  = s.addr;
    const bool     we = s.we;
    const bool sh0 = s.shadow & 0x01, sh1 = s.shadow & 0x02, sh2 = s.shadow & 0x04;
    const bool sh3 = s.shadow & 0x08, sh4 = s.shadow & 0x10, sh5 = s.shadow & 0x20;
    const bool sh6 = s.shadow & 0x40;
    const bool rom01 = s.rom_select;
    const bool mainb = (b == 0x00 || b == 0x01);
    const bool mega  = (b == 0xE0 || b == 0xE1);
    const bool iolc  = (mainb && !sh6) || mega;       // banks where I/O and the slots appear
    const bool romb  = (b >= 0xFE) || (!rom01 && b >= 0xFC);

    e.rom_addr = (uint32_t)((romb ? (b & 3) : 3) << 16) | a;

    // 0. the interrupt-dispatch ROM bytes inside the I/O page (bank 00, reads)
    if (b == 0x00 && a >= 0xC071 && a <= 0xC07F && !sh6 && !we) {
        e.region = R_ROM;
        e.local = e.local_rom = !(rom01 && s.ROMBANK);
        return e;
    }
    // 1. the I/O page: never ours
    if ((a & 0xFF00) == 0xC000 && (iolc || (s.shadow_all && b >= 0x02 && b <= 0x7F))) {
        e.region = R_IO; e.side_effect = true;
        return e;
    }
    // 2. slot / internal-firmware space $C100-$CFFF
    if (iolc && a >= 0xC100 && a <= 0xCFFF) {
        e.region = R_CX; e.side_effect = true;
        bool internal;
        if (a >= 0xC800) {
            internal = s.INTCXROM || s.INTC8ROM;
        } else {
            const int slot = (a >> 8) & 7;
            internal = s.INTCXROM || (slot == 3 ? !s.SLOTC3ROM : !((s.SLTROMSEL >> slot) & 1));
        }
        // the motherboard and the cards must see: writes, the Mega II banks,
        // $C3xx (sets INTC8ROM), $CFFF (clears the expansion-ROM latches),
        // and everything while ROM 01's ROMBANK is flipped
        const bool must_bus = we || mega || (a & 0xFF00) == 0xC300 || a == 0xCFFF ||
                              (rom01 && s.ROMBANK);
        e.local = e.local_rom = s.cxrom_local && internal && !must_bus;
        return e;
    }
    // 3. Mega II RAM: the socket's - but below $C000 the card may keep a copy
    //    (slow_copy): every write is stored in it too (the write stays a socket
    //    cycle), and a read is the card's when it is asked to be (slow_local)
    if (mega) {
        e.region = R_SLOW;
        if (s.slow_copy && a < 0xC000) {
            e.local    = s.slow_local && !we;
            e.local_we = we;
        }
        return e;
    }
    // 4. ROM banks: reads from the image, writes vanish
    if (romb) {
        e.region = R_ROM; e.local = true; e.local_rom = !we;
        return e;
    }
    // 5. banks 00/01
    if (mainb) {
        const bool lc_area = a >= 0xD000 && !sh6;      // with IOLC inhibited it is plain RAM
        const bool vecpull = !s.vpb_n;
        const bool vec4    = vecpull && b == 0x00 &&
                             (a == 0xFFEE || a == 0xFFEF || a == 0xFFFE || a == 0xFFFF);
        if (!we && ((lc_area && (s.RDROM || vecpull)) || vec4)) {
            e.region = R_ROM;
            e.local = e.local_rom = !(rom01 && s.ROMBANK);
            return e;
        }
        e.region = R_RAM; e.local = true;
        if (we) {
            const bool stored = !(lc_area && !s.LC_WE);  // write-protected language card
            e.local_we = stored;
            if (stored) {
                const uint8_t bphys = b | (o.aux ? 1 : 0);
                const bool txt1 = !sh0 && a >= 0x0400 && a <= 0x07FF;
                const bool txt2 = !rom01 && !sh5 && a >= 0x0800 && a <= 0x0BFF;
                const bool hgr1 = !sh1 && a >= 0x2000 && a <= 0x3FFF;
                const bool hgr2 = !sh2 && a >= 0x4000 && a <= 0x5FFF;
                const bool shr  = !sh3 && bphys == 0x01 && a >= 0x2000 && a <= 0x9FFF;
                if (b == 0x00) e.forward_write = txt1 || txt2 || hgr1 || hgr2 || shr;
                else           e.forward_write = shr || txt1 || txt2 || (!sh4 && (hgr1 || hgr2));
            }
        }
        return e;
    }
    // 6. expansion banks
    if (b >= 0x02 && b <= 0x7F) {
        e.region = R_EXP;
        const int top   = 2 + s.exp_banks;
        const int bphys = b | (o.aux ? 1 : 0);
        e.local = (b < top) && (bphys < top);
        if (we && e.local) {
            e.local_we = true;
            if (s.shadow_all) {
                const bool txt1 = !sh0 && a >= 0x0400 && a <= 0x07FF;
                const bool txt2 = !rom01 && !sh5 && a >= 0x0800 && a <= 0x0BFF;
                const bool hgr1 = !sh1 && a >= 0x2000 && a <= 0x3FFF;
                const bool hgr2 = !sh2 && a >= 0x4000 && a <= 0x5FFF;
                e.forward_write = txt1 || txt2 || hgr1 || hgr2;
            }
        }
        // a bank the card does not hold: a write the FPI shadows into E0/E1 is
        // a socket cycle, and the copy of Mega II RAM is given its byte
        if (we && !e.local && s.slow_copy && o.slowram_ce) {
            e.local_we = true;
            e.slow_only = true;
        }
        return e;
    }
    return e;   // banks 80-DF, F0-FB (and FC/FD on ROM 01): not ours
}

// ---------------------------------------------------------------------------
// Soft-switch tracker golden model (for hdl/twgs/gs_mmu_replica.sv)
// ---------------------------------------------------------------------------
struct SoftSw {
    bool STORE80, RAMRD, RAMWRT, INTCXROM, ALTZP, SLOTC3ROM, PAGE2, HIRES;
    bool RDROM, LCRAM2, LC_WE, LC_PRE, ROMBANK, INTC8ROM, bank_latch;
    uint8_t shadow, cyareg, sltromsel;

    void reset()
    {
        STORE80 = RAMRD = RAMWRT = INTCXROM = ALTZP = SLOTC3ROM = PAGE2 = HIRES = false;
        RDROM = true; LCRAM2 = true; LC_WE = true; LC_PRE = false;
        ROMBANK = false; INTC8ROM = false; bank_latch = true;
        shadow = 0x08; cyareg = 0x80; sltromsel = 0x00;
    }
    uint8_t statereg() const
    {
        return (ALTZP << 7) | (PAGE2 << 6) | (RAMRD << 5) | (RAMWRT << 4) |
               (RDROM << 3) | (LCRAM2 << 2) | (ROMBANK << 1) | (INTCXROM << 0);
    }
    uint8_t misc() const
    {
        return (bank_latch << 6) | (INTC8ROM << 5) | (SLOTC3ROM << 4) | (STORE80 << 3) |
               (HIRES << 2) | (LC_WE << 1) | (LC_PRE << 0);
    }
    bool iolc_bank(uint8_t b) const
    {
        return ((b == 0x00 || b == 0x01) && !(shadow & 0x40)) || b == 0xE0 || b == 0xE1;
    }
    bool io_page(uint32_t addr) const
    {
        const uint8_t b = addr >> 16;
        return ((addr & 0xFF00) == 0xC000) &&
               (iolc_bank(b) || ((cyareg & 0x10) && b >= 0x02 && b <= 0x7F));
    }
    bool cx_space(uint32_t addr) const
    {
        const uint16_t a = addr & 0xFFFF;
        return a >= 0xC100 && a <= 0xCFFF && iolc_bank(addr >> 16);
    }

    // one completed bus cycle, as the FPI and the Mega II see it
    void cycle(uint32_t addr, bool we, uint8_t d, bool rom3)
    {
        const uint16_t a = addr & 0xFFFF;
        if (io_page(addr)) {
            const uint8_t r = a & 0xFF;
            if (r <= 0x0B) {
                if (we) {
                    const bool v = r & 1;
                    switch (r >> 1) {
                    case 0: STORE80 = v; break;
                    case 1: RAMRD = v; break;
                    case 2: RAMWRT = v; break;
                    case 3: INTCXROM = v; break;
                    case 4: ALTZP = v; break;
                    case 5: SLOTC3ROM = v; break;
                    }
                }
            } else if (r == 0x28) {
                if (!rom3) ROMBANK = !ROMBANK;
            } else if (r == 0x29) {
                if (we) bank_latch = d & 1;
            } else if (r == 0x2D) {
                if (we) sltromsel = d;
            } else if (r == 0x35) {
                if (we) shadow = d;
            } else if (r == 0x36) {
                if (we) cyareg = d;
            } else if (r == 0x54 || r == 0x55) {
                PAGE2 = r & 1;
            } else if (r == 0x56 || r == 0x57) {
                HIRES = r & 1;
            } else if (r == 0x68) {
                if (we) {
                    ALTZP = d & 0x80; PAGE2 = d & 0x40; RAMRD = d & 0x20; RAMWRT = d & 0x10;
                    RDROM = d & 0x08; LCRAM2 = d & 0x04; ROMBANK = d & 0x02; INTCXROM = d & 0x01;
                }
            } else if (r >= 0x80 && r <= 0x8F) {
                LCRAM2 = !(r & 0x08);                 // $C080-87: bank 2, $C088-8F: bank 1
                const int sel = r & 3;
                RDROM = (sel == 1 || sel == 2);       // x0/x3 read RAM, x1/x2 read ROM
                if (!(r & 1)) {                       // even: write-protect
                    LC_WE = false; LC_PRE = false;
                } else if (we) {                      // odd write: only clears pre-write
                    LC_PRE = false;
                } else {                              // odd read: two in a row write-enable
                    if (LC_PRE) LC_WE = true;
                    LC_PRE = true;
                }
            }
        } else if (cx_space(addr)) {
            if ((a & 0xFF00) == 0xC300 && !SLOTC3ROM) INTC8ROM = true;
            if (a == 0xCFFF) INTC8ROM = false;
        }
    }

    void fill(In& s) const
    {
        s.LCRAM2 = LCRAM2; s.RDROM = RDROM; s.LC_WE = LC_WE; s.shadow = shadow;
        s.ALTZP = ALTZP; s.RAMRD = RAMRD; s.RAMWRT = RAMWRT; s.STORE80 = STORE80;
        s.PAGE2 = PAGE2; s.HIRES = HIRES; s.bank_latch = bank_latch;
        s.shadow_all = cyareg & 0x10; s.SLTROMSEL = sltromsel;
        s.INTCXROM = INTCXROM; s.SLOTC3ROM = SLOTC3ROM; s.INTC8ROM = INTC8ROM; s.ROMBANK = ROMBANK;
    }
};

// ---------------------------------------------------------------------------
// A whole machine's memory side.  The socket benches use one instance as the
// motherboard behind the FPI (fast RAM = whatever the socket wrote) and one
// as the ideal reference a lockstep core runs against.
//
// I/O is a deterministic stand-in, a function of the access sequence only
// (never of time), so runs at different speeds can be compared: the soft-
// switch status reads return the tracked state, the vertical-blanking flag
// ($C019) and the video counters ($C02E/$C02F) advance with every read of
// them (so firmware that waits for the beam gets on with it), everything
// else reads back the last byte written to that register.
// ---------------------------------------------------------------------------
struct Machine {
    SoftSw sw;
    bool   rom3 = false;
    int    ram_banks = 2;                 // fast RAM banks present (00, 01, expansion)
    std::vector<uint8_t> fast, slow, rom;
    uint8_t io[256];
    uint32_t beam = 0;                    // advances on each read of $C019 / $C02E / $C02F
    long   n_io_wr = 0, n_shadow_wr = 0, n_lc_sw = 0, n_c028 = 0;

    Machine() : fast(128 * 65536, 0), slow(2 * 65536, 0), rom(4 * 65536, 0xFF)
    {
        memset(io, 0, sizeof(io));
        sw.reset();
    }
    void reset() { sw.reset(); }

    In mk_in(uint32_t addr, bool we, bool vpb_n) const
    {
        In s{};
        s.bank = addr >> 16; s.addr = addr & 0xFFFF; s.we = we; s.vpb_n = vpb_n;
        s.rom_select = !rom3;
        sw.fill(s);
        s.cxrom_local = false; s.exp_banks = 0;
        return s;
    }
    bool cx_internal(uint16_t a) const
    {
        if (a >= 0xC800) return sw.INTCXROM || sw.INTC8ROM;
        const int slot = (a >> 8) & 7;
        return sw.INTCXROM || (slot == 3 ? !sw.SLOTC3ROM : !((sw.sltromsel >> slot) & 1));
    }
    // $C071-$C07F of bank 00 reads the FPI's interrupt-dispatch ROM
    bool irq_rom(uint32_t addr) const
    {
        return (addr >> 16) == 0x00 && (addr & 0xFFFF) >= 0xC071 && (addr & 0xFFFF) <= 0xC07F &&
               !(sw.shadow & 0x40);
    }
    // the bank-00/01 ROM windows with ROM 01's ROMBANK flipped read with A14
    // cleared (bench G21: "$Bxxx instead of $Fxxx")
    uint8_t rom_window(uint16_t a) const
    {
        const uint16_t ra = (!rom3 && sw.ROMBANK) ? (a & ~0x4000) : a;
        return rom[(3u << 16) | ra];
    }
    uint8_t io_read(uint8_t r) const
    {
        switch (r) {
        case 0x11: return sw.LCRAM2 << 7;
        case 0x12: return (!sw.RDROM) << 7;
        case 0x13: return sw.RAMRD << 7;
        case 0x14: return sw.RAMWRT << 7;
        case 0x15: return sw.INTCXROM << 7;
        case 0x16: return sw.ALTZP << 7;
        case 0x17: return sw.SLOTC3ROM << 7;
        case 0x18: return sw.STORE80 << 7;
        case 0x19: return (beam & 1) << 7;      // VBL: alternates from read to read
        case 0x1C: return sw.PAGE2 << 7;
        case 0x1D: return sw.HIRES << 7;
        case 0x29: return (io[r] & 0xFE) | (sw.bank_latch ? 1 : 0);
        case 0x2D: return sw.sltromsel;
        case 0x2E: return 0x80 | ((beam >> 1) & 0x7F);   // vertical counter
        case 0x2F: return (beam & 1) << 7;               // horizontal counter (bit 7 = V0)
        case 0x34: return io[r] & 0x7F;         // clock chip: transaction always complete
        case 0x35: return sw.shadow;
        case 0x36: return sw.cyareg;
        case 0x68: return sw.statereg();
        default:   return io[r];
        }
    }

    // read data for a cycle, from the state before the cycle (no side effects)
    uint8_t peek(uint32_t addr, bool vpb_n) const
    {
        const In  s = mk_in(addr, false, vpb_n);
        const Out o = ref_mmu(s);
        const uint16_t a = s.addr;
        const uint8_t  b = s.bank;
        if (irq_rom(addr)) return rom_window(a);
        if (sw.io_page(addr)) return io_read(a & 0xFF);
        if (sw.cx_space(addr)) return cx_internal(a) ? rom_window(a) : 0xFF;   // no slot cards
        const bool romc = (o.romc_ce || o.romd_ce) && rom3;
        if (o.rom1_ce || romc) return rom[((uint32_t)(b & 3) << 16) | a];
        if (o.rom2_ce) return (b == 0xFF) ? rom[(3u << 16) | a] : rom_window(a);
        if (o.fastram_ce) return ((int)(o.addr_bus >> 16) < ram_banks) ? fast[o.addr_bus] : 0xFF;
        if (o.slowram_ce) return slow[o.addr_bus & 0x1FFFF];
        return 0xFF;                               // nothing there: floating bus
    }

    // a completed cycle: memory writes, then the soft-switch side effects
    void commit(uint32_t addr, bool we, uint8_t d, bool vpb_n)
    {
        const In  s = mk_in(addr, we, vpb_n);
        const Out o = ref_mmu(s);
        if (we) {
            if (sw.io_page(addr)) {
                io[addr & 0xFF] = d;
                n_io_wr++;
            } else if (!sw.cx_space(addr)) {
                if (o.fastram_ce && (int)(o.addr_bus >> 16) < ram_banks) fast[o.addr_bus] = d;
                if (o.slowram_ce && o.slowram_we) slow[o.addr_bus & 0x1FFFF] = d;
                if (o.fastram_ce && o.slowram_ce) n_shadow_wr++;
            }
        }
        if (sw.io_page(addr)) {
            const uint8_t r = addr & 0xFF;
            if (r >= 0x80 && r <= 0x8F) n_lc_sw++;
            if (r == 0x28) n_c028++;
            if (!we && (r == 0x19 || r == 0x2E || r == 0x2F)) beam++;
        }
        sw.cycle(addr, we, d, rom3);
    }

    // bench classification of a cycle, from the state before it:
    //   bit 0  I/O page          bit 1  FPI sync (slow) cycle
    //   bit 2  ROM read (the FPI hides its refresh there)
    //   bit 3  write the FPI shadows into E0/E1    bit 4  Mega II bank
    //   bit 5  slot space $C100-$CFFF
    int classify(uint32_t addr, bool we, bool vpb_n) const
    {
        const In  s = mk_in(addr, we, vpb_n);
        const Out o = ref_mmu(s);
        const uint8_t  b = s.bank;
        const uint16_t a = s.addr;
        const uint8_t  sh = sw.shadow;
        int c = 0;
        if (sw.io_page(addr) && !(irq_rom(addr) && !we)) c |= 1;
        if (irq_rom(addr) && !we) c |= 4;
        // FPI sync-cycle classification: slow_class_now of the MiSTer
        // rtl/clock_divider.v (native speed, no Zip register file)
        bool slow = (b == 0xE0 || b == 0xE1);
        if ((b == 0x00 || b == 0x01) && (a >> 8) == 0xC0 && !(sh & 0x40) &&
            !((a == 0xC02D && !we) || a == 0xC035 || a == 0xC036 || a == 0xC037 ||
              (a == 0xC068 && !we) || (a >= 0xC071 && a <= 0xC07F)))
            slow = true;
        if (we && (b == 0x00 || b == 0x01) &&
            ((a >= 0x0400 && a <= 0x07FF && !(sh & 0x01)) ||
             (a >= 0x0800 && a <= 0x0BFF && !(sh & 0x20)) ||
             (a >= 0x2000 && a <= 0x3FFF && !(sh & 0x02) && !(b == 0x01 && (sh & 0x10))) ||
             (a >= 0x4000 && a <= 0x5FFF && !(sh & 0x04) && !(b == 0x01 && (sh & 0x10))) ||
             (a >= 0x2000 && a <= 0x9FFF && b == 0x01 && !(sh & 0x08))))
            slow = true;
        if (slow) c |= 2;
        if (!we && !sw.io_page(addr) &&
            (o.rom1_ce || o.rom2_ce || ((o.romc_ce || o.romd_ce) && rom3) ||
             (sw.cx_space(addr) && cx_internal(a))))
            c |= 4;
        if (we && !sw.io_page(addr) && !sw.cx_space(addr) && o.fastram_ce && o.slowram_ce) c |= 8;
        if (b == 0xE0 || b == 0xE1) c |= 16;
        if (sw.cx_space(addr)) c |= 32;
        return c;
    }

    bool load_rom(const char* path)
    {
        FILE* f = fopen(path, "rb");
        if (!f) return false;
        std::vector<uint8_t> buf(4 * 65536);
        const size_t n = fread(buf.data(), 1, buf.size(), f);
        fclose(f);
        if (n == 2 * 65536) {            // ROM 01: banks FE/FF
            rom3 = false;
            memcpy(&rom[2 * 65536], buf.data(), n);
        } else if (n == 4 * 65536) {     // ROM 3: banks FC-FF
            rom3 = true;
            memcpy(&rom[0], buf.data(), n);
        } else {
            return false;
        }
        return true;
    }
};

} // namespace iigs
#endif
