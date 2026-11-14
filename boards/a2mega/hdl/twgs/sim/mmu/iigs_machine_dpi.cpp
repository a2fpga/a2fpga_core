// ============================================================================
// iigs_machine_dpi.cpp - DPI-C access to the golden machine model
// (iigs_mmu_model.h) for the socket benches (tb_gs_broker.sv).
//
// Two machines:
//   0  the motherboard behind the FPI: its fast RAM holds what the socket
//      wrote, its switches follow the socket cycles
//   1  the ideal reference: the machine a lockstep reference core runs
//      against, every access applied
//
// GPL-3 (it includes the golden model ported from the MiSTer Apple IIgs
// core); a2mega bench glue (c) 2026 Ed Anuff <ed@a2fpga.com>.
// ============================================================================
#include <cstdint>
#include <cstdio>
#include "iigs_mmu_model.h"

using namespace iigs;

static Machine* mach[2] = {nullptr, nullptr};

static Machine& M(int m)
{
    if (!mach[0]) { mach[0] = new Machine; mach[1] = new Machine; }
    return *mach[m & 1];
}

extern "C" {

// returns 1 (ROM 01, 128 KB), 3 (ROM 3, 256 KB) or 0 (cannot load)
int mach_load_rom(const char* path)
{
    if (!M(0).load_rom(path) || !M(1).load_rom(path)) return 0;
    return M(0).rom3 ? 3 : 1;
}

void mach_config(int ram_banks)
{
    M(0).ram_banks = ram_banks;
    M(1).ram_banks = ram_banks;
}

void mach_reset(int m) { M(m).reset(); }

// a byte of fast RAM as it is before anything has written it (both machines)
void mach_poke(int addr, int data)
{
    M(0).fast[(uint32_t)addr & 0x7FFFFF] = (uint8_t)data;
    M(1).fast[(uint32_t)addr & 0x7FFFFF] = (uint8_t)data;
}

int mach_peek(int m, int addr, int vpb_n)
{
    return M(m).peek((uint32_t)addr & 0xFFFFFF, vpb_n != 0);
}

void mach_commit(int m, int addr, int we, int data, int vpb_n)
{
    M(m).commit((uint32_t)addr & 0xFFFFFF, we != 0, (uint8_t)data, vpb_n != 0);
}

// Machine::classify bits: 0 I/O, 1 FPI sync cycle, 2 ROM read, 3 shadowed
// write, 4 Mega II bank, 5 slot space
int mach_class(int m, int addr, int we, int vpb_n)
{
    return M(m).classify((uint32_t)addr & 0xFFFFFF, we != 0, vpb_n != 0);
}

// The accelerator's question, answered by the golden model on machine m's
// switch state: bit 0 local, 1 forward_write, 2 side_effect, 3 local_we,
// 4 local_rom, bits 10:8 region
// (bit 5: slow_only.  The card's copy of Mega II RAM - mach_slow - is part of the
// question: whether it is kept, and whether its reads are the card's.)
static bool g_slow_copy = false, g_slow_local = false;
void mach_slow(int copy, int local)
{
    g_slow_copy = copy != 0;
    g_slow_local = local != 0;
}

int mach_ext(int m, int addr, int we, int vpb_n, int cxrom_local, int exp_banks)
{
    In s = M(m).mk_in((uint32_t)addr & 0xFFFFFF, we != 0, vpb_n != 0);
    s.cxrom_local = cxrom_local != 0;
    s.exp_banks = (uint8_t)exp_banks;
    s.slow_copy = g_slow_copy;
    s.slow_local = g_slow_local;
    const Out o = ref_mmu(s);
    const Ext e = ref_ext(s, o);
    return (e.local ? 1 : 0) | (e.forward_write ? 2 : 0) | (e.side_effect ? 4 : 0) |
           (e.local_we ? 8 : 0) | (e.local_rom ? 16 : 0) | (e.slow_only ? 32 : 0) | (e.region << 8);
}

// space: 0 fast RAM (24-bit address), 1 Mega II RAM (17-bit), 2 I/O register
// file (8-bit), 3 soft-switch view (0 STATEREG, 1 SHADOW, 2 CYAREG,
// 3 SLTROMSEL, 4 misc)
int mach_get(int m, int space, int addr)
{
    Machine& x = M(m);
    switch (space) {
    case 0: return x.fast[(uint32_t)addr & 0x7FFFFF];
    case 1: return x.slow[(uint32_t)addr & 0x1FFFF];
    case 2: return x.io[addr & 0xFF];
    default:
        switch (addr) {
        case 0: return x.sw.statereg();
        case 1: return x.sw.shadow;
        case 2: return x.sw.cyareg;
        case 3: return x.sw.sltromsel;
        default: return x.sw.misc();
        }
    }
}

// number of bytes that differ between the two machines: space 0 fast RAM in
// [lo, hi), 1 Mega II RAM + I/O register file + soft switches
int mach_diff(int space, int lo, int hi)
{
    Machine& a = M(0);
    Machine& b = M(1);
    int n = 0;
    if (space == 0) {
        for (int i = lo; i < hi; i++) if (a.fast[i] != b.fast[i]) n++;
    } else {
        for (int i = 0; i < 2 * 65536; i++) if (a.slow[i] != b.slow[i]) n++;
        for (int i = 0; i < 256; i++) if (a.io[i] != b.io[i]) n++;
        if (a.sw.statereg() != b.sw.statereg() || a.sw.shadow != b.sw.shadow ||
            a.sw.cyareg != b.sw.cyareg || a.sw.sltromsel != b.sw.sltromsel ||
            a.sw.misc() != b.sw.misc()) n++;
    }
    return n;
}

// first differing Mega II RAM address, or -1
int mach_diff_where()
{
    Machine& a = M(0);
    Machine& b = M(1);
    for (int i = 0; i < 2 * 65536; i++) if (a.slow[i] != b.slow[i]) return i;
    for (int i = 0; i < 256; i++) if (a.io[i] != b.io[i]) return 0x20000 + i;
    return -1;
}

// copy the ideal machine's Mega II RAM into the motherboard model (bench
// bookkeeping after a posted write was dropped by a reset)
void mach_sync_slow()
{
    M(0).slow = M(1).slow;
}

// counters: 0 I/O writes, 1 shadowed writes, 2 language-card switch
// accesses, 3 $C028 accesses
int mach_stat(int m, int which)
{
    Machine& x = M(m);
    switch (which) {
    case 0: return (int)x.n_io_wr;
    case 1: return (int)x.n_shadow_wr;
    case 2: return (int)x.n_lc_sw;
    default: return (int)x.n_c028;
    }
}

} // extern "C"
