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

#include "capnp_subscriber.h"

CapnpSubscriber::CapnpSubscriber(uint32_t schema_id, CapnpPostFn post_fn)
    : schema_id_(schema_id), post_fn_(std::move(post_fn)) {}

void CapnpSubscriber::on_message(uint16_t service_id,
                                 uint16_t instance_id,
                                 uint16_t method_id,
                                 uint8_t message_type,
                                 uint8_t return_code,
                                 uint16_t client_id,
                                 uint16_t session_id,
                                 const uint8_t* payload,
                                 uint32_t payload_len) {
    VsomeipMessageHeader hdr{
        .service_id = service_id,
        .instance_id = instance_id,
        .method_id = method_id,
        .message_type = message_type,
        .return_code = return_code,
        .request_id = (static_cast<uint64_t>(client_id) << 16) | session_id,
        .payload_len = payload_len,
    };

    auto header_bytes = encode_capnp_header(hdr, schema_id_);

    if (payload == nullptr || payload_len == 0) {
        // Empty payload — header-only message
        post_fn_(header_bytes.data(), static_cast<uint32_t>(header_bytes.size()), nullptr, 0, true);
        return;
    }

    bool aligned = is_capnp_aligned(payload);

    if (aligned) {
        // Path A aligned: post raw bytes directly
        post_fn_(header_bytes.data(),
                 static_cast<uint32_t>(header_bytes.size()),
                 payload,
                 payload_len,
                 true);
    } else {
        // Fallback: copy to aligned buffer
        auto* aligned_buf = capnp_align_copy(payload, payload_len);
        post_fn_(header_bytes.data(),
                 static_cast<uint32_t>(header_bytes.size()),
                 aligned_buf,
                 payload_len,
                 false);
        delete[] aligned_buf;
    }
}

std::vector<uint8_t> CapnpSubscriber::encode_capnp_header(const VsomeipMessageHeader& hdr,
                                                          uint32_t schema_id) {
    // Start with the standard 21-byte header from VsomeipSubscriber
    auto bytes = VsomeipSubscriber::encode_header(hdr);

    // Append schema_id as 4 bytes LE
    bytes.push_back(static_cast<uint8_t>(schema_id & 0xFF));
    bytes.push_back(static_cast<uint8_t>((schema_id >> 8) & 0xFF));
    bytes.push_back(static_cast<uint8_t>((schema_id >> 16) & 0xFF));
    bytes.push_back(static_cast<uint8_t>((schema_id >> 24) & 0xFF));

    return bytes;  // 25 bytes total
}

// ── CapnpSelectiveDecoder ───────────────────────────────────────────────────

void CapnpSelectiveDecoder::register_schema(uint32_t schema_id, DecodeHandler handler) {
    handlers_[schema_id] = std::move(handler);
}

std::vector<uint8_t> CapnpSelectiveDecoder::decode(uint32_t schema_id,
                                                   const uint8_t* payload,
                                                   uint32_t payload_len) const {
    if (payload == nullptr || payload_len == 0)
        return {};

    auto it = handlers_.find(schema_id);
    if (it == handlers_.end())
        return {};

    return it->second(payload, payload_len);
}

bool CapnpSelectiveDecoder::has_schema(uint32_t schema_id) const {
    return handlers_.find(schema_id) != handlers_.end();
}
