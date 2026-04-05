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

// capnp_bridge.h — Alignment guard and path selection for Cap'n Proto payloads.
//
// vsomeip payloads are virtually always 8-byte aligned on Linux x86_64/arm64
// because std::vector uses the platform allocator, which aligns to at least
// max_align_t (16 bytes on most targets). The check is retained for safety.
//
// Two receive paths:
//   Path A (raw passthrough): post raw Cap'n Proto bytes as kExternalTypedData.
//     Dart reads fields via generated @Native accessors into native memory.
//     Zero copies, zero decodes on either side.
//
//   Path B (selective decode): C++ reads only the fields the UI needs.
//     Populates a thin struct. Posts that. One encode + one decode.

#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

/// Check if a pointer is aligned to 8 bytes (Cap'n Proto word boundary).
/// Returns true if aligned, false if not.
inline bool is_capnp_aligned(const void* ptr) {
    return (reinterpret_cast<uintptr_t>(ptr) & 7) == 0;
}

/// Size of a Cap'n Proto word in bytes.
constexpr size_t kCapnpWordSize = 8;

/// Copy unaligned data into an aligned buffer.
/// Returns a heap-allocated buffer that the caller must free with delete[].
/// The buffer is padded to a Cap'n Proto word boundary.
inline uint8_t* capnp_align_copy(const uint8_t* data, size_t len) {
    const size_t aligned_len = ((len + kCapnpWordSize - 1) / kCapnpWordSize)
                               * kCapnpWordSize;
    auto* buf = new uint8_t[aligned_len];
    std::memcpy(buf, data, len);
    // Zero-fill padding bytes
    if (aligned_len > len) {
        std::memset(buf + len, 0, aligned_len - len);
    }
    return buf;
}

/// Schema registration entry.
struct CapnpSchemaEntry {
    uint32_t schema_id;
    const char* schema_name;
};
