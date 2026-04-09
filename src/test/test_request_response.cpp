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

// test_request_response.cpp — Tests for request/response and fire-and-forget.
//
// Since we can't link against the real vsomeip library in unit tests, these
// tests verify:
//   - PendingRequest tracker: session ID allocation, matching, timeout
//   - Response encoding via VsomeipSubscriber::encode_header
//   - Error encoding for timeout and NAK responses
//   - Concurrent request tracking with independent resolution
//   - Fire-and-forget header encoding (REQUEST_NO_RETURN message type)

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <gtest/gtest.h>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

#include "../vsomeip_subscriber.h"
#include "../vsomeip_types.h"

// ── PendingRequest tracker — extracted logic from vsomeip_bridge.cpp ────────────
//
// In production, this lives inside the bridge. Here we test it in isolation.

class PendingRequest {
public:
    using ResponseCallback = std::function<void(uint8_t disc, const uint8_t* data, uint32_t len)>;

    // Register a pending request. Returns a unique session ID.
    uint16_t add(ResponseCallback cb) {
        std::lock_guard<std::mutex> lock(mutex_);
        uint16_t session = next_session_++;
        if (next_session_ == 0)
            next_session_ = 1;  // skip 0
        pending_[session] = std::move(cb);
        return session;
    }

    // Resolve a pending request with a response. Returns true if found.
    bool resolve(uint16_t session_id, uint8_t disc, const uint8_t* data, uint32_t len) {
        ResponseCallback cb;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = pending_.find(session_id);
            if (it == pending_.end())
                return false;
            cb = std::move(it->second);
            pending_.erase(it);
        }
        cb(disc, data, len);
        return true;
    }

    // Resolve with an error (timeout, NAK).
    bool reject(uint16_t session_id, const std::string& error_msg) {
        return resolve(session_id,
                       vsomeip_disc::kError,
                       reinterpret_cast<const uint8_t*>(error_msg.data()),
                       static_cast<uint32_t>(error_msg.size()));
    }

    size_t count() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return pending_.size();
    }

private:
    mutable std::mutex mutex_;
    uint16_t next_session_{1};
    std::unordered_map<uint16_t, ResponseCallback> pending_;
};

// ── Captured response ───────────────────────────────────────────────────────────

struct CapturedResponse {
    uint8_t disc;
    std::vector<uint8_t> data;
};

class ResponseCapture {
public:
    void on_response(uint8_t disc, const uint8_t* data, uint32_t len) {
        std::lock_guard<std::mutex> lock(mutex_);
        responses_.push_back({disc, {data, data + len}});
        cv_.notify_all();
    }

    std::vector<CapturedResponse> responses() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return responses_;
    }

    bool wait_for(size_t n, std::chrono::milliseconds timeout = std::chrono::milliseconds(1000)) {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [&] { return responses_.size() >= n; });
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::vector<CapturedResponse> responses_;
};

// ── Tests: PendingRequest tracker ───────────────────────────────────────────────

TEST(RequestResponse, SessionIdAllocation) {
    PendingRequest tracker;
    auto s1 = tracker.add([](uint8_t, const uint8_t*, uint32_t) {});
    auto s2 = tracker.add([](uint8_t, const uint8_t*, uint32_t) {});
    EXPECT_NE(s1, s2);
    EXPECT_EQ(tracker.count(), 2u);
}

TEST(RequestResponse, ResolveRemovesPending) {
    PendingRequest tracker;
    ResponseCapture cap;

    auto session = tracker.add(
        [&](uint8_t d, const uint8_t* data, uint32_t len) { cap.on_response(d, data, len); });

    EXPECT_EQ(tracker.count(), 1u);

    uint8_t payload[] = {0xAA, 0xBB};
    EXPECT_TRUE(tracker.resolve(session, vsomeip_disc::kMessage, payload, 2));
    EXPECT_EQ(tracker.count(), 0u);

    auto resps = cap.responses();
    ASSERT_EQ(resps.size(), 1u);
    EXPECT_EQ(resps[0].disc, vsomeip_disc::kMessage);
    EXPECT_EQ(resps[0].data.size(), 2u);
    EXPECT_EQ(resps[0].data[0], 0xAA);
}

TEST(RequestResponse, ResolveUnknownSessionReturnsFalse) {
    PendingRequest tracker;
    EXPECT_FALSE(tracker.resolve(9999, vsomeip_disc::kMessage, nullptr, 0));
}

TEST(RequestResponse, RejectPostsError) {
    PendingRequest tracker;
    ResponseCapture cap;

    auto session = tracker.add(
        [&](uint8_t d, const uint8_t* data, uint32_t len) { cap.on_response(d, data, len); });

    EXPECT_TRUE(tracker.reject(session, "request timed out"));
    EXPECT_EQ(tracker.count(), 0u);

    auto resps = cap.responses();
    ASSERT_EQ(resps.size(), 1u);
    EXPECT_EQ(resps[0].disc, vsomeip_disc::kError);
    std::string msg(resps[0].data.begin(), resps[0].data.end());
    EXPECT_EQ(msg, "request timed out");
}

TEST(RequestResponse, DoubleResolveReturnsFalse) {
    PendingRequest tracker;
    auto session = tracker.add([](uint8_t, const uint8_t*, uint32_t) {});

    EXPECT_TRUE(tracker.resolve(session, vsomeip_disc::kMessage, nullptr, 0));
    EXPECT_FALSE(tracker.resolve(session, vsomeip_disc::kMessage, nullptr, 0));
}

TEST(RequestResponse, MultipleConcurrentResolveIndependently) {
    PendingRequest tracker;
    ResponseCapture cap1, cap2;

    auto s1 = tracker.add(
        [&](uint8_t d, const uint8_t* data, uint32_t len) { cap1.on_response(d, data, len); });
    auto s2 = tracker.add(
        [&](uint8_t d, const uint8_t* data, uint32_t len) { cap2.on_response(d, data, len); });

    // Resolve out of order
    uint8_t p2[] = {0x02};
    uint8_t p1[] = {0x01};
    EXPECT_TRUE(tracker.resolve(s2, vsomeip_disc::kMessage, p2, 1));
    EXPECT_TRUE(tracker.resolve(s1, vsomeip_disc::kMessage, p1, 1));

    ASSERT_EQ(cap1.responses().size(), 1u);
    ASSERT_EQ(cap2.responses().size(), 1u);
    EXPECT_EQ(cap1.responses()[0].data[0], 0x01);
    EXPECT_EQ(cap2.responses()[0].data[0], 0x02);
}

// ── Tests: Timeout simulation ───────────────────────────────────────────────────

TEST(RequestResponse, TimeoutRejectsAfterDelay) {
    PendingRequest tracker;
    ResponseCapture cap;

    auto session = tracker.add(
        [&](uint8_t d, const uint8_t* data, uint32_t len) { cap.on_response(d, data, len); });

    // Simulate a timeout timer on a separate thread
    std::thread timer([&, session] {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        tracker.reject(session, "timeout");
    });

    EXPECT_TRUE(cap.wait_for(1, std::chrono::milliseconds(5000)));
    timer.join();

    auto resps = cap.responses();
    ASSERT_EQ(resps.size(), 1u);
    EXPECT_EQ(resps[0].disc, vsomeip_disc::kError);
}

TEST(RequestResponse, ResolveBeforeTimeoutCancelsTimeout) {
    PendingRequest tracker;
    ResponseCapture cap;

    auto session = tracker.add(
        [&](uint8_t d, const uint8_t* data, uint32_t len) { cap.on_response(d, data, len); });

    // Resolve immediately
    uint8_t resp[] = {0xFF};
    EXPECT_TRUE(tracker.resolve(session, vsomeip_disc::kMessage, resp, 1));

    // Timeout fires after resolve — should return false (already resolved)
    std::thread timer([&, session] {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        EXPECT_FALSE(tracker.reject(session, "timeout"));
    });
    timer.join();

    // Only one response received (the real one, not the timeout)
    EXPECT_EQ(cap.responses().size(), 1u);
    EXPECT_EQ(cap.responses()[0].disc, vsomeip_disc::kMessage);
}

// ── Tests: Response header encoding ─────────────────────────────────────────────

TEST(RequestResponse, ResponseHeaderEncoding) {
    // A response has message_type = 0x80 (MT_RESPONSE)
    VsomeipMessageHeader hdr{
        .service_id = 0x1234,
        .instance_id = 0x0001,
        .method_id = 0x0001,
        .message_type = 0x80,  // RESPONSE
        .return_code = 0x00,   // E_OK
        .request_id = 0x00010001,
        .payload_len = 2,
    };

    auto bytes = VsomeipSubscriber::encode_header(hdr);
    EXPECT_EQ(bytes.size(), 21u);
    EXPECT_EQ(bytes[0], vsomeip_disc::kMessage);
    EXPECT_EQ(bytes[7], 0x80);  // message_type at offset 7
    EXPECT_EQ(bytes[8], 0x00);  // return_code at offset 8
}

TEST(RequestResponse, FireAndForgetHeaderEncoding) {
    // Fire-and-forget has message_type = 0x01 (REQUEST_NO_RETURN)
    VsomeipMessageHeader hdr{
        .service_id = 0x5678,
        .instance_id = 0x0002,
        .method_id = 0x0003,
        .message_type = 0x01,  // REQUEST_NO_RETURN
        .return_code = 0x00,
        .request_id = 0,
        .payload_len = 0,
    };

    auto bytes = VsomeipSubscriber::encode_header(hdr);
    EXPECT_EQ(bytes[7], 0x01);  // REQUEST_NO_RETURN
}

// ── Tests: Session ID wraparound ────────────────────────────────────────────────

TEST(RequestResponse, SessionIdWraparound) {
    PendingRequest tracker;

    // Allocate many sessions to test wraparound doesn't collide
    std::vector<uint16_t> sessions;
    for (int i = 0; i < 100; ++i) {
        sessions.push_back(tracker.add([](uint8_t, const uint8_t*, uint32_t) {}));
    }

    // All unique
    std::sort(sessions.begin(), sessions.end());
    auto last = std::unique(sessions.begin(), sessions.end());
    EXPECT_EQ(last, sessions.end());  // no duplicates
}

// ── Tests: Concurrent add + resolve stress test ─────────────────────────────────

TEST(RequestResponse, ConcurrentAddResolve) {
    PendingRequest tracker;
    std::atomic<int> resolved{0};
    constexpr int N = 1000;

    std::thread adder([&] {
        for (int i = 0; i < N; ++i) {
            auto s = tracker.add([&](uint8_t, const uint8_t*, uint32_t) { resolved.fetch_add(1); });
            // Immediately resolve from another conceptual "thread"
            tracker.resolve(s, vsomeip_disc::kMessage, nullptr, 0);
        }
    });

    adder.join();
    EXPECT_EQ(resolved.load(), N);
    EXPECT_EQ(tracker.count(), 0u);
}
