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

// vsomeip_subscriber.h — Event subscriber and message dispatch.
//
// Owns the on_message hot path: vsomeip callback → header encode →
// zero-copy payload → post to Dart worker isolate.
//
// THREADING: on_message is called on Boost.Asio's internal thread pool.
// All operations must be lock-free on the hot path.

#pragma once

#include <cstdint>
#include <cstring>
#include <functional>
#include <vector>

#include "vsomeip_types.h"

// Callback for posting encoded messages to Dart.
// Parameters: (header_data, header_len, payload_data, payload_len)
// header_data includes the discriminator byte prefix.
// payload_data may be nullptr if payload_len == 0.
using MessagePostFn = std::function<void(const uint8_t* header_data,
                                         uint32_t header_len,
                                         const uint8_t* payload_data,
                                         uint32_t payload_len)>;

class VsomeipSubscriber {
public:
    explicit VsomeipSubscriber(MessagePostFn post_fn);

    // The hot path: called from vsomeip's Boost.Asio thread pool.
    // Encodes the message header, then posts header + payload to Dart.
    //
    // Parameters mirror what vsomeip::message provides:
    //   service_id, instance_id, method_id — identity
    //   message_type, return_code — SOME/IP header fields
    //   client_id, session_id — for request/response pairing
    //   payload, payload_len — raw SOME/IP payload (may be nullptr/0)
    void on_message(uint16_t service_id,
                    uint16_t instance_id,
                    uint16_t method_id,
                    uint8_t message_type,
                    uint8_t return_code,
                    uint16_t client_id,
                    uint16_t session_id,
                    const uint8_t* payload,
                    uint32_t payload_len);

    // Encode a VsomeipMessageHeader into wire bytes with discriminator prefix.
    // Returns the encoded bytes (discriminator + packed header fields).
    static std::vector<uint8_t> encode_header(const VsomeipMessageHeader& hdr);

private:
    MessagePostFn post_fn_;
};
