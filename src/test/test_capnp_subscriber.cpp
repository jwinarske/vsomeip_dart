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

// test_capnp_subscriber.cpp — Tests for Cap'n Proto receive paths.
//
// Covers:
//   - Path A aligned: header + payload posted, was_aligned = true
//   - Path A misaligned: alignment copy triggered, was_aligned = false
//   - Empty payload: header-only delivery
//   - Header encoding includes schema_id (25 bytes)
//   - Schema_id roundtrip in header
//   - Selective decoder: registered handler called
//   - Selective decoder: unregistered schema returns empty
//   - Selective decoder: empty payload returns empty

#include "../capnp_subscriber.h"
#include "../vsomeip_types.h"

#include <gtest/gtest.h>
#include <cstring>
#include <mutex>
#include <vector>

// ── Captured post data ──────────────────────────────────────────────────────

struct CapnpPostedMessage {
    std::vector<uint8_t> header;
    std::vector<uint8_t> payload;
    bool was_aligned;
};

class CapnpPostCapture {
public:
    void post(const uint8_t* hdr, uint32_t hdr_len,
              const uint8_t* payload, uint32_t payload_len,
              bool was_aligned) {
        std::lock_guard<std::mutex> lock(mutex_);
        CapnpPostedMessage msg;
        msg.header.assign(hdr, hdr + hdr_len);
        if (payload && payload_len > 0) {
            msg.payload.assign(payload, payload + payload_len);
        }
        msg.was_aligned = was_aligned;
        messages_.push_back(std::move(msg));
    }

    std::vector<CapnpPostedMessage> messages() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return messages_;
    }

private:
    mutable std::mutex mutex_;
    std::vector<CapnpPostedMessage> messages_;
};

// ── Helper: decode schema_id from capnp header bytes ────────────────────────

static uint32_t read_schema_id(const std::vector<uint8_t>& hdr) {
    // schema_id is at bytes [21..24] (after the standard 21-byte header)
    EXPECT_GE(hdr.size(), 25u);
    return static_cast<uint32_t>(hdr[21]) |
           (static_cast<uint32_t>(hdr[22]) << 8) |
           (static_cast<uint32_t>(hdr[23]) << 16) |
           (static_cast<uint32_t>(hdr[24]) << 24);
}

// ── Path A: aligned payload ─────────────────────────────────────────────────

TEST(CapnpSubscriber, PathA_AlignedPayloadPostsRawBytes) {
    CapnpPostCapture capture;
    CapnpSubscriber sub(0x0001, [&](const uint8_t* h, uint32_t hl,
                                    const uint8_t* p, uint32_t pl,
                                    bool aligned) {
        capture.post(h, hl, p, pl, aligned);
    });

    // Create an 8-byte aligned payload
    alignas(8) uint8_t payload[16] = {
        0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C,
    };

    sub.on_message(0x1234, 0x0001, 0x8001, 0x02, 0x00,
                   0x00, 0x01, payload, 16);

    auto msgs = capture.messages();
    ASSERT_EQ(msgs.size(), 1u);
    EXPECT_TRUE(msgs[0].was_aligned);
    EXPECT_EQ(msgs[0].payload.size(), 16u);
    EXPECT_EQ(msgs[0].payload[0], 0xDE);
    EXPECT_EQ(msgs[0].payload[15], 0x0C);
}

// ── Path A: misaligned payload ──────────────────────────────────────────────

TEST(CapnpSubscriber, PathA_MisalignedPayloadCopiesAndPosts) {
    CapnpPostCapture capture;
    CapnpSubscriber sub(0x0001, [&](const uint8_t* h, uint32_t hl,
                                    const uint8_t* p, uint32_t pl,
                                    bool aligned) {
        capture.post(h, hl, p, pl, aligned);
    });

    // Create a misaligned payload (offset by 1 from 8-byte boundary)
    alignas(8) uint8_t buf[17] = {};
    uint8_t* misaligned = buf + 1;  // guaranteed misaligned
    misaligned[0] = 0xAA;
    misaligned[1] = 0xBB;

    sub.on_message(0x1234, 0x0001, 0x8001, 0x02, 0x00,
                   0x00, 0x01, misaligned, 8);

    auto msgs = capture.messages();
    ASSERT_EQ(msgs.size(), 1u);
    EXPECT_FALSE(msgs[0].was_aligned);
    EXPECT_EQ(msgs[0].payload.size(), 8u);
    EXPECT_EQ(msgs[0].payload[0], 0xAA);
    EXPECT_EQ(msgs[0].payload[1], 0xBB);
}

// ── Empty payload ───────────────────────────────────────────────────────────

TEST(CapnpSubscriber, EmptyPayloadPostsHeaderOnly) {
    CapnpPostCapture capture;
    CapnpSubscriber sub(0x0002, [&](const uint8_t* h, uint32_t hl,
                                    const uint8_t* p, uint32_t pl,
                                    bool aligned) {
        capture.post(h, hl, p, pl, aligned);
    });

    sub.on_message(0x1234, 0x0001, 0x8001, 0x02, 0x00,
                   0x00, 0x01, nullptr, 0);

    auto msgs = capture.messages();
    ASSERT_EQ(msgs.size(), 1u);
    EXPECT_TRUE(msgs[0].payload.empty());
    EXPECT_TRUE(msgs[0].was_aligned);
}

// ── Header encoding ─────────────────────────────────────────────────────────

TEST(CapnpSubscriber, HeaderEncodingIncludes25Bytes) {
    VsomeipMessageHeader hdr{
        .service_id = 0x1234, .instance_id = 0x0001,
        .method_id = 0x8001, .message_type = 0x02,
        .return_code = 0x00,
        .request_id = 0x12345678, .payload_len = 100,
    };

    auto bytes = CapnpSubscriber::encode_capnp_header(hdr, 0x0001);
    EXPECT_EQ(bytes.size(), 25u);
    EXPECT_EQ(bytes[0], vsomeip_disc::kMessage);
}

TEST(CapnpSubscriber, SchemaIdRoundtripInHeader) {
    VsomeipMessageHeader hdr{};
    auto bytes = CapnpSubscriber::encode_capnp_header(hdr, 0xDEADBEEF);
    EXPECT_EQ(read_schema_id(bytes), 0xDEADBEEF);
}

TEST(CapnpSubscriber, SchemaIdZero) {
    VsomeipMessageHeader hdr{};
    auto bytes = CapnpSubscriber::encode_capnp_header(hdr, 0x0000);
    EXPECT_EQ(read_schema_id(bytes), 0u);
}

TEST(CapnpSubscriber, SchemaIdAccessor) {
    CapnpSubscriber sub(0x0042, [](const uint8_t*, uint32_t,
                                   const uint8_t*, uint32_t, bool) {});
    EXPECT_EQ(sub.schema_id(), 0x0042u);
}

// ── Selective decoder (Path B) ──────────────────────────────────────────────

TEST(CapnpSelectiveDecoder, RegisteredHandlerIsCalled) {
    CapnpSelectiveDecoder decoder;

    decoder.register_schema(0x0001, [](const uint8_t* data, uint32_t len) {
        // Simulate extracting just the first 4 bytes (speed field)
        std::vector<uint8_t> result(data, data + std::min(len, 4u));
        return result;
    });

    uint8_t payload[] = {0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02};
    auto result = decoder.decode(0x0001, payload, 6);

    ASSERT_EQ(result.size(), 4u);
    EXPECT_EQ(result[0], 0xDE);
    EXPECT_EQ(result[3], 0xEF);
}

TEST(CapnpSelectiveDecoder, UnregisteredSchemaReturnsEmpty) {
    CapnpSelectiveDecoder decoder;

    uint8_t payload[] = {0x01, 0x02};
    auto result = decoder.decode(0x9999, payload, 2);
    EXPECT_TRUE(result.empty());
}

TEST(CapnpSelectiveDecoder, EmptyPayloadReturnsEmpty) {
    CapnpSelectiveDecoder decoder;
    decoder.register_schema(0x0001, [](const uint8_t*, uint32_t) {
        return std::vector<uint8_t>{0xFF};
    });

    auto result = decoder.decode(0x0001, nullptr, 0);
    EXPECT_TRUE(result.empty());
}

TEST(CapnpSelectiveDecoder, HasSchema) {
    CapnpSelectiveDecoder decoder;
    EXPECT_FALSE(decoder.has_schema(0x0001));

    decoder.register_schema(0x0001, [](const uint8_t*, uint32_t) {
        return std::vector<uint8_t>{};
    });
    EXPECT_TRUE(decoder.has_schema(0x0001));
}

TEST(CapnpSelectiveDecoder, MultipleSchemas) {
    CapnpSelectiveDecoder decoder;
    decoder.register_schema(0x0001, [](const uint8_t*, uint32_t) {
        return std::vector<uint8_t>{0x01};
    });
    decoder.register_schema(0x0002, [](const uint8_t*, uint32_t) {
        return std::vector<uint8_t>{0x02};
    });

    uint8_t payload[] = {0xFF};
    EXPECT_EQ(decoder.decode(0x0001, payload, 1)[0], 0x01);
    EXPECT_EQ(decoder.decode(0x0002, payload, 1)[0], 0x02);
}
