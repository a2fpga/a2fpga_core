#pragma once

#include <Arduino.h>
#include <stdint.h>

// Simple sine wave tone generator for audio debugging
class A2FPGATone {
public:
    // Initialize tone generator
    static bool begin();
    
    // Start generating tone at specified frequency
    static bool start(float frequency = 440.0f);
    
    // Stop tone generation
    static void stop();
    
    // Check if tone is active
    static bool isActive();
    
    // Generate audio samples directly into buffer (mono)
    static void generateSamples(int16_t* buffer, size_t num_samples);
    
    // Cleanup resources
    static void end();
    
private:
    static volatile bool s_tone_active;
    static float s_frequency;
    static float s_phase;
    static float s_phase_increment;
    static const float s_sample_rate;
    static const float s_amplitude;
};