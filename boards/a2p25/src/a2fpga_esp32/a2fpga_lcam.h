#ifndef A2FPGA_LCAM_H
#define A2FPGA_LCAM_H

#include <Arduino.h>
#include "esp_err.h"

// External constants (defined in main .ino file)
extern const int PIN_CAM_PCLK;
extern const int PIN_CAM_VSYNC;
extern const int PIN_CAM_D0;
extern const int PIN_CAM_D1;
extern const int PIN_CAM_D2;
extern const int PIN_CAM_D3;

// Build-time options (defined in main .ino file)
extern const uint32_t SMOKE_MS;

// Function declarations
void lcam_start();
void lcam_stop();
void lcam_log_every_n_words(uint32_t n);
void lcam_print_status();
void lcam_set_logging(uint8_t n);
void lcam_set_log_every(uint32_t n);
void lcam_set_log_rate_ms(uint32_t ms);

// Debug/stats functions
uint32_t lcam_get_words_seen();
uint32_t lcam_get_ring_drops();
uint32_t lcam_get_words_captured();
void lcam_reset_stats();

// Capture configuration
// - VSYNC EOF mode: when true, LCD_CAM generates EOF on VSYNC (requires gated VSYNC in FPGA).
//   When false, LCD_CAM uses length-based EOF every N bytes (preferred for high-rate bursts).
void lcam_set_vsync_eof(bool enable);
bool lcam_get_vsync_eof();
int  lcam_get_current_offset();
void lcam_debug_burst(uint32_t count);

// Expected address window used by the stream alignment heuristic. The parser
// scores 10-byte phase candidates by how many addresses fall inside this range.
// Defaults to [$C000..$C0FF] to include ES5503 and heartbeat test packets.
void lcam_set_addr_window(uint16_t min_addr, uint16_t max_addr);
void lcam_get_addr_window(uint16_t* min_addr, uint16_t* max_addr);

// Task management functions
esp_err_t lcam_init_tasks();
void lcam_cleanup_tasks();

#endif // A2FPGA_LCAM_H
