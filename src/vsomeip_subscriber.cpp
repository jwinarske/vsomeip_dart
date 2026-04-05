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

// vsomeip_subscriber.cpp — zero-copy payload dispatch.
//
// The critical hot path: vsomeip callback → Dart.
// Called on Boost.Asio's internal thread pool — must be lock-free.

#include "vsomeip_subscriber.h"

VsomeipSubscriber::VsomeipSubscriber(MessagePostFn post_fn)
    : post_fn_(std::move(post_fn)) {}

void VsomeipSubscriber::on_message(uint16_t service_id,
                                   uint16_t instance_id,
                                   uint16_t method_id,
                                   uint8_t message_type,
                                   uint8_t return_code,
                                   uint16_t client_id,
                                   uint16_t session_id,
                                   const uint8_t* payload,
                                   uint32_t payload_len) {
    // ── Pack header ─────────────────────────────────────────────────────────
    VsomeipMessageHeader hdr{
        .service_id   = service_id,
        .instance_id  = instance_id,
        .method_id    = method_id,
        .message_type = message_type,
        .return_code  = return_code,
        .request_id   = (static_cast<uint64_t>(client_id) << 16) | session_id,
        .payload_len  = payload_len,
    };

    // ── Encode header with discriminator ────────────────────────────────────
    auto header_bytes = encode_header(hdr);

    // ── Post to Dart ────────────────────────────────────────────────────────
    post_fn_(header_bytes.data(),
             static_cast<uint32_t>(header_bytes.size()),
             payload_len > 0 ? payload : nullptr,
             payload_len);
}

std::vector<uint8_t> VsomeipSubscriber::encode_header(
    const VsomeipMessageHeader& hdr) {
    // Wire format:
    //   [0]       discriminator = 0x01 (VsomeipMessage)
    //   [1..2]    service_id (LE)
    //   [3..4]    instance_id (LE)
    //   [5..6]    method_id (LE)
    //   [7]       message_type
    //   [8]       return_code
    //   [9..16]   request_id (LE)
    //   [17..20]  payload_len (LE)
    // Total: 21 bytes

    std::vector<uint8_t> buf;
    buf.reserve(21);

    // Discriminator
    buf.push_back(vsomeip_disc::kMessage);

    // Helper: append little-endian bytes
    auto push_u16 = [&buf](uint16_t v) {
        buf.push_back(static_cast<uint8_t>(v & 0xFF));
        buf.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
    };
    auto push_u32 = [&buf](uint32_t v) {
        buf.push_back(static_cast<uint8_t>(v & 0xFF));
        buf.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
        buf.push_back(static_cast<uint8_t>((v >> 16) & 0xFF));
        buf.push_back(static_cast<uint8_t>((v >> 24) & 0xFF));
    };
    auto push_u64 = [&buf](uint64_t v) {
        for (int i = 0; i < 8; ++i) {
            buf.push_back(static_cast<uint8_t>((v >> (i * 8)) & 0xFF));
        }
    };

    push_u16(hdr.service_id);
    push_u16(hdr.instance_id);
    push_u16(hdr.method_id);
    buf.push_back(hdr.message_type);
    buf.push_back(hdr.return_code);
    push_u64(hdr.request_id);
    push_u32(hdr.payload_len);

    return buf;
}
