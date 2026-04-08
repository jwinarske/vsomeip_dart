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

#include "signal_filter.h"

#include <algorithm>
#include <cmath>
#include <cstring>

// ── EmaFilter ───────────────────────────────────────────────────────────────

EmaFilter::EmaFilter(float alpha) : alpha_(alpha) {
    // M6: handle NaN/Inf — naive `<=` and `>` against NaN are both false,
    // leaving alpha_=NaN. Use a positive-finite test instead.
    if (!(alpha_ > 0.0f && alpha_ <= 1.0f)) {
        alpha_ = (alpha_ > 1.0f) ? 1.0f : 0.001f;
    }
}

float EmaFilter::apply(float input) {
    if (!initialized_) {
        y_ = input;
        initialized_ = true;
        return y_;
    }
    y_ = alpha_ * input + (1.0f - alpha_) * y_;
    return y_;
}

void EmaFilter::reset() {
    initialized_ = false;
    y_ = 0.0f;
}

// ── Lowpass1Filter ──────────────────────────────────────────────────────────

Lowpass1Filter::Lowpass1Filter(float cutoff_hz, float sample_hz) {
    // RC = 1 / (2*pi*cutoff)
    // dt = 1 / sample_hz
    // alpha = dt / (RC + dt)
    constexpr float kTwoPi = 6.28318530718f;
    // M6: NaN-safe positive bounds.
    if (!(cutoff_hz > 0.0f)) {
        cutoff_hz = 0.001f;
    }
    if (!(sample_hz > 0.0f)) {
        sample_hz = 1.0f;
    }
    const float rc = 1.0f / (kTwoPi * cutoff_hz);
    const float dt = 1.0f / sample_hz;
    alpha_ = dt / (rc + dt);
}

float Lowpass1Filter::apply(float input) {
    if (!initialized_) {
        y_ = input;
        initialized_ = true;
        return y_;
    }
    y_ = alpha_ * input + (1.0f - alpha_) * y_;
    return y_;
}

void Lowpass1Filter::reset() {
    initialized_ = false;
    y_ = 0.0f;
}

// ── MedianFilter ────────────────────────────────────────────────────────────

MedianFilter::MedianFilter(uint16_t window_size)
    : window_size_(window_size == 0 ? 1 : window_size),
      window_(window_size_, 0.0f),
      scratch_(window_size_, 0.0f) {}

float MedianFilter::apply(float input) {
    window_[next_idx_] = input;
    next_idx_ = (next_idx_ + 1) % window_size_;
    if (next_idx_ == 0) {
        full_ = true;
    }

    const size_t valid = full_ ? window_size_ : next_idx_;
    if (valid == 0) {
        return input;
    }

    // M2: reuse the preallocated scratch buffer instead of allocating each
    // call. apply() runs on the vsomeip callback thread; allocation here
    // could throw bad_alloc into Boost.Asio.
    std::copy(window_.begin(), window_.begin() + static_cast<long>(valid), scratch_.begin());
    std::sort(scratch_.begin(), scratch_.begin() + static_cast<long>(valid));
    return scratch_[valid / 2];
}

void MedianFilter::reset() {
    std::fill(window_.begin(), window_.end(), 0.0f);
    std::fill(scratch_.begin(), scratch_.end(), 0.0f);
    next_idx_ = 0;
    full_ = false;
}

// ── FilterRegistry ──────────────────────────────────────────────────────────

static std::unique_ptr<SignalFilter> create_filter(FilterType type, float param, float sample_hz) {
    switch (type) {
        case FilterType::Passthrough:
            return std::make_unique<PassthroughFilter>();
        case FilterType::Ema:
            return std::make_unique<EmaFilter>(param);
        case FilterType::Lowpass1:
            return std::make_unique<Lowpass1Filter>(param, sample_hz);
        case FilterType::Median: {
            // M6: clamp the float→uint16 cast. NaN, negatives, and values
            // above 1024 produce UB on the cast in C++17. Anchor at 1
            // (degenerate but valid) when out of range.
            uint16_t window = 1;
            if (param >= 1.0f && param <= 1024.0f) {
                window = static_cast<uint16_t>(param);
            }
            return std::make_unique<MedianFilter>(window);
        }
    }
    return std::make_unique<PassthroughFilter>();
}

void FilterRegistry::set_filter(uint16_t svc,
                                uint16_t inst,
                                uint16_t evt,
                                FilterType type,
                                uint16_t payload_offset,
                                float param,
                                float sample_hz) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto& list = entries_[make_key(svc, inst, evt)];

    // Replace existing filter at this offset, if any
    for (auto& e : list) {
        if (e.payload_offset == payload_offset) {
            e.filter = create_filter(type, param, sample_hz);
            return;
        }
    }

    // Otherwise insert in sorted order by offset
    FilterEntry e;
    e.payload_offset = payload_offset;
    e.filter = create_filter(type, param, sample_hz);
    auto pos = std::lower_bound(
        list.begin(), list.end(), payload_offset, [](const FilterEntry& a, uint16_t off) {
            return a.payload_offset < off;
        });
    list.insert(pos, std::move(e));
}

void FilterRegistry::clear_filter(uint16_t svc, uint16_t inst, uint16_t evt) {
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.erase(make_key(svc, inst, evt));
}

void FilterRegistry::clear_filter_at(uint16_t svc,
                                     uint16_t inst,
                                     uint16_t evt,
                                     uint16_t payload_offset) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(make_key(svc, inst, evt));
    if (it == entries_.end())
        return;

    auto& list = it->second;
    list.erase(std::remove_if(list.begin(),
                              list.end(),
                              [payload_offset](const FilterEntry& e) {
                                  return e.payload_offset == payload_offset;
                              }),
               list.end());

    if (list.empty())
        entries_.erase(it);
}

bool FilterRegistry::has_filter(uint16_t svc, uint16_t inst, uint16_t evt) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(make_key(svc, inst, evt));
    return it != entries_.end() && !it->second.empty();
}

bool FilterRegistry::apply(
    uint16_t svc, uint16_t inst, uint16_t evt, uint8_t* payload, uint32_t payload_len) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = entries_.find(make_key(svc, inst, evt));
    if (it == entries_.end() || it->second.empty())
        return false;

    bool any = false;
    for (auto& e : it->second) {
        const auto offset = e.payload_offset;
        if (static_cast<uint32_t>(offset) + sizeof(float) > payload_len) {
            continue;  // skip out-of-range filters silently
        }
        float v;
        std::memcpy(&v, payload + offset, sizeof(float));
        v = e.filter->apply(v);
        std::memcpy(payload + offset, &v, sizeof(float));
        any = true;
    }
    return any;
}

size_t FilterRegistry::count() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return entries_.size();
}
