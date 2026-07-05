/*
 * gcr_dsk.c — Apple II 6-and-2 GCR codec for DOS 3.3 order .dsk/.do images.
 * See gcr_dsk.h. Algorithm/tables/gap sizes ported from AppleWin
 * CImageBase::Code62 / Decode62 / NibblizeTrack (source/DiskImageHelper.cpp).
 */

#include "gcr_dsk.h"
#include <string.h>

/* 6-and-2 write-translate table: the 64 legal "disk bytes" ($96..$FF), those
 * with no more than two consecutive zero bits. (AppleWin ms_DiskByte.) */
static const uint8_t kDiskByte[0x40] = {
    0x96,0x97,0x9A,0x9B,0x9D,0x9E,0x9F,0xA6,
    0xA7,0xAB,0xAC,0xAD,0xAE,0xAF,0xB2,0xB3,
    0xB4,0xB5,0xB6,0xB7,0xB9,0xBA,0xBB,0xBC,
    0xBD,0xBE,0xBF,0xCB,0xCD,0xCE,0xCF,0xD3,
    0xD6,0xD7,0xD9,0xDA,0xDB,0xDC,0xDD,0xDE,
    0xDF,0xE5,0xE6,0xE7,0xE9,0xEA,0xEB,0xEC,
    0xED,0xEE,0xEF,0xF2,0xF3,0xF4,0xF5,0xF6,
    0xF7,0xF9,0xFA,0xFB,0xFC,0xFD,0xFE,0xFF
};

/* Inverse of kDiskByte: disk byte -> 6-bit value (0..63), or 0xFF if illegal.
 * Lazily built; the disk-serve task is single-threaded so no lock is needed. */
static uint8_t kReadByte[256];
static int     kReadByteReady = 0;

static void ensure_read_table(void)
{
    if (kReadByteReady)
        return;
    memset(kReadByte, 0xFF, sizeof(kReadByte));
    for (int i = 0; i < 0x40; i++)
        kReadByte[kDiskByte[i]] = (uint8_t)i;
    kReadByteReady = 1;
}

/* Sector order tables (AppleWin ms_SectorNumber): map a physical sector 0..15
 * (as it appears in order around the track / in the address field) to the
 * 256-byte sector slot in the image file. Used both ways: encode pulls
 * physical P's data from file offset order[P]*256; decode stores physical P's
 * recovered data to that same offset. Index with gcr_order_t. */
/* CAUTION — the classic interleave footgun, which bit this codec once:
 * physical sector P carries the file's sector order[P]. For DOS 3.3 order
 * the canonical physical->logical map is {0,7,E,6,D,5,C,4,B,3,A,2,9,1,8,F};
 * for ProDOS order it is {0,8,1,9,2,A,3,B,4,C,5,D,6,E,7,F}. (AppleWin's
 * ms_SectorNumber rows list ProDOS FIRST — porting them as DOS-first swapped
 * the two and broke every externally-created image while remaining perfectly
 * self-consistent for our own decode->encode round trips. Proven against
 * ProDOS boot0 in simulation: the swapped table BRKs at $09xx, the canonical
 * one boots.) */
static const uint8_t kSectorOrder[2][16] = {
    /* GCR_ORDER_DOS (.dsk/.do) */
    { 0x00,0x07,0x0E,0x06,0x0D,0x05,0x0C,0x04,
      0x0B,0x03,0x0A,0x02,0x09,0x01,0x08,0x0F },
    /* GCR_ORDER_PRODOS (.po) */
    { 0x00,0x08,0x01,0x09,0x02,0x0A,0x03,0x0B,
      0x04,0x0C,0x05,0x0D,0x06,0x0E,0x07,0x0F },
};

/* 4-and-4 codec (address field). */
#define CODE44A(a) ((uint8_t)((((a) >> 1) & 0x55) | 0xAA))
#define CODE44B(a) ((uint8_t)(((a) & 0x55) | 0xAA))
static inline uint8_t decode44(uint8_t a, uint8_t b)
{
    return (uint8_t)((((a) << 1) | 1) & (b));
}

/* Prologues / epilogues. */
static const uint8_t kAddrProlog[3] = { 0xD5, 0xAA, 0x96 };
static const uint8_t kDataProlog[3] = { 0xD5, 0xAA, 0xAD };
static const uint8_t kEpilog[3]     = { 0xDE, 0xAA, 0xEB };

/* ---- 6-and-2 encode: 256 raw bytes -> 343 disk bytes (342 data + checksum).
 * Verbatim port of AppleWin Code62. -------------------------------------- */
static void code62(const uint8_t sec[256], uint8_t out[343])
{
    uint8_t nib[342];
    uint8_t offset = 0xAC;
    int idx = 0;

#define ADDVALUE(a) value = (uint8_t)((value << 2) | (((a) & 0x01) << 1) | (((a) & 0x02) >> 1))
    while (offset != 0x02) {
        uint8_t value = 0;
        ADDVALUE(sec[offset]); offset -= 0x56;
        ADDVALUE(sec[offset]); offset -= 0x56;
        ADDVALUE(sec[offset]); offset -= 0x53;
        nib[idx++] = (uint8_t)(value << 2);
    }
#undef ADDVALUE
    nib[idx - 2] &= 0x3F;   /* last two aux groups are partial */
    nib[idx - 1] &= 0x3F;
    for (int i = 0; i < 256; i++)
        nib[idx++] = sec[i];
    /* idx == 342 */

    /* running-XOR checksum -> 343 six-bit values */
    uint8_t xbuf[343];
    uint8_t saved = 0;
    for (int i = 0; i < 342; i++) {
        xbuf[i] = (uint8_t)(saved ^ nib[i]);
        saved = nib[i];
    }
    xbuf[342] = saved;

    /* translate to disk bytes (high 6 bits of each value) */
    for (int i = 0; i < 343; i++)
        out[i] = kDiskByte[xbuf[i] >> 2];
}

/* ---- 6-and-2 decode: 343 disk bytes -> 256 raw bytes. Returns 1 if the disk
 * bytes are all legal and the checksum matches, else 0 (out untouched on fail).
 * Verbatim port of AppleWin Decode62 + explicit checksum/legality checks. -- */
static int decode62(const uint8_t in[343], uint8_t out[256])
{
    ensure_read_table();

    uint8_t sb[343];   /* six-bit values in AppleWin's <<2 form */
    for (int i = 0; i < 343; i++) {
        uint8_t v = kReadByte[in[i]];
        if (v == 0xFF)
            return 0;             /* illegal disk byte */
        sb[i] = (uint8_t)(v << 2);
    }

    /* undo running-XOR into nib[0..341]; sb[342] is the checksum */
    uint8_t nib[342];
    uint8_t saved = 0;
    for (int i = 0; i < 342; i++) {
        nib[i] = (uint8_t)(saved ^ sb[i]);
        saved = nib[i];
    }
    if (sb[342] != saved)
        return 0;                 /* checksum mismatch */

    /* reassemble 256 bytes: high 6 bits from the 256-section (nib+0x56),
     * low 2 bits from the aux section (nib[0..85]). */
    const uint8_t *lowbits = nib;
    const uint8_t *base    = nib + 0x56;
    uint8_t offset = 0xAC;
    while (offset != 0x02) {
        if (offset >= 0xAC)
            out[offset] = (uint8_t)((base[offset] & 0xFC)
                                    | ((lowbits[0] & 0x80) >> 7)
                                    | ((lowbits[0] & 0x40) >> 5));
        offset -= 0x56;
        out[offset] = (uint8_t)((base[offset] & 0xFC)
                                | ((lowbits[0] & 0x20) >> 5)
                                | ((lowbits[0] & 0x10) >> 3));
        offset -= 0x56;
        out[offset] = (uint8_t)((base[offset] & 0xFC)
                                | ((lowbits[0] & 0x08) >> 3)
                                | ((lowbits[0] & 0x04) >> 1));
        offset -= 0x53;
        lowbits++;
    }
    return 1;
}

/* ---- public: encode one sector-image track -> 6656-byte nibble stream ---- */
size_t gcr_encode_dos_track(const uint8_t dsk_track[DSK_TRACK_BYTES],
                            uint8_t track, uint8_t volume, gcr_order_t order,
                            uint8_t *out, size_t out_cap)
{
    const uint8_t *ord = kSectorOrder[order == GCR_ORDER_PRODOS ? 1 : 0];

    if (out_cap < GCR_TRACK_BYTES)
        return 0;

    uint8_t *p = out;
    int i;

    /* GAP 1: 48 self-sync bytes */
    for (i = 0; i < 48; i++)
        *p++ = 0xFF;

    for (int s = 0; s < 16; s++) {
        /* address field */
        *p++ = kAddrProlog[0]; *p++ = kAddrProlog[1]; *p++ = kAddrProlog[2];
        *p++ = CODE44A(volume); *p++ = CODE44B(volume);
        *p++ = CODE44A(track);  *p++ = CODE44B(track);
        *p++ = CODE44A((uint8_t)s); *p++ = CODE44B((uint8_t)s);
        uint8_t chk = (uint8_t)(volume ^ track ^ (uint8_t)s);
        *p++ = CODE44A(chk); *p++ = CODE44B(chk);
        *p++ = kEpilog[0]; *p++ = kEpilog[1]; *p++ = kEpilog[2];

        /* GAP 2: 6 self-sync bytes */
        for (i = 0; i < 6; i++)
            *p++ = 0xFF;

        /* data field: prologue + 343 six-and-two + epilogue */
        *p++ = kDataProlog[0]; *p++ = kDataProlog[1]; *p++ = kDataProlog[2];
        code62(&dsk_track[ord[s] * 256], p);
        p += 343;
        *p++ = kEpilog[0]; *p++ = kEpilog[1]; *p++ = kEpilog[2];

        /* GAP 3: 27 self-sync bytes (the RWTS write splice lands here) */
        for (i = 0; i < 27; i++)
            *p++ = 0xFF;
    }

    /* pad the remainder with self-sync so the track is exactly 6656 bytes; the
     * window wrap then falls inside a long $FF run and RWTS resyncs cleanly. */
    while ((size_t)(p - out) < GCR_TRACK_BYTES)
        *p++ = 0xFF;

    return GCR_TRACK_BYTES;
}

/* ---- public: decode a (possibly partially rewritten) nibble window -------- */
uint16_t gcr_decode_dos_track(const uint8_t *nibbles, size_t len,
                              gcr_order_t order,
                              uint8_t dsk_track[DSK_TRACK_BYTES])
{
    const uint8_t *ord = kSectorOrder[order == GCR_ORDER_PRODOS ? 1 : 0];

    if (len < 16)
        return 0;

    uint16_t mask = 0;

    for (size_t i = 0; i < len; i++) {
        /* address prologue? (circular) */
        if (nibbles[i] != 0xD5 ||
            nibbles[(i + 1) % len] != 0xAA ||
            nibbles[(i + 2) % len] != 0x96)
            continue;

        size_t a = i + 3;
        uint8_t vol = decode44(nibbles[a % len],       nibbles[(a + 1) % len]);
        uint8_t trk = decode44(nibbles[(a + 2) % len], nibbles[(a + 3) % len]);
        uint8_t sec = decode44(nibbles[(a + 4) % len], nibbles[(a + 5) % len]);
        uint8_t chk = decode44(nibbles[(a + 6) % len], nibbles[(a + 7) % len]);
        (void)trk;
        if (sec >= 16 || chk != (uint8_t)(vol ^ trk ^ sec))
            continue;
        if (mask & (1u << sec))
            continue;   /* already have this sector */

        /* find the data prologue shortly after the address epilogue */
        size_t j = a + 8;
        size_t limit = j + 64;
        int found = 0;
        for (; j < limit; j++) {
            if (nibbles[j % len] == 0xD5 &&
                nibbles[(j + 1) % len] == 0xAA &&
                nibbles[(j + 2) % len] == 0xAD) {
                found = 1;
                break;
            }
        }
        if (!found)
            continue;

        uint8_t d343[343];
        size_t d = j + 3;
        for (int k = 0; k < 343; k++)
            d343[k] = nibbles[(d + k) % len];

        uint8_t out256[256];
        if (decode62(d343, out256)) {
            memcpy(&dsk_track[ord[sec] * 256], out256, 256);
            mask |= (uint16_t)(1u << sec);
            if (mask == 0xFFFF)
                break;
        }
    }

    return mask;
}
