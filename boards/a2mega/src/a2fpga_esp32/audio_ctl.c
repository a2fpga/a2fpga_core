/* audio_ctl.c — see audio_ctl.h. */
#include "audio_ctl.h"
#include "fpga_link.h"
#include "settings.h"
#include "osd_console.h"
#include "esp_log.h"

static const char *TAG = "audio_ctl";

int audio_mb_shift(void)
{
    uint8_t v = settings()->mb_volume;
    if (v == 0) return AUDIO_MB_SHIFT_DEFAULT;
    int sh = AUDIO_MB_SHIFT_MIN + (int)v - 1;
    if (sh < AUDIO_MB_SHIFT_MIN) sh = AUDIO_MB_SHIFT_MIN;
    if (sh > AUDIO_MB_SHIFT_MAX) sh = AUDIO_MB_SHIFT_MAX;
    return sh;
}

const char *audio_mb_label(void)
{
    static const char *const names[] = { "LOW", "MEDIUM", "HIGH", "MAX" };
    return names[audio_mb_shift() - AUDIO_MB_SHIFT_MIN];
}

void audio_ctl_apply(void)
{
    if (!fpga_link_ok()) return;
    int sh = audio_mb_shift();
    uint8_t ctl = (uint8_t)(AUDIO_CTL_MAILBOX | ((sh - AUDIO_MB_SHIFT_MIN) << 2));
    fpga_link_lock();
    fpga_reg_write(A2REG_GS_SEL, AUDIO_CTL_INDEX);
    fpga_reg_write(A2REG_GS_DATA, ctl);
    uint8_t rb = fpga_reg_read(A2REG_GS_DATA);
    fpga_link_unlock();
    if ((rb & 0x0D) == ctl)
        osd_log("AUDIO: MOCKINGBOARD << %d (%s)", sh, audio_mb_label());
    else
        ESP_LOGW(TAG, "audio ctl write %02X read back %02X (core without the window?)", ctl, rb);
}
