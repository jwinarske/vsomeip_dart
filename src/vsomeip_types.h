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

// vsomeip_types.h — Wire types for the vsomeip bridge.
//
// These structs define the message layout exchanged between the C++ bridge
// and the Dart worker isolate via Dart_PostCObject_DL.
//
// Wire protocol discriminator bytes:
//   0x01 = VsomeipMessage        — incoming SOME/IP request, response, or notification
//   0x02 = VsomeipAvailability   — service available / unavailable
//   0x03 = VsomeipState          — app registered / deregistered
//   0x04 = VsomeipSubscribeAck   — subscription accepted/rejected by service
//   0x05 = VsomeipError          — bridge or vsomeip error
//   0x10 = VsomeipBatch          ��� batch of VsomeipMessage structs (ring buffer drain)
//   0xFF = sentinel

#pragma once

#include <cstdint>
#include <cstring>
#include <string>

// Discriminator byte constants
namespace vsomeip_disc {
constexpr uint8_t kMessage       = 0x01;
constexpr uint8_t kAvailability  = 0x02;
constexpr uint8_t kState         = 0x03;
constexpr uint8_t kSubscribeAck  = 0x04;
constexpr uint8_t kError         = 0x05;
constexpr uint8_t kBatch         = 0x10;
constexpr uint8_t kSentinel      = 0xFF;
}  // namespace vsomeip_disc

struct VsomeipMessageHeader {
    uint16_t service_id;
    uint16_t instance_id;
    uint16_t method_id;     // method for REQUEST/RESPONSE, event ID for notifications
    uint8_t  message_type;  // REQUEST=0, RESPONSE=0x80, NOTIFICATION=0x02, etc.
    uint8_t  return_code;   // E_OK=0, E_NOT_OK=1, E_UNKNOWN_SERVICE=2, etc.
    uint64_t request_id;    // (client_id << 16) | session_id
    uint32_t payload_len;   // length of raw payload bytes following the header
};

struct VsomeipAvailability {
    uint16_t service_id;
    uint16_t instance_id;
    bool     available;
};

struct VsomeipState {
    bool        registered;  // true = REGISTERED, false = DEREGISTERED
    std::string app_name;
};

struct VsomeipSubscribeAck {
    uint16_t service_id;
    uint16_t instance_id;
    uint16_t eventgroup_id;
    uint16_t event_id;
    uint16_t error_code;   // 0 = accepted, non-zero = rejected
};

struct VsomeipError {
    std::string source;    // which bridge function produced the error
    std::string message;
    uint32_t    code;
};

// Ring buffer entry — compact struct for the SPSC poll path.
// Carries enough metadata to reconstruct a VsomeipMessageHeader on the
// Dart side without requiring Glaze decode on the hot path.
struct SomeIpRingEntry {
    uint16_t service_id;
    uint16_t instance_id;
    uint16_t method_id;
    uint8_t  message_type;
    uint8_t  return_code;
    uint32_t payload_len;
    // Payload data follows in a separate buffer managed by the ring buffer.
    // This struct only carries the header; the caller copies payload bytes
    // into/out of the ring buffer's payload region separately.
};
