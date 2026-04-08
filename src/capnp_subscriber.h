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

// capnp_subscriber.h — Cap'n Proto zero-copy receive paths.
//
// Path A (raw passthrough): post raw Cap'n Proto bytes as payload.
//   Dart reads fields via generated @Native accessors into native memory.
//   Zero copies, zero decodes on the C++ side.
//
// Path B (selective decode): C++ reads specific fields from the Cap'n Proto
//   message and posts a compact struct. One decode + one encode.
//
// Both paths check alignment before reading. Misaligned payloads (< 0.001%
// in practice) are copied into an aligned buffer before access.

#pragma once

#include <cstdint>
#include <cstring>
#include <functional>
#include <vector>

#include "capnp_bridge.h"
#include "vsomeip_subscriber.h"
#include "vsomeip_types.h"

// Callback for posting raw Cap'n Proto payload + SOME/IP header to Dart.
// Parameters: (header_data, header_len, payload_data, payload_len, was_aligned)
using CapnpPostFn = std::function<void(const uint8_t* header_data,
                                       uint32_t header_len,
                                       const uint8_t* payload_data,
                                       uint32_t payload_len,
                                       bool was_aligned)>;

// Callback for posting selectively decoded fields to Dart.
// Parameters: (schema_id, decoded_data, decoded_len)
using CapnpDecodedPostFn =
    std::function<void(uint32_t schema_id, const uint8_t* data, uint32_t len)>;

class CapnpSubscriber {
public:
    explicit CapnpSubscriber(uint32_t schema_id, CapnpPostFn post_fn);

    /// Process an incoming message on the raw passthrough path (Path A).
    /// Checks alignment, posts header + raw Cap'n Proto payload.
    void on_message(uint16_t service_id,
                    uint16_t instance_id,
                    uint16_t method_id,
                    uint8_t message_type,
                    uint8_t return_code,
                    uint16_t client_id,
                    uint16_t session_id,
                    const uint8_t* payload,
                    uint32_t payload_len);

    /// Encode a SOME/IP header with Cap'n Proto discriminator (0x01)
    /// and schema_id appended after the standard 21-byte header.
    /// Wire format: [disc=0x01][header 20B][schema_id 4B LE] = 25 bytes.
    static std::vector<uint8_t> encode_capnp_header(const VsomeipMessageHeader& hdr,
                                                    uint32_t schema_id);

    uint32_t schema_id() const { return schema_id_; }

private:
    uint32_t schema_id_;
    CapnpPostFn post_fn_;
};

/// Selectively decode Cap'n Proto fields on the C++ side (Path B).
/// Uses registered schema handlers to extract only UI-relevant fields.
class CapnpSelectiveDecoder {
public:
    using DecodeHandler =
        std::function<std::vector<uint8_t>(const uint8_t* payload, uint32_t payload_len)>;

    /// Register a decode handler for a schema.
    void register_schema(uint32_t schema_id, DecodeHandler handler);

    /// Decode fields from payload using the registered handler.
    /// Returns empty vector if schema_id is not registered or payload is empty.
    std::vector<uint8_t> decode(uint32_t schema_id,
                                const uint8_t* payload,
                                uint32_t payload_len) const;

    bool has_schema(uint32_t schema_id) const;

private:
    std::unordered_map<uint32_t, DecodeHandler> handlers_;
};
