// ============================================================================
// mmu_replica_tb.cpp - soft-switch tracker of hdl/twgs/gs_mmu_replica.sv
// against the golden SoftSw model (iigs_mmu_model.h), and the tracked state
// carried through into the decode.
//
//   1  directed: the language-card protocol, STATEREG, ROMBANK, INTC8ROM,
//      reset values - stated here as facts about the machine, checked on
//      BOTH the RTL and the golden model.
//   2  randomized bus-cycle sequences (I/O-heavy), state compared after
//      every cycle; after each, a random access is decoded through the
//      replica and compared with ref_ext() on the golden state.
//
// Usage: Vgs_mmu_replica [+rom3]   (the binary is built once per ROM)
// ============================================================================
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include "Vgs_mmu_replica.h"
#include "verilated.h"
#include "iigs_mmu_model.h"

using namespace iigs;

static Vgs_mmu_replica* dut;
static SoftSw gold;
static bool rom3 = false;
static long n_tests = 0, n_fail = 0;

static void tick()
{
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
}

static void fail(const char* what, uint32_t addr, int we, int d)
{
    if (n_fail < 40)
        printf("  FAIL %s after %s %06X data %02X: statereg dut %02X ref %02X, shadow %02X/%02X, "
               "cyareg %02X/%02X, slt %02X/%02X, misc %02X/%02X\n",
               what, we ? "write" : "read", addr, d, dut->statereg_o, gold.statereg(),
               dut->shadow_o, gold.shadow, dut->cyareg_o, gold.cyareg,
               dut->sltromsel_o, gold.sltromsel, dut->misc_o, gold.misc());
    n_fail++;
}

static void do_reset()
{
    dut->sw_reset_i = 1; dut->cyc_stb_i = 0; tick();
    dut->sw_reset_i = 0; dut->eval();
    gold.reset();
}

static bool state_equal()
{
    return dut->statereg_o == gold.statereg() && dut->shadow_o == gold.shadow &&
           dut->cyareg_o == gold.cyareg && dut->sltromsel_o == gold.sltromsel &&
           dut->misc_o == gold.misc();
}

static void cycle(uint32_t addr, bool we, uint8_t d)
{
    dut->cyc_stb_i = 1; dut->cyc_addr_i = addr; dut->cyc_we_i = we; dut->cyc_wdata_i = d;
    tick();
    dut->cyc_stb_i = 0; dut->eval();
    gold.cycle(addr, we, d, rom3);
    n_tests++;
    if (!state_equal()) fail("state", addr, we, d);
}

// a fact about the machine: both models must agree with it
static void expect(const char* what, bool rtl, bool model)
{
    n_tests++;
    if (!rtl || !model) {
        printf("  FAIL directed: %s (rtl %s, golden %s)\n", what, rtl ? "ok" : "WRONG", model ? "ok" : "WRONG");
        n_fail++;
    }
}
#define RD(a)      cycle((a), false, 0)
#define WR(a, d)   cycle((a), true, (d))
// statereg bits: 7 ALTZP 6 PAGE2 5 RAMRD 4 RAMWRT 3 RDROM 2 LCBNK2 1 ROMBANK 0 INTCXROM
// misc bits:     6 bank latch 5 INTC8ROM 4 SLOTC3ROM 3 80STORE 2 HIRES 1 LC_WE 0 LC pre-write
#define ST(mask, val)  ((dut->statereg_o & (mask)) == (val)), ((gold.statereg() & (mask)) == (val))
#define MI(mask, val)  ((dut->misc_o & (mask)) == (val)), ((gold.misc() & (mask)) == (val))

static void directed()
{
    do_reset();
    expect("reset: LC reads ROM, bank 2", ST(0x0C, 0x0C));
    expect("reset: LC write-enabled, pre-write clear", MI(0x03, 0x02));
    expect("reset: IIe switches clear", ST(0xF3, 0x00));
    expect("reset: SHADOW = $08", dut->shadow_o == 0x08, gold.shadow == 0x08);
    expect("reset: bank latch set", MI(0x40, 0x40));

    RD(0x00C080);
    expect("$C080: read RAM, bank 2", ST(0x0C, 0x04));
    expect("$C080: write-protected", MI(0x03, 0x00));
    RD(0x00C081);
    expect("$C081 once: read ROM, bank 2", ST(0x0C, 0x0C));
    expect("$C081 once: still write-protected, pre-write set", MI(0x03, 0x01));
    RD(0x00C081);
    expect("$C081 twice: write-enabled", MI(0x02, 0x02));
    RD(0x00C082);
    expect("$C082: read ROM, write-protected", MI(0x03, 0x00));
    RD(0x00C083); RD(0x00C083);
    expect("$C083 x2: read RAM bank 2", ST(0x0C, 0x04));
    expect("$C083 x2: write-enabled", MI(0x02, 0x02));
    RD(0x00C088);
    expect("$C088: read RAM bank 1", ST(0x0C, 0x00));
    expect("$C088: write-protected", MI(0x02, 0x00));
    RD(0x00C08B); RD(0x00C08B);
    expect("$C08B x2: read RAM bank 1, write-enabled", ST(0x0C, 0x00));
    expect("$C08B x2: write-enabled", MI(0x02, 0x02));
    RD(0x00C08A);
    expect("$C08A: read ROM bank 1", ST(0x0C, 0x08));
    RD(0x00C089); WR(0x00C089, 0); RD(0x00C089);
    expect("$C089 read, write, read: a write clears pre-write, so still protected", MI(0x02, 0x00));
    RD(0x00C089);
    expect("... and one more read enables", MI(0x02, 0x02));
    RD(0x00C08F);
    expect("$C08F (echo of $C08B): RAM bank 1", ST(0x0C, 0x00));
    RD(0xE1C080);
    expect("the language-card switches answer in bank E1 too", ST(0x0C, 0x04));
    expect("  ... and write-protect", MI(0x02, 0x00));

    WR(0x00C005, 0); WR(0x00C003, 0); WR(0x00C009, 0); WR(0x00C001, 0);
    expect("$C005/$C003/$C009: RAMWRT, RAMRD, ALTZP", ST(0xB0, 0xB0));
    expect("$C001: 80STORE", MI(0x08, 0x08));
    RD(0x00C004); RD(0x00C002); RD(0x00C008); RD(0x00C000);
    expect("reads of $C000-$C00B change nothing", ST(0xB0, 0xB0));
    RD(0x00C055); RD(0x00C057);
    expect("$C055 read: PAGE2", ST(0x40, 0x40));
    expect("$C057 read: HIRES", MI(0x04, 0x04));
    WR(0x00C054, 0); WR(0x00C056, 0);
    expect("$C054 write: PAGE2 off", ST(0x40, 0x00));
    expect("$C056 write: HIRES off", MI(0x04, 0x00));

    WR(0x00C068, 0x4D);
    expect("STATEREG write $4D", ST(rom3 ? 0xFD : 0xFF, 0x4D));
    WR(0x00C068, 0x0C);
    WR(0x00C035, 0x5F); WR(0x00C02D, 0xA6); WR(0x00C036, 0x94); WR(0x00C029, 0x00);
    expect("SHADOW written through bank 00 before it inhibits I/O there", dut->shadow_o == 0x5F, gold.shadow == 0x5F);
    expect("with IOLC inhibited, bank-00 $C0xx is RAM: later writes missed", dut->sltromsel_o == 0x00, gold.sltromsel == 0x00);
    WR(0xE0C02D, 0xA6); WR(0xE0C036, 0x94); WR(0xE1C029, 0x00);
    expect("... but bank E0/E1 I/O still works: SLTROMSEL", dut->sltromsel_o == 0xA6, gold.sltromsel == 0xA6);
    expect("CYAREG", dut->cyareg_o == 0x94, gold.cyareg == 0x94);
    expect("NEWVIDEO bit 0 = bank latch", MI(0x40, 0x00));
    WR(0x05C035, 0x08);
    expect("all-banks shadow (CYAREG bit 4): I/O answers in bank 05", dut->shadow_o == 0x08, gold.shadow == 0x08);
    WR(0x00C036, 0x80);
    WR(0x05C035, 0x7F);
    expect("... and not once the bit is clear", dut->shadow_o == 0x08, gold.shadow == 0x08);

    do_reset();
    RD(0x00C028);
    expect("$C028 read toggles ROMBANK on ROM 01 only", ST(0x02, rom3 ? 0x00 : 0x02));
    WR(0x00C028, 0);
    expect("$C028 write toggles it back", ST(0x02, 0x00));
    RD(0x00C300);
    expect("$C3xx with SLOTC3ROM clear sets INTC8ROM", MI(0x20, 0x20));
    RD(0x00CFFF);
    expect("$CFFF clears INTC8ROM", MI(0x20, 0x00));
    WR(0x00C00B, 0); RD(0x00C3FF);
    expect("$C3xx with SLOTC3ROM set does not", MI(0x20, 0x00));
    WR(0x00C00A, 0); WR(0xE0C3A0, 0);
    expect("a write to $C3xx in bank E0 counts", MI(0x20, 0x20));
    RD(0x02C300); RD(0x00D000); RD(0x00C2FF);
    expect("nothing else does", MI(0x20, 0x20));
    do_reset();
    expect("reset clears INTC8ROM", MI(0x20, 0x00));
}

static void check_decode(uint32_t r)
{
    static const uint8_t banks[] = {0x00, 0x01, 0x02, 0x05, 0x7F, 0xE0, 0xE1, 0xFC, 0xFE, 0xFF};
    In s{};
    s.bank = banks[r % 10];
    s.addr = (r & 0x100) ? (0xC000 | ((r >> 12) & 0xFFF)) : (uint16_t)(r >> 12);
    s.we = r & 0x200;
    s.vpb_n = !((r & 0xC00) == 0xC00);
    s.rom_select = !rom3;
    gold.fill(s);
    s.cxrom_local = dut->cxrom_local_i;
    s.exp_banks = dut->exp_banks_i;
    dut->acc_addr_i = ((uint32_t)s.bank << 16) | s.addr;
    dut->acc_we_i = s.we; dut->acc_vpb_n_i = s.vpb_n;
    dut->eval();
    const Out o = ref_mmu(s);
    const Ext x = ref_ext(s, o);
    n_tests++;
    const bool ok = dut->acc_region_o == (unsigned)x.region && dut->acc_local_o == x.local &&
                    dut->acc_forward_write_o == x.forward_write && dut->acc_local_we_o == x.local_we &&
                    dut->acc_local_rom_o == x.local_rom && dut->acc_side_effect_o == x.side_effect &&
                    (dut->acc_phys_o & 0xFFFFFF) == o.addr_bus &&
                    (!x.local_rom || (dut->acc_rom_addr_o & 0x3FFFF) == x.rom_addr);
    if (!ok) {
        if (n_fail < 40)
            printf("  FAIL decode %02X/%04X we=%d vpb_n=%d: region %u/%d local %u/%d fwd %u/%d lwe %u/%d rom %u/%d phys %06X/%06X\n",
                   s.bank, s.addr, s.we, s.vpb_n, dut->acc_region_o, x.region, dut->acc_local_o, x.local,
                   dut->acc_forward_write_o, x.forward_write, dut->acc_local_we_o, x.local_we,
                   dut->acc_local_rom_o, x.local_rom, dut->acc_phys_o & 0xFFFFFF, o.addr_bus);
        n_fail++;
    }
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "+rom3")) rom3 = true;
    dut = new Vgs_mmu_replica;
    dut->rst_n = 0; dut->sw_reset_i = 0; dut->cyc_stb_i = 0;
    dut->cxrom_local_i = 0; dut->exp_banks_i = 0;
    dut->acc_addr_i = 0; dut->acc_we_i = 0; dut->acc_vpb_n_i = 1;
    tick();
    dut->rst_n = 1; tick();

    printf("mmu_replica_tb (%s): directed soft-switch facts...\n", rom3 ? "ROM 3" : "ROM 01");
    directed();
    printf("mmu_replica_tb: directed done: %ld checks, %ld failures\n", n_tests, n_fail);

    printf("mmu_replica_tb: randomized bus-cycle sequences...\n");
    static const uint8_t iobanks[] = {0x00, 0x00, 0x00, 0x01, 0xE0, 0xE1, 0x02, 0x7F, 0xFF, 0x80};
    static const uint8_t ioregs[]  = {
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x28, 0x29,
        0x2D, 0x35, 0x36, 0x54, 0x55, 0x56, 0x57, 0x68, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86,
        0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x30
    };
    srand(0x5C0816);
    do_reset();
    const long before = n_tests, fbefore = n_fail;
    for (long i = 0; i < 3000000; i++) {
        uint32_t r1 = ((uint32_t)rand() << 16) ^ rand();
        uint32_t r2 = ((uint32_t)rand() << 16) ^ rand();
        if ((r1 & 0xFFFF) == 0x1234) {                 // an occasional machine reset
            do_reset();
            dut->cxrom_local_i = r2 & 1; dut->exp_banks_i = (r2 >> 4) % 127;
            continue;
        }
        const uint8_t bank = iobanks[(r1 >> 8) % 10];
        uint16_t a;
        switch ((r1 >> 4) & 15) {
        case 0: case 1:  a = 0xC000 | (r2 & 0xFF); break;                    // any I/O register
        case 2:          a = 0xC300 | (r2 & 0xFF); break;
        case 3:          a = (r2 & 1) ? 0xCFFF : (0xC100 | (r2 & 0xEFF)); break;
        case 4:          a = (uint16_t)r2; break;                            // anything
        default:         a = 0xC000 | ioregs[r2 % sizeof(ioregs)]; break;    // the switches
        }
        uint8_t d = (uint8_t)(r2 >> 16);
        // keep the IOLC inhibit and all-banks bits mostly clear, so the
        // sequence spends its time in the interesting states
        if ((a & 0xFF) == 0x35 && (r2 & 0x7000000)) d &= ~0x40;
        if ((a & 0xFF) == 0x36 && (r2 & 0x3000000)) d &= ~0x10;
        cycle(((uint32_t)bank << 16) | a, r1 & 1, d);
        check_decode(r2 ^ (r1 << 3));
    }
    printf("mmu_replica_tb: randomized done: %ld checks, %ld failures\n", n_tests - before, n_fail - fbefore);

    printf("mmu_replica_tb (%s): TOTAL %ld checks, %ld failures -> %s\n",
           rom3 ? "ROM 3" : "ROM 01", n_tests, n_fail, n_fail ? "FAIL" : "PASS");
    delete dut;
    return n_fail ? 1 : 0;
}
