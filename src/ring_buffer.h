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

// ring_buffer.h — Lock-free single-producer single-consumer (SPSC) ring buffer.
//
// Used on the hot path between the vsomeip Boost.Asio callback thread
// (producer) and the Dart worker isolate poll timer (consumer).
//
// Design constraints:
//   - One writer thread (vsomeip callback), one reader thread (Dart poll)
//   - No mutex — uses acquire/release atomics only
//   - Fixed capacity (power of 2) — determined at compile time via template param
//   - When full, push() drops the new entry (back-pressure to vsomeip)
//   - Capacity is N-1 usable slots (one slot reserved to distinguish full from empty)

#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <new>
#include <type_traits>

template <typename T, uint32_t N>
class spsc_ring_buffer {
    static_assert(N >= 2, "Ring buffer capacity must be at least 2");
    static_assert((N & (N - 1)) == 0, "Ring buffer capacity must be a power of 2");
    static_assert(std::is_trivially_copyable_v<T>,
                  "Ring buffer element must be trivially copyable");

public:
    static std::unique_ptr<spsc_ring_buffer> create() {
        return std::unique_ptr<spsc_ring_buffer>(new spsc_ring_buffer());
    }

    // Producer: try to enqueue an entry.
    // Returns true on success, false if the buffer is full (entry is dropped).
    bool push(const T& entry) noexcept {
        const uint32_t head = head_.load(std::memory_order_relaxed);
        const uint32_t next = (head + 1) & mask_;
        if (next == tail_.load(std::memory_order_acquire)) {
            return false;  // full
        }
        buf_[head] = entry;
        head_.store(next, std::memory_order_release);
        return true;
    }

    // Consumer: try to dequeue an entry.
    // Returns true on success (entry written to out), false if empty.
    bool pop(T& out) noexcept {
        const uint32_t tail = tail_.load(std::memory_order_relaxed);
        if (tail == head_.load(std::memory_order_acquire)) {
            return false;  // empty
        }
        out = buf_[tail];
        tail_.store((tail + 1) & mask_, std::memory_order_release);
        return true;
    }

    // Returns the number of entries currently in the buffer.
    // This is approximate when called from either thread while the other
    // is actively pushing/popping.
    uint32_t size() const noexcept {
        const uint32_t head = head_.load(std::memory_order_acquire);
        const uint32_t tail = tail_.load(std::memory_order_acquire);
        return (head - tail) & mask_;
    }

    // Maximum number of entries the buffer can hold (N - 1).
    static constexpr uint32_t capacity() noexcept { return N - 1; }

    bool empty() const noexcept {
        return head_.load(std::memory_order_acquire) ==
               tail_.load(std::memory_order_acquire);
    }

private:
    spsc_ring_buffer() : head_(0), tail_(0) {}

    static constexpr uint32_t mask_ = N - 1;

    // Separate cache lines to avoid false sharing between producer and consumer.
    alignas(64) std::atomic<uint32_t> head_;
    alignas(64) std::atomic<uint32_t> tail_;
    alignas(64) T buf_[N];
};
