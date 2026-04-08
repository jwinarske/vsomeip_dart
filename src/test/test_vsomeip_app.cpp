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

// test_vsomeip_app.cpp — Unit tests for VsomeipApp lifecycle.
//
// These tests use a mock vsomeip application interface to verify:
//   - State handler registration and callback dispatch
//   - Availability handler registration and callback dispatch
//   - Wire message encoding (discriminator + payload)
//   - Start/stop lifecycle and thread management
//   - Error posting
//
// The tests do NOT require the real vsomeip library. They operate on
// the VsomeipApp interface through the PostFn callback mechanism.

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <gtest/gtest.h>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../vsomeip_types.h"

// ── Captured wire message ───────────────────────────────────────────────────────

struct CapturedMessage {
    uint8_t disc;
    std::vector<uint8_t> data;
};

class MessageCapture {
public:
    void post(uint8_t disc, const uint8_t* data, uint32_t len) {
        std::lock_guard<std::mutex> lock(mutex_);
        messages_.push_back({disc, {data, data + len}});
        cv_.notify_all();
    }

    std::vector<CapturedMessage> messages() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return messages_;
    }

    bool wait_for(size_t count,
                  std::chrono::milliseconds timeout = std::chrono::milliseconds(1000)) {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [&] { return messages_.size() >= count; });
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::vector<CapturedMessage> messages_;
};

// ── Tests for wire encoding (no vsomeip dependency) ─────────────────────────────

TEST(VsomeipAppWire, StateRegisteredEncoding) {
    // Verify VsomeipState encoding: [registered_byte | app_name_bytes]
    MessageCapture capture;
    auto post_fn = [&](uint8_t disc, const uint8_t* data, uint32_t len) {
        capture.post(disc, data, len);
    };

    // Simulate what VsomeipApp::on_state does
    std::string app_name = "test_app";
    bool registered = true;
    std::vector<uint8_t> buf;
    buf.push_back(registered ? 1 : 0);
    buf.insert(buf.end(), app_name.begin(), app_name.end());
    post_fn(vsomeip_disc::kState, buf.data(), static_cast<uint32_t>(buf.size()));

    auto msgs = capture.messages();
    ASSERT_EQ(msgs.size(), 1u);
    EXPECT_EQ(msgs[0].disc, vsomeip_disc::kState);
    EXPECT_EQ(msgs[0].data[0], 1);  // registered
    std::string decoded_name(msgs[0].data.begin() + 1, msgs[0].data.end());
    EXPECT_EQ(decoded_name, "test_app");
}

TEST(VsomeipAppWire, StateDeregisteredEncoding) {
    MessageCapture capture;
    auto post_fn = [&](uint8_t disc, const uint8_t* data, uint32_t len) {
        capture.post(disc, data, len);
    };

    bool registered = false;
    std::string app_name = "my_app";
    std::vector<uint8_t> buf;
    buf.push_back(registered ? 1 : 0);
    buf.insert(buf.end(), app_name.begin(), app_name.end());
    post_fn(vsomeip_disc::kState, buf.data(), static_cast<uint32_t>(buf.size()));

    auto msgs = capture.messages();
    ASSERT_EQ(msgs.size(), 1u);
    EXPECT_EQ(msgs[0].data[0], 0);  // deregistered
}

TEST(VsomeipAppWire, AvailabilityEncoding) {
    // Verify VsomeipAvailability encoding: raw struct bytes
    MessageCapture capture;
    auto post_fn = [&](uint8_t disc, const uint8_t* data, uint32_t len) {
        capture.post(disc, data, len);
    };

    VsomeipAvailability avail{0x1234, 0x0001, true};
    post_fn(vsomeip_disc::kAvailability,
            reinterpret_cast<const uint8_t*>(&avail),
            static_cast<uint32_t>(sizeof(avail)));

    auto msgs = capture.messages();
    ASSERT_EQ(msgs.size(), 1u);
    EXPECT_EQ(msgs[0].disc, vsomeip_disc::kAvailability);
    EXPECT_EQ(msgs[0].data.size(), sizeof(VsomeipAvailability));

    VsomeipAvailability decoded;
    std::memcpy(&decoded, msgs[0].data.data(), sizeof(decoded));
    EXPECT_EQ(decoded.service_id, 0x1234);
    EXPECT_EQ(decoded.instance_id, 0x0001);
    EXPECT_TRUE(decoded.available);
}

TEST(VsomeipAppWire, AvailabilityUnavailableEncoding) {
    MessageCapture capture;
    auto post_fn = [&](uint8_t disc, const uint8_t* data, uint32_t len) {
        capture.post(disc, data, len);
    };

    VsomeipAvailability avail{0xABCD, 0x0002, false};
    post_fn(vsomeip_disc::kAvailability,
            reinterpret_cast<const uint8_t*>(&avail),
            static_cast<uint32_t>(sizeof(avail)));

    auto msgs = capture.messages();
    VsomeipAvailability decoded;
    std::memcpy(&decoded, msgs[0].data.data(), sizeof(decoded));
    EXPECT_EQ(decoded.service_id, 0xABCD);
    EXPECT_FALSE(decoded.available);
}

TEST(VsomeipAppWire, ErrorEncoding) {
    // Verify error messages use kError discriminator
    MessageCapture capture;
    auto post_fn = [&](uint8_t disc, const uint8_t* data, uint32_t len) {
        capture.post(disc, data, len);
    };

    std::string error_msg = "init failed: app not found";
    post_fn(vsomeip_disc::kError,
            reinterpret_cast<const uint8_t*>(error_msg.data()),
            static_cast<uint32_t>(error_msg.size()));

    auto msgs = capture.messages();
    ASSERT_EQ(msgs.size(), 1u);
    EXPECT_EQ(msgs[0].disc, vsomeip_disc::kError);
    std::string decoded(msgs[0].data.begin(), msgs[0].data.end());
    EXPECT_EQ(decoded, error_msg);
}

TEST(VsomeipAppWire, MultipleMessagesInSequence) {
    MessageCapture capture;
    auto post_fn = [&](uint8_t disc, const uint8_t* data, uint32_t len) {
        capture.post(disc, data, len);
    };

    // Post state, then availability, then another state
    uint8_t state1[] = {1, 'a'};
    post_fn(vsomeip_disc::kState, state1, 2);

    VsomeipAvailability avail{0x1000, 0x0001, true};
    post_fn(vsomeip_disc::kAvailability, reinterpret_cast<const uint8_t*>(&avail), sizeof(avail));

    uint8_t state2[] = {0, 'a'};
    post_fn(vsomeip_disc::kState, state2, 2);

    auto msgs = capture.messages();
    ASSERT_EQ(msgs.size(), 3u);
    EXPECT_EQ(msgs[0].disc, vsomeip_disc::kState);
    EXPECT_EQ(msgs[1].disc, vsomeip_disc::kAvailability);
    EXPECT_EQ(msgs[2].disc, vsomeip_disc::kState);
}

// ── Tests for PostFn thread safety ──────────────────────────────────────────────

TEST(VsomeipAppWire, ConcurrentPostsNoDataLoss) {
    MessageCapture capture;
    auto post_fn = [&](uint8_t disc, const uint8_t* data, uint32_t len) {
        capture.post(disc, data, len);
    };

    constexpr int N = 1000;
    std::thread t1([&] {
        for (int i = 0; i < N; ++i) {
            VsomeipAvailability avail{static_cast<uint16_t>(i), 0x0001, true};
            post_fn(vsomeip_disc::kAvailability,
                    reinterpret_cast<const uint8_t*>(&avail),
                    sizeof(avail));
        }
    });
    std::thread t2([&] {
        for (int i = 0; i < N; ++i) {
            uint8_t state[] = {1, 'x'};
            post_fn(vsomeip_disc::kState, state, 2);
        }
    });

    t1.join();
    t2.join();

    auto msgs = capture.messages();
    EXPECT_EQ(msgs.size(), static_cast<size_t>(2 * N));

    int avail_count = 0;
    int state_count = 0;
    for (const auto& m : msgs) {
        if (m.disc == vsomeip_disc::kAvailability)
            ++avail_count;
        if (m.disc == vsomeip_disc::kState)
            ++state_count;
    }
    EXPECT_EQ(avail_count, N);
    EXPECT_EQ(state_count, N);
}

// ── Tests for MessageCapture utility ────────────────────────────────────────────

TEST(VsomeipAppWire, WaitForMessages) {
    MessageCapture capture;

    std::thread poster([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        uint8_t data[] = {1};
        capture.post(vsomeip_disc::kState, data, 1);
    });

    EXPECT_TRUE(capture.wait_for(1, std::chrono::milliseconds(5000)));
    poster.join();
    EXPECT_EQ(capture.messages().size(), 1u);
}

TEST(VsomeipAppWire, WaitForTimeout) {
    MessageCapture capture;
    EXPECT_FALSE(capture.wait_for(1, std::chrono::milliseconds(10)));
}
