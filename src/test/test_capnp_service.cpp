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

// test_capnp_service.cpp — Tests for Cap'n Proto zero-copy send path.
//
// Covers:
//   - Correct payload size from sizeInWords
//   - Direct write: no intermediate allocation (fields at correct offsets)
//   - Field values round-trip (write → read)
//   - Builder overflow protection
//   - All three schema builders (VehicleSpeed, RadarObject, ImuData)

#include <cmath>
#include <cstring>
#include <gtest/gtest.h>

#include "../capnp_service.h"

// ── Helper: read LE values from buffer ──────────────────────────────────────

static float read_float32(const uint8_t* p) {
    float v;
    std::memcpy(&v, p, sizeof(float));
    return v;
}

static double read_float64(const uint8_t* p) {
    double v;
    std::memcpy(&v, p, sizeof(double));
    return v;
}

static uint16_t read_uint16(const uint8_t* p) {
    uint16_t v;
    std::memcpy(&v, p, sizeof(uint16_t));
    return v;
}

static uint64_t read_uint64(const uint8_t* p) {
    uint64_t v;
    std::memcpy(&v, p, sizeof(uint64_t));
    return v;
}

// ── CapnpPayloadBuilder tests ───────────────────────────────────────────────

TEST(CapnpService, BuilderInitializesZero) {
    CapnpPayloadBuilder builder(16);
    for (size_t i = 0; i < builder.size(); ++i) {
        EXPECT_EQ(builder.data()[i], 0);
    }
}

TEST(CapnpService, BuilderSizeInWords) {
    EXPECT_EQ(CapnpPayloadBuilder(8).size_in_words(), 1u);
    EXPECT_EQ(CapnpPayloadBuilder(16).size_in_words(), 2u);
    EXPECT_EQ(CapnpPayloadBuilder(9).size_in_words(), 2u);  // rounds up
    EXPECT_EQ(CapnpPayloadBuilder(1).size_in_words(), 1u);
}

TEST(CapnpService, BuilderSetFloat32) {
    CapnpPayloadBuilder builder(8);
    builder.set_float32(0, 3.14f);
    EXPECT_FLOAT_EQ(read_float32(builder.data()), 3.14f);
}

TEST(CapnpService, BuilderSetFloat64) {
    CapnpPayloadBuilder builder(16);
    builder.set_float64(0, 2.71828);
    EXPECT_DOUBLE_EQ(read_float64(builder.data()), 2.71828);
}

TEST(CapnpService, BuilderSetUint16) {
    CapnpPayloadBuilder builder(8);
    builder.set_uint16(0, 0xABCD);
    EXPECT_EQ(read_uint16(builder.data()), 0xABCD);
}

TEST(CapnpService, BuilderSetUint64) {
    CapnpPayloadBuilder builder(16);
    builder.set_uint64(0, 0x123456789ABCDEF0);
    EXPECT_EQ(read_uint64(builder.data()), 0x123456789ABCDEF0);
}

TEST(CapnpService, BuilderOverflowProtection) {
    CapnpPayloadBuilder builder(4);
    // Writing beyond capacity should be silently ignored
    builder.set_uint64(0, 0xDEADBEEF);  // needs 8 bytes, only 4 available
    // Buffer should remain zero (write was skipped)
    EXPECT_EQ(builder.data()[0], 0);
}

TEST(CapnpService, BuilderTakeMovesOwnership) {
    CapnpPayloadBuilder builder(8);
    builder.set_uint8(0, 0xFF);
    auto buf = builder.take();
    EXPECT_EQ(buf.size(), 8u);
    EXPECT_EQ(buf[0], 0xFF);
    // After take(), builder's buffer is moved
    EXPECT_EQ(builder.size(), 0u);
}

// ── VehicleSpeed builder tests ──────────────────────────────────────────────

TEST(CapnpService, VehicleSpeedCorrectSize) {
    auto buf = capnp_build_vehicle_speed(0.0f, 0, 0);
    EXPECT_EQ(buf.size(), 16u);  // 2 Cap'n Proto words
}

TEST(CapnpService, VehicleSpeedFieldRoundtrip) {
    auto buf = capnp_build_vehicle_speed(120.5f, 1234567890ULL, 42, 1);

    EXPECT_FLOAT_EQ(read_float32(buf.data() + 0), 120.5f);
    EXPECT_EQ(read_uint64(buf.data() + 4), 1234567890ULL);
    EXPECT_EQ(read_uint16(buf.data() + 12), 42);
    EXPECT_EQ(buf[14], 1);  // qualityFlag
    EXPECT_EQ(buf[15], 0);  // reserved
}

TEST(CapnpService, VehicleSpeedDefaultQualityFlag) {
    auto buf = capnp_build_vehicle_speed(0.0f, 0, 0);
    EXPECT_EQ(buf[14], 0);  // default quality flag
}

// ── RadarObject builder tests ───────────────────────────────────────────────

TEST(CapnpService, RadarObjectCorrectSize) {
    auto buf = capnp_build_radar_object(0, 0, 0, 0, 0, 0);
    EXPECT_EQ(buf.size(), 40u);  // 5 Cap'n Proto words
}

TEST(CapnpService, RadarObjectFieldRoundtrip) {
    auto buf = capnp_build_radar_object(100, 25.5f, -3.2f, 15.0f, -10.5f, 9999ULL, 1);

    EXPECT_EQ(read_uint16(buf.data() + 0), 100);
    EXPECT_FLOAT_EQ(read_float32(buf.data() + 4), 25.5f);
    EXPECT_FLOAT_EQ(read_float32(buf.data() + 8), -3.2f);
    EXPECT_FLOAT_EQ(read_float32(buf.data() + 12), 15.0f);
    EXPECT_FLOAT_EQ(read_float32(buf.data() + 16), -10.5f);
    EXPECT_EQ(read_uint64(buf.data() + 24), 9999ULL);
    EXPECT_EQ(buf[32], 1);  // classification = car
}

// ── ImuData builder tests ───────────────────────────────────────────────────

TEST(CapnpService, ImuDataCorrectSize) {
    auto buf = capnp_build_imu_data(0, 0, 0, 0, 0, 0, 0);
    EXPECT_EQ(buf.size(), 40u);  // 5 Cap'n Proto words
}

TEST(CapnpService, ImuDataFieldRoundtrip) {
    auto buf = capnp_build_imu_data(1.0f, -2.0f, 9.8f, 0.01f, -0.02f, 0.03f, 5555ULL, 7);

    EXPECT_FLOAT_EQ(read_float32(buf.data() + 0), 1.0f);
    EXPECT_FLOAT_EQ(read_float32(buf.data() + 4), -2.0f);
    EXPECT_FLOAT_EQ(read_float32(buf.data() + 8), 9.8f);
    EXPECT_FLOAT_EQ(read_float32(buf.data() + 12), 0.01f);
    EXPECT_FLOAT_EQ(read_float32(buf.data() + 16), -0.02f);
    EXPECT_FLOAT_EQ(read_float32(buf.data() + 20), 0.03f);
    EXPECT_EQ(read_uint64(buf.data() + 24), 5555ULL);
    EXPECT_EQ(read_uint16(buf.data() + 32), 7);
}

// ── Cross-builder: write → read roundtrip via generated reader layout ───────

TEST(CapnpService, VehicleSpeedWriteReadRoundtrip) {
    // Build
    auto buf = capnp_build_vehicle_speed(87.3f, 1000000ULL, 0x0001, 0);
    // Read back at same offsets (matching VehicleSpeedReader layout)
    EXPECT_FLOAT_EQ(read_float32(buf.data() + 0), 87.3f);
    EXPECT_EQ(read_uint64(buf.data() + 4), 1000000ULL);
    EXPECT_EQ(read_uint16(buf.data() + 12), 0x0001);
}
