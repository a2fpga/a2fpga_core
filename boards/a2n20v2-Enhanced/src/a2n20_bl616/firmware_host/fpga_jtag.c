/*
 * fpga_jtag.c — bit-banged JTAG to the GW2AR-18, host-firmware side.
 *
 * The FPGA's JTAG pins are plain BL616 GPIOs (io_cfg.h in ../firmware):
 * TMS=GPIO16, TCK=GPIO10, TDI=GPIO12, TDO=GPIO14. The device-mode build
 * drives them from USB MPSSE bytes; here we drive them from an internal
 * sequencer so the FPGA's external SPI config flash (W25Q64) can be
 * programmed with no PC attached.
 *
 * SPI-over-JTAG (Gowin UG290E §7.2.4, mirrored from openFPGALoader's
 * gowin.cpp): after IR 0x16 ("Program SPI Flash"), each Shift-DR burst is
 * one SPI transaction to the W25Q64 — CS frames the burst, TCK=SCLK,
 * TDI=MOSI, TDO=MISO. Quirks (both from openFPGALoader): the burst must
 * enter Shift-DR via EXIT2-DR (Capture-DR must not run between bytes of a
 * transaction), SPI wants MSB-first so bits are clocked out MSB-first
 * (equivalent to reversing bytes for an LSB-first JTAG shifter), and MISO
 * arrives one TCK late (sample k+1 carries bit k).
 */
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "bflb_gpio.h"
#include "usb_osal.h"
#include "fpga_spi.h"
#include "fpga_jtag.h"

/* Same registers/discipline as ../firmware/jtag_process.c: SET/CLEAR only,
 * never read-modify-write GPIO_CFG136 (RMW there breaks USB on BL616). */
#define JTAG_GPIO_SET (*(volatile uint32_t *)0x20000AEC)
#define JTAG_GPIO_CLR (*(volatile uint32_t *)0x20000AF4)
#define JTAG_GPIO_IN  (*(volatile uint32_t *)0x20000AC4)

#define TMS_BIT (1u << 16)
#define TCK_BIT (1u << 10)
#define TDI_BIT (1u << 12)
#define TDO_BIT (1u << 14)

/* Gowin GW2A JTAG instructions (UG290E table 7-2, 8-bit IR) */
#define GWIR_NOOP        0x02
#define GWIR_IDCODE      0x11
#define GWIR_CFG_ENABLE  0x15
#define GWIR_SPI_FLASH   0x16   /* JTAG pins -> SPI master to W25Q64 */
#define GWIR_CFG_DISABLE 0x3A
#define GWIR_RELOAD      0x3C   /* reconfigure from flash */
#define GWIR_BSCAN_SPI   0x3D

static bool s_pins_ready;

void fpga_jtag_init_pins(void)
{
    if (s_pins_ready)
        return;
    struct bflb_device_s *gpio = bflb_device_get_by_name("gpio");
    bflb_gpio_init(gpio, 16, GPIO_OUTPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_0); /* TMS */
    bflb_gpio_init(gpio, 10, GPIO_OUTPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_0); /* TCK */
    bflb_gpio_init(gpio, 12, GPIO_OUTPUT | GPIO_PULLUP | GPIO_SMT_EN | GPIO_DRV_0); /* TDI */
    bflb_gpio_init(gpio, 14, GPIO_INPUT | GPIO_PULLUP | GPIO_SMT_EN);               /* TDO */
    JTAG_GPIO_CLR = TMS_BIT | TCK_BIT | TDI_BIT;
    s_pins_ready = true;
}

/* One TCK cycle: present TMS/TDI, sample TDO just before the rising edge
 * (TDO changes on falling edges). The delays keep every phase of the TCK
 * waveform comfortably wide (~100+ ns): back-to-back MMIO writes alone
 * make a ~20-30 ns high pulse, marginal for the TAP's input path. */
static inline void jtag_dly(void)
{
    for (volatile int d = 0; d < 16; d++) { }
}

static inline int jtag_clk(int tms, int tdi)
{
    if (tms)
        JTAG_GPIO_SET = TMS_BIT;
    else
        JTAG_GPIO_CLR = TMS_BIT;
    if (tdi)
        JTAG_GPIO_SET = TDI_BIT;
    else
        JTAG_GPIO_CLR = TDI_BIT;
    jtag_dly();
    int tdo = (JTAG_GPIO_IN & TDO_BIT) ? 1 : 0;
    JTAG_GPIO_SET = TCK_BIT;
    jtag_dly();
    JTAG_GPIO_CLR = TCK_BIT;
    return tdo;
}

/* Test-Logic-Reset, then park in Run-Test/Idle. */
void fpga_jtag_reset(void)
{
    for (int i = 0; i < 6; i++)
        jtag_clk(1, 0);
    jtag_clk(0, 0);
}

/* Shift an 8-bit instruction (LSB first), end back in Run-Test/Idle. */
void fpga_jtag_ir(uint8_t code)
{
    jtag_clk(1, 0);                      /* RTI -> Select-DR   */
    jtag_clk(1, 0);                      /* -> Select-IR       */
    jtag_clk(0, 0);                      /* -> Capture-IR      */
    jtag_clk(0, 0);                      /* -> Shift-IR        */
    for (int i = 0; i < 8; i++)
        jtag_clk(i == 7, (code >> i) & 1);   /* TMS=1 on last -> Exit1 */
    jtag_clk(1, 0);                      /* -> Update-IR       */
    jtag_clk(0, 0);                      /* -> RTI             */
    /* Gowin commands execute during Run-Test/Idle clocks; openFPGALoader
     * follows every instruction with 6 of them (send_command). */
    for (int i = 0; i < 6; i++)
        jtag_clk(0, 0);
}

/* Read the 32-bit DR (LSB first) currently selected, from RTI. */
static uint32_t jtag_dr_read32(void)
{
    uint32_t v = 0;
    jtag_clk(1, 0);                      /* -> Select-DR  */
    jtag_clk(0, 0);                      /* -> Capture-DR */
    jtag_clk(0, 0);                      /* -> Shift-DR   */
    for (int i = 0; i < 32; i++)
        v |= (uint32_t)jtag_clk(i == 31, 0) << i;
    jtag_clk(1, 0);                      /* -> Update-DR  */
    jtag_clk(0, 0);                      /* -> RTI        */
    return v;
}

uint32_t fpga_jtag_idcode(void)
{
    fpga_jtag_reset();
    fpga_jtag_ir(GWIR_IDCODE);
    return jtag_dr_read32();
}

/* One SPI transaction in 0x16 mode, mirroring openFPGALoader's GW2A
 * spi_put exactly: send_command(0x16), enter Shift-DR via EXIT2-DR, shift
 * exactly 8*n clocks with TMS raised on the LAST data bit (a stray extra
 * SCLK edge would break page programming). MISO is delayed one clock, so
 * when reading, one extra dummy BYTE is shifted and rx byte i is rebuilt
 * from raw TDO samples 8i+1..8i+8. */
void fpga_jtag_spi_xfer(const uint8_t *tx, uint8_t *rx, uint32_t len)
{
    fpga_jtag_ir(GWIR_SPI_FLASH);

    jtag_clk(1, 0);                      /* RTI -> Select-DR */
    jtag_clk(0, 0);                      /* -> Capture-DR    */
    jtag_clk(1, 0);                      /* -> Exit1-DR      */
    jtag_clk(0, 0);                      /* -> Pause-DR      */
    jtag_clk(1, 0);                      /* -> Exit2-DR      */
    jtag_clk(0, 0);                      /* -> Shift-DR      */

    uint32_t nbytes = rx ? len + 1 : len;    /* dummy tail byte for reads */
    uint32_t nbits = nbytes * 8;
    for (uint32_t b = 0; b < nbits; b++) {
        uint32_t byi = b >> 3, bii = b & 7;
        int mosi = (tx && byi < len) ? (tx[byi] >> (7 - bii)) & 1 : 0;
        int tdo = jtag_clk(b == nbits - 1, mosi);   /* TMS=1 on last bit */
        if (rx && b > 0) {
            uint32_t rb = b - 1;         /* MISO bit rb arrives on clock rb+1 */
            if (rb < len * 8) {
                if (tdo)
                    rx[rb >> 3] |= 0x80u >> (rb & 7);
                else
                    rx[rb >> 3] &= ~(0x80u >> (rb & 7));
            }
        }
    }
    jtag_clk(1, 0);                      /* Exit1 -> Update-DR */
    jtag_clk(0, 0);                      /* -> RTI             */
}

/* Read n bytes of the W25Q64 starting at addr (SPI 0x03). */
void fpga_jtag_flash_read(uint32_t addr, uint8_t *dst, uint32_t n)
{
    uint8_t buf[4 + 64];
    while (n) {
        uint32_t chunk = n > 64 ? 64 : n;
        uint8_t tx[4 + 64];
        memset(tx, 0, sizeof(tx));
        tx[0] = 0x03;
        tx[1] = (addr >> 16) & 0xFF;
        tx[2] = (addr >> 8) & 0xFF;
        tx[3] = addr & 0xFF;
        fpga_jtag_spi_xfer(tx, buf, 4 + chunk);
        memcpy(dst, buf + 4, chunk);
        dst += chunk;
        addr += chunk;
        n -= chunk;
    }
}

/* Gowin status register (IR 0x41): 32-bit DR. */
#define GWSTAT_MEMORY_ERASE     (1u << 5)
#define GWSTAT_SYS_EDIT_MODE    (1u << 7)
#define GWSTAT_DONE_FINAL       (1u << 13)

uint32_t fpga_jtag_status(void)
{
    fpga_jtag_ir(0x41);
    uint32_t v = 0;
    jtag_clk(1, 0);
    jtag_clk(0, 0);
    jtag_clk(0, 0);
    for (int i = 0; i < 32; i++)
        v |= (uint32_t)jtag_clk(i == 31, 1) << i;
    jtag_clk(1, 0);
    jtag_clk(0, 0);
    return v;
}

static bool wait_status(uint32_t mask, uint32_t want, int loops)
{
    while (loops--) {
        if ((fpga_jtag_status() & mask) == want)
            return true;
    }
    return false;
}

/* openFPGALoader's GW2A prepare_flash_access: kill the fabric (the config
 * controller must own the die for flash access), then ConfigEnable + 0x3D.
 * The screen and Apple II die here — fpga_jtag_reload() brings them back. */
bool fpga_jtag_flash_enter(void)
{
    fpga_jtag_reset();
    /* eraseSRAM */
    fpga_jtag_ir(GWIR_CFG_ENABLE);
    if (!wait_status(GWSTAT_SYS_EDIT_MODE, GWSTAT_SYS_EDIT_MODE, 1000))
        return false;
    fpga_jtag_ir(0x05);                  /* ERASE_SRAM */
    fpga_jtag_ir(GWIR_NOOP);
    /* erase runs on RTI clocks; give it time and clocks */
    for (int i = 0; i < 4000; i++)
        jtag_clk(0, 0);
    usb_osal_msleep(20);
    wait_status(GWSTAT_MEMORY_ERASE, GWSTAT_MEMORY_ERASE, 1000);
    fpga_jtag_ir(0x09);                  /* XFER_DONE */
    fpga_jtag_ir(GWIR_NOOP);
    fpga_jtag_ir(GWIR_CFG_DISABLE);
    fpga_jtag_ir(GWIR_NOOP);
    if (fpga_jtag_status() & GWSTAT_DONE_FINAL)
        return false;                    /* fabric still configured */
    /* GW2A needs nothing further: 0x16 per transaction IS the SPI mode.
     * (ConfigEnable + 0x3D here is the NON-GW2A path in openFPGALoader —
     * sending it on a GW2A blocks 0x16 and MISO reads all-FF.) */
    return true;
}

/* Reconfigure from external flash (openFPGALoader post_flash_access +
 * reset): RELOAD + NOOP, then the device boots itself (~600 ms). */
void fpga_jtag_reload(void)
{
    fpga_jtag_ir(GWIR_RELOAD);
    fpga_jtag_ir(GWIR_NOOP);
    fpga_jtag_reset();
}
