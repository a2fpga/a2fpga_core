/*
 * w5100.c -- Emulated WIZnet W5100 core (MACRAW bridge) for the A2FPGA
 * Uthernet II card. See w5100.h for the architecture overview.
 *
 * The FPGA card holds the W5100 register/buffer space (served to the Apple II at
 * bus speed) and raises a per-socket doorbell (FPGA reg 0x7A) when the Apple II
 * writes Sn_CR. We poll that doorbell, read the command + registers/buffers over
 * SPI memory SPACE 3, and act:
 *   - MACRAW OPEN  -> start bridging socket 0 to the USB-Ethernet adapter
 *   - MACRAW SEND  -> drain the TX ring and transmit the raw frame
 *   - MACRAW RECV  -> recompute Sn_RX_RSR from the Apple II's read pointer
 *   - CLOSE        -> stop bridging
 * Wire frames arrive via w5100_macraw_rx() (called from the USB RX hook), are
 * MAC-filtered, framed with the 2-byte length header, and pushed into the RX ring.
 *
 * The actual TX/promiscuous/MAC-filter plumbing lives in main.c behind the weak
 * hooks below.
 */

#include "w5100.h"
#include "fpga_spi.h"
#include <string.h>

/* ---- weak bridge hooks (overridden in main.c) ---- */
__attribute__((weak)) void w5100_bridge_tx(const uint8_t *frame, uint32_t len) { (void)frame; (void)len; }
__attribute__((weak)) bool w5100_bridge_dongle_mac(uint8_t mac[6]) { (void)mac; return false; }
__attribute__((weak)) void w5100_bridge_set_dongle_mac(const uint8_t mac[6]) { (void)mac; }
__attribute__((weak)) void w5100_bridge_set_promiscuous(void) {}

/* ---- emulation state ---- */
typedef struct {
    uint8_t  mode;        /* Sn_MR protocol field */
    uint8_t  status;      /* Sn_SR */
    uint16_t rx_base;     /* W5100 address of this socket's RX buffer */
    uint16_t rx_size;     /* bytes */
    uint16_t rx_mask;     /* rx_size - 1 */
    uint16_t rx_wr;       /* our RX write pointer (offset, wraps via mask) */
    uint16_t tx_base;
    uint16_t tx_size;
    uint16_t tx_mask;
} sock_t;

static sock_t g_sock[W5100_NUM_SOCKETS];
static bool    g_macraw_active;
static bool    g_macraw_mf;       /* MAC filter enabled */
static uint8_t g_mac[6];          /* Apple II SHAR (read at MACRAW open) */
static bool    g_mac_valid;
static bool    g_dongle_mirrored; /* dongle MAC programmed = Apple II SHAR */
static bool    g_shar_seeded;     /* SHAR preloaded with the dongle MAC */

/* Diagnostics surfaced on the DebugOverlay (scratch regs 0x0C/0x0D) */
static volatile uint32_t g_cmds;       /* socket commands serviced (doorbell) */
static volatile uint32_t g_rx_frames;  /* frames bridged wire -> Apple II */
static volatile uint32_t g_tx_frames;  /* frames bridged Apple II -> wire */
static volatile uint32_t g_drop_full;  /* RX frames dropped: MACRAW ring full */

/* W5100 power-on register defaults. The emulated register backing store comes up
 * zeroed, but software probes the chip by reading reset defaults -- notably IP65,
 * which reads RTR (0x0017-18) and expects 0x07D0. Seed the documented defaults at
 * boot so detection passes. (addr, value) pairs over the common register block. */
static const struct { uint16_t addr; uint8_t val; } W5100_DEFAULTS[] = {
    { 0x0017, 0x07 }, { 0x0018, 0xD0 },  /* RTR  = 0x07D0 (retry time, 200ms) */
    { 0x0019, 0x08 },                    /* RCR  = 8 (retry count) */
    { 0x001A, 0x55 },                    /* RMSR = 2KB per socket */
    { 0x001B, 0x55 },                    /* TMSR = 2KB per socket */
    { 0x0028, 0x28 },                    /* PTIMER */
};

/* Scratch for moving a frame between SPACE 3 and the wire */
static uint8_t g_frame[W5100_MAX_FRAME + 4];

/* ---- SPACE 3 register helpers (W5100 16-bit regs are big-endian) ---- */
static inline uint8_t w_rd8(uint16_t addr)
{
    uint8_t v;
    fpga_spi_xfer_read(FPGA_SPACE_W5100, addr, &v, 1);
    return v;
}
static inline void w_wr8(uint16_t addr, uint8_t v)
{
    fpga_spi_xfer_write(FPGA_SPACE_W5100, addr, &v, 1);
}
static inline uint16_t w_rd16(uint16_t addr)
{
    uint8_t b[2];
    fpga_spi_xfer_read(FPGA_SPACE_W5100, addr, b, 2);
    return ((uint16_t)b[0] << 8) | b[1];
}
static inline void w_wr16(uint16_t addr, uint16_t v)
{
    uint8_t b[2] = { (uint8_t)(v >> 8), (uint8_t)v };
    fpga_spi_xfer_write(FPGA_SPACE_W5100, addr, b, 2);
}

/* Decode a 2-bit RMSR/TMSR field to a byte count (1/2/4/8 KB). */
static uint16_t mem_size_field(uint8_t reg, int socket)
{
    uint8_t f = (reg >> (socket * 2)) & 0x03;
    return (uint16_t)(1024u << f);
}

/* ---- command handlers ---- */

static void macraw_open(int n)
{
    sock_t *s = &g_sock[n];
    uint8_t rmsr = w_rd8(W5100_RMSR);
    uint8_t tmsr = w_rd8(W5100_TMSR);

    /* Socket 0 buffers start at the bases; (later sockets would be offset, but
     * MACRAW is socket 0 only.) */
    s->rx_base = W5100_RX_BASE;
    s->rx_size = mem_size_field(rmsr, n);
    s->rx_mask = s->rx_size - 1;
    s->tx_base = W5100_TX_BASE;
    s->tx_size = mem_size_field(tmsr, n);
    s->tx_mask = s->tx_size - 1;
    s->rx_wr   = 0;

    /* Reset ring pointers in the backing store */
    w_wr16(W5100_S_BASE(n) + W5100_Sn_TX_RD, 0);
    w_wr16(W5100_S_BASE(n) + W5100_Sn_TX_WR, 0);
    w_wr16(W5100_S_BASE(n) + W5100_Sn_RX_RD, 0);
    w_wr16(W5100_S_BASE(n) + W5100_Sn_RX_RSR, 0);
    w_wr16(W5100_S_BASE(n) + W5100_Sn_TX_FSR, s->tx_size);

    s->status = W5100_SOCK_MACRAW;
    w_wr8(W5100_S_BASE(n) + W5100_Sn_SR, s->status);

    /* Capture the Apple II MAC (SHAR) for filtering */
    fpga_spi_xfer_read(FPGA_SPACE_W5100, W5100_SHAR, g_mac, 6);
    g_mac_valid = (g_mac[0] | g_mac[1] | g_mac[2] | g_mac[3] | g_mac[4] | g_mac[5]) != 0;

    uint8_t sn_mr = w_rd8(W5100_S_BASE(n) + W5100_Sn_MR);
    g_macraw_mf = (sn_mr & W5100_MR_MF) != 0;
    g_macraw_active = true;
    g_dongle_mirrored = false;   /* w5100_sync_mac() will mirror SHAR -> dongle */
}

static void sock_close(int n)
{
    g_sock[n].status = W5100_SOCK_CLOSED;
    w_wr8(W5100_S_BASE(n) + W5100_Sn_SR, W5100_SOCK_CLOSED);
    if (n == 0 && g_macraw_active) {
        g_macraw_active = false;
        g_dongle_mirrored = false;
    }
}

/* Keep the dongle MAC and the Apple II SHAR equal so the dongle's hardware filter
 * passes the Apple II's frames -- no promiscuous, no per-packet work. Idempotent;
 * polled each w5100_poll so it handles both plug orders and re-plug. */
static void w5100_sync_mac(void)
{
    uint8_t dmac[6];
    if (!w5100_bridge_dongle_mac(dmac)) {
        /* No adapter / not enumerated yet -> reset so we re-apply on (re)connect */
        g_dongle_mirrored = false;
        g_shar_seeded = false;
        return;
    }
#ifdef W5100_BRIDGE_FORCE_PROMISC
    if (!g_shar_seeded) { w5100_bridge_set_promiscuous(); g_shar_seeded = true; }
    (void)dmac;
#else
    if (g_macraw_active) {
        /* Mirror the Apple II's MAC onto the dongle (e.g. IP65's cfg_mac). */
        if (g_mac_valid && !g_dongle_mirrored) {
            w5100_bridge_set_dongle_mac(g_mac);
            g_dongle_mirrored = true;
        }
    } else if (!g_shar_seeded) {
        /* Preload SHAR with the dongle MAC so stacks that read their MAC from the
         * card adopt it (stacks that write their own SHAR are handled above). */
        fpga_spi_xfer_write(FPGA_SPACE_W5100, W5100_SHAR, dmac, 6);
        g_shar_seeded = true;
    }
#endif
}

static void macraw_send(int n)
{
    sock_t *s = &g_sock[n];
    uint16_t rd = w_rd16(W5100_S_BASE(n) + W5100_Sn_TX_RD);
    uint16_t wr = w_rd16(W5100_S_BASE(n) + W5100_Sn_TX_WR);
    uint16_t len = (uint16_t)(wr - rd);          /* bytes queued (mod 2^16) */

    if (len == 0 || len > W5100_MAX_FRAME) {
        /* nothing to do / bogus length: just resync the read pointer */
        w_wr16(W5100_S_BASE(n) + W5100_Sn_TX_RD, wr);
        w_wr16(W5100_S_BASE(n) + W5100_Sn_TX_FSR, s->tx_size);
        return;
    }

    /* Read the frame out of the TX ring (handle wrap) */
    uint16_t off = rd & s->tx_mask;
    uint16_t first = s->tx_size - off;
    if (first >= len) {
        fpga_spi_xfer_read(FPGA_SPACE_W5100, s->tx_base + off, g_frame, len);
    } else {
        fpga_spi_xfer_read(FPGA_SPACE_W5100, s->tx_base + off, g_frame, first);
        fpga_spi_xfer_read(FPGA_SPACE_W5100, s->tx_base, g_frame + first, len - first);
    }

    w5100_bridge_tx(g_frame, len);
    g_tx_frames++;

    /* Advance read pointer, refresh free size */
    w_wr16(W5100_S_BASE(n) + W5100_Sn_TX_RD, wr);
    w_wr16(W5100_S_BASE(n) + W5100_Sn_TX_FSR, s->tx_size);
}

/* RECV: the Apple II advanced Sn_RX_RD; recompute Sn_RX_RSR. */
static void macraw_recv(int n)
{
    sock_t *s = &g_sock[n];
    uint16_t rd = w_rd16(W5100_S_BASE(n) + W5100_Sn_RX_RD);
    uint16_t rsr = (uint16_t)(s->rx_wr - rd);
    w_wr16(W5100_S_BASE(n) + W5100_Sn_RX_RSR, rsr);
}

static void dispatch(int n, uint8_t cmd)
{
    switch (cmd) {
    case W5100_CR_OPEN: {
        uint8_t mr = w_rd8(W5100_S_BASE(n) + W5100_Sn_MR) & 0x0F;
        g_sock[n].mode = mr;
        if (mr == W5100_MR_MACRAW && n == 0) {
            macraw_open(n);
        } else {
            /* TCP/UDP/IPRAW hardware sockets: not in this phase. Park as CLOSED
             * so software sees a defined (if unhelpful) state. */
            g_sock[n].status = W5100_SOCK_CLOSED;
            w_wr8(W5100_S_BASE(n) + W5100_Sn_SR, W5100_SOCK_CLOSED);
        }
        break;
    }
    case W5100_CR_SEND:
        if (g_sock[n].status == W5100_SOCK_MACRAW) macraw_send(n);
        break;
    case W5100_CR_RECV:
        if (g_sock[n].status == W5100_SOCK_MACRAW) macraw_recv(n);
        break;
    case W5100_CR_CLOSE:
    case W5100_CR_DISCON:
        sock_close(n);
        break;
    default:
        break;
    }
}

/* ---- public API ---- */

/* True once the W5100 reset-default registers have been seeded AND a read-back
 * has confirmed they actually landed in the card's BSRAM. */
static bool g_defaults_seeded = false;

/* Seed the W5100 reset-default registers (RTR=0x07D0 etc.) so software probes
 * (IP65 reads RTR and expects 0x07D0) detect the card. Returns true once a
 * read-back confirms the write landed.
 *
 * Why this is in the poll loop and not w5100_init: SPACE-3 writes issued at the
 * very start of the W5100 task (right after the scheduler starts, while the
 * Apple II bus and card are still settling) do NOT land in BSRAM -- verified on
 * HW: a 0xA0 ramp written at init read back 0x00, while the identical write a
 * few hundred ms later round-trips fine. So we retry until a read-back confirms,
 * which is self-healing across that startup window. */
static bool w5100_seed_defaults(void)
{
    for (unsigned i = 0; i < sizeof(W5100_DEFAULTS) / sizeof(W5100_DEFAULTS[0]); i++)
        w_wr8(W5100_DEFAULTS[i].addr, W5100_DEFAULTS[i].val);

    fpga_spi_reg_write(FPGA_REG_U2_CMD_PENDING, 0x0F);  /* clear stale doorbell */

    /* Confirm RTR (0x0017) read-back == 0x07: the write actually reached BSRAM. */
    return w_rd8(0x0017) == 0x07;
}

void w5100_init(void)
{
    memset(g_sock, 0, sizeof(g_sock));
    g_macraw_active = false;
    g_macraw_mf = false;
    g_mac_valid = false;
    g_dongle_mirrored = false;
    g_shar_seeded = false;
    g_cmds = g_rx_frames = g_tx_frames = 0;
    memset(g_mac, 0, sizeof(g_mac));
    g_defaults_seeded = false;   /* actual seeding happens in w5100_poll */
}

/* Surface bridge state on the DebugOverlay (scratch regs 0x0C-0x0F, shown as hex
 * over HDMI). Leaves 0x07 (overlay byte0) alone -- the XInput/gamepad path uses
 * it. Overlay layout:
 *   byte1 (0x0C) = status: b0 macraw_active, b1 dongle_mirrored, b2 mac_valid,
 *                  b3 macraw_mf, b4 heartbeat, b7 defaults_seeded
 *   byte2 (0x0D) = g_rx_frames low byte (frames wire -> Apple II ring)
 *   byte3 (0x0E) = g_tx_frames low byte (frames Apple II -> wire)
 *   byte4 (0x0F) = g_drop_full low byte (RX frames dropped: MACRAW ring full) */
static void w5100_report(void)
{
    static uint8_t hb;
    hb ^= 1;

    uint8_t st = (g_macraw_active ? 0x01 : 0) | (g_dongle_mirrored ? 0x02 : 0) |
                 (g_mac_valid ? 0x04 : 0) | (g_macraw_mf ? 0x08 : 0) |
                 (hb ? 0x10 : 0) | (g_defaults_seeded ? 0x80 : 0);

    fpga_spi_reg_write(0x0C, st);
    fpga_spi_reg_write(0x0D, (uint8_t)g_rx_frames);
    fpga_spi_reg_write(0x0E, (uint8_t)g_tx_frames);
    fpga_spi_reg_write(0x0F, (uint8_t)g_drop_full);
}

void w5100_poll(void)
{
    /* Self-healing seed: retry the reset-default registers until a read-back
     * confirms they landed (early-startup SPACE-3 writes are dropped -- see
     * w5100_seed_defaults). Once confirmed, stop. */
    if (!g_defaults_seeded)
        g_defaults_seeded = w5100_seed_defaults();

    w5100_sync_mac();   /* keep dongle MAC == Apple II SHAR (runs every tick) */

    /* Throttle the DebugOverlay to ~2 Hz -- updating it every poll (~1 kHz) makes
     * the hex unreadable (human eyes can't track it). Command servicing below
     * still runs every tick. */
    static uint16_t rpt;
    if (++rpt >= 500) { rpt = 0; w5100_report(); }

    uint8_t pending = fpga_spi_reg_read(FPGA_REG_U2_CMD_PENDING) & 0x0F;
    if (!pending) return;

    for (int n = 0; n < W5100_NUM_SOCKETS; n++) {
        if (!(pending & (1 << n))) continue;
        uint8_t cmd = w_rd8(W5100_S_BASE(n) + W5100_Sn_CR);
        dispatch(n, cmd);
        g_cmds++;
        /* W5100 auto-clears Sn_CR once accepted */
        w_wr8(W5100_S_BASE(n) + W5100_Sn_CR, 0);
    }
    /* Clear the serviced doorbell bits (write-1-to-clear) */
    fpga_spi_reg_write(FPGA_REG_U2_CMD_PENDING, pending);
}

bool w5100_macraw_active(void)
{
    return g_macraw_active;
}

bool w5100_get_mac(uint8_t mac[6])
{
    if (!g_mac_valid) return false;
    memcpy(mac, g_mac, 6);
    return true;
}

void w5100_macraw_rx(const uint8_t *frame, uint32_t len)
{
    if (!g_macraw_active || len < 14 || len > W5100_MAX_FRAME) return;
    sock_t *s = &g_sock[0];

    /* MAC filter: accept broadcast/multicast (bit0 of first octet) or our MAC */
    if (g_macraw_mf && g_mac_valid) {
        bool mcast = (frame[0] & 0x01) != 0;             /* covers broadcast too */
        bool ours  = (memcmp(frame, g_mac, 6) == 0);
        if (!mcast && !ours) return;
    }

    /* W5100 MACRAW record = 2-byte length (frame + 2), big-endian, then frame */
    uint16_t rec = (uint16_t)(len + 2);

    /* Drop if it would not fit (leave room; never fill completely) */
    uint16_t used = (uint16_t)(s->rx_wr - w_rd16(W5100_S_BASE(0) + W5100_Sn_RX_RD));
    if ((uint32_t)used + rec >= s->rx_size) { g_drop_full++; return; }

    /* Build header + frame in scratch and write into the RX ring (handle wrap) */
    g_frame[0] = (uint8_t)(rec >> 8);
    g_frame[1] = (uint8_t)rec;
    memcpy(g_frame + 2, frame, len);
    uint16_t total = (uint16_t)(len + 2);

    uint16_t off = s->rx_wr & s->rx_mask;
    uint16_t first = s->rx_size - off;
    if (first >= total) {
        fpga_spi_xfer_write(FPGA_SPACE_W5100, s->rx_base + off, g_frame, total);
    } else {
        fpga_spi_xfer_write(FPGA_SPACE_W5100, s->rx_base + off, g_frame, first);
        fpga_spi_xfer_write(FPGA_SPACE_W5100, s->rx_base, g_frame + first, total - first);
    }

    s->rx_wr = (uint16_t)(s->rx_wr + total);
    g_rx_frames++;

    /* Publish received size for the Apple II (the W5100 has no host-visible
     * Sn_RX_WR; software polls Sn_RX_RSR and advances Sn_RX_RD). */
    uint16_t rd = w_rd16(W5100_S_BASE(0) + W5100_Sn_RX_RD);
    w_wr16(W5100_S_BASE(0) + W5100_Sn_RX_RSR, (uint16_t)(s->rx_wr - rd));
}
