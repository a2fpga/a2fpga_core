#include "a2fpga_radio.h"

using namespace libhelix;

// Constants
const size_t RADIO_AUDIO_BUFFER_SIZE = 1024;  // Expected by I2S system (AUDIO_BUFFER_FRAMES * 2)

// Internal constants
#define PCM_RING_BUFFER_SIZE (16384)    // Larger buffer to handle burst decoding
#define PCM_PREBUFFER_SIZE (4608)       // Minimum buffer before starting playback (2 MP3 frames)
#define PCM_UNDERRUN_SIZE (1536)        // Stop playback when buffer drops below 1.5 I2S cycles
#define UNDERRUN_GRACE_PERIOD 5         // Allow 5 cycles of silence before rebuffering
#define STREAM_BUFFER_SIZE 4096

// Static member variables
static bool s_radio_active = false;
static String s_radio_url = "";
static TaskHandle_t s_radio_task = NULL;

// MP3 decoder
static MP3DecoderHelix s_mp3_decoder;
static bool s_mp3_decoder_initialized = false;

// PCM ring buffer
static int16_t s_pcm_ring_buffer[PCM_RING_BUFFER_SIZE];
static volatile size_t s_pcm_write_index = 0;
static volatile size_t s_pcm_read_index = 0;
static volatile size_t s_pcm_available = 0;
static bool s_pcm_prebuffered = false;
static int s_underrun_grace_cycles = 0;

// Network buffers
static uint8_t s_stream_buffer[STREAM_BUFFER_SIZE];

// PCM ring buffer functions
static size_t pcm_ring_write(const int16_t* data, size_t samples) {
  size_t written = 0;
  for (size_t i = 0; i < samples && s_pcm_available < PCM_RING_BUFFER_SIZE; i++) {
    s_pcm_ring_buffer[s_pcm_write_index] = data[i];
    s_pcm_write_index = (s_pcm_write_index + 1) % PCM_RING_BUFFER_SIZE;
    s_pcm_available++;
    written++;
  }
  return written;
}

static size_t pcm_ring_read(int16_t* data, size_t max_samples) {
  size_t read = 0;
  size_t available_before = s_pcm_available;
  
  for (size_t i = 0; i < max_samples && s_pcm_available > 0; i++) {
    data[i] = s_pcm_ring_buffer[s_pcm_read_index];
    s_pcm_read_index = (s_pcm_read_index + 1) % PCM_RING_BUFFER_SIZE;
    s_pcm_available--;
    read++;
  }
  
  // Debug only actual problematic reads (not normal full buffer state)
  if (available_before > max_samples && read < max_samples && read > 0) {
    Serial.printf("RING READ ISSUE: had %d, tried %d, got %d, remaining %d\n", 
                  available_before, max_samples, read, s_pcm_available);
  }
  
  return read;
}

// MP3 decoder callback - receives decoded PCM data
void A2FPGARadio::mp3DataCallback(MP3FrameInfo &info, int16_t *pcm_buffer, size_t len, void* ref) {
  // Debug: print MP3 frame info periodically with more details
  static int frame_count = 0;
  static uint32_t last_samprate = 0;
  static int last_nChans = 0;
  static int last_samples = 0;
  
  // Print if frame characteristics change or every 200 frames
  bool changed = (info.samprate != last_samprate) || (info.nChans != last_nChans) || (len != last_samples);
  if (changed || (frame_count % 200 == 0)) {
    Serial.printf("MP3 Frame #%d: %dHz, %dch, %dbps, %d samples, bitrate=%d, layer=%d, buffer: %d/%d\n", 
                  frame_count, info.samprate, info.nChans, info.bitsPerSample, len, 
                  info.bitrate, info.layer, s_pcm_available, PCM_RING_BUFFER_SIZE);
    last_samprate = info.samprate;
    last_nChans = info.nChans;
    last_samples = len;
  }
  frame_count++;
  
  // Check if buffer has enough space, if not wait briefly for consumer
  while (s_pcm_available + len > PCM_RING_BUFFER_SIZE) {
    vTaskDelay(pdMS_TO_TICKS(1)); // Wait for consumer to drain buffer
  }
  
  // Write decoded PCM data to ring buffer
  size_t written = pcm_ring_write(pcm_buffer, len);
  if (written < len) {
    Serial.printf("Warning: PCM ring buffer full, dropped %d samples\n", len - written);
  }
}

// Radio streaming task
void A2FPGARadio::radioTask(void* arg) {
  WiFiClient* client = nullptr;
  WiFiClientSecure* secure_client = nullptr;
  HTTPClient http;
  Stream* stream = nullptr;
  
  Serial.println("Radio task started");
  
  // Choose client type based on URL
  if (s_radio_url.startsWith("https://")) {
    secure_client = new WiFiClientSecure();
    secure_client->setInsecure(); // Skip certificate validation
    http.begin(*secure_client, s_radio_url);
  } else {
    client = new WiFiClient();
    http.begin(*client, s_radio_url);
  }
  
  // Set headers for streaming
  http.addHeader("User-Agent", "A2FPGA-ESP32/1.0");
  http.addHeader("Accept", "audio/mpeg, audio/*");
  
  Serial.println("Connecting to custom radio stream...");
  
  int httpCode = http.GET();
  if (httpCode == HTTP_CODE_OK) {
    Serial.printf("Custom radio connected! HTTP %d\n", httpCode);
    Serial.printf("Content-Type: %s\n", http.header("Content-Type").c_str());
    
    stream = http.getStreamPtr();
    
    // Initialize MP3 decoder
    s_mp3_decoder.setDataCallback(mp3DataCallback);
    s_mp3_decoder.begin();
    s_mp3_decoder_initialized = true;
    Serial.println("MP3 decoder initialized with callback");
    
    uint32_t total_bytes = 0;
    uint8_t mp3_buffer[512];
    
    // Main streaming loop
    Serial.printf("Starting streaming loop, s_radio_active=%d, http.connected()=%d\n", s_radio_active, http.connected());
    while (s_radio_active && http.connected()) {
      int bytes_available = stream->available();
      
      if (bytes_available > 0) {
        size_t to_read = std::min((size_t)bytes_available, (size_t)sizeof(mp3_buffer));
        size_t bytes_read = stream->readBytes(mp3_buffer, to_read);
        total_bytes += bytes_read;
        
        if (bytes_read > 0) {
          // Debug network read patterns
          static int network_debug_count = 0;
          if (++network_debug_count % 50 == 0) {
            Serial.printf("Network: read %d bytes, total %d KB, available %d, PCM buffer: %d/%d\n", 
                         bytes_read, total_bytes / 1024, bytes_available, s_pcm_available, PCM_RING_BUFFER_SIZE);
          }
          
          // Check buffer level before feeding more data
          if (s_pcm_available > PCM_RING_BUFFER_SIZE / 2) {
            // Buffer is getting full, slow down producer
            vTaskDelay(pdMS_TO_TICKS(10));
          }
          
          // Feed MP3 data to decoder (this will trigger the callback when a frame is decoded)
          s_mp3_decoder.write(mp3_buffer, bytes_read);
          
          // Small yield to let main audio task handle PCM data
          vTaskDelay(pdMS_TO_TICKS(1));
        }
      } else {
        // No data available, yield briefly
        static int no_data_count = 0;
        if (++no_data_count % 1000 == 0) {
          Serial.printf("No data available from stream (count: %d)\n", no_data_count);
        }
        vTaskDelay(pdMS_TO_TICKS(10));
      }
    }
    
    Serial.printf("Radio streaming ended. Total bytes: %d\n", total_bytes);
  } else {
    Serial.printf("HTTP connection failed: %d\n", httpCode);
  }
  
  // Cleanup
  if (s_mp3_decoder_initialized) {
    s_mp3_decoder.end();
    s_mp3_decoder_initialized = false;
  }
  
  http.end();
  
  if (secure_client) {
    delete secure_client;
  }
  if (client) {
    delete client;
  }
  
  // Mark task as finished
  s_radio_task = NULL;
  s_radio_active = false;
  
  Serial.println("Radio task ended");
  vTaskDelete(NULL);
}

// Public interface implementation
bool A2FPGARadio::begin() {
  resetState();
  return true;
}

bool A2FPGARadio::start(const String& url) {
  if (s_radio_active) {
    stop();
    vTaskDelay(pdMS_TO_TICKS(100)); // Wait for cleanup
  }
  
  s_radio_url = url;
  resetState();
  
  Serial.printf("Starting custom radio stream: %s\n", url.c_str());
  
  // Set active flag and create radio streaming task
  s_radio_active = true;
  BaseType_t ok = xTaskCreatePinnedToCore(radioTask, "radio", 8192, NULL, 5, &s_radio_task, 1);
  if (ok != pdPASS) {
    s_radio_active = false;
    Serial.println("Failed to create radio task");
    return false;
  }
  
  Serial.println("Radio task created successfully");
  return true;
}

void A2FPGARadio::stop() {
  s_radio_active = false;
  
  if (s_radio_task) {
    // Wait for task to finish
    vTaskDelay(pdMS_TO_TICKS(100));
    s_radio_task = NULL;
  }
  
  resetState();
  Serial.println("Custom radio streaming stopped");
}

bool A2FPGARadio::isActive() {
  return s_radio_active;
}

String A2FPGARadio::getCurrentURL() {
  return s_radio_url;
}

bool A2FPGARadio::hasPCMData() {
  return s_pcm_prebuffered || s_underrun_grace_cycles > 0;
}

size_t A2FPGARadio::readPCMSamples(int16_t* buffer, size_t requested_samples) {
  if (!s_radio_active) {
    // Fill with silence if radio not active
    for (size_t i = 0; i < requested_samples; i++) {
      buffer[i] = 0;
    }
    return requested_samples;
  }
  
  updateBufferState();
  
  size_t samples_read = 0;
  if (s_pcm_prebuffered || s_underrun_grace_cycles > 0) {
    // Read available PCM data
    samples_read = pcm_ring_read(buffer, requested_samples);
    
    // Pad remaining with silence for consistent I2S timing
    for (size_t i = samples_read; i < requested_samples; i++) {
      buffer[i] = 0;
    }
  } else {
    // Not prebuffered, send silence
    for (size_t i = 0; i < requested_samples; i++) {
      buffer[i] = 0;
    }
  }
  
  return requested_samples; // Always return full buffer size
}

bool A2FPGARadio::isPrebuffered() {
  return s_pcm_prebuffered;
}

int A2FPGARadio::getGracePeriodCycles() {
  return s_underrun_grace_cycles;
}

void A2FPGARadio::getBufferStatus(size_t* available, size_t* total) {
  if (available) *available = s_pcm_available;
  if (total) *total = PCM_RING_BUFFER_SIZE;
}

void A2FPGARadio::end() {
  stop();
}

// Private helper functions
void A2FPGARadio::resetState() {
  s_pcm_prebuffered = false;
  s_underrun_grace_cycles = 0;
  s_pcm_available = 0;
  s_pcm_write_index = 0;
  s_pcm_read_index = 0;
}

void A2FPGARadio::updateBufferState() {
  size_t current_available = s_pcm_available;
  
  // Check if we have enough data to start/continue playback
  if (!s_pcm_prebuffered && current_available >= PCM_PREBUFFER_SIZE) {
    s_pcm_prebuffered = true;
    s_underrun_grace_cycles = 0;  // Reset grace period when prebuffer fills
    Serial.printf("PCM prebuffer filled (%d samples), starting playback\n", current_available);
  }
  
  // If we hit underrun, use grace period before rebuffering
  if (s_pcm_prebuffered && current_available < PCM_UNDERRUN_SIZE) {
    s_underrun_grace_cycles++;
    if (s_underrun_grace_cycles >= UNDERRUN_GRACE_PERIOD) {
      s_pcm_prebuffered = false;
      s_underrun_grace_cycles = 0;
      Serial.printf("PCM underrun (%d < %d) after %d cycles, rebuffering...\n", 
                   current_available, PCM_UNDERRUN_SIZE, UNDERRUN_GRACE_PERIOD);
    } else {
      Serial.printf("PCM underrun grace period: %d/%d cycles\n", 
                   s_underrun_grace_cycles, UNDERRUN_GRACE_PERIOD);
    }
  } else if (s_pcm_prebuffered) {
    // Reset grace period when buffer is healthy
    s_underrun_grace_cycles = 0;
  }
}