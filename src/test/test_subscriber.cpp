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

// test_subscriber.cpp — Tests for VsomeipSubscriber on_message hot path.
//
// Covers:
//   - Header encoding with discriminator prefix
//   - All header fields roundtrip correctly
//   - Zero-length payload posts nullptr
//   - Non-zero payload data is forwarded
//   - Large payload (1 MB)
//   - Rapid-fire 10k messages with no drops
//   - Request ID encoding (client_id << 16 | session_id)

#include <cstring>
#include <gtest/gtest.h>
#include <mutex>
#include <vector>

#include "../vsomeip_subscriber.h"
#include "../vsomeip_types.h"

// ── Captured post data ──────────────────────────────────────────────────────────

struct PostedMessage {
    std::vector<uint8_t> header;
    std::vector<uint8_t> payload;
};

class PostCapture {
public:
    void post(const uint8_t* hdr, uint32_t hdr_len, const uint8_t* payload, uint32_t payload_len) {
        std::lock_guard<std::mutex> lock(mutex_);
        PostedMessage msg;
        msg.header.assign(hdr, hdr + hdr_len);
        if (payload && payload_len > 0) {
            msg.payload.assign(payload, payload + payload_len);
        }
        messages_.push_back(std::move(msg));
    }

    std::vector<PostedMessage> messages() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return messages_;
    }

    size_t count() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return messages_.size();
    }

private:
    mutable std::mutex mutex_;
    std::vector<PostedMessage> messages_;
};

// ── Helper: decode header from wire bytes ───────────────────────────────────────

static uint16_t read_u16_le(const uint8_t* p) {
    return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

static uint32_t read_u32_le(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

static uint64_t read_u64_le(const uint8_t* p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) {
        v |= static_cast<uint64_t>(p[i]) << (i * 8);
    }
    return v;
}

static VsomeipMessageHeader decode_wire_header(const std::vector<uint8_t>& hdr) {
    // hdr[0] = discriminator (0x01)
    // hdr[1..2] = service_id, etc.
    EXPECT_GE(hdr.size(), 21u);
    EXPECT_EQ(hdr[0], vsomeip_disc::kMessage);

    VsomeipMessageHeader decoded{};
    decoded.service_id = read_u16_le(&hdr[1]);
    decoded.instance_id = read_u16_le(&hdr[3]);
    decoded.method_id = read_u16_le(&hdr[5]);
    decoded.message_type = hdr[7];
    decoded.return_code = hdr[8];
    decoded.request_id = read_u64_le(&hdr[9]);
    decoded.payload_len = read_u32_le(&hdr[17]);
    return decoded;
}

// ── Tests ───────────────────────────────────────────────────────────────────────

TEST(Subscriber, EncodeHeaderSize) {
    VsomeipMessageHeader hdr{};
    auto bytes = VsomeipSubscriber::encode_header(hdr);
    EXPECT_EQ(bytes.size(), 21u);
    EXPECT_EQ(bytes[0], vsomeip_disc::kMessage);
}

TEST(Subscriber, EncodeHeaderFieldsRoundtrip) {
    VsomeipMessageHeader hdr{
        .service_id = 0xAAAA,
        .instance_id = 0xBBBB,
        .method_id = 0xCCCC,
        .message_type = 0x80,
        .return_code = 0x01,
        .request_id = 0x123456789ABCDEF0,
        .payload_len = 65535,
    };
    auto bytes = VsomeipSubscriber::encode_header(hdr);
    auto decoded = decode_wire_header(bytes);

    EXPECT_EQ(decoded.service_id, 0xAAAA);
    EXPECT_EQ(decoded.instance_id, 0xBBBB);
    EXPECT_EQ(decoded.method_id, 0xCCCC);
    EXPECT_EQ(decoded.message_type, 0x80);
    EXPECT_EQ(decoded.return_code, 0x01);
    EXPECT_EQ(decoded.request_id, 0x123456789ABCDEF0);
    EXPECT_EQ(decoded.payload_len, 65535u);
}

TEST(Subscriber, ZeroLengthPayloadPostsNullPayload) {
    PostCapture capture;
    VsomeipSubscriber sub([&](const uint8_t* h, uint32_t hl, const uint8_t* p, uint32_t pl) {
        capture.post(h, hl, p, pl);
    });

    sub.on_message(0x1234, 0x0001, 0x0001, 0x02, 0x00, 0x00, 0x01, nullptr, 0);

    auto msgs = capture.messages();
    ASSERT_EQ(msgs.size(), 1u);
    EXPECT_TRUE(msgs[0].payload.empty());

    auto decoded = decode_wire_header(msgs[0].header);
    EXPECT_EQ(decoded.service_id, 0x1234);
    EXPECT_EQ(decoded.payload_len, 0u);
}

TEST(Subscriber, NonZeroPayloadIsForwarded) {
    PostCapture capture;
    VsomeipSubscriber sub([&](const uint8_t* h, uint32_t hl, const uint8_t* p, uint32_t pl) {
        capture.post(h, hl, p, pl);
    });

    const uint8_t payload[] = {0xDE, 0xAD, 0xBE, 0xEF};
    sub.on_message(0x1234, 0x0001, 0x0001, 0x02, 0x00, 0x00, 0x01, payload, 4);

    auto msgs = capture.messages();
    ASSERT_EQ(msgs.size(), 1u);
    ASSERT_EQ(msgs[0].payload.size(), 4u);
    EXPECT_EQ(msgs[0].payload[0], 0xDE);
    EXPECT_EQ(msgs[0].payload[1], 0xAD);
    EXPECT_EQ(msgs[0].payload[2], 0xBE);
    EXPECT_EQ(msgs[0].payload[3], 0xEF);
}

TEST(Subscriber, RequestIdEncoding) {
    PostCapture capture;
    VsomeipSubscriber sub([&](const uint8_t* h, uint32_t hl, const uint8_t* p, uint32_t pl) {
        capture.post(h, hl, p, pl);
    });

    // client_id = 0x1234, session_id = 0x5678
    // request_id = (0x1234 << 16) | 0x5678 = 0x12345678
    sub.on_message(0x0100, 0x0001, 0x8001, 0x00, 0x00, 0x1234, 0x5678, nullptr, 0);

    auto msgs = capture.messages();
    auto decoded = decode_wire_header(msgs[0].header);
    EXPECT_EQ(decoded.request_id, 0x12345678u);
}

TEST(Subscriber, AllHeaderFieldsFromOnMessage) {
    PostCapture capture;
    VsomeipSubscriber sub([&](const uint8_t* h, uint32_t hl, const uint8_t* p, uint32_t pl) {
        capture.post(h, hl, p, pl);
    });

    const uint8_t payload[] = {0x01, 0x02};
    sub.on_message(0xFFFF, 0x0002, 0x8001, 0x80, 0x03, 0xABCD, 0xEF01, payload, 2);

    auto msgs = capture.messages();
    auto decoded = decode_wire_header(msgs[0].header);
    EXPECT_EQ(decoded.service_id, 0xFFFF);
    EXPECT_EQ(decoded.instance_id, 0x0002);
    EXPECT_EQ(decoded.method_id, 0x8001);
    EXPECT_EQ(decoded.message_type, 0x80);
    EXPECT_EQ(decoded.return_code, 0x03);
    EXPECT_EQ(decoded.request_id, (uint64_t(0xABCD) << 16) | 0xEF01);
    EXPECT_EQ(decoded.payload_len, 2u);
}

TEST(Subscriber, LargePayload1MB) {
    PostCapture capture;
    VsomeipSubscriber sub([&](const uint8_t* h, uint32_t hl, const uint8_t* p, uint32_t pl) {
        capture.post(h, hl, p, pl);
    });

    std::vector<uint8_t> big(1024 * 1024, 0xAB);
    sub.on_message(0x1234,
                   0x0001,
                   0x0001,
                   0x02,
                   0x00,
                   0x00,
                   0x01,
                   big.data(),
                   static_cast<uint32_t>(big.size()));

    auto msgs = capture.messages();
    ASSERT_EQ(msgs.size(), 1u);
    EXPECT_EQ(msgs[0].payload.size(), big.size());
    EXPECT_EQ(msgs[0].payload[0], 0xAB);
    EXPECT_EQ(msgs[0].payload.back(), 0xAB);

    auto decoded = decode_wire_header(msgs[0].header);
    EXPECT_EQ(decoded.payload_len, static_cast<uint32_t>(big.size()));
}

TEST(Subscriber, RapidFire10kMessages) {
    PostCapture capture;
    VsomeipSubscriber sub([&](const uint8_t* h, uint32_t hl, const uint8_t* p, uint32_t pl) {
        capture.post(h, hl, p, pl);
    });

    constexpr int N = 10000;
    for (int i = 0; i < N; ++i) {
        uint8_t byte = static_cast<uint8_t>(i & 0xFF);
        sub.on_message(
            0x1234, 0x0001, 0x0001, 0x02, 0x00, 0x00, static_cast<uint16_t>(i & 0xFFFF), &byte, 1);
    }

    EXPECT_EQ(capture.count(), static_cast<size_t>(N));
}

TEST(Subscriber, DiscriminatorIsAlwaysMessage) {
    PostCapture capture;
    VsomeipSubscriber sub([&](const uint8_t* h, uint32_t hl, const uint8_t* p, uint32_t pl) {
        capture.post(h, hl, p, pl);
    });

    // Various message types should all use kMessage discriminator
    for (uint8_t mt : {0x00, 0x02, 0x80, 0x81}) {
        sub.on_message(0x0100, 0x0001, 0x0001, mt, 0x00, 0x00, 0x01, nullptr, 0);
    }

    auto msgs = capture.messages();
    ASSERT_EQ(msgs.size(), 4u);
    for (const auto& m : msgs) {
        EXPECT_EQ(m.header[0], vsomeip_disc::kMessage);
    }
}
