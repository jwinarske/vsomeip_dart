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

#include "capnp_service.h"

#include <cstring>

// ── CapnpPayloadBuilder ─────────────────────────────────────────────────────

CapnpPayloadBuilder::CapnpPayloadBuilder(size_t capacity)
    : buf_(capacity, 0) {}

void CapnpPayloadBuilder::set_float32(size_t offset, float value) {
    if (offset + sizeof(float) > buf_.size()) return;
    std::memcpy(buf_.data() + offset, &value, sizeof(float));
}

void CapnpPayloadBuilder::set_float64(size_t offset, double value) {
    if (offset + sizeof(double) > buf_.size()) return;
    std::memcpy(buf_.data() + offset, &value, sizeof(double));
}

void CapnpPayloadBuilder::set_uint8(size_t offset, uint8_t value) {
    if (offset >= buf_.size()) return;
    buf_[offset] = value;
}

void CapnpPayloadBuilder::set_uint16(size_t offset, uint16_t value) {
    if (offset + sizeof(uint16_t) > buf_.size()) return;
    std::memcpy(buf_.data() + offset, &value, sizeof(uint16_t));
}

void CapnpPayloadBuilder::set_uint32(size_t offset, uint32_t value) {
    if (offset + sizeof(uint32_t) > buf_.size()) return;
    std::memcpy(buf_.data() + offset, &value, sizeof(uint32_t));
}

void CapnpPayloadBuilder::set_uint64(size_t offset, uint64_t value) {
    if (offset + sizeof(uint64_t) > buf_.size()) return;
    std::memcpy(buf_.data() + offset, &value, sizeof(uint64_t));
}

// ── Schema-specific builders ────────────────────────────────────────────────

std::vector<uint8_t> capnp_build_vehicle_speed(
    float speed_kmh, uint64_t timestamp,
    uint16_t sensor_id, uint8_t quality_flag) {
    // VehicleSpeed data section layout:
    //   [0..3]   speedKmh    Float32
    //   [4..11]  timestamp   UInt64
    //   [12..13] sensorId    UInt16
    //   [14]     qualityFlag UInt8
    //   [15]     reserved    UInt8
    // Total: 16 bytes = 2 Cap'n Proto words
    CapnpPayloadBuilder builder(16);
    builder.set_float32(0, speed_kmh);
    builder.set_uint64(4, timestamp);
    builder.set_uint16(12, sensor_id);
    builder.set_uint8(14, quality_flag);
    return builder.take();
}

std::vector<uint8_t> capnp_build_radar_object(
    uint16_t object_id, float distance_m, float azimuth_deg,
    float velocity_ms, float rcs_dbsm, uint64_t timestamp,
    uint8_t classification) {
    // RadarObject data section layout:
    //   [0..1]   objectId       UInt16
    //   [2..3]   padding
    //   [4..7]   distanceM      Float32
    //   [8..11]  azimuthDeg     Float32
    //   [12..15] velocityMs     Float32
    //   [16..19] rcsDbsm        Float32
    //   [20..23] padding
    //   [24..31] timestamp      UInt64
    //   [32]     classification UInt8
    // Total: 40 bytes = 5 Cap'n Proto words
    CapnpPayloadBuilder builder(40);
    builder.set_uint16(0, object_id);
    builder.set_float32(4, distance_m);
    builder.set_float32(8, azimuth_deg);
    builder.set_float32(12, velocity_ms);
    builder.set_float32(16, rcs_dbsm);
    builder.set_uint64(24, timestamp);
    builder.set_uint8(32, classification);
    return builder.take();
}

std::vector<uint8_t> capnp_build_imu_data(
    float accel_x, float accel_y, float accel_z,
    float gyro_x, float gyro_y, float gyro_z,
    uint64_t timestamp, uint16_t sensor_id) {
    // ImuData data section layout:
    //   [0..3]   accelX    Float32
    //   [4..7]   accelY    Float32
    //   [8..11]  accelZ    Float32
    //   [12..15] gyroX     Float32
    //   [16..19] gyroY     Float32
    //   [20..23] gyroZ     Float32
    //   [24..31] timestamp UInt64
    //   [32..33] sensorId  UInt16
    // Total: 40 bytes = 5 Cap'n Proto words
    CapnpPayloadBuilder builder(40);
    builder.set_float32(0, accel_x);
    builder.set_float32(4, accel_y);
    builder.set_float32(8, accel_z);
    builder.set_float32(12, gyro_x);
    builder.set_float32(16, gyro_y);
    builder.set_float32(20, gyro_z);
    builder.set_uint64(24, timestamp);
    builder.set_uint16(32, sensor_id);
    return builder.take();
}
