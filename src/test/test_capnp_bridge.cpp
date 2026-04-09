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

// test_capnp_bridge.cpp — Tests for Cap'n Proto alignment guard.

#include <cstdint>
#include <cstring>
#include <gtest/gtest.h>

#include "../capnp_bridge.h"

TEST(CapnpBridge, AlignedPointerDetected) {
    alignas(8) uint8_t buf[64] = {};
    EXPECT_TRUE(is_capnp_aligned(buf));
}

TEST(CapnpBridge, MisalignedPointerDetected) {
    alignas(8) uint8_t buf[64] = {};
    // Offset by 1 byte to create misalignment
    EXPECT_FALSE(is_capnp_aligned(buf + 1));
    EXPECT_FALSE(is_capnp_aligned(buf + 3));
    EXPECT_FALSE(is_capnp_aligned(buf + 5));
}

TEST(CapnpBridge, NullPointerIsAligned) {
    // nullptr is technically 0, which is 8-byte aligned
    EXPECT_TRUE(is_capnp_aligned(nullptr));
}

TEST(CapnpBridge, AlignCopyPreservesData) {
    const uint8_t src[] = {0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02};
    auto* dst = capnp_align_copy(src, sizeof(src));

    ASSERT_NE(dst, nullptr);
    EXPECT_TRUE(is_capnp_aligned(dst));
    EXPECT_EQ(std::memcmp(dst, src, sizeof(src)), 0);

    delete[] dst;
}

TEST(CapnpBridge, AlignCopyPadsToWordBoundary) {
    // 6 bytes → should be padded to 8 bytes (1 Cap'n Proto word)
    const uint8_t src[] = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06};
    auto* dst = capnp_align_copy(src, sizeof(src));

    ASSERT_NE(dst, nullptr);
    // Padding bytes should be zero
    EXPECT_EQ(dst[6], 0);
    EXPECT_EQ(dst[7], 0);

    delete[] dst;
}

TEST(CapnpBridge, AlignCopyExactWordSize) {
    // Exactly 8 bytes — no padding needed
    const uint8_t src[8] = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08};
    auto* dst = capnp_align_copy(src, sizeof(src));

    ASSERT_NE(dst, nullptr);
    EXPECT_EQ(std::memcmp(dst, src, sizeof(src)), 0);

    delete[] dst;
}

TEST(CapnpBridge, AlignCopyLargeBuffer) {
    // 1 MB buffer
    const size_t len = 1024 * 1024;
    auto* src = new uint8_t[len];
    std::memset(src, 0xAB, len);

    auto* dst = capnp_align_copy(src, len);

    ASSERT_NE(dst, nullptr);
    EXPECT_TRUE(is_capnp_aligned(dst));
    EXPECT_EQ(std::memcmp(dst, src, len), 0);

    delete[] src;
    delete[] dst;
}

TEST(CapnpBridge, WordSizeConstant) {
    EXPECT_EQ(kCapnpWordSize, 8u);
}

TEST(CapnpBridge, SchemaEntryFields) {
    CapnpSchemaEntry entry{0x0001, "vehicle_speed"};
    EXPECT_EQ(entry.schema_id, 0x0001u);
    EXPECT_STREQ(entry.schema_name, "vehicle_speed");
}
