/*
 * w5100.h -- Emulated WIZnet W5100 core for the A2FPGA Uthernet II card.
 *
 * The FPGA Uthernet2 card (hdl/uthernet2/uthernet2.sv) holds the W5100 register
 * and buffer space in BSRAM and serves the Apple II at bus speed. This module is
 * the "engine": it reads/writes that backing store over the SPI connector's
 * memory SPACE 3, watches the per-socket command doorbell (FPGA reg 0x7A), and
 * implements W5100 behavior on the BL616.
 *
 * Phase 2/3 scope: MACRAW on socket 0, bridged to the USB-Ethernet adapter
 * (the Apple II runs its own stack -- IP65, etc. -- and appears on the LAN with
 * its own MAC/IP). TCP/UDP hardware-socket modes are a later phase.
 */

#ifndef _W5100_H
#define _W5100_H

#include <stdbool.h>
#include <stdint.h>

/* MCU firmware build marker -- shown on fpga_screen at boot (with __DATE__/__TIME__)
 * so the running image can be confirmed, paralleling the FPGA version string. */
#define MCU_BUILD_STR "u2"

/* RX path: by default the Apple II's SHAR is mirrored onto the dongle's hardware
 * MAC (r8152_write_hwaddr) so its hardware filter delivers only unicast-to-us +
 * broadcast (what a real Uthernet II sees), NOT all LAN traffic. Define
 * W5100_BRIDGE_FORCE_PROMISC to use promiscuous instead -- a fallback only: it
 * floods the small MACRAW ring faster than the ~1 MHz Apple II can drain it. */

/* ---- W5100 address map (natural addresses; the card compresses to BSRAM) ---- */
#define W5100_MR        0x0000  /* Mode Register */
#define W5100_GAR       0x0001  /* Gateway IP (4) */
#define W5100_SUBR      0x0005  /* Subnet mask (4) */
#define W5100_SHAR      0x0009  /* Source MAC (6) */
#define W5100_SIPR      0x000F  /* Source IP (4) */
#define W5100_RMSR      0x001A  /* RX memory size register */
#define W5100_TMSR      0x001B  /* TX memory size register */

#define W5100_TX_BASE   0x4000  /* TX buffer base (8 KB: 0x4000-0x5FFF) */
#define W5100_RX_BASE   0x6000  /* RX buffer base (8 KB: 0x6000-0x7FFF) */
#define W5100_MEM_END   0x8000

/* Mode Register bits */
#define W5100_MR_AI     0x02    /* address auto-increment */
#define W5100_MR_IND    0x01    /* indirect bus mode */
#define W5100_MR_RST    0x80    /* software reset */

/* ---- Per-socket registers (socket n base = 0x0400 + n*0x100) ---- */
#define W5100_S_BASE(n) (0x0400 + ((n) * 0x0100))
#define W5100_Sn_MR     0x00    /* socket mode */
#define W5100_Sn_CR     0x01    /* socket command */
#define W5100_Sn_IR     0x02    /* socket interrupt */
#define W5100_Sn_SR     0x03    /* socket status */
#define W5100_Sn_PORT   0x04    /* source port (2) */
#define W5100_Sn_DHAR   0x06    /* dest MAC (6) */
#define W5100_Sn_DIPR   0x0C    /* dest IP (4) */
#define W5100_Sn_DPORT  0x10    /* dest port (2) */
#define W5100_Sn_PROTO  0x14    /* IP protocol (IPRAW) */
#define W5100_Sn_TOS    0x15
#define W5100_Sn_TTL    0x16
#define W5100_Sn_TX_FSR 0x20    /* TX free size (2) */
#define W5100_Sn_TX_RD  0x22    /* TX read pointer (2) */
#define W5100_Sn_TX_WR  0x24    /* TX write pointer (2) */
#define W5100_Sn_RX_RSR 0x26    /* RX received size (2) */
#define W5100_Sn_RX_RD  0x28    /* RX read pointer (2) */

/* Socket mode (Sn_MR) protocol field */
#define W5100_MR_CLOSE  0x00
#define W5100_MR_TCP    0x01
#define W5100_MR_UDP    0x02
#define W5100_MR_IPRAW  0x03
#define W5100_MR_MACRAW 0x04
#define W5100_MR_MF     0x40    /* MAC filter (MACRAW) */

/* Socket command (Sn_CR) */
#define W5100_CR_OPEN   0x01
#define W5100_CR_LISTEN 0x02
#define W5100_CR_CONNECT 0x04
#define W5100_CR_DISCON 0x08
#define W5100_CR_CLOSE  0x10
#define W5100_CR_SEND   0x20
#define W5100_CR_RECV   0x40

/* Socket status (Sn_SR) */
#define W5100_SOCK_CLOSED   0x00
#define W5100_SOCK_INIT     0x13
#define W5100_SOCK_ESTABLISHED 0x17
#define W5100_SOCK_UDP      0x22
#define W5100_SOCK_IPRAW    0x32
#define W5100_SOCK_MACRAW   0x42

#define W5100_NUM_SOCKETS   4
#define W5100_MAX_FRAME     1518   /* max Ethernet frame the bridge moves */

/* ---- public API ---- */

/* Initialize emulation state (call once after the FPGA is ready). */
void w5100_init(void);

/* Poll the command doorbell (FPGA reg 0x7A) and service pending commands.
 * Call from the W5100 task loop. */
void w5100_poll(void);

/* True once a MACRAW socket is open (bridge active). Used by the RX path to
 * decide whether to deliver wire frames to the card. */
bool w5100_macraw_active(void);

/* Deliver one received Ethernet frame (from the USB-Ethernet RX hook) to the
 * open MACRAW socket's RX ring. Applies the W5100 MAC filter when enabled.
 * No-op if MACRAW is not active. */
void w5100_macraw_rx(const uint8_t *frame, uint32_t len);

/* Copy the Apple II's configured MAC (SHAR) into mac[6]. Returns false if not
 * yet set (all zero). */
bool w5100_get_mac(uint8_t mac[6]);

/* ---- bridge hooks (implemented weak in w5100.c, overridden in main.c) ----
 * MAC strategy: make the dongle's MAC equal the Apple II's SHAR so the dongle's
 * hardware filter accepts the Apple II's frames (no promiscuous, no per-packet
 * work). w5100.c orchestrates; main.c provides these primitives. */

/* Transmit one Ethernet frame verbatim on the USB-Ethernet adapter. */
void w5100_bridge_tx(const uint8_t *frame, uint32_t len);

/* Get the USB-Ethernet dongle's hardware MAC into mac[6]. Returns false if no
 * adapter is connected/enumerated yet (MAC not known). */
bool w5100_bridge_dongle_mac(uint8_t mac[6]);

/* Program the dongle's hardware MAC = mac[6] (so its filter passes the Apple II's
 * frames). Primary path. */
void w5100_bridge_set_dongle_mac(const uint8_t mac[6]);

/* Fallback: put the dongle in promiscuous mode (accept all frames). Used only
 * when built with W5100_BRIDGE_FORCE_PROMISC. */
void w5100_bridge_set_promiscuous(void);

#endif /* _W5100_H */
