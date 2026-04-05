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
// Implements lifecycle, subscribe, message handler, and service provider functions.

#include "vsomeip_bridge.h"
#include "dart_api_dl.h"
#include "capnp_bridge.h"
#include "vsomeip_app.h"
#include "vsomeip_service.h"
#include "vsomeip_subscriber.h"
#include "vsomeip_types.h"

#if __has_include(<vsomeip/vsomeip.hpp>)
#include <vsomeip/vsomeip.hpp>
#define VSOMEIP_AVAILABLE 1
#else
#define VSOMEIP_AVAILABLE 0
#endif

#include <cstring>
#include <memory>
#include <set>
#include <unordered_map>
#include <mutex>

// ── Dart_PostCObject_DL function pointer ────────────────────────────────────────

using PostCObjectFnType = bool (*)(Dart_Port_DL, Dart_CObject*);
static PostCObjectFnType g_post_cobject = nullptr;

// ── Bridge init ─────────────────────────────────────────────────────────────────

extern "C" void vsomeip_bridge_init(void* dart_api_dl_data) {
    (void)dart_api_dl_data;
    // Store the Dart_PostCObject_DL function pointer.
    // In a full Dart SDK integration, we'd call Dart_InitializeApiDL here.
    // For now, set the global to the real function.
    g_post_cobject = &Dart_PostCObject_DL;
}

// ── Helper: post a discriminated wire message to a Dart port ────────────────────

static void post_to_dart(Dart_Port_DL port, uint8_t disc,
                         const uint8_t* data, uint32_t len) {
    if (!g_post_cobject) return;

    // Build typed data: [disc | data...]
    auto buf_len = static_cast<intptr_t>(1 + len);
    auto* buf = new uint8_t[buf_len];
    buf[0] = disc;
    if (len > 0 && data) {
        std::memcpy(buf + 1, data, len);
    }

    // Post as ExternalTypedData — Dart GC frees via finalizer
    Dart_CObject obj;
    obj.type = Dart_CObject_kExternalTypedData;
    obj.value.as_external_typed_data.type = Dart_TypedData_kUint8;
    obj.value.as_external_typed_data.length = buf_len;
    obj.value.as_external_typed_data.data = buf;
    obj.value.as_external_typed_data.peer = buf;
    obj.value.as_external_typed_data.callback =
        [](void*, void* peer) { delete[] static_cast<uint8_t*>(peer); };

    g_post_cobject(port, &obj);
}

// ── Helper: post header + payload as a 2-element array to Dart ──────────────────

static void post_message_to_dart(Dart_Port_DL port,
                                 const uint8_t* hdr, uint32_t hdr_len,
                                 const uint8_t* payload, uint32_t payload_len) {
    if (!g_post_cobject) return;

    // Header as TypedData (Dart copies it)
    Dart_CObject hdr_obj;
    hdr_obj.type = Dart_CObject_kTypedData;
    hdr_obj.value.as_typed_data.type = Dart_TypedData_kUint8;
    hdr_obj.value.as_typed_data.length = hdr_len;
    hdr_obj.value.as_typed_data.values = hdr;

    // Payload as ExternalTypedData (zero-copy, Dart GC owns via finalizer)
    Dart_CObject payload_obj;
    if (payload && payload_len > 0) {
        auto* owned = new uint8_t[payload_len];
        std::memcpy(owned, payload, payload_len);
        payload_obj.type = Dart_CObject_kExternalTypedData;
        payload_obj.value.as_external_typed_data.type = Dart_TypedData_kUint8;
        payload_obj.value.as_external_typed_data.length = payload_len;
        payload_obj.value.as_external_typed_data.data = owned;
        payload_obj.value.as_external_typed_data.peer = owned;
        payload_obj.value.as_external_typed_data.callback =
            [](void*, void* peer) { delete[] static_cast<uint8_t*>(peer); };
    } else {
        payload_obj.type = Dart_CObject_kNull;
    }

    // 2-element array: [header, payload]
    Dart_CObject* items[2] = {&hdr_obj, &payload_obj};
    Dart_CObject arr;
    arr.type = Dart_CObject_kArray;
    arr.value.as_array.length = 2;
    arr.value.as_array.values = items;

    g_post_cobject(port, &arr);
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
}

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

#if VSOMEIP_AVAILABLE
// Extract fields from a vsomeip::message and dispatch to VsomeipSubscriber
static void dispatch_message(
    const std::shared_ptr<vsomeip::message>& msg,
    const std::shared_ptr<VsomeipSubscriber>& subscriber) {

    auto pl = msg->get_payload();
    const uint8_t* payload_data = nullptr;
    uint32_t payload_len = 0;
    if (pl && pl->get_length() > 0) {
        payload_data = pl->get_data();
        payload_len = static_cast<uint32_t>(pl->get_length());
    }

    subscriber->on_message(
        msg->get_service(),
        msg->get_instance(),
        msg->get_method(),
        static_cast<uint8_t>(msg->get_message_type()),
        static_cast<uint8_t>(msg->get_return_code()),
        msg->get_client(),
        msg->get_session(),
        payload_data,
        payload_len);
}
#endif

extern "C" void vsomeip_subscribe(void* handle,
                                   uint16_t service_id,
                                   uint16_t instance_id,
                                   uint16_t eventgroup_id,
                                   uint16_t event_id,
                                   Dart_Port_DL events_port) {
    auto* app = get_app(handle);
    if (!app) return;

    auto post_fn = [events_port](const uint8_t* hdr, uint32_t hdr_len,
                                 const uint8_t* payload, uint32_t payload_len) {
        post_message_to_dart(events_port, hdr, hdr_len, payload, payload_len);
    };

    auto subscriber = std::make_shared<VsomeipSubscriber>(std::move(post_fn));

    app->app()->register_message_handler(
        service_id, instance_id, event_id,
#if VSOMEIP_AVAILABLE
        [subscriber](const std::shared_ptr<vsomeip::message>& msg) {
            dispatch_message(msg, subscriber);
        }
#else
        [subscriber](const std::shared_ptr<void>&) {}
#endif
    );

    std::set<vsomeip::eventgroup_t> groups{eventgroup_id};
    app->app()->request_event(service_id, instance_id, event_id, groups);
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
        post_message_to_dart(events_port, hdr, hdr_len, payload, payload_len);
    };

    auto subscriber = std::make_shared<VsomeipSubscriber>(std::move(post_fn));

    app->app()->register_message_handler(
        service_id, instance_id, method_id,
#if VSOMEIP_AVAILABLE
        [subscriber](const std::shared_ptr<vsomeip::message>& msg) {
            dispatch_message(msg, subscriber);
        }
#else
        [subscriber](const std::shared_ptr<void>&) {}
#endif
    );
}

extern "C" void vsomeip_unregister_message_handler(void* handle,
                                                     uint16_t service_id,
                                                     uint16_t instance_id,
                                                     uint16_t method_id) {
    auto* app = get_app(handle);
    if (!app) return;
    app->app()->unregister_message_handler(service_id, instance_id, method_id);
}

// ── Request / response (stubs — full impl requires session tracking) ────────────

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
    (void)service_id; (void)instance_id; (void)method_id;
    (void)payload_buf; (void)payload_len; (void)timeout_ms; (void)result_port;
}

extern "C" void vsomeip_send_fire_forget(void* handle,
                                          uint16_t service_id,
                                          uint16_t instance_id,
                                          uint16_t method_id,
                                          const uint8_t* payload_buf,
                                          uint32_t payload_len) {
    auto* app = get_app(handle);
    if (!app) return;
    (void)service_id; (void)instance_id; (void)method_id;
    (void)payload_buf; (void)payload_len;
}

extern "C" void vsomeip_send_response(void* handle,
                                       uint64_t request_id,
                                       const uint8_t* payload_buf,
                                       uint32_t payload_len) {
    auto* app = get_app(handle);
    if (!app) return;
    (void)request_id; (void)payload_buf; (void)payload_len;
}

// ── Service provider role ───────────────────────────────────────────────────────

extern "C" void vsomeip_offer_service(void* handle,
                                       uint16_t service_id,
                                       uint16_t instance_id,
                                       Dart_Port_DL requests_port) {
    auto* app = get_app(handle);
    if (!app) return;
    app->app()->offer_service(service_id, instance_id);
    (void)requests_port;
}

extern "C" void vsomeip_stop_offer_service(void* handle,
                                            uint16_t service_id,
                                            uint16_t instance_id) {
    auto* app = get_app(handle);
    if (!app) return;
    app->app()->stop_offer_service(service_id, instance_id);
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
#if VSOMEIP_AVAILABLE
    std::set<vsomeip::eventgroup_t> groups;
    for (uint32_t i = 0; i < n_eventgroups; ++i) {
        groups.insert(eventgroup_ids[i]);
    }
    auto evt_type = is_field ? vsomeip::event_type_e::ET_FIELD
                             : vsomeip::event_type_e::ET_EVENT;
    app->app()->offer_event(service_id, instance_id, event_id, groups,
                            evt_type, std::chrono::milliseconds(cycle_ms));
#else
    (void)service_id; (void)instance_id; (void)event_id;
    (void)eventgroup_ids; (void)n_eventgroups; (void)is_field; (void)cycle_ms;
#endif
}

extern "C" void vsomeip_stop_offer_event(void* handle,
                                          uint16_t service_id,
                                          uint16_t instance_id,
                                          uint16_t event_id) {
    auto* app = get_app(handle);
    if (!app) return;
#if VSOMEIP_AVAILABLE
    app->app()->stop_offer_event(service_id, instance_id, event_id);
#else
    (void)service_id; (void)instance_id; (void)event_id;
#endif
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
#if VSOMEIP_AVAILABLE
    auto rt = vsomeip::runtime::get();
    auto pl = rt->create_payload();
    pl->set_data(payload_buf, payload_len);
    app->app()->notify(service_id, instance_id, event_id, pl, force);
#else
    (void)service_id; (void)instance_id; (void)event_id;
    (void)payload_buf; (void)payload_len; (void)force;
#endif
}

// ── Cap'n Proto support (stubs for now) ─────────────────────────────────────────

extern "C" void vsomeip_capnp_subscribe(void* handle,
                                         uint16_t service_id,
                                         uint16_t instance_id,
                                         uint16_t eventgroup_id,
                                         uint16_t event_id,
                                         uint32_t schema_id,
                                         Dart_Port_DL events_port) {
    // Delegate to normal subscribe — Cap'n Proto validation happens in the
    // capnp_subscriber layer, not at the C ABI level.
    vsomeip_subscribe(handle, service_id, instance_id,
                      eventgroup_id, event_id, events_port);
    (void)schema_id;
}

extern "C" void vsomeip_capnp_subscribe_decoded(void* handle,
                                                  uint16_t service_id,
                                                  uint16_t instance_id,
                                                  uint16_t eventgroup_id,
                                                  uint16_t event_id,
                                                  uint32_t schema_id,
                                                  Dart_Port_DL events_port) {
    vsomeip_subscribe(handle, service_id, instance_id,
                      eventgroup_id, event_id, events_port);
    (void)schema_id;
}

extern "C" void vsomeip_capnp_notify(void* handle,
                                      uint16_t service_id,
                                      uint16_t instance_id,
                                      uint16_t event_id,
                                      uint32_t schema_id,
                                      const uint8_t* fields_json,
                                      int32_t json_len,
                                      bool force) {
    (void)schema_id; (void)fields_json; (void)json_len;
    // For now, delegate to normal notify with empty payload
    vsomeip_notify(handle, service_id, instance_id, event_id,
                   nullptr, 0, force);
}

extern "C" void vsomeip_capnp_register_schema(void* handle,
                                               uint32_t schema_id,
                                               const char* schema_name) {
    (void)handle; (void)schema_id; (void)schema_name;
}
