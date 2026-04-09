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

#include <cstring>
#include <gtest/gtest.h>
#include <type_traits>

#include "../vsomeip_types.h"

// Verify all wire types are trivially copyable (required for ring buffer
// and zero-copy Dart_PostCObject_DL payloads).

TEST(VsomeipTypes, MessageHeaderIsTrivialCopy) {
    EXPECT_TRUE(std::is_trivially_copyable_v<VsomeipMessageHeader>);
}

TEST(VsomeipTypes, AvailabilityIsTrivialCopy) {
    EXPECT_TRUE(std::is_trivially_copyable_v<VsomeipAvailability>);
}

TEST(VsomeipTypes, SubscribeAckIsTrivialCopy) {
    EXPECT_TRUE(std::is_trivially_copyable_v<VsomeipSubscribeAck>);
}

TEST(VsomeipTypes, RingEntryIsTrivialCopy) {
    EXPECT_TRUE(std::is_trivially_copyable_v<SomeIpRingEntry>);
}

// VsomeipState and VsomeipError contain std::string — NOT trivially copyable.
// They are serialised via Glaze, not placed in the ring buffer.
TEST(VsomeipTypes, StateIsNotTrivialCopy) {
    EXPECT_FALSE(std::is_trivially_copyable_v<VsomeipState>);
}

TEST(VsomeipTypes, ErrorIsNotTrivialCopy) {
    EXPECT_FALSE(std::is_trivially_copyable_v<VsomeipError>);
}

// Discriminator constants match the wire protocol spec.
TEST(VsomeipTypes, DiscriminatorValues) {
    EXPECT_EQ(vsomeip_disc::kMessage, 0x01);
    EXPECT_EQ(vsomeip_disc::kAvailability, 0x02);
    EXPECT_EQ(vsomeip_disc::kState, 0x03);
    EXPECT_EQ(vsomeip_disc::kSubscribeAck, 0x04);
    EXPECT_EQ(vsomeip_disc::kError, 0x05);
    EXPECT_EQ(vsomeip_disc::kBatch, 0x10);
    EXPECT_EQ(vsomeip_disc::kSentinel, 0xFF);
}

// Verify struct field layout via designated initialiser roundtrip.
TEST(VsomeipTypes, MessageHeaderFields) {
    VsomeipMessageHeader hdr{
        .service_id = 0x1234,
        .instance_id = 0x0001,
        .method_id = 0x8001,
        .message_type = 0x02,
        .return_code = 0x00,
        .request_id = 0xDEAD0000BEEF,
        .payload_len = 1024,
    };
    EXPECT_EQ(hdr.service_id, 0x1234);
    EXPECT_EQ(hdr.instance_id, 0x0001);
    EXPECT_EQ(hdr.method_id, 0x8001);
    EXPECT_EQ(hdr.message_type, 0x02);
    EXPECT_EQ(hdr.return_code, 0x00);
    EXPECT_EQ(hdr.request_id, 0xDEAD0000BEEF);
    EXPECT_EQ(hdr.payload_len, 1024u);
}

TEST(VsomeipTypes, AvailabilityFields) {
    VsomeipAvailability avail{
        .service_id = 0xABCD,
        .instance_id = 0x0002,
        .available = true,
    };
    EXPECT_EQ(avail.service_id, 0xABCD);
    EXPECT_EQ(avail.instance_id, 0x0002);
    EXPECT_TRUE(avail.available);
}

TEST(VsomeipTypes, SubscribeAckFields) {
    VsomeipSubscribeAck ack{
        .service_id = 0x1111,
        .instance_id = 0x2222,
        .eventgroup_id = 0x3333,
        .event_id = 0x4444,
        .error_code = 0,
    };
    EXPECT_EQ(ack.service_id, 0x1111);
    EXPECT_EQ(ack.instance_id, 0x2222);
    EXPECT_EQ(ack.eventgroup_id, 0x3333);
    EXPECT_EQ(ack.event_id, 0x4444);
    EXPECT_EQ(ack.error_code, 0);
}

TEST(VsomeipTypes, StateFields) {
    VsomeipState state{
        .registered = true,
        .app_name = "test_app",
    };
    EXPECT_TRUE(state.registered);
    EXPECT_EQ(state.app_name, "test_app");
}

TEST(VsomeipTypes, ErrorFields) {
    VsomeipError err{
        .source = "vsomeip_subscribe",
        .message = "service not found",
        .code = 42,
    };
    EXPECT_EQ(err.source, "vsomeip_subscribe");
    EXPECT_EQ(err.message, "service not found");
    EXPECT_EQ(err.code, 42u);
}

TEST(VsomeipTypes, RingEntryFields) {
    SomeIpRingEntry entry{
        .service_id = 0x0100,
        .instance_id = 0x0001,
        .method_id = 0x8001,
        .message_type = 0x02,
        .return_code = 0x00,
        .payload_len = 256,
    };
    EXPECT_EQ(entry.service_id, 0x0100);
    EXPECT_EQ(entry.instance_id, 0x0001);
    EXPECT_EQ(entry.method_id, 0x8001);
    EXPECT_EQ(entry.message_type, 0x02);
    EXPECT_EQ(entry.return_code, 0x00);
    EXPECT_EQ(entry.payload_len, 256u);
}

// Verify memcpy roundtrip for trivially-copyable types (simulates
// ring buffer and zero-copy transport).
TEST(VsomeipTypes, MessageHeaderMemcpyRoundtrip) {
    VsomeipMessageHeader src{
        .service_id = 0xFFFF,
        .instance_id = 0x0001,
        .method_id = 0x0002,
        .message_type = 0x80,
        .return_code = 0x01,
        .request_id = 0x123456789ABCDEF0,
        .payload_len = 65535,
    };
    VsomeipMessageHeader dst{};
    std::memcpy(&dst, &src, sizeof(VsomeipMessageHeader));
    EXPECT_EQ(dst.service_id, src.service_id);
    EXPECT_EQ(dst.instance_id, src.instance_id);
    EXPECT_EQ(dst.method_id, src.method_id);
    EXPECT_EQ(dst.message_type, src.message_type);
    EXPECT_EQ(dst.return_code, src.return_code);
    EXPECT_EQ(dst.request_id, src.request_id);
    EXPECT_EQ(dst.payload_len, src.payload_len);
}
