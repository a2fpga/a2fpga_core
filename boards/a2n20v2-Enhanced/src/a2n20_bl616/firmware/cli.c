/*
 * CLI — Ctrl-X Ctrl-C Enter break-in sequence on the UART USB interface.
 * When active, UART passthrough pauses and a simple command shell runs
 * on the USB UART endpoint (Interface 1, EP 0x83/0x04).
 */

#include <string.h>
#include <stdio.h>
#include "usbd_core.h"
#include "usbd_ftdi.h"
#include "uart_interface.h"
#include "bflb_mtimer.h"
#include "cli.h"
#include "fpga_spi.h"
#include "fpga_screen.h"
#include "ff.h"
#include "diskio.h"

#define CLI_CMD_BUF_SIZE 128
#define CLI_OUT_BUF_SIZE 512

#ifdef CONFIG_USB_HS
#define CLI_EP_MPS 512
#else
#define CLI_EP_MPS 64
#endif

/* Break-in state machine: 0x18 (Ctrl-X) → 0x03 (Ctrl-C) → 0x0D (Enter) */
#define BREAK_STATE_IDLE   0
#define BREAK_STATE_GOT_X  1
#define BREAK_STATE_GOT_C  2

static uint8_t break_state = BREAK_STATE_IDLE;
static bool active = false;

/* CLI command buffer */
static char cmd_buf[CLI_CMD_BUF_SIZE];
static uint32_t cmd_pos = 0;

/* CLI output buffer — written via cli_write, flushed to USB */
USB_NOCACHE_RAM_SECTION USB_MEM_ALIGNX static uint8_t cli_out_buf[CLI_OUT_BUF_SIZE];
static volatile bool cli_tx_busy = false;
static bool prompt_pending = false;

#define FW_VERSION "0.2"
#define FW_BUILD   __DATE__ " " __TIME__

static const char *banner =
    "\r\nA2N20 BL616 Firmware v" FW_VERSION " (" __DATE__ " " __TIME__ ")\r\n"
    "Type 'help' for commands.\r\n";

static const char *prompt = "a2n20> ";

static const char *help_text =
    "Commands:\r\n"
    "  help    - show this help\r\n"
    "  version - show firmware version and build timestamp\r\n"
    "  status  - show FPGA device ID, version, and status\r\n"
    "  hello   - display 'Hello from the MCU!' on Apple II screen\r\n"
    "  regs    - dump video control registers\r\n"
    "  dir     - list SD card root directory\r\n"
    "  spitest - stress test MCU<->FPGA SPI (10000 cycles)\r\n"
    "  sdtest  - read SD sector 0 ten times, compare checksums\r\n"
    "  quit    - exit CLI, resume UART passthrough\r\n";

void cli_write(const char *str)
{
    uint32_t len = strlen(str);
    if (len > CLI_OUT_BUF_SIZE - 2) len = CLI_OUT_BUF_SIZE - 2;

    /* Prepend FTDI status header */
    cli_out_buf[0] = FTDI_MODEM_STATUS_0;
    cli_out_buf[1] = FTDI_MODEM_STATUS_1;
    memcpy(&cli_out_buf[2], str, len);

    cli_tx_busy = true;
    usbd_ep_start_write(0, CDC_IN_EP, cli_out_buf, len + 2);

    /* Spin-wait for completion — CLI is interactive, latency matters more than throughput */
    uint32_t timeout = 1000000;
    while (cli_tx_busy && --timeout)
        ;
}

static void cli_enter(void)
{
    active = true;
    cmd_pos = 0;
    uart_pause();
    cli_write(banner);
    prompt_pending = true;
}

static void cli_exit(void)
{
    cli_write("\r\nResuming UART passthrough.\r\n");
    active = false;
    cmd_pos = 0;
    break_state = BREAK_STATE_IDLE;
    uart_resume();
}

/* --- FPGA command implementations --- */

static void cli_cmd_status(void)
{
    char buf[128];

    /* Device ID */
    uint8_t id[4];
    fpga_spi_read_device_id(id);
    snprintf(buf, sizeof(buf), "Device ID : %c%c%c%c\r\n", id[0], id[1], id[2], id[3]);
    cli_write(buf);

    /* Protocol version */
    uint8_t ver = fpga_spi_reg_read(0x04);
    snprintf(buf, sizeof(buf), "Proto Ver : 0x%02X\r\n", ver);
    cli_write(buf);

    /* Status register with decoded bits */
    uint8_t status = fpga_spi_read_status();
    snprintf(buf, sizeof(buf),
        "STATUS    : 0x%02X  FPGA=%d SDRAM=%d A2RST=%d WR=%d RD=%d\r\n",
        status,
        (status >> 7) & 1,
        (status >> 6) & 1,
        (status >> 5) & 1,
        (status >> 1) & 1,
        (status >> 0) & 1);
    cli_write(buf);

    /* System time (32-bit, regs 0x08-0x0B) */
    uint32_t sys_time = fpga_spi_reg_read(0x08)
                      | ((uint32_t)fpga_spi_reg_read(0x09) << 8)
                      | ((uint32_t)fpga_spi_reg_read(0x0A) << 16)
                      | ((uint32_t)fpga_spi_reg_read(0x0B) << 24);
    snprintf(buf, sizeof(buf), "SYS_TIME  : 0x%08lX\r\n", (unsigned long)sys_time);
    cli_write(buf);

    /* Scratch register loopback test: write pattern, read back, verify */
    int pass = 0, fail = 0;
    static const uint8_t patterns[] = {0xA5, 0x5A, 0xFF, 0x00, 0x0F, 0xF0};
    for (int i = 0; i < (int)(sizeof(patterns)/sizeof(patterns[0])); i++) {
        fpga_spi_reg_write(0x07, patterns[i]);
        uint8_t rb = fpga_spi_reg_read(0x07);
        if (rb == patterns[i]) pass++; else fail++;
    }
    snprintf(buf, sizeof(buf), "SPI Test  : %d/%d pass", pass, pass + fail);
    cli_write(buf);
    if (fail) {
        snprintf(buf, sizeof(buf), " (%d FAIL)\r\n", fail);
    } else {
        snprintf(buf, sizeof(buf), " OK\r\n");
    }
    cli_write(buf);
}

static void cli_cmd_hello(void)
{
    fpga_spi_reg_write(0x10, 1);  /* VIDEO_ENABLE */
    fpga_spi_reg_write(0x11, 1);  /* TEXT_MODE */
    fpga_screen_clear();
    fpga_screen_puts("Hello from the MCU!");
    cli_write("Displaying message for 3 seconds...\r\n");
    bflb_mtimer_delay_ms(3000);
    fpga_spi_reg_write(0x10, 0);  /* VIDEO_ENABLE=0 */
    cli_write("Done.\r\n");
}

static void cli_cmd_regs(void)
{
    static const char *reg_names[] = {
        "VIDEO_ENABLE", "TEXT_MODE", "MIXED_MODE", "HIRES_MODE",
        "PAGE2", "AN3", "STORE80", "COL80",
        "ALTCHAR", "SHRG_MODE"
    };
    char buf[64];

    cli_write("Video Control Registers:\r\n");
    for (int i = 0; i < 10; i++) {
        uint8_t val = fpga_spi_reg_read(0x10 + i);
        snprintf(buf, sizeof(buf), "  0x%02X %-14s = 0x%02X\r\n", 0x10 + i, reg_names[i], val);
        cli_write(buf);
    }
}

static void cli_cmd_spitest(void)
{
    static const uint8_t patterns[] = {0xA5, 0x5A, 0xFF, 0x00, 0x0F, 0xF0};
    int pass = 0, fail_wr = 0, fail_rd = 0;
    char buf[120];

    cli_write("MCU<->FPGA SPI stress test (10000 cycles)...\r\n");
    for (int i = 0; i < 10000; i++) {
        uint8_t p = patterns[i % 6];
        fpga_spi_reg_write(0x07, p);
        uint8_t rb1 = fpga_spi_reg_read(0x07);
        if (rb1 == p) {
            pass++;
        } else {
            /* Re-read to distinguish write error from read error */
            uint8_t rb2 = fpga_spi_reg_read(0x07);
            if (rb2 == p) {
                /* Register has correct value — first read was corrupted */
                fail_rd++;
                if (fail_rd + fail_wr <= 8) {
                    snprintf(buf, sizeof(buf),
                        "  RD_ERR #%d: wrote 0x%02X, read1=0x%02X read2=0x%02X\r\n",
                        i, p, rb1, rb2);
                    cli_write(buf);
                }
            } else {
                /* Register has wrong value — write was lost or corrupted */
                fail_wr++;
                if (fail_rd + fail_wr <= 8) {
                    snprintf(buf, sizeof(buf),
                        "  WR_ERR #%d: wrote 0x%02X, read1=0x%02X read2=0x%02X\r\n",
                        i, p, rb1, rb2);
                    cli_write(buf);
                }
            }
        }
    }
    int total_fail = fail_wr + fail_rd;
    snprintf(buf, sizeof(buf), "Result: %d/10000 pass", pass);
    cli_write(buf);
    if (total_fail) {
        snprintf(buf, sizeof(buf), " (%d FAIL: %d write, %d read)\r\n",
                 total_fail, fail_wr, fail_rd);
    } else {
        snprintf(buf, sizeof(buf), " OK\r\n");
    }
    cli_write(buf);
}

static void cli_cmd_sdtest(void)
{
    char buf[128];
    BYTE sect[512];
    uint32_t checksums[10];
    int init_pass = 0, init_fail = 0;

    cli_write("SD sector 0 read test (10 rounds)...\r\n");
    for (int round = 0; round < 10; round++) {
        /* Full init each round */
        DSTATUS st = disk_initialize(0);
        if (st) {
            snprintf(buf, sizeof(buf), "  Round %d: init FAIL (0x%02X)\r\n", round, st);
            cli_write(buf);
            init_fail++;
            checksums[round] = 0xDEAD;
            continue;
        }
        init_pass++;

        DRESULT dr = disk_read(0, sect, 0, 1);
        if (dr != RES_OK) {
            snprintf(buf, sizeof(buf), "  Round %d: read FAIL (%d)\r\n", round, dr);
            cli_write(buf);
            checksums[round] = 0xBEEF;
            continue;
        }

        /* Simple checksum */
        uint32_t sum = 0;
        for (int j = 0; j < 512; j++) sum += sect[j];
        checksums[round] = sum;

        snprintf(buf, sizeof(buf), "  Round %d: sig=%02X%02X sum=0x%08lX\r\n",
                 round, sect[510], sect[511], (unsigned long)sum);
        cli_write(buf);
    }

    /* Summary */
    int match = 0;
    for (int i = 1; i < 10; i++) {
        if (checksums[i] == checksums[0]) match++;
    }
    snprintf(buf, sizeof(buf), "Init: %d/10 pass. Reads matching round 0: %d/9\r\n",
             init_pass, match);
    cli_write(buf);
}

static void cli_cmd_dir(void)
{
    FATFS fs;
    DIR dir;
    FILINFO fno;
    FRESULT res;
    char buf[128];
    int nfiles = 0;

    res = f_mount(&fs, "", 1);
    if (res != FR_OK) {
        snprintf(buf, sizeof(buf), "Mount failed (err %d). No SD card?\r\n", res);
        cli_write(buf);
        return;
    }

    res = f_opendir(&dir, "/");
    if (res != FR_OK) {
        snprintf(buf, sizeof(buf), "Open root dir failed (err %d)\r\n", res);
        cli_write(buf);
        f_mount(NULL, "", 0);
        return;
    }

    cli_write("Directory of /\r\n\r\n");

    for (;;) {
        res = f_readdir(&dir, &fno);
        if (res != FR_OK || fno.fname[0] == 0) break;

        if (fno.fattrib & AM_DIR) {
            snprintf(buf, sizeof(buf), "  <DIR>  %s\r\n", fno.fname);
        } else {
            snprintf(buf, sizeof(buf), "  %7lu  %s\r\n", (unsigned long)fno.fsize, fno.fname);
        }
        cli_write(buf);
        nfiles++;
    }

    f_closedir(&dir);

    snprintf(buf, sizeof(buf), "\r\n%d file(s)\r\n", nfiles);
    cli_write(buf);

    f_mount(NULL, "", 0);
}

static void cli_execute(void)
{
    cmd_buf[cmd_pos] = '\0';

    /* Trim leading/trailing whitespace */
    char *cmd = cmd_buf;
    while (*cmd == ' ') cmd++;
    uint32_t len = strlen(cmd);
    while (len > 0 && cmd[len - 1] == ' ') cmd[--len] = '\0';

    if (len == 0) {
        /* Empty command — just show prompt again */
    } else if (strcmp(cmd, "help") == 0) {
        cli_write(help_text);
    } else if (strcmp(cmd, "version") == 0) {
        cli_write("A2N20 BL616 Firmware v" FW_VERSION "\r\n"
                  "Build: " FW_BUILD "\r\n");
    } else if (strcmp(cmd, "status") == 0) {
        cli_cmd_status();
    } else if (strcmp(cmd, "hello") == 0) {
        cli_cmd_hello();
    } else if (strcmp(cmd, "regs") == 0) {
        cli_cmd_regs();
    } else if (strcmp(cmd, "dir") == 0 || strcmp(cmd, "ls") == 0) {
        cli_cmd_dir();
    } else if (strcmp(cmd, "spitest") == 0) {
        cli_cmd_spitest();
    } else if (strcmp(cmd, "sdtest") == 0) {
        cli_cmd_sdtest();
    } else if (strcmp(cmd, "quit") == 0 || strcmp(cmd, "exit") == 0) {
        cli_exit();
        return;
    } else {
        cli_write("Unknown command: ");
        cli_write(cmd);
        cli_write("\r\n");
    }

    cmd_pos = 0;
    prompt_pending = true;
}

void cli_feed(uint8_t byte)
{
    if (active) return;

    switch (break_state) {
    case BREAK_STATE_IDLE:
        if (byte == 0x18) /* Ctrl-X */
            break_state = BREAK_STATE_GOT_X;
        break;
    case BREAK_STATE_GOT_X:
        if (byte == 0x03) /* Ctrl-C */
            break_state = BREAK_STATE_GOT_C;
        else
            break_state = BREAK_STATE_IDLE;
        break;
    case BREAK_STATE_GOT_C:
        if (byte == 0x0D) { /* Enter */
            cli_enter();
        }
        break_state = BREAK_STATE_IDLE;
        break;
    }
}

bool cli_is_active(void)
{
    return active;
}

void cli_notify_in_complete(void)
{
    cli_tx_busy = false;
}

void cli_process(void)
{
    if (!active) return;

    if (prompt_pending && !cli_tx_busy) {
        cli_write(prompt);
        prompt_pending = false;
    }

    /* Read from USB OUT endpoint buffer */
    uint8_t tmp[64];
    uint32_t nbytes = uart_get_usb_out_data(tmp, sizeof(tmp));

    for (uint32_t i = 0; i < nbytes; i++) {
        uint8_t ch = tmp[i];

        if (ch == '\r' || ch == '\n') {
            cli_write("\r\n");
            cli_execute();
            return;
        } else if (ch == 0x7F || ch == 0x08) {
            /* Backspace */
            if (cmd_pos > 0) {
                cmd_pos--;
                cli_write("\b \b");
            }
        } else if (ch >= 0x20 && ch < 0x7F) {
            if (cmd_pos < CLI_CMD_BUF_SIZE - 1) {
                cmd_buf[cmd_pos++] = ch;
                /* Echo character */
                char echo[2] = {ch, 0};
                cli_write(echo);
            }
        }
    }
}
