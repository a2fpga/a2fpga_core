#ifndef ES5503_H
#define ES5503_H

#include <stdint.h>
#include <vector>
#include <functional>
#include <memory>
#include <algorithm>
#include <string.h>

// Standalone ES5503 (DOC) implementation based on MAME
class ES5503 {
public:
    // Construction
    ES5503(uint32_t clock_rate, uint8_t *wave_memory, uint32_t memory_size);
    
    // Static factory method to create ES5503 with allocated wave memory
    static ES5503* create_with_memory(uint32_t clock_rate, uint32_t memory_size = 65536);
    
    // Destructor to free wave memory if allocated internally
    ~ES5503();
    
    // Set number of output channels (must be a power of 2)
    void set_channels(int channels);

    // Set target output sample rate (for rate conversion)
    void set_output_sample_rate(uint32_t rate);
    
    // Read from register
    uint8_t read(uint16_t offset);
    
    // Write to register
    void write(uint16_t offset, uint8_t data);
    
    // Generate audio into provided buffer
    void generate_audio(int16_t *buffer, int num_samples);
    
    // Get IRQ state
    bool get_irq() const { return m_irq_active; }
    
    // Set callback for IRQ
    void set_irq_callback(std::function<void(bool)> callback) {
        m_irq_callback = callback;
    }
    
    // Get channel strobe value
    uint8_t get_channel_strobe() const { return m_channel_strobe; }
    
    // Reset the chip
    void reset();
    
    // Get wave memory pointer
    uint8_t* get_wave_memory() const { return m_wave_memory; }

    // Get current output sample rate (for sample rate conversion)
    uint32_t get_output_rate() const { return m_output_rate; }

    // Get number of enabled oscillators
    int get_oscsenabled() const { return m_oscsenabled; }

    // Get oscillator control register (for firmware-level key-on compensation)
    uint8_t get_osc_control(int osc) const { return m_oscillators[osc].control; }

    // Force oscillator halt bit (firmware compensates for clock domain mismatch)
    void force_osc_halt(int osc) { m_oscillators[osc].control |= 1; }
    
private:
    // Oscillator modes
    enum {
        MODE_FREE = 0,
        MODE_ONESHOT = 1,
        MODE_SYNCAM = 2,
        MODE_SWAP = 3
    };
    
    // Oscillator structure
    struct ES5503Osc {
        uint16_t freq;
        uint16_t wtsize;
        uint8_t  control;
        uint8_t  vol;
        uint8_t  data;
        uint32_t wavetblpointer;
        uint8_t  wavetblsize;
        uint8_t  resolution;

        uint32_t accumulator;
        uint8_t  irqpend;

        // Grace period tracking: continue generating from recently-active oscillators
        // even if briefly halted, to avoid 10ms gaps from timing granularity
        uint32_t last_active_ms;  // millis() when oscillator was last running
        bool was_generating;      // was this oscillator generating audio last call?
    };
    
    // Halt an oscillator
    void halt_osc(int onum, int type, uint32_t *accumulator, int resshift);
    
    // Read a byte from wave memory
    uint8_t read_byte(uint32_t address);
    
    // Update audio stream
    void update_stream(int16_t *buffer, int num_samples);
    
    // Member variables
    ES5503Osc m_oscillators[32];
    
    int8_t  m_oscsenabled;       // # of oscillators enabled
    int     m_rege0;             // contents of register 0xe0
    
    uint8_t m_channel_strobe;
    
    int m_output_channels;
    uint32_t m_output_rate;          // ES5503 native rate based on clock and oscillators
    uint32_t m_target_sample_rate;   // Target output rate (e.g., 44100 Hz for I2S)
    
    uint32_t m_clock_rate;
    
    std::vector<int32_t> m_mix_buffer;
    
    bool m_irq_active;
    std::function<void(bool)> m_irq_callback;
    
    uint8_t *m_wave_memory;
    uint32_t m_memory_size;
    bool m_memory_allocated;  // Track if we need to free memory
    
    // Constants
    static const uint16_t wavesizes[8];
    static const uint32_t wavemasks[8];
    static const uint32_t accmasks[8];
    static const int      resshifts[8];
};

// Moved static constants to .cpp file

#endif // ES5503_H