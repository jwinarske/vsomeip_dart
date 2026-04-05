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

// capnp_service.h — Cap'n Proto zero-copy send path.
//
// Builds Cap'n Proto messages directly into a buffer using a
// FlatMessageBuilder-style approach. In production, the builder writes
// directly into the vsomeip payload buffer — zero intermediate copies.
//
// For unit testing without the real Cap'n Proto library, this module
// provides a CapnpPayloadBuilder that constructs little-endian packed
// fields matching the Cap'n Proto data section layout.

#pragma once

#include "capnp_bridge.h"
#include "vsomeip_types.h"

#include <cstdint>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

/// Builds a Cap'n Proto-compatible payload buffer.
///
/// In production, this wraps capnp::FlatMessageBuilder. For unit testing,
/// it writes fields at fixed offsets in little-endian format matching
/// the Cap'n Proto data section layout.
class CapnpPayloadBuilder {
public:
    /// Create a builder with the given initial capacity in bytes.
    /// The buffer is zero-initialized.
    explicit CapnpPayloadBuilder(size_t capacity);

    /// Write a float32 at the given byte offset.
    void set_float32(size_t offset, float value);

    /// Write a float64 at the given byte offset.
    void set_float64(size_t offset, double value);

    /// Write a uint8 at the given byte offset.
    void set_uint8(size_t offset, uint8_t value);

    /// Write a uint16 at the given byte offset.
    void set_uint16(size_t offset, uint16_t value);

    /// Write a uint32 at the given byte offset.
    void set_uint32(size_t offset, uint32_t value);

    /// Write a uint64 at the given byte offset.
    void set_uint64(size_t offset, uint64_t value);

    /// Get the raw payload bytes.
    const uint8_t* data() const { return buf_.data(); }

    /// Get the current payload size in bytes.
    size_t size() const { return buf_.size(); }

    /// Get the size in Cap'n Proto words (8 bytes each).
    size_t size_in_words() const {
        return (buf_.size() + kCapnpWordSize - 1) / kCapnpWordSize;
    }

    /// Get ownership of the buffer.
    std::vector<uint8_t> take() { return std::move(buf_); }

    /// Check if the buffer is 8-byte aligned (always true for heap alloc).
    bool is_aligned() const { return is_capnp_aligned(buf_.data()); }

private:
    std::vector<uint8_t> buf_;
};

/// Build a VehicleSpeed Cap'n Proto payload.
///
/// Returns a buffer containing the packed fields in Cap'n Proto
/// data section layout (little-endian, fixed offsets).
std::vector<uint8_t> capnp_build_vehicle_speed(
    float speed_kmh, uint64_t timestamp,
    uint16_t sensor_id, uint8_t quality_flag = 0);

/// Build a RadarObject Cap'n Proto payload.
std::vector<uint8_t> capnp_build_radar_object(
    uint16_t object_id, float distance_m, float azimuth_deg,
    float velocity_ms, float rcs_dbsm, uint64_t timestamp,
    uint8_t classification = 0);

/// Build an ImuData Cap'n Proto payload.
std::vector<uint8_t> capnp_build_imu_data(
    float accel_x, float accel_y, float accel_z,
    float gyro_x, float gyro_y, float gyro_z,
    uint64_t timestamp, uint16_t sensor_id = 0);
