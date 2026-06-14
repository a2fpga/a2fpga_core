#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include "MP3DecoderHelix.h"

// Radio stream management
class A2FPGARadio {
public:
    // Initialize radio system
    static bool begin();
    
    // Start streaming from URL
    static bool start(const String& url);
    
    // Stop streaming
    static void stop();
    
    // Check if radio is active
    static bool isActive();
    
    // Get current stream URL
    static String getCurrentURL();
    
    // Check if PCM data is ready for I2S
    static bool hasPCMData();
    
    // Read PCM samples for I2S output (returns actual samples read, pads with silence to requested_samples)
    static size_t readPCMSamples(int16_t* buffer, size_t requested_samples);
    
    // Check if in prebuffered state (ready for playback)
    static bool isPrebuffered();
    
    // Check if in grace period (underrun handling)
    static int getGracePeriodCycles();
    
    // Get buffer status
    static void getBufferStatus(size_t* available, size_t* total);
    
    // Cleanup resources
    static void end();

private:
    // Internal radio streaming task
    static void radioTask(void* arg);
    
    // MP3 decoder callback
    static void mp3DataCallback(MP3FrameInfo& info, int16_t* pcm_buffer, size_t len, void* ref);
    
    // Ring buffer functions
    static size_t ringBufferWrite(const int16_t* data, size_t samples);
    static size_t ringBufferRead(int16_t* data, size_t max_samples);
    
    // State management
    static void resetState();
    static void updateBufferState();
};

// Constants for integration with main audio system
extern const size_t RADIO_AUDIO_BUFFER_SIZE;  // Size expected by I2S system