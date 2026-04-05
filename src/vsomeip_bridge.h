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

// vsomeip_bridge.h
//
// C ABI for Dart FFI. All functions are asynchronous.
// Results are delivered via Dart_PostCObject_DL to the provided port.
//
// THREADING MODEL:
//   - vsomeip event loop runs on a dedicated std::thread (never joins)
//   - All vsomeip callbacks fire on Boost.Asio's internal thread pool
//   - Dart_PostCObject_DL is called from the callback thread
//   - events_port MUST belong to a Dart worker isolate, NOT the main isolate
//   - The worker isolate throttles and forwards to the main isolate

#pragma once

#include <stdbool.h>
#include <stdint.h>

// Dart_Port type for Dart_PostCObject_DL
typedef int64_t Dart_Port_DL;

#ifdef __cplusplus
extern "C" {
#endif

// Must be called once at startup with Dart's DL init data.
void vsomeip_bridge_init(void* dart_api_dl_data);

// ── Application lifecycle ─────────────────────────────────────────────────────
//
// Creates a vsomeip application and starts its event loop on a dedicated
// std::thread. events_port receives:
//   0x03 VsomeipState       — on registration with the routing manager
//   0x02 VsomeipAvailability — when services come online/offline
//
// app_name: identifies this application in the vsomeip routing (must be unique)
// config_path: path to vsomeip JSON config, or NULL for default search
void* vsomeip_app_create(Dart_Port_DL events_port,
                          const char* app_name,
                          const char* config_path);

void  vsomeip_app_destroy(void* handle);

// ── Service consumer (client) role ───────────────────────────────────────────

// Declare interest in a service. Triggers VsomeipAvailability callback
// when the service is discovered (or lost).
void vsomeip_request_service(void* handle,
                              uint16_t service_id,
                              uint16_t instance_id);

void vsomeip_release_service(void* handle,
                              uint16_t service_id,
                              uint16_t instance_id);

// Subscribe to an event group. Triggers VsomeipSubscribeAck, then
// VsomeipMessage for each event notification.
// events_port: the worker isolate's port (not the main isolate)
void vsomeip_subscribe(void* handle,
                        uint16_t service_id,
                        uint16_t instance_id,
                        uint16_t eventgroup_id,
                        uint16_t event_id,
                        Dart_Port_DL events_port);

void vsomeip_unsubscribe(void* handle,
                          uint16_t service_id,
                          uint16_t instance_id,
                          uint16_t eventgroup_id);

// Register a handler for all messages from a service/instance/method tuple.
// ANY_SERVICE (0xFFFF), ANY_INSTANCE (0xFFFF), ANY_METHOD (0xFFFF) wildcards
// are supported.
// events_port: worker isolate port
void vsomeip_register_message_handler(void* handle,
                                       uint16_t service_id,
                                       uint16_t instance_id,
                                       uint16_t method_id,
                                       Dart_Port_DL events_port);

void vsomeip_unregister_message_handler(void* handle,
                                         uint16_t service_id,
                                         uint16_t instance_id,
                                         uint16_t method_id);

// ── Request / response ────────────────────────────────────────────────────────
//
// Send a request and receive the response.
// result_port: receives exactly one 0x01 VsomeipMessage (the response)
//              or 0x05 VsomeipError on timeout / NAK.
// timeout_ms:  0 = no timeout
void vsomeip_send_request(void* handle,
                           uint16_t service_id,
                           uint16_t instance_id,
                           uint16_t method_id,
                           const uint8_t* payload_buf,
                           uint32_t payload_len,
                           uint32_t timeout_ms,
                           Dart_Port_DL result_port);

// Send a fire-and-forget message (message type REQUEST_NO_RETURN).
void vsomeip_send_fire_forget(void* handle,
                               uint16_t service_id,
                               uint16_t instance_id,
                               uint16_t method_id,
                               const uint8_t* payload_buf,
                               uint32_t payload_len);

// Send a response to a received request.
// request_id: the vsomeip session ID from the incoming VsomeipMessage
void vsomeip_send_response(void* handle,
                            uint64_t request_id,
                            const uint8_t* payload_buf,
                            uint32_t payload_len);

// ── Service provider role ─────────────────────────────────────────────────────

// Offer a service. After this call, the service is discoverable by other apps.
// requests_port: worker isolate port — receives 0x01 VsomeipMessage for each
//                incoming request; the Dart layer calls vsomeip_send_response
//                to reply.
void vsomeip_offer_service(void* handle,
                            uint16_t service_id,
                            uint16_t instance_id,
                            Dart_Port_DL requests_port);

void vsomeip_stop_offer_service(void* handle,
                                 uint16_t service_id,
                                 uint16_t instance_id);

// Offer a SOME/IP event or field.
// cycle_ms: 0 = no cyclic sending. > 0 = send notification every cycle_ms ms.
void vsomeip_offer_event(void* handle,
                          uint16_t service_id,
                          uint16_t instance_id,
                          uint16_t event_id,
                          const uint16_t* eventgroup_ids,
                          uint32_t n_eventgroups,
                          bool     is_field,
                          uint32_t cycle_ms);

void vsomeip_stop_offer_event(void* handle,
                               uint16_t service_id,
                               uint16_t instance_id,
                               uint16_t event_id);

// Publish a notification (notify all current subscribers).
// Zero-copy path: payload_buf is released after this call returns.
void vsomeip_notify(void* handle,
                    uint16_t service_id,
                    uint16_t instance_id,
                    uint16_t event_id,
                    const uint8_t* payload_buf,
                    uint32_t payload_len,
                    bool     force);

#ifdef __cplusplus
}
#endif
