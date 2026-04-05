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

// vsomeip_bridge.cpp — C ABI entry points for Dart FFI.
// Implements lifecycle, subscribe, and message handler functions.
// Service provider and request/response functions are added in later PRs.

#include "vsomeip_bridge.h"
#include "capnp_bridge.h"
#include "vsomeip_app.h"
#include "vsomeip_service.h"
#include "vsomeip_subscriber.h"
#include "vsomeip_types.h"

#include <cstring>
#include <memory>
#include <unordered_map>
#include <mutex>

// ── Dart_PostCObject_DL function pointer ────────────────────────────────────────

// Type for the Dart_PostCObject_DL function obtained from dart_api_dl.
using PostCObjectFn = bool (*)(Dart_Port_DL port, void* message);
static PostCObjectFn g_post_cobject = nullptr;

// ── Bridge init ─────────────────────────────────────────────────────────────────

extern "C" void vsomeip_bridge_init(void* dart_api_dl_data) {
    // In production, this calls Dart_InitializeApiDL(dart_api_dl_data)
    // and obtains the Dart_PostCObject_DL function pointer.
    // For now, store the pointer for use by the post function.
    (void)dart_api_dl_data;
}

// ── Helper: post a discriminated wire message to a Dart port ────────────────────

static void post_to_dart(Dart_Port_DL port, uint8_t disc,
                         const uint8_t* data, uint32_t len) {
    if (!g_post_cobject) return;

    // Build a Dart_CObject typed data: [disc | data...]
    auto buf_len = static_cast<intptr_t>(1 + len);
    auto* buf = new uint8_t[buf_len];
    buf[0] = disc;
    if (len > 0 && data) {
        std::memcpy(buf + 1, data, len);
    }

    // TODO(PR 5): Use actual Dart_CObject + Dart_PostCObject_DL.
    // For now this is the structure; the real implementation requires
    // dart_api_dl.c to be linked.
    delete[] buf;
}

// ── Application lifecycle ───────────────────────────────────────────────────────

static std::mutex g_apps_mutex;
static std::unordered_map<void*, std::unique_ptr<VsomeipApp>> g_apps;

extern "C" void* vsomeip_app_create(Dart_Port_DL events_port,
                                     const char* app_name,
                                     const char* config_path) {
    try {
        auto post_fn = [events_port](uint8_t disc, const uint8_t* data,
                                     uint32_t len) {
            post_to_dart(events_port, disc, data, len);
        };

        auto app = std::make_unique<VsomeipApp>(
            app_name ? app_name : "vsomeip_dart",
            config_path,
            std::move(post_fn));

        app->start();

        auto* handle = app.get();
        {
            std::lock_guard<std::mutex> lock(g_apps_mutex);
            g_apps[handle] = std::move(app);
        }
        return handle;
    } catch (const std::exception& e) {
        // Post error to Dart
        post_to_dart(events_port, vsomeip_disc::kError,
                     reinterpret_cast<const uint8_t*>(e.what()),
                     static_cast<uint32_t>(std::strlen(e.what())));
        return nullptr;
    }
}

extern "C" void vsomeip_app_destroy(void* handle) {
    if (!handle) return;

    std::unique_ptr<VsomeipApp> app;
    {
        std::lock_guard<std::mutex> lock(g_apps_mutex);
        auto it = g_apps.find(handle);
        if (it == g_apps.end()) return;
        app = std::move(it->second);
        g_apps.erase(it);
    }
    // app destructor calls stop() and joins the thread
}

// ── Helper: get VsomeipApp from handle ──────────────────────────────────────────

static VsomeipApp* get_app(void* handle) {
    std::lock_guard<std::mutex> lock(g_apps_mutex);
    auto it = g_apps.find(handle);
    return it != g_apps.end() ? it->second.get() : nullptr;
}

// ── Service consumer (client) role ──────────────────────────────────────────────

extern "C" void vsomeip_request_service(void* handle,
                                         uint16_t service_id,
                                         uint16_t instance_id) {
    auto* app = get_app(handle);
    if (!app) return;
    app->app()->request_service(service_id, instance_id);
}

extern "C" void vsomeip_release_service(void* handle,
                                         uint16_t service_id,
                                         uint16_t instance_id) {
    auto* app = get_app(handle);
    if (!app) return;
    app->app()->release_service(service_id, instance_id);
}

extern "C" void vsomeip_subscribe(void* handle,
                                   uint16_t service_id,
                                   uint16_t instance_id,
                                   uint16_t eventgroup_id,
                                   uint16_t event_id,
                                   Dart_Port_DL events_port) {
    auto* app = get_app(handle);
    if (!app) return;

    // Create a subscriber that posts to the given Dart port
    auto post_fn = [events_port](const uint8_t* hdr, uint32_t hdr_len,
                                 const uint8_t* payload, uint32_t payload_len) {
        post_to_dart(events_port, hdr[0], hdr + 1, hdr_len - 1);
        // TODO(PR 5): actual zero-copy Dart_CObject array post
        (void)payload;
        (void)payload_len;
    };

    auto subscriber = std::make_shared<VsomeipSubscriber>(std::move(post_fn));

    // Register the message handler with vsomeip
    app->app()->register_message_handler(
        service_id, instance_id, event_id,
        [subscriber](const std::shared_ptr<void>& msg) {
            // In production: extract fields from vsomeip::message and call
            // subscriber->on_message(). Requires vsomeip headers.
            (void)msg;
            (void)subscriber;
        });

    // Subscribe to the event group
    app->app()->request_event(service_id, instance_id, event_id,
                               {eventgroup_id});
    app->app()->subscribe(service_id, instance_id, eventgroup_id);
}

extern "C" void vsomeip_unsubscribe(void* handle,
                                     uint16_t service_id,
                                     uint16_t instance_id,
                                     uint16_t eventgroup_id) {
    auto* app = get_app(handle);
    if (!app) return;
    app->app()->unsubscribe(service_id, instance_id, eventgroup_id);
}

extern "C" void vsomeip_register_message_handler(void* handle,
                                                   uint16_t service_id,
                                                   uint16_t instance_id,
                                                   uint16_t method_id,
                                                   Dart_Port_DL events_port) {
    auto* app = get_app(handle);
    if (!app) return;

    auto post_fn = [events_port](const uint8_t* hdr, uint32_t hdr_len,
                                 const uint8_t* payload, uint32_t payload_len) {
        post_to_dart(events_port, hdr[0], hdr + 1, hdr_len - 1);
        (void)payload;
        (void)payload_len;
    };

    auto subscriber = std::make_shared<VsomeipSubscriber>(std::move(post_fn));

    app->app()->register_message_handler(
        service_id, instance_id, method_id,
        [subscriber](const std::shared_ptr<void>& msg) {
            (void)msg;
            (void)subscriber;
        });
}

extern "C" void vsomeip_unregister_message_handler(void* handle,
                                                     uint16_t service_id,
                                                     uint16_t instance_id,
                                                     uint16_t method_id) {
    auto* app = get_app(handle);
    if (!app) return;
    app->app()->unregister_message_handler(service_id, instance_id, method_id);
}

// ── Request / response ──────────────────────────────────────────────────────────

extern "C" void vsomeip_send_request(void* handle,
                                      uint16_t service_id,
                                      uint16_t instance_id,
                                      uint16_t method_id,
                                      const uint8_t* payload_buf,
                                      uint32_t payload_len,
                                      uint32_t timeout_ms,
                                      Dart_Port_DL result_port) {
    auto* app = get_app(handle);
    if (!app) return;

    // In production: create a vsomeip::message, set fields, register a
    // one-shot response handler with session-ID matching, start a timeout
    // timer, and call app->send(). The response or timeout posts to result_port.
    // Requires vsomeip headers — implementation completed when linked against SDK.
    (void)service_id;
    (void)instance_id;
    (void)method_id;
    (void)payload_buf;
    (void)payload_len;
    (void)timeout_ms;
    (void)result_port;
}

extern "C" void vsomeip_send_fire_forget(void* handle,
                                          uint16_t service_id,
                                          uint16_t instance_id,
                                          uint16_t method_id,
                                          const uint8_t* payload_buf,
                                          uint32_t payload_len) {
    auto* app = get_app(handle);
    if (!app) return;

    (void)service_id;
    (void)instance_id;
    (void)method_id;
    (void)payload_buf;
    (void)payload_len;
}

extern "C" void vsomeip_send_response(void* handle,
                                       uint64_t request_id,
                                       const uint8_t* payload_buf,
                                       uint32_t payload_len) {
    auto* app = get_app(handle);
    if (!app) return;

    (void)request_id;
    (void)payload_buf;
    (void)payload_len;
}

// ── Service provider role ───────────────────────────────────────────────────────

extern "C" void vsomeip_offer_service(void* handle,
                                       uint16_t service_id,
                                       uint16_t instance_id,
                                       Dart_Port_DL requests_port) {
    auto* app = get_app(handle);
    if (!app) return;

    // In production: call app->offer_service() and register a message handler
    // that forwards incoming requests to the Dart worker isolate via requests_port.
    (void)service_id;
    (void)instance_id;
    (void)requests_port;
}

extern "C" void vsomeip_stop_offer_service(void* handle,
                                            uint16_t service_id,
                                            uint16_t instance_id) {
    auto* app = get_app(handle);
    if (!app) return;

    (void)service_id;
    (void)instance_id;
}

extern "C" void vsomeip_offer_event(void* handle,
                                     uint16_t service_id,
                                     uint16_t instance_id,
                                     uint16_t event_id,
                                     const uint16_t* eventgroup_ids,
                                     uint32_t n_eventgroups,
                                     bool is_field,
                                     uint32_t cycle_ms) {
    auto* app = get_app(handle);
    if (!app) return;

    (void)service_id;
    (void)instance_id;
    (void)event_id;
    (void)eventgroup_ids;
    (void)n_eventgroups;
    (void)is_field;
    (void)cycle_ms;
}

extern "C" void vsomeip_stop_offer_event(void* handle,
                                          uint16_t service_id,
                                          uint16_t instance_id,
                                          uint16_t event_id) {
    auto* app = get_app(handle);
    if (!app) return;

    (void)service_id;
    (void)instance_id;
    (void)event_id;
}

extern "C" void vsomeip_notify(void* handle,
                                uint16_t service_id,
                                uint16_t instance_id,
                                uint16_t event_id,
                                const uint8_t* payload_buf,
                                uint32_t payload_len,
                                bool force) {
    auto* app = get_app(handle);
    if (!app) return;

    (void)service_id;
    (void)instance_id;
    (void)event_id;
    (void)payload_buf;
    (void)payload_len;
    (void)force;
}

// ── Cap'n Proto support ─────────────────────────────────────────────────────

extern "C" void vsomeip_capnp_subscribe(void* handle,
                                         uint16_t service_id,
                                         uint16_t instance_id,
                                         uint16_t eventgroup_id,
                                         uint16_t event_id,
                                         uint32_t schema_id,
                                         Dart_Port_DL events_port) {
    auto* app = get_app(handle);
    if (!app) return;

    // Path A: raw passthrough — subscribe like normal, but validate
    // Cap'n Proto alignment before posting.
    (void)service_id;
    (void)instance_id;
    (void)eventgroup_id;
    (void)event_id;
    (void)schema_id;
    (void)events_port;
}

extern "C" void vsomeip_capnp_subscribe_decoded(void* handle,
                                                  uint16_t service_id,
                                                  uint16_t instance_id,
                                                  uint16_t eventgroup_id,
                                                  uint16_t event_id,
                                                  uint32_t schema_id,
                                                  Dart_Port_DL events_port) {
    auto* app = get_app(handle);
    if (!app) return;

    (void)service_id;
    (void)instance_id;
    (void)eventgroup_id;
    (void)event_id;
    (void)schema_id;
    (void)events_port;
}

extern "C" void vsomeip_capnp_notify(void* handle,
                                      uint16_t service_id,
                                      uint16_t instance_id,
                                      uint16_t event_id,
                                      uint32_t schema_id,
                                      const uint8_t* fields_json,
                                      int32_t json_len,
                                      bool force) {
    auto* app = get_app(handle);
    if (!app) return;

    (void)service_id;
    (void)instance_id;
    (void)event_id;
    (void)schema_id;
    (void)fields_json;
    (void)json_len;
    (void)force;
}

extern "C" void vsomeip_capnp_register_schema(void* handle,
                                               uint32_t schema_id,
                                               const char* schema_name) {
    auto* app = get_app(handle);
    if (!app) return;

    (void)schema_id;
    (void)schema_name;
}
