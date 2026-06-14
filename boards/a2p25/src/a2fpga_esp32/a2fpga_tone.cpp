#include "a2fpga_tone.h"
#include <math.h>

// Static member definitions
volatile bool A2FPGATone::s_tone_active = false;
float A2FPGATone::s_frequency = 440.0f;
float A2FPGATone::s_phase = 0.0f;
float A2FPGATone::s_phase_increment = 0.0f;
const float A2FPGATone::s_sample_rate = 44100.0f;  // Match I2S sample rate
const float A2FPGATone::s_amplitude = 16000.0f;    // ~50% of 16-bit range

bool A2FPGATone::begin() {
    s_tone_active = false;
    s_phase = 0.0f;
    s_frequency = 440.0f;
    s_phase_increment = (2.0f * M_PI * s_frequency) / s_sample_rate;
    
    Serial.println("A2FPGATone: initialized");
    return true;
}

bool A2FPGATone::start(float frequency) {
    if (frequency <= 0.0f || frequency > s_sample_rate / 2.0f) {
        Serial.printf("A2FPGATone: Invalid frequency %.1fHz (range: 0.1 - %.1f Hz)\n", 
                      frequency, s_sample_rate / 2.0f);
        return false;
    }
    
    s_frequency = frequency;
    s_phase = 0.0f;  // Reset phase for clean start
    s_phase_increment = (2.0f * M_PI * s_frequency) / s_sample_rate;
    s_tone_active = true;
    
    Serial.printf("A2FPGATone: started %.1fHz sine wave (phase_inc=%.6f)\n", 
                  s_frequency, s_phase_increment);
    return true;
}

void A2FPGATone::stop() {
    s_tone_active = false;
    s_phase = 0.0f;
    Serial.println("A2FPGATone: stopped");
}

bool A2FPGATone::isActive() {
    return s_tone_active;
}

void A2FPGATone::generateSamples(int16_t* buffer, size_t num_samples) {
    if (!s_tone_active || !buffer) {
        // Fill with silence if not active
        for (size_t i = 0; i < num_samples; i++) {
            buffer[i] = 0;
        }
        return;
    }
    
    for (size_t i = 0; i < num_samples; i++) {
        // Generate sine wave sample
        float sample_f = s_amplitude * sinf(s_phase);
        
        // Convert to 16-bit integer with clipping
        int32_t sample_i32 = (int32_t)(sample_f + 0.5f);
        if (sample_i32 > 32767) sample_i32 = 32767;
        else if (sample_i32 < -32768) sample_i32 = -32768;
        
        buffer[i] = (int16_t)sample_i32;
        
        // Advance phase
        s_phase += s_phase_increment;
        
        // Wrap phase to avoid floating point precision issues
        if (s_phase >= 2.0f * M_PI) {
            s_phase -= 2.0f * M_PI;
        }
    }
}

void A2FPGATone::end() {
    stop();
    Serial.println("A2FPGATone: cleanup complete");
}