#!/usr/bin/env python3
"""Regenerate the memory floorplan at the end of the accelerator probe's .cst files.

    gen_floorplan.py            all three variants
    gen_floorplan.py flat|c32|rom3 [strips|low|quads]
    gen_floorplan.py near

The GW5AST-138B has its BSRAM sites in horizontal strips 18 rows apart
(R10 ... R100), 36-38 sites per strip across the whole die (one every ~6.5
columns).  Left to itself the placer put the RAM in the outermost strips,
40-50 rows from the core.  The layout used ("strips"): bank-00/01 RAM (64
blocks) in the two strips the core sits between (R46, R64), 32 sites each, the
eight blocks of a data bit together (4 + 4), two bits per column quarter, one
copy of the read addresses and enables per quarter; the second memory in the
strips outside those.  Variants (one project each):

  flat  accel_probe_138b.cst      second memory = a 128 KB ROM image (ROM 01),
                                  64 blocks in R28 / R82
  c32   accel_probe_138b_c32.cst  second memory = 32 KB (a cache in front of a
                                  backing store), 16 blocks in the middle of
                                  R28 / R82 (nearer the core than the RAM's ends)
  rom3  accel_probe_138b_r3.cst   second memory = a 256 KB ROM image (ROM 3),
                                  128 blocks in R28 / R82 / R10 / R100

  near  accel_probe_138b_near.cst the near-memory probe: the near memory's 14
                                  blocks in sites 18-21 of R46 / R64, everything
                                  else left to the placer (the far memories are
                                  read from registers).  Some site indices hold
                                  two blocks, named [A] and [B] (18, 19 and 21
                                  here; 17, 20 and 22 hold one, and naming a
                                  half of those is error CT1130): the data bits
                                  are in 18 / 19, the tag bits in 17 / 20 / 21.
                                  The blocks in R64 take the read address from
                                  the core's second copy of it (accel_probe_top),
                                  and a pair of entry bits is one memory to the
                                  synthesizer, so each pair is in one row.  Left
                                  alone the placer put near blocks 100 columns
                                  from the core; one block per index spread them
                                  over 46 columns and the core with them.

"low" is the same layout one strip further down (RAM in R64 / R82), nearer the
socket's pins, which are on the bottom edge and the lower right edge.

"quads" (flat only; kept for the record) put the 128 sites nearest the core
over six strips, in four quadrants: worse, it pulls the core itself apart
(exploration log, integration build 10).

Instance names are what GowinSynthesis gives accel_probe_top's arrays: it
merges the two bits that share a read-address copy into one 16Kx2 memory
named after the even bit, split into blocks ..._0_0_s (even bit) and
..._0_1_s (odd bit).
"""
import pathlib, sys

HERE = pathlib.Path(__file__).parent
MARK = "// Floorplan of the two local memories"
FILES = {"flat": "accel_probe_138b.cst", "c32": "accel_probe_138b_c32.cst", "rom3": "accel_probe_138b_r3.cst",
         "near": "accel_probe_138b_near.cst"}

def name(mem, bit, blk):
    p = 2 * (bit // 2)
    g = "g_blk" if mem == "ram" else "g_rblk"
    return f"g_bit[{p}].{g}[{blk}].m{mem}_g_bit[{p}].{g}[{blk}].m{mem}_0_{bit % 2}_s"

def loc(mem, bit, blk, strip, idx):
    return f'INS_LOC "{name(mem, bit, blk)}" BSRAM_{strip}[{idx}];'

def strips(variant, low=False):
    # low: everything one strip (18 rows) further down, towards the socket's pins
    ram = ("R64", "R82") if low else ("R46", "R64")
    rom = ("R46", "R100", "R28", "R10") if low else ("R28", "R82", "R10", "R100")
    out = []
    for bit in range(8):
        for blk in range(8):
            out.append(loc("ram", bit, blk, ram[blk // 4], 3 + bit * 4 + blk % 4))
    for bit in range(8):
        if variant == "flat":
            for blk in range(8):
                out.append(loc("rom", bit, blk, rom[blk // 4], 3 + bit * 4 + blk % 4))
        elif variant == "c32":
            for blk in range(2):
                out.append(loc("rom", bit, blk, rom[blk], 15 + bit))
        else:
            for blk in range(16):
                out.append(loc("rom", bit, blk, rom[blk // 4], 3 + bit * 4 + blk % 4))
    return out

def quads():
    CENTER_ROW, CENTER_IDX, COLS_PER_IDX = 55, 18.5, 6.5
    QUADS = [[("R46", 18, 5),  ("R28", 18, 8),  ("R10", 18, 12)],
             [("R46", 19, 32), ("R28", 19, 29), ("R10", 19, 25)],
             [("R64", 18, 5),  ("R82", 18, 8),  ("R100", 18, 12)],
             [("R64", 19, 32), ("R82", 19, 29), ("R100", 19, 25)]]
    out = []
    for q, strps in enumerate(QUADS):
        sites = []
        for strip, a, b in strps:
            sites += [(strip, i) for i in range(a, b + (1 if b >= a else -1), 1 if b >= a else -1)]
        sites.sort(key=lambda s: abs(int(s[0][1:]) - CENTER_ROW) + abs(s[1] - CENTER_IDX) * COLS_PER_IDX)
        for n, (strip, idx) in enumerate(sites):
            mem, j = ("ram" if n % 2 == 0 else "rom"), n // 2
            out.append(loc(mem, 2 * q + j // 8, j % 8, strip, idx))
    return out

NEAR_SITES = ["R46[18][A]", "R46[18][B]", "R64[18][A]", "R64[18][B]",      # data bits 0-7
              "R46[19][A]", "R46[19][B]", "R64[19][A]", "R64[19][B]",
              "R46[20]", "R46[17]",                                        # tag bits 8-13 (a pair of bits is
                                                                           # one memory to the synthesizer: both in one row)
              "R46[21][A]", "R46[21][B]", "R64[21][A]", "R64[21][B]",
              "R64[20]",                                                   # tag bit 14 (gs_accel NEAR_KW = 5)
              "R64[17]",                                                   # bit 15
              "R46[22]", "R46[16]",                                        # bits 16, 17 (the whole tag of NEAR_KW = 9:
              "R64[22]"]                                                   # bit 18     19 blocks)

# The line cache's blocks (gs_accel NEAR_LINE): the eight words of a line - even words on the
# core's first copy of its next address, in R46, odd words on the second, in R64 - and the tags.
LINE_SITES = ([(f"u_acc/g_line.g_nb[{w}].nmem/bram", f"{'R64' if w % 2 else 'R46'}[{18 + w // 4}][{'AB'[(w // 2) % 2]}]")
               for w in range(8)]
              + [("u_acc/g_line.g_nt.nmem_g_line.g_nt.nmem_0_0_s", "R46[20]")])

def write_accel():
    """hdl/accel_only/accel_only_138b.cst, the accelerator-only board build: the pin
    constraints of hdl/a2mega_138b.cst for the ports hdl/accel_only/accel_only_top.sv has,
    and the near memory's floorplan with gs_accel's names."""
    import re
    top = (HERE.parent / "accel_only" / "accel_only_top.sv").read_text()
    top = top[top.index("module top ("):top.index(");", top.index("module top ("))]
    ports = set(re.findall(r"(\w+)\s*(?:,|$)", re.sub(r"//.*", "", top), re.M))
    kept, seen, dropped = [], set(), set()
    for l in (HERE.parent / "a2mega_138b.cst").read_text().split("\n"):
        m = re.match(r'\s*(IO_LOC|IO_PORT)\s+"([^"\[]+)(\[\d+\])?"', l)
        if not m:              kept.append(l)
        elif m.group(2) in ports: kept.append(l); seen.add(m.group(2))
        else:                  dropped.add(m.group(2))
    # (the negative halves of the DDR3's differential pairs have no line of their own in the reference)
    missing = sorted(p for p in ports if p not in seen and p not in ("top", "input", "output", "inout", "wire", "ddr_ck_n", "ddr_dqs_n"))
    assert not missing, f"ports of the top with no pin: {missing}"
    nb = lambda b: f"u_acc/g_nb[{b - b % 2}].nmem_g_nb[{b - b % 2}].nmem_0_{b % 2}_s"
    topsrc = (HERE.parent / "accel_only" / "accel_only_top.sv").read_text()
    kw = re.search(r"\.NEAR_KW\((\d+)\)", topsrc)
    # entry bits read with the core's next address: data, {ROM, A12}, NEAR_KW address bits - or, with the
    # split tag (NEAR_SPLIT), the fourteen of NEAR_KW = 4: the tag's high address bits are in blocks of
    # their own, read from a register, which need no site
    nbits = 14 if re.search(r"\.NEAR_SPLIT\(1", topsrc) else 8 + 2 + (int(kw.group(1)) if kw else 4)
    assert nbits <= len(NEAR_SITES), "no site for that many near-memory bits"
    lines = [f'INS_LOC "{nb(b)}" BSRAM_{NEAR_SITES[b]};' for b in range(nbits)]
    # the line cache (gs_accel NEAR_LINE, unless ACC_BYTE_CACHE is defined): eight blocks of a line's
    # words and one of tags - LINE_SITES below
    defs = (HERE.parent / "accel_only" / "accel_only_defines.v").read_text()
    if not any(l.strip().startswith("`define ACC_BYTE_CACHE") for l in defs.splitlines()):
        lines = [f'INS_LOC "{n}" BSRAM_{s};' for n, s in LINE_SITES]
    hdr = ("// Accelerator-only build (hdl/accel_only/accel_only_top.sv, a2mega_accel_138B.gprj).\n"
           "// GENERATED by hdl/accel_probe_138b/gen_floorplan.py accel - edit that.\n"
           "// The pin constraints are hdl/a2mega_138b.cst's (the reference), for the ports this top\n"
           "// has: the others (" + ", ".join(sorted(dropped)) + ")\n"
           "// are not ports here and are left to the unused-pin default.\n//\n")
    (HERE.parent / "accel_only" / "accel_only_138b.cst").write_text(hdr + "\n".join(kept).rstrip("\n") + "\n\n"
        + "// Floorplan of the near memory (gs_accel) - as the timing probe's, which gen_floorplan.py explains.\n"
        + "\n".join(lines) + "\n")
    print(f"accel: {len(seen)} ports, {len(lines)} INS_LOC lines -> ../accel_only/accel_only_138b.cst")

def write(variant, layout="strips"):
    if variant == "accel":
        write_accel()
        return
    if variant == "near":
        # entry bit b (0-7 data, 8-13 tag) is block ..._0_{b % 2}_s of the pair g_nb[b - b % 2]
        nb = lambda b: f"g_near.g_nb[{b - b % 2}].nmem_g_near.g_nb[{b - b % 2}].nmem_0_{b % 2}_s"
        SITES = NEAR_SITES
        lines = [f'INS_LOC "{nb(b)}" BSRAM_{SITES[b]};' for b in range(14)]
        s = (HERE / FILES["flat"]).read_text()
        (HERE / FILES["near"]).write_text(s[:s.index(MARK)].rstrip("\n") + "\n\n"
            + "// Floorplan of the near memory - generated by gen_floorplan.py, which explains it.\n"
            + "\n".join(lines) + "\n")
        print(f"near: {len(lines)} INS_LOC lines -> {FILES['near']}")
        return
    lines = quads() if (layout == "quads" and variant == "flat") else strips(variant, layout == "low")
    assert len(lines) == {"flat": 128, "c32": 80, "rom3": 192}[variant]
    assert len({l.split('"')[2] for l in lines}) == len(lines), "two blocks on one site"
    cst = HERE / FILES[variant]
    s = cst.read_text() if cst.exists() else (HERE / FILES["flat"]).read_text()
    if MARK in s:
        s = s[:s.index(MARK)]
    cst.write_text(s.rstrip("\n") + "\n\n" + MARK + " - generated by gen_floorplan.py, which explains it.\n"
                   + "\n".join(lines) + "\n")
    print(f"{variant} ({layout}): {len(lines)} INS_LOC lines -> {cst.name}")

if len(sys.argv) > 1:
    write(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "strips")
else:
    for v in FILES:
        write(v)
