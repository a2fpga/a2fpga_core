// ============================================================================
// mmu_decode_tb.cpp - sweep of hdl/twgs/gs_mmu_decode.sv against the golden
// model (iigs_mmu_model.h).  Ported from vsim/mmu_tb.cpp of the MiSTer Apple
// IIgs core (GPL-3) and extended with the accelerator outputs.
//
// Phases
//   1  exhaustive over every combination of the nine IIe/language-card
//      switches, the seven SHADOW bits, the bank latch and the all-banks
//      shadow bit (2^18), x boundary addresses x banks 00/01/E0/E1, the
//      expansion banks and the ROM banks x read/write; ROM 01, then ROM 3.
//      The Cx-space switches are sampled here and swept in phase 2.
//   2  Cx space: INTCXROM, SLOTC3ROM, INTC8ROM, ROMBANK, cxrom_local, IOLC
//      inhibit, RDROM, LCBNK2, bank latch, all-banks shadow x all 256
//      SLTROMSEL values x every $Cn00 page boundary.
//   3  expansion banks: every bank 02-7F x every backed size.
//   4  randomized over everything.
//
// +quick on the command line divides phase 1 by 16 (smoke test).
// ============================================================================
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include "Vgs_mmu_decode.h"
#include "verilated.h"
#include "iigs_mmu_model.h"

using namespace iigs;

static Vgs_mmu_decode* dut;
static long n_tests = 0, n_fail = 0;
static long n_fast_r = 0, n_fast_w = 0, n_fast_i = 0, n_fast_s = 0, n_fast_x = 0;      // vectors in the cheap view's classes

struct Dut { Out o; Ext e; };

static void apply(const In& s, Dut& d)
{
    dut->bank_log   = s.bank;
    dut->addr_log   = s.addr;
    dut->we         = s.we;
    dut->vpb_n      = s.vpb_n;
    dut->rom_select = s.rom_select;
    dut->LCRAM2     = s.LCRAM2;
    dut->RDROM      = s.RDROM;
    dut->LC_WE      = s.LC_WE;
    dut->shadow     = s.shadow;
    dut->ALTZP      = s.ALTZP;
    dut->RAMRD      = s.RAMRD;
    dut->RAMWRT     = s.RAMWRT;
    dut->STORE80    = s.STORE80;
    dut->PAGE2      = s.PAGE2;
    dut->HIRES_MODE = s.HIRES;
    dut->bank_latch = s.bank_latch;
    dut->shadow_all = s.shadow_all;
    dut->SLTROMSEL  = s.SLTROMSEL;
    dut->INTCXROM   = s.INTCXROM;
    dut->SLOTC3ROM  = s.SLOTC3ROM;
    dut->INTC8ROM   = s.INTC8ROM;
    dut->ROMBANK    = s.ROMBANK;
    dut->cxrom_local = s.cxrom_local;
    dut->exp_banks  = s.exp_banks;
    dut->eval();

    d.o.addr_bus   = dut->addr_bus & 0xFFFFFF;
    d.o.aux        = dut->aux;
    d.o.lcram2_sel = dut->lcram2_sel;
    d.o.inhibit_cxxx = dut->inhibit_cxxx;
    d.o.IO         = dut->IO;
    d.o.EXTERNAL_IO = dut->EXTERNAL_IO;
    d.o.is_internal = dut->is_internal;
    d.o.is_internal_io = dut->is_internal_io;
    d.o.fastram_ce = dut->fastram_ce;
    d.o.slowram_ce = dut->slowram_ce;
    d.o.slowram_we = dut->slowram_we;
    d.o.rom1_ce    = dut->rom1_ce;
    d.o.rom2_ce    = dut->rom2_ce;
    d.o.romc_ce    = dut->romc_ce;
    d.o.romd_ce    = dut->romd_ce;
    d.o.slot_ce    = dut->slot_ce;
    d.o.slot_internalrom_ce = dut->slot_internalrom_ce;
    d.o.rom_writethrough    = dut->rom_writethrough;
    d.e.region        = dut->region;
    d.e.local         = dut->is_local;
    d.e.forward_write = dut->forward_write;
    d.e.local_we      = dut->local_we;
    d.e.local_rom     = dut->local_rom;
    d.e.side_effect   = dut->side_effect;
    d.e.rom_addr      = dut->rom_addr & 0x3FFFF;
}

static void describe(const In& s)
{
    printf("  MISMATCH bank=%02X addr=%04X we=%d vpb_n=%d rsel=%d "
           "LCRAM2=%d RDROM=%d LC_WE=%d sh=%02X ALTZP=%d RAMRD=%d RAMWRT=%d ST80=%d PG2=%d HIRES=%d "
           "latch=%d shall=%d SLT=%02X INTCX=%d C3=%d C8=%d ROMBANK=%d cxl=%d exp=%d\n",
           s.bank, s.addr, s.we, s.vpb_n, s.rom_select, s.LCRAM2, s.RDROM, s.LC_WE, s.shadow,
           s.ALTZP, s.RAMRD, s.RAMWRT, s.STORE80, s.PAGE2, s.HIRES, s.bank_latch, s.shadow_all,
           s.SLTROMSEL, s.INTCXROM, s.SLOTC3ROM, s.INTC8ROM, s.ROMBANK, s.cxrom_local, s.exp_banks);
}

#define CHECK(dv, rv, name, fmt) \
    if ((dv) != (rv)) { \
        if (n_fail < 40) { \
            if (mism == 0) describe(s); \
            printf("    %-18s dut=" fmt " ref=" fmt "\n", name, (unsigned)(dv), (unsigned)(rv)); \
        } \
        mism++; \
    }

static void run_one(const In& s)
{
    Dut d;
    apply(s, d);
    const Out r = ref_mmu(s);
    const Ext x = ref_ext(s, r);
    n_tests++;

    int mism = 0;
    // MiSTer outputs
    CHECK(d.o.addr_bus, r.addr_bus, "addr_bus", "%06x")
    CHECK(d.o.aux, r.aux, "aux", "%u")
    CHECK(d.o.lcram2_sel, r.lcram2_sel, "lcram2_sel", "%u")
    CHECK(d.o.inhibit_cxxx, r.inhibit_cxxx, "inhibit_cxxx", "%u")
    CHECK(d.o.IO, r.IO, "IO", "%u")
    CHECK(d.o.EXTERNAL_IO, r.EXTERNAL_IO, "EXTERNAL_IO", "%u")
    CHECK(d.o.is_internal, r.is_internal, "is_internal", "%u")
    CHECK(d.o.is_internal_io, r.is_internal_io, "is_internal_io", "%u")
    CHECK(d.o.fastram_ce, r.fastram_ce, "fastram_ce", "%u")
    CHECK(d.o.slowram_ce, r.slowram_ce, "slowram_ce", "%u")
    CHECK(d.o.slowram_we, r.slowram_we, "slowram_we", "%u")
    CHECK(d.o.rom1_ce, r.rom1_ce, "rom1_ce", "%u")
    CHECK(d.o.rom2_ce, r.rom2_ce, "rom2_ce", "%u")
    CHECK(d.o.romc_ce, r.romc_ce, "romc_ce", "%u")
    CHECK(d.o.romd_ce, r.romd_ce, "romd_ce", "%u")
    CHECK(d.o.slot_ce, r.slot_ce, "slot_ce", "%u")
    CHECK(d.o.slot_internalrom_ce, r.slot_internalrom_ce, "slot_internalrom_ce", "%u")
    CHECK(d.o.rom_writethrough, r.rom_writethrough, "rom_writethrough", "%u")
    // accelerator outputs
    CHECK(d.e.region, x.region, "region", "%u")
    CHECK(d.e.local, x.local, "local", "%u")
    CHECK(d.e.forward_write, x.forward_write, "forward_write", "%u")
    CHECK(d.e.local_we, x.local_we, "local_we", "%u")
    CHECK(d.e.local_rom, x.local_rom, "local_rom", "%u")
    CHECK(d.e.side_effect, x.side_effect, "side_effect", "%u")
    if (d.e.local_rom || x.local_rom) CHECK(d.e.rom_addr, x.rom_addr, "rom_addr", "%05x")
    // the cheap view (near memory): a subset of "the card's alone", and for that
    // subset the same ROM / bank / A12 answers as the full decode (golden model)
    if (dut->fast_exp) {
        // expansion RAM of the card: read or write, the byte at its own address
        n_fast_x++;
        CHECK((unsigned)dut->fast_rw, (unsigned)s.vpb_n, "fast_exp: fast_rw", "%u")
        if (dut->fast_rw) {
            CHECK(x.local, 1u, "fast_exp: local", "%u")
            CHECK(x.side_effect, 0u, "fast_exp: side", "%u")
            CHECK(x.forward_write, 0u, "fast_exp: forward", "%u")
            CHECK(x.local_we, (unsigned)s.we, "fast_exp: local_we", "%u")
            CHECK(x.local_rom, 0u, "fast_exp: rom", "%u")
            CHECK((unsigned)dut->fast_rom, 0u, "fast_exp: fast_rom", "%u")
            CHECK(r.addr_bus, ((uint32_t)s.bank << 16) | s.addr, "fast_exp: phys", "%06x")
        }
    } else if (dut->fast_rw) {
        CHECK(x.local, 1u, "fast_rw: local", "%u")
        CHECK(x.side_effect, 0u, "fast_rw: side", "%u")
        if (s.we) {
            n_fast_w++;
            CHECK(x.forward_write, 0u, "fast_rw: forward", "%u")
            CHECK(x.local_we, 1u, "fast_rw: local_we", "%u")
            CHECK(r.addr_bus, ((uint32_t)dut->fast_aux << 16) | s.addr, "fast_rw: w phys", "%06x")
        } else {
            n_fast_r++;
            CHECK((unsigned)dut->fast_rom, (unsigned)x.local_rom, "fast_rom", "%u")
            if (x.local_rom) {
                CHECK((unsigned)dut->fast_rbank, x.rom_addr >> 16, "fast_rbank", "%u")
            } else {
                CHECK(r.addr_bus, ((uint32_t)dut->fast_aux << 16) | (s.addr ^ (dut->fast_fold ? 0x1000u : 0u)),
                      "fast_rw: r phys", "%06x")
            }
        }
    }
    if (dut->fast_int) { n_fast_i++; CHECK(x.side_effect, 0u, "fast_int: side", "%u") }
    // ... and the socket's alone: never local, nothing stored, nothing forwarded
    if (dut->fast_sock) {
        n_fast_s++;
        CHECK(x.local, 0u, "fast_sock: local", "%u")
        CHECK(x.forward_write, 0u, "fast_sock: forward", "%u")
        CHECK(x.local_we, 0u, "fast_sock: local_we", "%u")
    }
    if (mism) n_fail++;
}

static uint32_t mix(uint32_t x)
{
    x ^= x >> 16; x *= 0x7feb352d; x ^= x >> 15; x *= 0x846ca68b; x ^= x >> 16;
    return x;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    bool quick = false;
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "+quick")) quick = true;
    dut = new Vgs_mmu_decode;

    static const uint8_t banks[] = {
        0x00, 0x01, 0x02, 0x03, 0x7E, 0x7F, 0x80, 0xE0, 0xE1, 0xE2, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF
    };
    static const uint16_t addrs[] = {
        0x0000, 0x01FF, 0x0200, 0x03FF, 0x0400, 0x05FF, 0x07FF, 0x0800, 0x0BFF, 0x0C00,
        0x1FFF, 0x2000, 0x3FFF, 0x4000, 0x5FFF, 0x6000, 0x9FFF, 0xA000, 0xBFFF,
        0xC000, 0xC010, 0xC02D, 0xC034, 0xC035, 0xC036, 0xC068, 0xC070, 0xC071, 0xC07F,
        0xC080, 0xC08F, 0xC090, 0xC0FF, 0xC100, 0xC2FF, 0xC300, 0xC6FF, 0xC700, 0xC7FF,
        0xC800, 0xCFFF, 0xD000, 0xD0FF, 0xD100, 0xDFFF, 0xE000, 0xEFFF, 0xF7FF,
        0xFFEE, 0xFFEF, 0xFFFC, 0xFFFE, 0xFFFF
    };

    // ---- Phase 1: exhaustive over the map switches -------------------------
    printf("mmu_decode_tb: phase 1 (all 2^18 switch combinations x banks x boundary addresses)%s...\n",
           quick ? " [+quick: 1/16]" : "");
    for (int rsel = 1; rsel >= 0; rsel--) {
        const long before = n_tests, fbefore = n_fail;
        In s{};
        s.rom_select = rsel;
        for (uint32_t sw = 0; sw < (1u << 18); sw++) {
            if (quick && (sw & 15) != (uint32_t)(rsel ? 5 : 10)) continue;
            s.LCRAM2  = sw & 1;   s.RDROM   = sw & 2;    s.LC_WE  = sw & 4;
            s.ALTZP   = sw & 8;   s.RAMRD   = sw & 16;   s.RAMWRT = sw & 32;
            s.STORE80 = sw & 64;  s.PAGE2   = sw & 128;  s.HIRES  = sw & 256;
            s.shadow  = (sw >> 9) & 0x7F;
            s.bank_latch = (sw >> 16) & 1;
            s.shadow_all = (sw >> 17) & 1;
            // sampled here, swept in phases 2-4
            const uint32_t h = mix(sw * 2654435761u + rsel);
            s.SLTROMSEL = (h & 1) ? 0x80 : (uint8_t)(h >> 8);
            s.INTCXROM = h & 2; s.SLOTC3ROM = h & 4; s.INTC8ROM = h & 8;
            s.ROMBANK  = (h & 0x30) == 0x30;
            s.cxrom_local = h & 0x40;
            s.exp_banks = (h & 0x80) ? 126 : ((h >> 16) & 0x7F) % 127;
            for (uint8_t b : banks) {
                s.bank = b;
                for (uint16_t a : addrs) {
                    s.addr = a;
                    for (int we = 0; we < 2; we++) {
                        s.we = we;
                        s.vpb_n = !(a >= 0xFFEE && !we);   // exercise vectors on reads
                        run_one(s);
                    }
                }
            }
        }
        printf("mmu_decode_tb: phase 1 %s: %ld tests, %ld failures\n",
               rsel ? "ROM 01" : "ROM 3", n_tests - before, n_fail - fbefore);
    }

    // ---- Phase 2: Cx space --------------------------------------------------
    {
        printf("mmu_decode_tb: phase 2 (Cx space: internal firmware vs slots)...\n");
        const long before = n_tests, fbefore = n_fail;
        static const uint8_t cbanks[] = {0x00, 0x01, 0x02, 0xE0, 0xE1, 0xFF};
        static const uint16_t caddrs[] = {
            0xBFFF, 0xC000, 0xC071, 0xC0FF, 0xC100, 0xC1FF, 0xC200, 0xC2FF, 0xC300, 0xC3FF, 0xC400,
            0xC4FF, 0xC500, 0xC600, 0xC700, 0xC7FF, 0xC800, 0xC8FF, 0xCFFE, 0xCFFF, 0xD000
        };
        In s{};
        s.LC_WE = true; s.vpb_n = true;
        for (int rsel = 1; rsel >= 0; rsel--) {
            s.rom_select = rsel;
            for (int sw = 0; sw < 1024; sw++) {
                s.INTCXROM = sw & 1;  s.SLOTC3ROM = sw & 2;  s.INTC8ROM = sw & 4;
                s.ROMBANK  = sw & 8;  s.cxrom_local = sw & 16;
                s.shadow   = (sw & 32) ? 0x48 : 0x08;
                s.RDROM    = sw & 64; s.LCRAM2 = sw & 128;
                s.bank_latch = sw & 256; s.shadow_all = sw & 512;
                for (int slt = 0; slt < 256; slt++) {
                    s.SLTROMSEL = slt;
                    for (uint8_t b : cbanks) {
                        s.bank = b;
                        for (uint16_t a : caddrs) {
                            s.addr = a;
                            for (int we = 0; we < 2; we++) { s.we = we; run_one(s); }
                        }
                    }
                }
            }
        }
        printf("mmu_decode_tb: phase 2 done: %ld tests, %ld failures\n", n_tests - before, n_fail - fbefore);
    }

    // ---- Phase 3: expansion banks -------------------------------------------
    {
        printf("mmu_decode_tb: phase 3 (expansion banks x backed size)...\n");
        const long before = n_tests, fbefore = n_fail;
        static const uint16_t eaddrs[] = {0x0000, 0x0400, 0x0800, 0x2000, 0x6000, 0xC000, 0xC100, 0xD000, 0xFFFF};
        In s{};
        s.LC_WE = true; s.vpb_n = true; s.RDROM = true; s.LCRAM2 = true; s.bank_latch = true;
        for (int rsel = 1; rsel >= 0; rsel--) {
            s.rom_select = rsel;
            for (int exp = 0; exp <= 126; exp++) {
                s.exp_banks = exp;
                for (int sw = 0; sw < 16; sw++) {
                    s.shadow_all = sw & 1; s.RAMRD = sw & 2; s.RAMWRT = sw & 4;
                    s.shadow = (sw & 8) ? 0x7F : 0x00;
                    for (int b = 0x02; b <= 0x81; b++) {
                        s.bank = b;
                        for (uint16_t a : eaddrs) {
                            s.addr = a;
                            for (int we = 0; we < 2; we++) { s.we = we; run_one(s); }
                        }
                    }
                }
            }
        }
        printf("mmu_decode_tb: phase 3 done: %ld tests, %ld failures\n", n_tests - before, n_fail - fbefore);
    }

    // ---- Phase 4: randomized -------------------------------------------------
    {
        printf("mmu_decode_tb: phase 4 (randomized)...\n");
        srand(0xA2C816);            // fixed seed: reproducible
        const long before = n_tests, fbefore = n_fail;
        for (long i = 0; i < 6000000; i++) {
            uint32_t r1 = ((uint32_t)rand() << 16) ^ rand();
            uint32_t r2 = ((uint32_t)rand() << 16) ^ rand();
            uint32_t r3 = ((uint32_t)rand() << 16) ^ rand();
            In t{};
            t.bank      = (i & 1) ? banks[r1 % (sizeof(banks))] : (uint8_t)(r1 >> 8);
            t.addr      = (i & 2) ? addrs[r2 % (sizeof(addrs)/2)] : (uint16_t)(r2 >> 8);
            t.we        = r1 & 1;
            t.vpb_n     = !(r1 & 2) || ((r1 & 12) != 0);   // mostly 1, sometimes 0
            t.rom_select = r2 & 1;
            t.LCRAM2    = r1 & 4;    t.RDROM = r1 & 8;     t.LC_WE = r1 & 16;
            t.shadow    = (r2 >> 8) & 0x7F;
            t.ALTZP     = r1 & 32;   t.RAMRD = r1 & 64;    t.RAMWRT = r1 & 128;
            t.STORE80   = r2 & 2;    t.PAGE2 = r2 & 4;     t.HIRES = r2 & 8;
            t.bank_latch = r2 & 16;  t.shadow_all = r2 & 32;
            t.SLTROMSEL = (uint8_t)(r1 >> 16);
            t.INTCXROM  = r3 & 1;    t.SLOTC3ROM = r3 & 2; t.INTC8ROM = r3 & 4;
            t.ROMBANK   = r3 & 8;    t.cxrom_local = r3 & 16;
            t.exp_banks = (r3 >> 8) % 127;
            run_one(t);
        }
        printf("mmu_decode_tb: phase 4 done: %ld tests, %ld failures\n", n_tests - before, n_fail - fbefore);
    }

    printf("mmu_decode_tb: cheap view: %ld read, %ld write, %ld expansion, %ld internal-cycle and %ld socket-only vectors checked\n",
           n_fast_r, n_fast_w, n_fast_x, n_fast_i, n_fast_s);
    printf("mmu_decode_tb: TOTAL %ld tests, %ld failures -> %s\n",
           n_tests, n_fail, n_fail ? "FAIL" : "PASS");
    delete dut;
    return n_fail ? 1 : 0;
}
