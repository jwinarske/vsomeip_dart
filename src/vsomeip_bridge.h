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

#ifdef __cplusplus
}
#endif
