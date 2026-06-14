#include "es5503.h"
#include <algorithm>
#include <cstring>
#include "esp_heap_caps.h"
#include <Arduino.h>  // for millis()

// ES5503 - Standalone DOC implementation based on MAME's ES5503 emulator
// Adapted from MAME's ES5503 implementation by R. Belmont

// Define static constants
const uint16_t ES5503::wavesizes[8] = { 256, 512, 1024, 2048, 4096, 8192, 16384, 32768 };
const uint32_t ES5503::wavemasks[8] = { 0x1ff00, 0x1fe00, 0x1fc00, 0x1f800, 0x1f000, 0x1e000, 0x1c000, 0x18000 };
const uint32_t ES5503::accmasks[8]  = { 0xff, 0x1ff, 0x3ff, 0x7ff, 0xfff, 0x1fff, 0x3fff, 0x7fff };
const int      ES5503::resshifts[8] = { 9, 10, 11, 12, 13, 14, 15, 16 };

// Constructor
ES5503::ES5503(uint32_t clock_rate, uint8_t *wave_memory, uint32_t memory_size) :
    m_oscsenabled(1),
    m_rege0(0xff),
    m_channel_strobe(0),
    m_output_channels(2),
    m_clock_rate(clock_rate),
    m_target_sample_rate(44100),  // Default to 44.1kHz I2S output
    m_irq_active(false),
    m_wave_memory(wave_memory),
    m_memory_size(memory_size),
    m_memory_allocated(false)
{
    // Initialize oscillators
    reset();

    // Calculate output rate
    m_output_rate = (m_clock_rate / 8) / (m_oscsenabled + 2);

    // Allocate mix buffer (1/50th of a second at maximum)
    m_mix_buffer.resize((m_output_rate/50) * m_output_channels);
}

// Static factory method to create ES5503 with allocated wave memory
ES5503* ES5503::create_with_memory(uint32_t clock_rate, uint32_t memory_size)
{
    // Allocate wave memory in PSRAM for large buffers
    uint8_t* wave_memory = nullptr;
    if (memory_size > 32768) {  // Use PSRAM for buffers larger than 32KB
        wave_memory = (uint8_t*)heap_caps_malloc(memory_size, MALLOC_CAP_SPIRAM);
        if (!wave_memory) {
            // Fallback to internal RAM if PSRAM allocation fails
            wave_memory = (uint8_t*)heap_caps_malloc(memory_size, MALLOC_CAP_INTERNAL);
        }
    } else {
        // Use internal RAM for smaller buffers
        wave_memory = (uint8_t*)heap_caps_malloc(memory_size, MALLOC_CAP_INTERNAL);
    }
    
    if (!wave_memory) {
        return nullptr;
    }
    
    // Initialize wave memory to zero for silent startup
    memset(wave_memory, 0, memory_size);
    
    ES5503* es5503 = new ES5503(clock_rate, wave_memory, memory_size);
    if (es5503) {
        es5503->m_memory_allocated = true;
    } else {
        heap_caps_free(wave_memory);
    }
    
    return es5503;
}

// Destructor
ES5503::~ES5503()
{
    if (m_memory_allocated && m_wave_memory) {
        heap_caps_free(m_wave_memory);
    }
}

// Set number of output channels
void ES5503::set_channels(int channels)
{
    m_output_channels = channels;
}

// Set target output sample rate (for rate conversion)
void ES5503::set_output_sample_rate(uint32_t rate)
{
    m_target_sample_rate = rate;
}

// Reset the chip
void ES5503::reset()
{
    m_rege0 = 0xff;
    m_channel_strobe = 0;
    m_irq_active = false;

    for (int i = 0; i < 32; i++)
    {
        m_oscillators[i].freq = 0;
        m_oscillators[i].wtsize = 0;
        m_oscillators[i].control = 0;
        m_oscillators[i].vol = 0;
        m_oscillators[i].data = 0x80;
        m_oscillators[i].wavetblpointer = 0;
        m_oscillators[i].wavetblsize = 0;
        m_oscillators[i].resolution = 0;
        m_oscillators[i].accumulator = 0;
        m_oscillators[i].irqpend = 0;
        m_oscillators[i].last_active_ms = 0;
        m_oscillators[i].was_generating = false;
    }

    // Default to 32 oscillators (IIgs Sound Manager standard)
    // The IIgs writes to $E1 at boot to set this, but that write often
    // happens before ESP32/LCAM capture is ready, so we default to 32.
    m_oscsenabled = 32;

    // Recalculate output rate: 7159090 / 8 / 34 = 26320 Hz
    m_output_rate = (m_clock_rate / 8) / (m_oscsenabled + 2);
}

// Read from register
uint8_t ES5503::read(uint16_t offset)
{
    uint8_t retval;
    int i;

    if (offset < 0xe0)
    {
        int osc = offset & 0x1f;

        switch(offset & 0xe0)
        {
            case 0:     // freq lo
                return (m_oscillators[osc].freq & 0xff);

            case 0x20:  // freq hi
                return (m_oscillators[osc].freq >> 8);

            case 0x40:  // volume
                return m_oscillators[osc].vol;

            case 0x60:  // data
                return m_oscillators[osc].data;

            case 0x80:  // wavetable pointer
                return (m_oscillators[osc].wavetblpointer>>8) & 0xff;

            case 0xa0:  // oscillator control
                return m_oscillators[osc].control;

            case 0xc0:  // bank select / wavetable size / resolution
                retval = 0;
                if (m_oscillators[osc].wavetblpointer & 0x10000)
                {
                    retval |= 0x40;
                }

                retval |= (m_oscillators[osc].wavetblsize<<3);
                retval |= m_oscillators[osc].resolution;
                return retval;
        }
    }
    else     // global registers
    {
        switch (offset)
        {
            case 0xe0:  // interrupt status
                retval = m_rege0;

                // Clear IRQ line
                m_irq_active = false;
                if (m_irq_callback) m_irq_callback(false);

                // scan all oscillators
                for (i = 0; i < m_oscsenabled; i++)
                {
                    if (m_oscillators[i].irqpend)
                    {
                        // signal this oscillator has an interrupt
                        retval = i<<1;

                        m_rege0 = retval | 0x80;

                        // and clear its flag
                        m_oscillators[i].irqpend = 0;
                        break;
                    }
                }

                // if any oscillators still need to be serviced, assert IRQ again immediately
                for (i = 0; i < m_oscsenabled; i++)
                {
                    if (m_oscillators[i].irqpend)
                    {
                        m_irq_active = true;
                        if (m_irq_callback) m_irq_callback(true);
                        break;
                    }
                }

                return retval | 0x41;

            case 0xe1:  // oscillator enable
                return (m_oscsenabled - 1) << 1;

            case 0xe2:  // A/D converter
                return 0; // Not implemented in standalone version
        }
    }

    return 0;
}

// Write to register
void ES5503::write(uint16_t offset, uint8_t data)
{
    if (offset < 0xe0)
    {
        int osc = offset & 0x1f;

        switch(offset & 0xe0)
        {
            case 0:     // freq lo
                m_oscillators[osc].freq &= 0xff00;
                m_oscillators[osc].freq |= data;
                break;

            case 0x20:  // freq hi
                m_oscillators[osc].freq &= 0x00ff;
                m_oscillators[osc].freq |= (data<<8);
                break;

            case 0x40:  // volume
                m_oscillators[osc].vol = data;
                break;

            case 0x60:  // data - ignore writes
                break;

            case 0x80:  // wavetable pointer
                m_oscillators[osc].wavetblpointer = (data<<8);
                break;

            case 0xa0:  // oscillator control
                // MAME key-on detection: reset accumulator on halt=1 → halt=0 transition.
                // This is cycle-accurate in MAME. For our shadow, the firmware applies
                // a targeted force-halt for ONESHOT/SWAP modes before calling write()
                // to compensate for clock domain mismatch (see handle_es5503_write).
                if ((m_oscillators[osc].control & 1) && (!(data&1)))
                {
                    m_oscillators[osc].accumulator = 0;
                }

                // The Ensoniq data sheet says that if the low bit of the mode is set,
                // then halting either internally or from the CPU will reset the oscillator.
                // In practice, this means in swap mode that we will also do the swap.
                if (!(m_oscillators[osc].control & 1) && ((data & 1)) && ((data >> 1) & 1))
                {
                    halt_osc(osc, 0, &m_oscillators[osc].accumulator, resshifts[m_oscillators[osc].resolution]);
                }
                m_oscillators[osc].control = data;
                break;

            case 0xc0:  // bank select / wavetable size / resolution
                if (data & 0x40)    // bank select - not used on the Apple IIgs
                {
                    m_oscillators[osc].wavetblpointer |= 0x10000;
                }
                else
                {
                    m_oscillators[osc].wavetblpointer &= 0xffff;
                }

                m_oscillators[osc].wavetblsize = ((data>>3) & 7);
                m_oscillators[osc].wtsize = wavesizes[m_oscillators[osc].wavetblsize];
                m_oscillators[osc].resolution = (data & 7);
                break;
        }
    }
    else     // global registers
    {
        switch (offset)
        {
            case 0xe0:  // interrupt status
                break;

            case 0xe1:  // oscillator enable
                // The number here is the number of oscillators to enable -1 times 2.
                // You can never have zero oscillators enabled.
                // So a value of 62 enables all 32 oscillators.
                m_oscsenabled = ((data>>1) & 0x1f) + 1;
                
                // Recalculate output rate when oscillator count changes
                m_output_rate = (m_clock_rate / 8) / (m_oscsenabled + 2);
                break;

            case 0xe2:  // A/D converter
                break;
        }
    }
}

// Read a byte from wave memory
uint8_t ES5503::read_byte(uint32_t address)
{
    if (address < m_memory_size)
    {
        return m_wave_memory[address];
    }
    return 0;
}

// Generate audio into provided buffer
void ES5503::generate_audio(int16_t *buffer, int num_samples)
{
    update_stream(buffer, num_samples);
}

// Update audio stream
void ES5503::update_stream(int16_t *buffer, int num_samples)
{
    int32_t *mixp;
    int osc, snum, i;
    uint32_t ramptr;

    // Grace period: continue generating from recently-active oscillators even if
    // briefly halted. This avoids 10ms gaps caused by timing granularity - on a real
    // ES5503, a brief halt would only cause ~100us of silence, but since we generate
    // in ~10ms chunks, a halt during generation causes 10ms of silence.
    const uint32_t GRACE_PERIOD_MS = 20;  // Continue generating for up to 20ms after halt
    uint32_t now_ms = millis();

    // Make sure we have a big enough buffer
    if (num_samples * m_output_channels > (int)m_mix_buffer.size())
    {
        m_mix_buffer.resize(num_samples * m_output_channels);
    }

    // Clear mix buffer
    std::fill(m_mix_buffer.begin(), m_mix_buffer.end(), 0);

    for (int chan = 0; chan < m_output_channels; chan++)
    {
        // Mix across all oscillators; some IIgs software may program voices
        // before updating E1 (enabled count). This ensures we don't miss sound
        // from higher-numbered oscillators that are already configured.
        for (osc = 0; osc < 32; osc++)
        {
            ES5503Osc *pOsc = &m_oscillators[osc];

            // Check if oscillator should generate audio:
            // 1. Not halted (control bit 0 clear), OR
            // 2. Was recently generating (within grace period) - to smooth over brief halts
            bool is_halted = (pOsc->control & 1);
            bool in_grace_period = pOsc->was_generating &&
                                   (now_ms - pOsc->last_active_ms) < GRACE_PERIOD_MS;
            bool should_generate = (!is_halted || in_grace_period) &&
                                   ((pOsc->control >> 4) & (m_output_channels - 1)) == chan;

            if (should_generate)
            {
                uint32_t wtptr = pOsc->wavetblpointer & wavemasks[pOsc->wavetblsize], altram;
                uint32_t acc = pOsc->accumulator;
                const uint16_t wtsize = pOsc->wtsize - 1;
                uint8_t ctrl = pOsc->control;
                const uint16_t freq = pOsc->freq;
                int16_t vol = pOsc->vol;
                int8_t data = -128;
                const int resshift = resshifts[pOsc->resolution] - pOsc->wavetblsize;
                const uint32_t sizemask = accmasks[pOsc->wavetblsize];
                const int mode = (pOsc->control>>1) & 3;

                // Start from sample 0 (original MAME behavior)
                mixp = &m_mix_buffer[0] + chan;

                for (snum = 0; snum < num_samples; snum++)
                {
                    altram = acc >> resshift;
                    ramptr = altram & sizemask;

                    acc += freq;

                    // channel strobe is always valid when reading; this allows potentially banking per voice
                    m_channel_strobe = (ctrl>>4) & 0xf;
                    data = (int32_t)read_byte(ramptr + wtptr) ^ 0x80;

                    uint8_t byte_value = read_byte(ramptr + wtptr);
                    if (byte_value == 0x00)
                    {
                        halt_osc(osc, 1, &acc, resshift);
                    }
                    else
                    {
                        if (mode != MODE_SYNCAM)
                        {
                            int value = data * vol;
                            *mixp += value;
                            // Uppermost enabled oscillator gets triple gain (hardware quirk)
                            if (osc == (m_oscsenabled - 1))
                            {
                                *mixp += value;
                                *mixp += value;
                            }
                        }
                        else
                        {
                            // if we're odd, we play nothing ourselves
                            if (osc & 1)
                            {
                                if (osc < 31)
                                {
                                    // if the next oscillator up is playing, it's volume becomes our control
                                    if (!(m_oscillators[osc + 1].control & 1))
                                    {
                                        m_oscillators[osc + 1].vol = data ^ 0x80;
                                    }
                                }
                            }
                            else    // hard sync, both oscillators play?
                            {
                                *mixp += data * vol;
                                // Uppermost enabled oscillator gets triple gain (hardware quirk)
                                if (osc == (m_oscsenabled - 1))
                                {
                                    *mixp += data * vol;
                                    *mixp += data * vol;
                                }
                            }
                        }
                        mixp += m_output_channels;

                        if (altram >= wtsize)
                        {
                            halt_osc(osc, 0, &acc, resshift);
                        }
                    }

                    // if oscillator halted, we've got no more samples to generate
                    if (pOsc->control & 1)
                    {
                        ctrl |= 1;
                        break;
                    }
                }

                pOsc->control = ctrl;
                pOsc->accumulator = acc;
                pOsc->data = data ^ 0x80;

                // Update grace period tracking - this oscillator was generating
                pOsc->last_active_ms = now_ms;
                pOsc->was_generating = true;
            }
            else
            {
                // Oscillator not generating - clear grace period if expired
                if (pOsc->was_generating && (now_ms - pOsc->last_active_ms) >= GRACE_PERIOD_MS)
                {
                    pOsc->was_generating = false;
                }
            }
        }
    }

    // Copy mix buffer to output buffer with appropriate scaling
    for (int chan = 0; chan < m_output_channels; chan++)
    {
        mixp = &m_mix_buffer[0] + chan;
        for (i = 0; i < num_samples; i++)
        {
            // Scale appropriately and convert to 16-bit output
            // Wave data is -128 to +127, volume is 0-255
            // Per-oscillator max: ~32640, with triple gain: ~97920
            // Multiple oscillators can easily exceed 16-bit range
            // Use larger divisor (>>3 = /8) and clamp to prevent overflow distortion
            int32_t value = *mixp;
            int32_t scaled = value >> 1;  // Divide by 8 to handle multiple oscillators

            // Clamp to 16-bit range to prevent wrap-around distortion
            if (scaled > 32767) scaled = 32767;
            else if (scaled < -32768) scaled = -32768;

            buffer[i * m_output_channels + chan] = (int16_t)scaled;

            mixp += m_output_channels;
        }
    }
}

// halt_osc: handle halting an oscillator
// onum = oscillator #
// type = 1 for 0 found in sample data, 0 for hit end of table size
void ES5503::halt_osc(int onum, int type, uint32_t *accumulator, int resshift)
{
    ES5503Osc *pOsc = &m_oscillators[onum];
    ES5503Osc *pPartner = &m_oscillators[onum^1];
    int mode = (pOsc->control>>1) & 3;
    const int partnerMode = (pPartner->control>>1) & 3;

    // check for sync mode
    if (mode == MODE_SYNCAM)
    {
        if (!(onum & 1))
        {
            // we're even, so if the odd oscillator 1 below us is playing,
            // restart it.
            if (!(m_oscillators[onum - 1].control & 1))
            {
                m_oscillators[onum - 1].accumulator = 0;
            }
        }

        // loop this oscillator for both sync and AM
        mode = MODE_FREE;
    }

    // if 0 found in sample data or mode is not free-run, halt this oscillator
    if ((mode != MODE_FREE) || (type != 0))
    {
        pOsc->control |= 1;
    }
    else    // preserve the relative phase of the oscillator when looping
    {
        const uint16_t wtsize = pOsc->wtsize;
        // For the ideal case, the accumulator is greater than or equal to the wave table size.
        // Unfortunately degenerate cases can occur on this chip (especially with SoundSmith on
        // the IIgs), so in those cases just zero the integer part of the accumulator.
        if ((*accumulator >> resshift) < wtsize)
        {
            *accumulator -= ((*accumulator >> resshift) << resshift);
        }
        else    // Ideal case.  Just subtract the wave table size from the integer part.
        {
            *accumulator -= (wtsize << resshift);
        }
    }

    // if we're in swap mode, start the partner
    if (mode == MODE_SWAP)
    {
        pPartner->control &= ~1;    // clear the halt bit
        pPartner->accumulator = 0;  // and make sure it starts from the top
    }
    else
    {
        // if we're not swap and we're the even oscillator of the pair and the partner's swap
        // but we aren't, we retrigger (!!!)  Verified on IIgs hardware.
        if ((partnerMode == MODE_SWAP) && ((onum & 1)==0))
        {
            pOsc->control &= ~1;

            // preserve the phase in this case too
            uint16_t wtsize = pOsc->wtsize - 1;
            *accumulator -= (wtsize << resshift);
        }
    }

    // IRQ enabled for this voice?
    if (pOsc->control & 0x08)
    {
        pOsc->irqpend = 1;

        m_irq_active = true;
        if (m_irq_callback) m_irq_callback(true);
    }
}
