#!/usr/bin/env python3
"""Block-level diff of two Apple II disk images (.hdv/.po/.2mg/.dsk).

Usage: tools/image_blkdiff.py GOOD BAD [--bs 512]

Compares the images block by block (skipping a 2IMG header when present) and, for
every differing block, says whether the bad block is a copy of some other block of
the good image (a stale buffer written to the wrong place), the good block shifted
by 1..8 bytes (the hdd.sv drain defect of 2026-11 shifted by one 32-bit word), or
unrelated data. Exit status 1 when the images differ.
"""
import argparse, hashlib, sys


def payload_base(data):
    return 64 if data[:4] == b"2IMG" else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("good"); ap.add_argument("bad")
    ap.add_argument("--bs", type=int, default=512)
    ap.add_argument("--max", type=int, default=64, help="blocks to list")
    a = ap.parse_args()
    g = open(a.good, "rb").read(); b = open(a.bad, "rb").read()
    base = payload_base(g); bs = a.bs
    if payload_base(b) != base:
        print("warning: only one image has a 2IMG header")
    if len(g) != len(b):
        print(f"sizes differ: good {len(g)} bad {len(b)}")
    if g[:base] != b[:base]:
        print("2IMG headers differ")
    n = min(len(g), len(b)) - base
    nblk = n // bs
    index = {}
    for i in range(nblk):
        index.setdefault(hashlib.md5(g[base + i*bs: base + (i+1)*bs]).digest(), []).append(i)
    diffs = []
    for i in range(nblk):
        x = g[base + i*bs: base + (i+1)*bs]; y = b[base + i*bs: base + (i+1)*bs]
        if x == y:
            continue
        copy_of = index.get(hashlib.md5(y).digest())
        shift = None
        for k in range(1, 9):
            if y[k:] == x[:bs-k] or x[k:] == y[:bs-k]:
                shift = k; break
        ndiff = sum(1 for p, q in zip(x, y) if p != q)
        diffs.append((i, ndiff, copy_of, shift, sum(1 for c in y if c)))
    print(f"blocks {nblk}, differing {len(diffs)}")
    for i, nd, copy_of, shift, nz in diffs[:a.max]:
        print(f"blk {i:6d} 0x{i:05x}: {nd:3d} bytes differ, nonzero={nz:3d}, "
              f"copy_of_good_block={copy_of}, shifted={shift if shift else False}")
    if len(diffs) > a.max:
        print(f"... {len(diffs) - a.max} more")
    sys.exit(1 if diffs or len(g) != len(b) else 0)


if __name__ == "__main__":
    main()
