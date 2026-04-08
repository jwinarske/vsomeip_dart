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

// Covers: empty read, full write, wrap-around, drain, concurrent access.

#include <atomic>
#include <gtest/gtest.h>
#include <thread>

#include "../ring_buffer.h"
#include "../vsomeip_types.h"

TEST(RingBuffer, EmptyReadReturnsZero) {
    auto rb = spsc_ring_buffer<SomeIpRingEntry, 8>::create();
    SomeIpRingEntry out;
    EXPECT_FALSE(rb->pop(out));  // empty branch
}

TEST(RingBuffer, SinglePushPop) {
    auto rb = spsc_ring_buffer<SomeIpRingEntry, 8>::create();
    SomeIpRingEntry in{.service_id = 0x01, .payload_len = 4};
    EXPECT_TRUE(rb->push(in));
    SomeIpRingEntry out;
    EXPECT_TRUE(rb->pop(out));
    EXPECT_EQ(out.service_id, 0x01u);
    EXPECT_EQ(out.payload_len, 4u);
}

TEST(RingBuffer, FullBufferDropsNewEntry) {
    // capacity = 8 slots, usable = 7 (one reserved for full/empty distinction)
    auto rb = spsc_ring_buffer<SomeIpRingEntry, 8>::create();
    for (int i = 0; i < 7; ++i) {
        EXPECT_TRUE(rb->push(SomeIpRingEntry{.service_id = static_cast<uint16_t>(i)}));
    }
    EXPECT_FALSE(rb->push(SomeIpRingEntry{.service_id = 99}));  // full branch
}

TEST(RingBuffer, WrapAround) {
    auto rb = spsc_ring_buffer<SomeIpRingEntry, 4>::create();
    // Fill and drain to force index wrap
    for (int round = 0; round < 3; ++round) {
        for (int i = 0; i < 3; ++i)
            rb->push(SomeIpRingEntry{.service_id = static_cast<uint16_t>(i)});
        SomeIpRingEntry out;
        for (int i = 0; i < 3; ++i) {
            ASSERT_TRUE(rb->pop(out));
            EXPECT_EQ(out.service_id, static_cast<uint16_t>(i));
        }
    }
}

TEST(RingBuffer, SizeTracking) {
    auto rb = spsc_ring_buffer<SomeIpRingEntry, 8>::create();
    EXPECT_EQ(rb->size(), 0u);
    EXPECT_TRUE(rb->empty());

    rb->push(SomeIpRingEntry{.service_id = 1});
    rb->push(SomeIpRingEntry{.service_id = 2});
    EXPECT_EQ(rb->size(), 2u);
    EXPECT_FALSE(rb->empty());

    SomeIpRingEntry out;
    rb->pop(out);
    EXPECT_EQ(rb->size(), 1u);
}

TEST(RingBuffer, CapacityConstant) {
    EXPECT_EQ((spsc_ring_buffer<SomeIpRingEntry, 8>::capacity()), 7u);
    EXPECT_EQ((spsc_ring_buffer<SomeIpRingEntry, 1024>::capacity()), 1023u);
}

TEST(RingBuffer, DrainAll) {
    auto rb = spsc_ring_buffer<SomeIpRingEntry, 16>::create();
    constexpr int count = 15;  // max usable slots
    for (int i = 0; i < count; ++i) {
        EXPECT_TRUE(rb->push(SomeIpRingEntry{.service_id = static_cast<uint16_t>(i)}));
    }
    SomeIpRingEntry out;
    for (int i = 0; i < count; ++i) {
        ASSERT_TRUE(rb->pop(out));
        EXPECT_EQ(out.service_id, static_cast<uint16_t>(i));
    }
    EXPECT_FALSE(rb->pop(out));  // now empty
    EXPECT_TRUE(rb->empty());
}

TEST(RingBuffer, ConcurrentProducerConsumer) {
    // One producer thread, one consumer thread — verify no entries lost
    auto rb = spsc_ring_buffer<SomeIpRingEntry, 1024>::create();
    constexpr int N = 100000;
    std::atomic<int> consumed{0};

    std::thread producer([&] {
        for (int i = 0; i < N; ++i) {
            SomeIpRingEntry e{.service_id = static_cast<uint16_t>(i & 0xFFFF)};
            while (!rb->push(e)) { /* back-pressure: retry */
            }
        }
    });
    std::thread consumer([&] {
        SomeIpRingEntry e;
        while (consumed.load() < N) {
            if (rb->pop(e))
                consumed.fetch_add(1);
        }
    });

    producer.join();
    consumer.join();
    EXPECT_EQ(consumed.load(), N);
}
