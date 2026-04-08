//
//    Copyright (c) 2026 Joel Winarske
//
//    Licensed under the Apache License, Version 2.0 (the "License");
//    you may not use this file except in compliance with the License.
//    You may obtain a copy of the License at
//
//        http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS,
//    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//    See the License for the specific language governing permissions and
//    limitations under the License.
//

// signal_filter.h — Per-signal smoothing filters for vsomeip payloads.
//
// Filters run on the C++ side between vsomeip's callback thread and the
// Dart_PostCObject_DL post. They mutate the float32 value at a configured
// payload offset in place. Filter state lives in the registry, keyed by
// (service_id, instance_id, event_id).

#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

enum class FilterType : uint8_t {
    Passthrough = 0,
    Ema = 1,       // Exponential moving average: y = a*x + (1-a)*y_prev
    Median = 2,    // Median over a sliding window
    Lowpass1 = 3,  // First-order IIR low-pass
};

/// Base interface for signal filters operating on a single float stream.
class SignalFilter {
public:
    virtual ~SignalFilter() = default;
    /// Apply the filter to one input sample. Returns the filtered value.
    virtual float apply(float input) = 0;
    /// Reset internal state.
    virtual void reset() = 0;
};

class PassthroughFilter : public SignalFilter {
public:
    float apply(float input) override { return input; }
    void reset() override {}
};

/// Exponential moving average: y = alpha * x + (1 - alpha) * y_prev
/// alpha in (0, 1]. Smaller = heavier smoothing.
class EmaFilter : public SignalFilter {
public:
    explicit EmaFilter(float alpha);
    float apply(float input) override;
    void reset() override;

private:
    float alpha_;
    float y_ = 0.0f;
    bool initialized_ = false;
};

/// First-order IIR low-pass filter.
/// alpha derived from cutoff_hz and sample_hz: alpha = dt / (RC + dt)
/// where RC = 1 / (2*pi*cutoff_hz), dt = 1 / sample_hz.
class Lowpass1Filter : public SignalFilter {
public:
    Lowpass1Filter(float cutoff_hz, float sample_hz);
    float apply(float input) override;
    void reset() override;

private:
    float alpha_;
    float y_ = 0.0f;
    bool initialized_ = false;
};

/// Median filter over a sliding window of N samples (N must be odd).
class MedianFilter : public SignalFilter {
public:
    explicit MedianFilter(uint16_t window_size);
    float apply(float input) override;
    void reset() override;

private:
    uint16_t window_size_;
    std::vector<float> window_;
    // M2: scratch buffer reused for sorting on every sample, instead of
    // allocating a fresh std::vector inside apply() on the hot path.
    std::vector<float> scratch_;
    size_t next_idx_ = 0;
    bool full_ = false;
};

/// Per-event filter registry. Thread-safe.
///
/// Keyed by (service_id << 32) | (instance_id << 16) | event_id.
class FilterRegistry {
public:
    using Key = uint64_t;

    static Key make_key(uint16_t svc, uint16_t inst, uint16_t evt) {
        return (static_cast<uint64_t>(svc) << 32) | (static_cast<uint64_t>(inst) << 16) |
               static_cast<uint64_t>(evt);
    }

    /// Configure a filter for the given (svc, inst, evt, payload_offset) tuple.
    /// Multiple filters per (svc, inst, evt) are supported — one per offset.
    /// Re-calling with the same offset replaces the existing filter for that
    /// offset (and resets its state).
    ///
    /// payload_offset: byte offset of the float32 to filter (must be 4-byte aligned).
    /// param: alpha for EMA (0..1), cutoff_hz for Lowpass1, window_size for Median.
    /// sample_hz: only used for Lowpass1 (default 100 Hz).
    void set_filter(uint16_t svc,
                    uint16_t inst,
                    uint16_t evt,
                    FilterType type,
                    uint16_t payload_offset,
                    float param,
                    float sample_hz = 100.0f);

    /// Remove ALL filters for the given (svc, inst, evt) tuple.
    void clear_filter(uint16_t svc, uint16_t inst, uint16_t evt);

    /// Remove only the filter at a specific offset within (svc, inst, evt).
    void clear_filter_at(uint16_t svc, uint16_t inst, uint16_t evt, uint16_t payload_offset);

    /// Returns true if any filter is configured for the given tuple.
    bool has_filter(uint16_t svc, uint16_t inst, uint16_t evt) const;

    /// Apply ALL filters configured for (svc, inst, evt) in place.
    /// Returns true if at least one filter was applied (any offset).
    bool apply(uint16_t svc, uint16_t inst, uint16_t evt, uint8_t* payload, uint32_t payload_len);

    /// Total number of (svc, inst, evt) tuples that have at least one filter.
    size_t count() const;

private:
    struct FilterEntry {
        uint16_t payload_offset;
        std::unique_ptr<SignalFilter> filter;
    };
    mutable std::mutex mutex_;
    // Map of event-key → list of filters (one per offset, sorted by offset).
    std::unordered_map<Key, std::vector<FilterEntry>> entries_;
};
