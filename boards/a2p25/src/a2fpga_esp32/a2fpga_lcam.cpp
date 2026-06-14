#include "a2fpga_lcam.h"
// Forward declaration for bus packet processing
extern void process_bus_packet(uint32_t packet);
#include "driver/gpio.h"
#include "driver/periph_ctrl.h"
#include "esp_heap_caps.h"
#include "esp_rom_gpio.h"
#include "esp_timer.h"
#include "soc/gpio_sig_map.h"
#include "soc/lcd_cam_struct.h"
#include "soc/lcd_cam_reg.h"
#include "soc/gdma_struct.h"
#include "soc/gdma_reg.h"

// -----------------------------------------------------------------------------
// High-speed LCD_CAM capture strategy for Apple II bus packets
//
// Summary:
// - Capture 4-bit packet stream (10 nibbles/packet) via LCD_CAM in 8-bit mode
//   using GDMA circular descriptors.
// - Avoid per-packet VSYNC→EOF (which causes ~1.35M EOFs/s) by default; instead
//   use length-based EOF every CHUNK_BYTES bytes (4 KB) to keep EOF rate low and
//   prevent AFIFO/GDMA thrash during bursts.
// - Because EOF no longer equals packet boundary, implement a fast per-buffer
//   stream alignment detector that identifies the correct 10-byte phase by
//   scoring candidate offsets against an expected address window.
// - Parsed 32-bit words are enqueued in a lock-free ring for downstream use.
//
// Optional:
// - VSYNC→EOF can be enabled at runtime for diagnostics, but requires gating
//   VSYNC in FPGA (e.g., every ~400 packets) to avoid reintroducing packet loss.
// -----------------------------------------------------------------------------

// ---------- Packet / DMA sizing ----------
static const int BYTES_PER_WORD   = 8;   // 8 data nibbles => 8 bytes (low nibble used)
static const int STOP_BYTES       = 2;   // VSYNC + stopper
static const int PACK_BYTES       = BYTES_PER_WORD + STOP_BYTES;  // 10 total
// Increase DMA chunk size and descriptor ring to reduce EOF churn
// Note: GDMA descriptor length fields are 12-bit (max 4095).
// Choose a multiple of 10 to align with packet length (10 bytes/packet) and avoid
// systematic loss at descriptor boundaries. 4090 fits within the 12-bit limit.
static const int CHUNK_BYTES      = 4090; // 409 packets per buffer (exact)
static const int DESC_COUNT       = 8;    // Larger ring for continuous capture
// Use GDMA channel 2 to avoid conflicts with other peripherals (e.g., I2S)
#define GDMA_CH                  2

// ---------- CAM signal macro compatibility ----------
#ifndef CAM_PCLK_IDX
#  ifdef CAM_PCLK_IN_IDX
#    define CAM_PCLK_IDX CAM_PCLK_IN_IDX
#  else
#    error "CAM_PCLK_IDX / CAM_PCLK_IN_IDX not defined by this Arduino core."
#  endif
#endif
#ifndef CAM_V_SYNC_IDX
#  ifdef CAM_V_SYNC_IN_IDX
#    define CAM_V_SYNC_IDX CAM_V_SYNC_IN_IDX
#  else
#    error "CAM_V_SYNC_IDX / CAM_V_SYNC_IN_IDX not defined by this Arduino core."
#  endif
#endif
#ifndef CAM_H_ENABLE_IDX
#  ifdef CAM_H_ENABLE_IN_IDX
#    define CAM_H_ENABLE_IDX CAM_H_ENABLE_IN_IDX
#  endif
#endif
#ifndef CAM_DATA_IN0_IDX
#  error "CAM_DATA_IN0_IDX..CAM_DATA_IN3_IDX not defined (S3 camera signals missing?)."
#endif
#ifndef GPIO_MATRIX_CONST_ONE_INPUT
#  define GPIO_MATRIX_CONST_ONE_INPUT  0x38
#endif

// ---------- Runtime capture configuration ----------
// Default to VSYNC→EOF for compatibility with gated VSYNC in FPGA.
static volatile bool     s_use_vsync_eof = true;   // true: VSYNC→EOF (default); false: length-EOF
static volatile uint16_t s_addr_min = 0xC000;      // alignment scoring window (min)
static volatile uint16_t s_addr_max = 0xC0FF;      // alignment scoring window (max)

// ---------- DMA descriptor compatibility ----------
#if __has_include("hal/dma_types.h")
  #include "hal/dma_types.h"
  typedef dma_descriptor_t DESC_T;
  static inline void      desc_set_buf(DESC_T* d, uint8_t* buf){ d->buffer = buf; }
  static inline uint8_t*  desc_get_buf(DESC_T* d){ return (uint8_t*)d->buffer; }
  static inline void      desc_set_next(DESC_T* d, DESC_T* n){ d->next = n; }
  static inline void      desc_prep(DESC_T* d, uint8_t* buf, size_t len, DESC_T* next){
    memset(d, 0, sizeof(*d));
    d->buffer = buf;
    d->dw0.size = len;
    d->dw0.length = len;
    d->dw0.owner = 1;
    d->dw0.suc_eof = 0;
    d->next = next;
  }
  static inline void      desc_rearm(DESC_T* d){ d->dw0.owner = 1; d->dw0.suc_eof = 0; }
  static inline uint32_t  desc_len(DESC_T* d){ return d->dw0.length; }
#else
  typedef struct {
    volatile uint32_t size    :12;
    volatile uint32_t length  :12;
    volatile uint32_t suc_eof :1;
    volatile uint32_t owner   :1;
    volatile uint32_t rsvd    :6;
    void*    buffer;
    void*    next;
  } DESC_T;
  static inline void      desc_set_buf(DESC_T* d, uint8_t* buf){ d->buffer = buf; }
  static inline uint8_t*  desc_get_buf(DESC_T* d){ return (uint8_t*)d->buffer; }
  static inline void      desc_set_next(DESC_T* d, DESC_T* n){ d->next = n; }
  static inline void      desc_prep(DESC_T* d, uint8_t* buf, size_t len, DESC_T* next){
    memset(d, 0, sizeof(*d));
    d->buffer = buf;
    d->size = len;
    d->length = len;
    d->owner = 1;
    d->suc_eof = 0;
    d->next = next;
  }
  static inline void      desc_rearm(DESC_T* d){ d->owner = 1; d->suc_eof = 0; }
  static inline uint32_t  desc_len(DESC_T* d){ return d->length; }
#endif

// ---------- Large Buffer Processing ----------
// Process enough packets to drain a full buffer in one go
static const uint32_t BATCH_PROCESS_SIZE = 1024;  // Max packets to process per batch

// Streaming alignment: in length-EOF mode, buffers may start at any nibble in the
// 10-nibble packet cycle. We auto-detect the offset that yields valid addresses.
static int s_stream_offset_mod10 = -1;  // -1 = unknown; else 0..9 where data nibble 0 starts
static uint8_t s_tail_bytes[9];          // last up to 9 bytes from previous buffer
static uint8_t s_tail_len = 0;

static inline uint32_t pack_word_from_8(const uint8_t* p) {
  // Fast pack of 8 low-nibble bytes into a 32-bit LSN-first word
  return  (p[0] & 0x0F) |
         ((uint32_t)(p[1] & 0x0F) << 4) |
         ((uint32_t)(p[2] & 0x0F) << 8) |
         ((uint32_t)(p[3] & 0x0F) << 12) |
         ((uint32_t)(p[4] & 0x0F) << 16) |
         ((uint32_t)(p[5] & 0x0F) << 20) |
         ((uint32_t)(p[6] & 0x0F) << 24) |
         ((uint32_t)(p[7] & 0x0F) << 28);
}

static inline bool addr_is_plausible_es5503(uint16_t addr) {
  // Expected address window (configurable). Defaults cover $C03C-$C03F and $C0FF heartbeat.
  uint16_t minv = s_addr_min, maxv = s_addr_max;
  return (addr >= minv && addr <= maxv);
}

static int detect_stream_offset(const uint8_t* buf, uint32_t len) {
  // Try all 10 possible offsets; score by how many plausible addresses in a small window
  const uint32_t window_bytes = (len < 800) ? len : 800; // ~80 packets window
  int best_off = 0; int best_score = -1;
  for (int off = 0; off < 10; ++off) {
    int score = 0;
    // walk in 10-byte strides, reading 8 bytes of data starting at 'off'
    for (uint32_t pos = off; pos + 7 < window_bytes; pos += 10) {
      uint32_t w = pack_word_from_8(buf + pos);
      uint16_t a = (w >> 16) & 0xFFFF;
      if (addr_is_plausible_es5503(a)) score++;
    }
    if (score > best_score) { best_score = score; best_off = off; }
  }
  // Heuristic: require some minimum confidence (at least 50% of samples plausible)
  int max_samples = (int)(window_bytes / 10);
  if (best_score >= (max_samples / 2)) return best_off;
  return best_off; // still return best guess; consumer will adapt next buffer
}
static const uint32_t BUFFER_TIMEOUT_US = 1000; // Timeout for partial buffers (1ms)

// ---------- Lock-free SPSC ring (for processed packets) ----------
static const uint32_t RB_SIZE = 4096;      // power of two (was 1024, increased for game bus traffic)
static uint32_t       rb_data[RB_SIZE];
static volatile uint32_t rb_head = 0;      // producer writes
static volatile uint32_t rb_tail = 0;      // consumer writes
static volatile uint32_t rb_drops = 0;

static inline bool rb_push(uint32_t w) {
  uint32_t h = rb_head;
  uint32_t n = (h + 1) & (RB_SIZE - 1);
  if (n == rb_tail) { rb_drops++; return false; }
  rb_data[h] = w;
  rb_head = n;
  return true;
}
static inline bool rb_pop(uint32_t* out) {
  uint32_t t = rb_tail;
  if (t == rb_head) return false;
  *out = rb_data[t];
  rb_tail = (t + 1) & (RB_SIZE - 1);
  return true;
}
static inline void rb_reset(){ rb_head = rb_tail = 0; rb_drops = 0; }

// ---------- Buffer State Management ----------
static volatile uint32_t s_current_buffer = 0;  // Which buffer is currently being filled
static volatile bool s_buffer_ready[DESC_COUNT] = {false, false, false}; // Which buffers are ready to process
static volatile uint32_t s_buffer_timeout_start[DESC_COUNT] = {0, 0, 0}; // Timeout tracking per buffer

// ---------- Runtime state ----------
static uint8_t  s_clk_inv = 0;            // 0=rising, 1=falling
static uint32_t word_print_every = 512;
static volatile uint32_t words_seen = 0;   // bumped by consumer (non-heartbeat only)
static volatile uint32_t words_captured = 0; // total words captured by LCD_CAM (including heartbeat)
// Default to safe, low-noise logging: level 1 with throttling
static volatile uint8_t s_log_level = 1;   // 0=off, 1=changes/periodic, 2=every buffer
static volatile uint32_t s_buf_seq = 0;    // processed buffer sequence number
static volatile int      s_last_logged_off = -2; // for change-detection logging
static volatile uint32_t s_log_every_buffers = 200; // periodic log cadence when level>=1
static volatile uint32_t s_log_min_interval_us = 1000000; // min time between logs (except burst)
static volatile uint64_t s_last_log_us = 0; // last emitted log time
// Additional idle suppression: heartbeat-only buffers are logged at most every N ms
static volatile uint32_t s_log_idle_interval_us = 5000000; // 5s for heartbeat-only logs
static volatile uint64_t s_last_idle_log_us = 0;
static volatile uint32_t s_debug_burst_remaining = 0; // if >0, log every buffer and decrement

static uint8_t* s_buf      = nullptr;     // DESC_COUNT * CHUNK_BYTES
static DESC_T*  s_desc     = nullptr;     // [DESC_COUNT], 16-byte aligned

static TaskHandle_t s_poller_task   = nullptr;
static TaskHandle_t s_consumer_task = nullptr;
static esp_timer_handle_t s_timeout_timer = nullptr;
static volatile uint32_t s_last_capture_time_us = 0;

// Runtime configuration

// ---------- Helpers ----------
static inline void route_in(int gpio, int sig_idx, bool inv=false) {
  esp_rom_gpio_connect_in_signal(gpio, sig_idx, inv);
}
static inline void route_const_one_to(int sig_idx) {
#ifdef CAM_H_ENABLE_IDX
  esp_rom_gpio_connect_in_signal(GPIO_MATRIX_CONST_ONE_INPUT, sig_idx, false);
#endif
}
static inline bool dma_eof() { return GDMA.channel[GDMA_CH].in.int_st.in_suc_eof; }
static inline void dma_ack_eof() { GDMA.channel[GDMA_CH].in.int_clr.in_suc_eof = 1; }
static inline volatile DESC_T* dma_eof_desc() { return (volatile DESC_T*)GDMA.channel[GDMA_CH].in.suc_eof_des_addr; }

static inline uint32_t pack_word_lsn_first(const uint8_t *b) {
  uint32_t w = 0;
  for (int i = 0; i < BYTES_PER_WORD; ++i) {
    uint8_t nib = b[i] & 0x0F;
    w |= ((uint32_t)nib) << (4*i);
  }
  return w;
}

// ---------- Large Buffer Batch Processing ---------- 
static void process_large_buffer(uint8_t* buffer, uint32_t buffer_length) {
  uint32_t processed_count = 0;
  
  // Detect the 10-byte phase at start of each buffer.
  // Note: Even in VSYNC-EOF mode, LCD_CAM EOF is asserted on VSYNC (nibble 8),
  // so the next buffer typically begins at nibble 9, not data nibble 0.
  // Therefore, run alignment detection for both modes. Only stitch/save tail in LEN-EOF.
  int off = s_stream_offset_mod10;
  {
    int new_off = detect_stream_offset(buffer, buffer_length);
    off = new_off;
    s_stream_offset_mod10 = off;
  }

  // Cross-boundary stitch (LEN-EOF only)
  if (!s_use_vsync_eof) {
    if (off != 0 && s_tail_len > 0 && processed_count < BATCH_PROCESS_SIZE) {
      uint8_t tail_bytes = (uint8_t)min(8, 10 - off);
      uint8_t head_bytes = (uint8_t)(8 - tail_bytes);
      if (s_tail_len >= tail_bytes && buffer_length >= head_bytes) {
        uint8_t tmp[8];
        if (tail_bytes > 0) memcpy(tmp, &s_tail_bytes[s_tail_len - tail_bytes], tail_bytes);
        if (head_bytes > 0) memcpy(tmp + tail_bytes, buffer, head_bytes);
        uint32_t w = pack_word_from_8(tmp);
        if (rb_push(w)) {
          uint16_t address = (w >> 16) & 0xFFFF;
          if (address != 0xC0FF) words_seen++;
          processed_count++;
        }
      }
    }
  }

  // Walk the buffer using the chosen alignment
  for (uint32_t pos = (uint32_t)off; pos + BYTES_PER_WORD <= buffer_length && processed_count < BATCH_PROCESS_SIZE; pos += 10) {
    const uint8_t* p = buffer + pos;
    uint32_t w = pack_word_from_8(p);

    // Push to ring buffer
    if (rb_push(w)) {
      uint16_t address = (w >> 16) & 0xFFFF;
      if (address != 0xC0FF) {  // Exclude heartbeat packets
        words_seen++;
      }
      processed_count++;
    } else {
      break; // Ring full
    }
  }

  // Save last up to 9 bytes only in LEN-EOF mode (used for cross-boundary reconstruction)
  if (!s_use_vsync_eof) {
    s_tail_len = (uint8_t)min<uint32_t>(9, buffer_length);
    if (s_tail_len > 0) memcpy(s_tail_bytes, buffer + buffer_length - s_tail_len, s_tail_len);
  } else {
    s_tail_len = 0;
  }

  // Low-noise debug logging: print when offset changes or every N buffers, or always at level>=2
  s_buf_seq++;
  {
    bool burst = (s_debug_burst_remaining > 0);
    bool changed = (off != s_last_logged_off);
    bool periodic = ((s_buf_seq % s_log_every_buffers) == 0);
    // Preview first word address for heartbeat detection
    uint16_t a0 = 0xFFFF;
    if (buffer_length >= (uint32_t)off + BYTES_PER_WORD) {
      uint32_t w0 = pack_word_from_8(buffer + off);
      a0 = (w0 >> 16) & 0xFFFF;
    }
    bool heartbeat_only = (a0 == 0xC0FF);
    // Ignore noisy 'changed' due to VSYNC-EOF idle off toggling when only heartbeats
    if (heartbeat_only && s_log_level == 1 && !burst) {
      changed = false;
    }
    bool base_wants_log = burst || (s_log_level >= 2) || (s_log_level >= 1 && (changed || periodic));
    // Throttle frequency unless in burst mode; apply stricter idle gating for heartbeat-only buffers
    uint64_t now_us = (uint64_t)esp_timer_get_time();
    bool allowed_by_time = false;
    if (burst) {
      allowed_by_time = true;
    } else if (heartbeat_only) {
      allowed_by_time = (s_last_idle_log_us == 0 || (now_us - s_last_idle_log_us) >= s_log_idle_interval_us);
    } else {
      allowed_by_time = (s_last_log_us == 0 || (now_us - s_last_log_us) >= s_log_min_interval_us);
    }
    bool should_log = base_wants_log && allowed_by_time;
    if (should_log) {
      Serial.printf("[LCAM] buf#%lu mode=%s len=%lu off=%d proc=%lu seen=%lu cap=%lu drop=%lu a0=$%04X\n",
                    (unsigned long)s_buf_seq,
                    s_use_vsync_eof?"VSYNC":"LEN",
                    (unsigned long)buffer_length,
                    off, (unsigned long)processed_count,
                    (unsigned long)words_seen, (unsigned long)words_captured,
                    (unsigned long)rb_drops, a0);
      s_last_logged_off = off;
      s_last_log_us = now_us;
      if (heartbeat_only) s_last_idle_log_us = now_us;
      if (burst) {
        // Decrement after emitting the log line
        if (s_debug_burst_remaining > 0) s_debug_burst_remaining--;
      }
    }
  }
}

// ----------------------------
// Public configuration APIs
// ----------------------------
void lcam_set_vsync_eof(bool enable) {
  s_use_vsync_eof = enable;
  // Applied at next lcam_start(); changing on-the-fly would require pausing GDMA safely.
}

bool lcam_get_vsync_eof() {
  return s_use_vsync_eof;
}

int lcam_get_current_offset() {
  return s_stream_offset_mod10;
}

void lcam_debug_burst(uint32_t count) {
  s_debug_burst_remaining = count;
}

void lcam_set_addr_window(uint16_t min_addr, uint16_t max_addr) {
  s_addr_min = min_addr;
  s_addr_max = max_addr;
}

void lcam_get_addr_window(uint16_t* min_addr, uint16_t* max_addr) {
  if (min_addr) *min_addr = s_addr_min;
  if (max_addr) *max_addr = s_addr_max;
}

// ---------- Timer Callback (Hardware Timer Context) ----------
static void IRAM_ATTR timeout_callback(void* arg) {
  uint32_t now_us = esp_timer_get_time();
  bool needs_processing = false;
  
  // Check for timed-out buffers with partial data
  for (int i = 0; i < DESC_COUNT; i++) {
    if (!s_buffer_ready[i] && s_buffer_timeout_start[i] > 0) {
      if (now_us - s_buffer_timeout_start[i] >= BUFFER_TIMEOUT_US) {
        s_buffer_ready[i] = true;  // Mark as ready for timeout processing
        s_buffer_timeout_start[i] = 0;
        needs_processing = true;
      }
    }
  }
  
  if (needs_processing) {
    // Signal poller task to process timed-out buffers
    BaseType_t xHigherPriorityTaskWoken = pdFALSE;
    vTaskNotifyGiveFromISR(s_poller_task, &xHigherPriorityTaskWoken);
    if (xHigherPriorityTaskWoken) {
      portYIELD_FROM_ISR();
    }
  }
}

void lcam_print_status() {
  uint8_t d =
    ((uint8_t)digitalRead(PIN_CAM_D3) << 3) |
    ((uint8_t)digitalRead(PIN_CAM_D2) << 2) |
    ((uint8_t)digitalRead(PIN_CAM_D1) << 1) |
    ((uint8_t)digitalRead(PIN_CAM_D0) << 0);
  Serial.printf("LCD_CAM CLK:%d VSYNC:%d D[3:0]=0x%X  edge=%u  words=%lu drops=%lu\n",
    digitalRead(PIN_CAM_PCLK), digitalRead(PIN_CAM_VSYNC), d, s_clk_inv,
    (unsigned long)words_seen, (unsigned long)rb_drops);
  Serial.printf("LCD_CAM GDMA: IN_ST=0x%08X INLINK=0x%08X EOF_DES=0x%08X\n",
    (unsigned)GDMA.channel[GDMA_CH].in.int_st.val,
    (unsigned)GDMA.channel[GDMA_CH].in.link.addr,
    (unsigned)GDMA.channel[GDMA_CH].in.suc_eof_des_addr);
}

// ---------- Bring-up ----------
static esp_err_t setup_lcd_cam_once() {
  if (!s_buf) {
    s_buf = (uint8_t*)heap_caps_aligned_alloc(16, DESC_COUNT * CHUNK_BYTES,
             MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    if (!s_buf) { Serial.println("LCD_CAM DMA buffer alloc failed"); return ESP_ERR_NO_MEM; }
    memset(s_buf, 0xBB, DESC_COUNT * CHUNK_BYTES);
  }
  if (!s_desc) {
    s_desc = (DESC_T*)heap_caps_aligned_alloc(16, DESC_COUNT * sizeof(DESC_T),
              MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    if (!s_desc) { Serial.println("LCD_CAM Desc alloc failed"); return ESP_ERR_NO_MEM; }
    memset(s_desc, 0, DESC_COUNT * sizeof(DESC_T));
  }

  periph_module_enable(PERIPH_LCD_CAM_MODULE);
  periph_module_reset(PERIPH_LCD_CAM_MODULE);
  periph_module_enable(PERIPH_GDMA_MODULE);
  periph_module_reset(PERIPH_GDMA_MODULE);

  LCD_CAM.cam_ctrl1.cam_reset       = 1;
  LCD_CAM.cam_ctrl1.cam_afifo_reset = 1;
  delayMicroseconds(3);
  LCD_CAM.cam_ctrl1.cam_reset       = 0;
  LCD_CAM.cam_ctrl1.cam_afifo_reset = 0;

  LCD_CAM.cam_ctrl.cam_clk_sel        = 2;    // 160MHz/4 = 40MHz base
  LCD_CAM.cam_ctrl.cam_clkm_div_a     = 0;
  LCD_CAM.cam_ctrl.cam_clkm_div_b     = 0;
  LCD_CAM.cam_ctrl.cam_clkm_div_num   = 2;    // 40MHz ÷ 2 = 20MHz effective (>13.5MHz FPGA rate)
  LCD_CAM.cam_ctrl.cam_update         = 1;

  gpio_set_direction((gpio_num_t)PIN_CAM_PCLK,  GPIO_MODE_INPUT);
  gpio_set_direction((gpio_num_t)PIN_CAM_VSYNC, GPIO_MODE_INPUT);
  gpio_set_direction((gpio_num_t)PIN_CAM_D0,    GPIO_MODE_INPUT);
  gpio_set_direction((gpio_num_t)PIN_CAM_D1,    GPIO_MODE_INPUT);
  gpio_set_direction((gpio_num_t)PIN_CAM_D2,    GPIO_MODE_INPUT);
  gpio_set_direction((gpio_num_t)PIN_CAM_D3,    GPIO_MODE_INPUT);

  route_in(PIN_CAM_PCLK,  CAM_PCLK_IDX,   false);
  route_in(PIN_CAM_VSYNC, CAM_V_SYNC_IDX, false);
  route_in(PIN_CAM_D0,    CAM_DATA_IN0_IDX, false);
  route_in(PIN_CAM_D1,    CAM_DATA_IN1_IDX, false);
  route_in(PIN_CAM_D2,    CAM_DATA_IN2_IDX, false);
  route_in(PIN_CAM_D3,    CAM_DATA_IN3_IDX, false);

#ifdef CAM_H_ENABLE_IDX
  route_const_one_to(CAM_H_ENABLE_IDX);
#endif

  GDMA.channel[GDMA_CH].in.conf0.in_rst           = 1;
  GDMA.channel[GDMA_CH].in.conf0.in_rst           = 0;
  GDMA.channel[GDMA_CH].in.conf0.indscr_burst_en  = 1;
  GDMA.channel[GDMA_CH].in.conf0.in_data_burst_en = 1;

  for (int i = 0; i < DESC_COUNT; ++i) {
    uint8_t* buf = s_buf + i * CHUNK_BYTES;
    DESC_T*  nxt = (i+1 < DESC_COUNT) ? &s_desc[i+1] : &s_desc[0];  // Circular for continuous capture
    desc_prep(&s_desc[i], buf, CHUNK_BYTES, nxt);
  }

  GDMA.channel[GDMA_CH].in.peri_sel.sel = 5;      // 5 = LCD_CAM

  GDMA.channel[GDMA_CH].in.int_ena.val = 0;
  GDMA.channel[GDMA_CH].in.int_ena.in_suc_eof = 1;
  GDMA.channel[GDMA_CH].in.link.addr  = (uint32_t)&s_desc[0];
  GDMA.channel[GDMA_CH].in.link.start = 1;

  // Use length-based EOF by default; optionally VSYNC->EOF if enabled at runtime
  LCD_CAM.cam_ctrl.cam_vs_eof_en         = s_use_vsync_eof ? 1 : 0;
  LCD_CAM.cam_ctrl.cam_stop_en           = 0;  // Continuous capture into descriptor ring
  LCD_CAM.cam_ctrl.cam_vsync_filter_thres= 1;   // Filter very short VSYNC glitches
  LCD_CAM.cam_ctrl.cam_byte_order        = 0;
  LCD_CAM.cam_ctrl.cam_bit_order         = 0;
  LCD_CAM.cam_ctrl.cam_update            = 1;

  LCD_CAM.cam_ctrl1.cam_2byte_en          = 0;                     // 8-bit
  // Ensure periodic length-based EOF per descriptor; VSYNC can add extra EOFs.
  LCD_CAM.cam_ctrl1.cam_rec_data_bytelen  = (CHUNK_BYTES - 1);
  LCD_CAM.cam_ctrl1.cam_clk_inv           = s_clk_inv;
  LCD_CAM.cam_ctrl1.cam_de_inv            = 0;
  LCD_CAM.cam_ctrl1.cam_vh_de_mode_en     = 0;   // DE-qualify disabled; capture on PCLK only
  LCD_CAM.cam_ctrl.cam_update             = 1;

  return ESP_OK;
}

// Continuous capture - no restart needed

// ---------- EOF processing (Triple Buffer Management) ----------
static inline void IRAM_ATTR on_eof_process() {
  volatile DESC_T* vd = dma_eof_desc();
  DESC_T* d = (DESC_T*)vd;
  uint8_t* buffer = desc_get_buf(d);
  uint32_t got = desc_len(d);
  
  if (got == 0 || got > (uint32_t)CHUNK_BYTES) got = CHUNK_BYTES;
  
  // Find which buffer this EOF corresponds to
  uint32_t buffer_idx = 0;
  for (int i = 0; i < DESC_COUNT; i++) {
    if (desc_get_buf(&s_desc[i]) == buffer) {
      buffer_idx = i;
      break;
    }
  }
  
  // Mark buffer as ready for processing if it has data
  if (got > 0 && !s_buffer_ready[buffer_idx]) {
    s_buffer_ready[buffer_idx] = true;
    s_buffer_timeout_start[buffer_idx] = 0; // Clear timeout since buffer is full
    // Count only when we actually queue a new buffer for processing
    words_captured++;
    
    // Signal processing task immediately for full buffers
    BaseType_t xHigherPriorityTaskWoken = pdFALSE;
    vTaskNotifyGiveFromISR(s_poller_task, &xHigherPriorityTaskWoken);
    if (xHigherPriorityTaskWoken) {
      portYIELD_FROM_ISR();
    }
  } else if (got > 0 && got < CHUNK_BYTES) {
    // Start timeout for partial buffer
    if (s_buffer_timeout_start[buffer_idx] == 0) {
      s_buffer_timeout_start[buffer_idx] = esp_timer_get_time();
    }
  }

  dma_ack_eof();
  // Continuous capture - DMA continues automatically with circular descriptors
}

// ---------- Poller task ----------
#define POLL_SPIN_LOOPS  4096

static inline bool gdma_link_down() {
  return GDMA.channel[GDMA_CH].in.link.addr == 0;
}

static inline void lcdcam_recover_if_needed() {
  // Recover if GDMA link pointer was cleared or EOF descriptor is zeroed
  if (gdma_link_down() || GDMA.channel[GDMA_CH].in.suc_eof_des_addr == 0) {
    // Re-arm GDMA channel config for LCD_CAM (I2S init may reset GDMA)
    GDMA.channel[GDMA_CH].in.conf0.in_rst = 1;
    GDMA.channel[GDMA_CH].in.conf0.in_rst = 0;
    GDMA.channel[GDMA_CH].in.conf0.indscr_burst_en  = 1;
    GDMA.channel[GDMA_CH].in.conf0.in_data_burst_en = 1;
    GDMA.channel[GDMA_CH].in.peri_sel.sel = 5;      // 5 = LCD_CAM

    // Re-arm descriptors and GDMA interrupts
    for (int i = 0; i < DESC_COUNT; ++i) {
      desc_rearm(&s_desc[i]);
      s_buffer_ready[i] = false;
      s_buffer_timeout_start[i] = 0;
    }
    GDMA.channel[GDMA_CH].in.int_clr.val = 0xFFFFFFFF;
    GDMA.channel[GDMA_CH].in.int_ena.val = 0;               // ensure clean enable
    GDMA.channel[GDMA_CH].in.int_ena.in_suc_eof = 1;
    GDMA.channel[GDMA_CH].in.link.addr  = (uint32_t)&s_desc[0];
    GDMA.channel[GDMA_CH].in.link.start = 1;
    LCD_CAM.cam_ctrl1.cam_start         = 1;
  }
}

static void poller_task(void*){
  for(;;){
    bool any = false;
    
    // If another driver reset GDMA, recover the link
    if (gdma_link_down()) lcdcam_recover_if_needed();
    
    // Fast polling for EOF events
    for (int i = 0; i < POLL_SPIN_LOOPS && !any; ++i) {
      if (dma_eof()) {
        on_eof_process();
        any = true;
      }
    }
    
    // Process any ready buffers
    for (int buf_idx = 0; buf_idx < DESC_COUNT; buf_idx++) {
      if (s_buffer_ready[buf_idx]) {
        // Process this buffer
        uint8_t* buffer = desc_get_buf(&s_desc[buf_idx]);
        uint32_t buffer_length = desc_len(&s_desc[buf_idx]);
        if (buffer_length > CHUNK_BYTES) buffer_length = CHUNK_BYTES;
        
        // Process the large buffer in batches
        process_large_buffer(buffer, buffer_length);
        
        // Mark buffer as processed and re-arm descriptor
        s_buffer_ready[buf_idx] = false;
        s_buffer_timeout_start[buf_idx] = 0;
        desc_rearm(&s_desc[buf_idx]);
        
        any = true;
      }
    }
    
    // Wait for notification from EOF or timeout
    if (!any) {
      // Wait for notification with timeout
      ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(2));
    }
    
    // Brief yield if no activity
    if (!any) vTaskDelay(1);
  }
}

// ---------- Consumer task ----------
static void packet_task(void*){
  uint32_t local_count = 0;
  for(;;){
    uint32_t w;
    if (rb_pop(&w)) {
      local_count++;
      if ((s_log_level > 0) && (local_count % word_print_every) == 0) {
        Serial.printf("LCD_CAM word[%lu]=0x%08X\n", (unsigned long)local_count, w);
      }
      
      // Process bus packet for ES5503 and other functionality
      process_bus_packet(w);
    } else {
      vTaskDelay(1);
    }
  }
}

esp_err_t lcam_init_tasks() {
  if (s_poller_task != nullptr || s_consumer_task != nullptr) {
    Serial.println("LCD_CAM tasks already running");
    return ESP_ERR_INVALID_STATE;
  }

  // Start consumer first (prio > poller)
  BaseType_t ret1 = xTaskCreatePinnedToCore(packet_task, "lcam_packet", 4096, nullptr, tskIDLE_PRIORITY + 2, &s_consumer_task, 1);
  // Start poller (prio lower). Increase stack to avoid canary trips during logging.
  BaseType_t ret2 = xTaskCreatePinnedToCore(poller_task, "lcam_poll", 4096, nullptr, tskIDLE_PRIORITY + 1, &s_poller_task, 1);

  if (ret1 != pdPASS || ret2 != pdPASS) {
    Serial.println("LCD_CAM failed to create tasks");
    lcam_cleanup_tasks();
    return ESP_FAIL;
  }
  
  return ESP_OK;
}

void lcam_cleanup_tasks() {
  if (s_poller_task != nullptr) {
    vTaskDelete(s_poller_task);
    s_poller_task = nullptr;
  }
  if (s_consumer_task != nullptr) {
    vTaskDelete(s_consumer_task);
    s_consumer_task = nullptr;
  }
}

void lcam_start() {
    // Stop tasks first
    if (setup_lcd_cam_once() != ESP_OK) { Serial.println("LCD_CAM setup failed"); return; }

    rb_reset(); 
    words_seen = 0;
    words_captured = 0;
    
    // Initialize buffer state
    s_current_buffer = 0;
    for (int i = 0; i < DESC_COUNT; i++) {
      s_buffer_ready[i] = false;
      s_buffer_timeout_start[i] = 0;
    }
    
    GDMA.channel[GDMA_CH].in.int_clr.val = 0xFFFFFFFF;
    GDMA.channel[GDMA_CH].in.link.addr   = (uint32_t)&s_desc[0];
    GDMA.channel[GDMA_CH].in.link.start  = 1;
    LCD_CAM.cam_ctrl1.cam_clk_inv        = s_clk_inv;
    LCD_CAM.cam_ctrl.cam_update          = 1;
    LCD_CAM.cam_ctrl1.cam_start          = 1;

    // Start tasks
    if (lcam_init_tasks() != ESP_OK) {
        Serial.println("LCD_CAM failed to start tasks");
        return;
    }

    // Reset stream alignment
    s_stream_offset_mod10 = -1;
    s_tail_len = 0;

    // Create timer for timeout handling
    if (!s_timeout_timer) {
        esp_timer_create_args_t timer_args = {};
        timer_args.callback = timeout_callback;
        timer_args.arg = nullptr;
        timer_args.dispatch_method = ESP_TIMER_TASK;
        timer_args.name = "lcam_timeout";
        esp_timer_create(&timer_args, &s_timeout_timer);
    }
    
    // Start periodic timer for timeout checking
    esp_timer_start_periodic(s_timeout_timer, BUFFER_TIMEOUT_US / 2);  // Check twice as often as timeout

    // Announce logging defaults and mode for quick visibility
    Serial.printf(
      "LCAM started: mode=%s log: level=%u, every=%lu, rate=%lums\n",
      s_use_vsync_eof ? "VSYNC" : "LEN",
      (unsigned)s_log_level,
      (unsigned long)s_log_every_buffers,
      (unsigned long)(s_log_min_interval_us/1000)
    );

    // Optional smoke wait (no polling; ISR/re-arm will run if data arrives)
    uint32_t start_ms = millis(), w0 = words_seen;
    if (SMOKE_MS) {
      uint32_t until = start_ms + SMOKE_MS;
      while ((int32_t)(millis() - until) < 0) {
        delay(1);  // yield cooperatively
      }
      uint32_t gotw = words_seen - w0;
      Serial.printf("LCD_CAM VSYNC-EOF test: %lu words in %ums\n", (unsigned long)gotw, (unsigned)SMOKE_MS);
      if (!gotw) {
        Serial.println("LCD_CAM capture failed: No words. Check PCLK burst (10 clocks/packet) and VSYNC on nibble 9.");
      }
    }
}

void lcam_stop() {
  // Stop timer first
  if (s_timeout_timer) {
    esp_timer_stop(s_timeout_timer);
  }
  
  // Stop tasks
  lcam_cleanup_tasks();
  
  // Stop the LCD_CAM and GDMA
  LCD_CAM.cam_ctrl1.cam_start = 0;
  GDMA.channel[GDMA_CH].in.link.stop = 1;
  Serial.println("LCD_CAM stopped.");
}

void lcam_log_every_n_words(uint32_t n) {
  // Log every N words processed
  if (n < 1) n = 1;
  word_print_every = n;
  Serial.printf("word_print_every=%lu\n", (unsigned long)word_print_every);
}

void lcam_set_logging(uint8_t n) {
  // Set logging level (clamped to 0..2)
  if (n > 2) n = 2;
  s_log_level = n;
}

void lcam_set_log_every(uint32_t n) {
  if (n == 0) n = 1;
  s_log_every_buffers = n;
}

void lcam_set_log_rate_ms(uint32_t ms) {
  if (ms < 10) ms = 10;            // sane floor
  if (ms > 60000) ms = 60000;      // sane ceiling
  s_log_min_interval_us = (uint32_t)ms * 1000U;
}

// Debug/stats functions
uint32_t lcam_get_words_seen() {
  return words_seen;
}

uint32_t lcam_get_ring_drops() {
  return rb_drops;
}

uint32_t lcam_get_words_captured() {
  return words_captured;
}

void lcam_reset_stats() {
  words_seen = 0;
  words_captured = 0;
  rb_drops = 0;
  s_stream_offset_mod10 = -1;
  s_tail_len = 0;
  s_buf_seq = 0;
  s_last_logged_off = -2;
  s_debug_burst_remaining = 0;
  s_last_log_us = 0;
  
  // Reset buffer state
  for (int i = 0; i < DESC_COUNT; i++) {
    s_buffer_ready[i] = false;
    s_buffer_timeout_start[i] = 0;
  }
}
