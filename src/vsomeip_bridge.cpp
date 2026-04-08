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

// Include vsomeip BEFORE dart_api_dl to avoid macro/typename conflicts
// between vsomeip's ILLEGAL_PORT (constexpr uint16_t) and Dart's
// ILLEGAL_PORT (#define) — vsomeip headers must be parsed first.
#if __has_include(<vsomeip/vsomeip.hpp>)
#include <vsomeip/vsomeip.hpp>
#define VSOMEIP_AVAILABLE 1
#else
#define VSOMEIP_AVAILABLE 0
#endif

#include <cstdint>
#include <cstring>
#include <exception>
#include <iostream>
#include <memory>
#include <mutex>
#include <set>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "capnp_bridge.h"
#include "signal_filter.h"
#include "vsomeip_app.h"
#include "vsomeip_bridge.h"
#include "vsomeip_service.h"
#include "vsomeip_subscriber.h"
#include "vsomeip_types.h"

// Hard cap on any untrusted SOME/IP payload we will allocate. Larger
// payloads are dropped on the dispatch path. Tunable, but must fit in
// uint32_t and be small enough that two of them comfortably fit in size_t.
static constexpr uint32_t kMaxPayloadBytes = 1u << 20;  // 1 MiB

// ── Dart_PostCObject_DL function pointer ────────────────────────────────────────

using PostCObjectFnType = bool (*)(Dart_Port_DL, Dart_CObject*);
static PostCObjectFnType g_post_cobject = nullptr;

// ── Bridge init ─────────────────────────────────────────────────────────────────

extern "C" int vsomeip_bridge_init(void* dart_api_dl_data) {
    auto result = Dart_InitializeApiDL(dart_api_dl_data);
    if (result == 0) {
        // Dart_PostCObject_DL is itself a function pointer populated by
        // Dart_InitializeApiDL — assign directly (no address-of).
        g_post_cobject = Dart_PostCObject_DL;
    }
    return result;
}

// ── Helper: post a discriminated wire message to a Dart port ────────────────────

static void post_to_dart(Dart_Port_DL port, uint8_t disc, const uint8_t* data, uint32_t len) {
    if (!g_post_cobject)
        return;
    // Cap the untrusted length, then promote through 64-bit math so the
    // `1 + len` cannot wrap.
    if (len > kMaxPayloadBytes)
        return;
    const uint64_t buf_len64 = static_cast<uint64_t>(len) + 1u;
    const auto buf_len = static_cast<intptr_t>(buf_len64);

    // Allocate via unique_ptr so we don't leak on exception OR on a failed
    // post. The Dart-side finalizer takes ownership only after a successful
    // post (release()); otherwise unique_ptr deletes on scope exit.
    std::unique_ptr<uint8_t[]> owned;
    try {
        owned.reset(new uint8_t[static_cast<size_t>(buf_len64)]);
    } catch (const std::bad_alloc&) {
        return;
    }
    owned[0] = disc;
    if (len > 0 && data) {
        std::memcpy(owned.get() + 1, data, len);
    }

    Dart_CObject obj;
    obj.type = Dart_CObject_kExternalTypedData;
    obj.value.as_external_typed_data.type = Dart_TypedData_kUint8;
    obj.value.as_external_typed_data.length = buf_len;
    obj.value.as_external_typed_data.data = owned.get();
    obj.value.as_external_typed_data.peer = owned.get();
    obj.value.as_external_typed_data.callback = [](void*, void* peer) {
        delete[] static_cast<uint8_t*>(peer);
    };

    if (g_post_cobject(port, &obj)) {
        // Dart now owns the buffer; release from unique_ptr.
        (void)owned.release();
    }
    // On false, owned is freed by unique_ptr destructor — no leak, no
    // double free (the finalizer never runs because the post failed).
}

// ── Helper: post header + payload as a 2-element array to Dart ──────────────────

static void post_message_to_dart(Dart_Port_DL port,
                                 const uint8_t* hdr,
                                 uint32_t hdr_len,
                                 const uint8_t* payload,
                                 uint32_t payload_len) {
    if (!g_post_cobject)
        return;
    // Cap the untrusted payload length before any allocation. The header is
    // bridge-controlled and bounded so we don't cap it.
    if (payload_len > kMaxPayloadBytes)
        return;

    Dart_CObject hdr_obj;
    hdr_obj.type = Dart_CObject_kTypedData;
    hdr_obj.value.as_typed_data.type = Dart_TypedData_kUint8;
    hdr_obj.value.as_typed_data.length = static_cast<intptr_t>(hdr_len);
    hdr_obj.value.as_typed_data.values = hdr;

    Dart_CObject payload_obj;
    std::unique_ptr<uint8_t[]> owned;
    if (payload && payload_len > 0) {
        try {
            owned.reset(new uint8_t[payload_len]);
        } catch (const std::bad_alloc&) {
            return;
        }
        std::memcpy(owned.get(), payload, payload_len);
        payload_obj.type = Dart_CObject_kExternalTypedData;
        payload_obj.value.as_external_typed_data.type = Dart_TypedData_kUint8;
        payload_obj.value.as_external_typed_data.length = static_cast<intptr_t>(payload_len);
        payload_obj.value.as_external_typed_data.data = owned.get();
        payload_obj.value.as_external_typed_data.peer = owned.get();
        payload_obj.value.as_external_typed_data.callback = [](void*, void* peer) {
            delete[] static_cast<uint8_t*>(peer);
        };
    } else {
        payload_obj.type = Dart_CObject_kNull;
    }

    Dart_CObject* items[2] = {&hdr_obj, &payload_obj};
    Dart_CObject arr;
    arr.type = Dart_CObject_kArray;
    arr.value.as_array.length = 2;
    arr.value.as_array.values = items;

    if (g_post_cobject(port, &arr)) {
        // Dart now owns the external buffer; release from unique_ptr.
        (void)owned.release();
    }
    // On failure, owned is freed by unique_ptr — finalizer never runs.
}

// ── Application lifecycle ───────────────────────────────────────────────────────

static std::mutex g_apps_mutex;
static std::unordered_map<void*, std::unique_ptr<VsomeipApp>> g_apps;

// H5: per-app set of (service, instance, method/event) tuples that have a
// registered message handler. We tear these down before stopping the app
// so no in-flight Boost.Asio callback fires after `vsomeip_app_destroy`
// returns and the Dart-side port has been closed.
struct HandlerKey {
    uint16_t svc;
    uint16_t inst;
    uint16_t method;
    bool operator==(const HandlerKey& o) const {
        return svc == o.svc && inst == o.inst && method == o.method;
    }
};
struct HandlerKeyHash {
    size_t operator()(const HandlerKey& k) const noexcept {
        return (static_cast<size_t>(k.svc) << 32) ^ (static_cast<size_t>(k.inst) << 16) ^
               static_cast<size_t>(k.method);
    }
};
static std::unordered_map<void*, std::unordered_set<HandlerKey, HandlerKeyHash>> g_handlers;

static void track_handler(void* handle, uint16_t svc, uint16_t inst, uint16_t method) {
    std::lock_guard<std::mutex> lock(g_apps_mutex);
    g_handlers[handle].insert({svc, inst, method});
}

extern "C" void* vsomeip_app_create(Dart_Port_DL events_port,
                                    const char* app_name,
                                    const char* config_path) {
    try {
        auto post_fn = [events_port](uint8_t disc, const uint8_t* data, uint32_t len) {
            post_to_dart(events_port, disc, data, len);
        };

        auto app = std::make_unique<VsomeipApp>(
            app_name ? app_name : "vsomeip_dart", config_path, std::move(post_fn));

        app->start();

        auto* handle = app.get();
        {
            std::lock_guard<std::mutex> lock(g_apps_mutex);
            g_apps[handle] = std::move(app);
        }
        return handle;
    } catch (const std::exception& e) {
        post_to_dart(events_port,
                     vsomeip_disc::kError,
                     reinterpret_cast<const uint8_t*>(e.what()),
                     static_cast<uint32_t>(std::strlen(e.what())));
        return nullptr;
    }
}

extern "C" void vsomeip_app_destroy(void* handle) {
    if (!handle)
        return;

    std::unique_ptr<VsomeipApp> app;
    std::unordered_set<HandlerKey, HandlerKeyHash> handlers;
    {
        std::lock_guard<std::mutex> lock(g_apps_mutex);
        auto it = g_apps.find(handle);
        if (it == g_apps.end())
            return;
        app = std::move(it->second);
        g_apps.erase(it);
        auto hit = g_handlers.find(handle);
        if (hit != g_handlers.end()) {
            handlers = std::move(hit->second);
            g_handlers.erase(hit);
        }
    }
    // H5: unregister all message handlers BEFORE stopping the app, so that
    // any in-flight Boost.Asio callback referencing the per-subscription
    // post_fn (which captures the now-closing Dart port) cannot fire after
    // we return. The shared_ptr<VsomeipSubscriber> captured in each lambda
    // will then drop with the lambda when vsomeip releases its handler
    // table during stop().
#if VSOMEIP_AVAILABLE
    if (app && app->app()) {
        for (const auto& k : handlers) {
            try {
                app->app()->unregister_message_handler(k.svc, k.inst, k.method);
            } catch (...) {
                // best-effort
            }
        }
    }
#else
    (void)handlers;
#endif
    // app's dtor calls stop() → app_->stop() → joins the worker thread.
}

static VsomeipApp* get_app(void* handle) {
    std::lock_guard<std::mutex> lock(g_apps_mutex);
    auto it = g_apps.find(handle);
    return it != g_apps.end() ? it->second.get() : nullptr;
}

// ── Service consumer (client) role ──────────────────────────────────────────────

extern "C" void vsomeip_request_service(void* handle, uint16_t service_id, uint16_t instance_id) {
    auto* app = get_app(handle);
    if (!app)
        return;
    app->app()->request_service(service_id, instance_id);
}

extern "C" void vsomeip_release_service(void* handle, uint16_t service_id, uint16_t instance_id) {
    auto* app = get_app(handle);
    if (!app)
        return;
    app->app()->release_service(service_id, instance_id);
}

// Global per-signal filter registry (shared across all subscribers).
static FilterRegistry g_filters;

#if VSOMEIP_AVAILABLE
// Extract fields from a vsomeip::message and dispatch to VsomeipSubscriber.
// Applies the per-signal filter (if configured) to a mutable copy of the
// payload before dispatch.
static void dispatch_message(const std::shared_ptr<vsomeip::message>& msg,
                             const std::shared_ptr<VsomeipSubscriber>& subscriber) {
    // Defensive try/catch — this runs on the Boost.Asio io_service thread.
    // An exception escaping here would terminate the process. We swallow
    // bad_alloc / runtime_error and drop the message.
    try {
        auto pl = msg->get_payload();
        const uint8_t* payload_data = nullptr;
        uint32_t payload_len = 0;
        if (pl && pl->get_length() > 0) {
            const auto raw_len = pl->get_length();
            // Reject obviously hostile lengths before allocating.
            if (raw_len > kMaxPayloadBytes) {
                std::cerr << "[vsomeip_bridge] dropping oversize payload: " << raw_len << " > "
                          << kMaxPayloadBytes << std::endl;
                return;
            }
            payload_data = pl->get_data();
            payload_len = static_cast<uint32_t>(raw_len);
        }

        const auto svc = msg->get_service();
        const auto inst = msg->get_instance();
        const auto mid = msg->get_method();

        // Apply filter if configured for this (svc, inst, evt) tuple. The
        // filter copy + apply can throw bad_alloc; the outer catch handles it.
        std::vector<uint8_t> filtered_buf;
        if (payload_len > 0 && g_filters.has_filter(svc, inst, mid)) {
            filtered_buf.assign(payload_data, payload_data + payload_len);
            g_filters.apply(svc, inst, mid, filtered_buf.data(), payload_len);
            payload_data = filtered_buf.data();
        }

        subscriber->on_message(svc,
                               inst,
                               mid,
                               static_cast<uint8_t>(msg->get_message_type()),
                               static_cast<uint8_t>(msg->get_return_code()),
                               msg->get_client(),
                               msg->get_session(),
                               payload_data,
                               payload_len);
    } catch (const std::exception& e) {
        std::cerr << "[vsomeip_bridge] dispatch_message exception: " << e.what() << std::endl;
    } catch (...) {
        std::cerr << "[vsomeip_bridge] dispatch_message: unknown exception" << std::endl;
    }
}
#endif

// ── Filter C ABI ────────────────────────────────────────────────────────────

extern "C" void vsomeip_set_filter(uint16_t service_id,
                                   uint16_t instance_id,
                                   uint16_t event_id,
                                   uint8_t filter_type,
                                   uint16_t payload_offset,
                                   float param) {
    g_filters.set_filter(service_id,
                         instance_id,
                         event_id,
                         static_cast<FilterType>(filter_type),
                         payload_offset,
                         param);
}

extern "C" void vsomeip_clear_filter(uint16_t service_id, uint16_t instance_id, uint16_t event_id) {
    g_filters.clear_filter(service_id, instance_id, event_id);
}

extern "C" void vsomeip_subscribe(void* handle,
                                  uint16_t service_id,
                                  uint16_t instance_id,
                                  uint16_t eventgroup_id,
                                  uint16_t event_id,
                                  Dart_Port_DL events_port) {
    auto* app = get_app(handle);
    if (!app)
        return;

    auto post_fn =
        [events_port](
            const uint8_t* hdr, uint32_t hdr_len, const uint8_t* payload, uint32_t payload_len) {
            post_message_to_dart(events_port, hdr, hdr_len, payload, payload_len);
        };

    auto subscriber = std::make_shared<VsomeipSubscriber>(std::move(post_fn));

    app->app()->register_message_handler(
        service_id,
        instance_id,
        event_id,
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
    track_handler(handle, service_id, instance_id, event_id);
}

extern "C" void vsomeip_unsubscribe(void* handle,
                                    uint16_t service_id,
                                    uint16_t instance_id,
                                    uint16_t eventgroup_id) {
    auto* app = get_app(handle);
    if (!app)
        return;
    app->app()->unsubscribe(service_id, instance_id, eventgroup_id);
}

extern "C" void vsomeip_register_message_handler(void* handle,
                                                 uint16_t service_id,
                                                 uint16_t instance_id,
                                                 uint16_t method_id,
                                                 Dart_Port_DL events_port) {
    auto* app = get_app(handle);
    if (!app)
        return;

    auto post_fn =
        [events_port](
            const uint8_t* hdr, uint32_t hdr_len, const uint8_t* payload, uint32_t payload_len) {
            post_message_to_dart(events_port, hdr, hdr_len, payload, payload_len);
        };

    auto subscriber = std::make_shared<VsomeipSubscriber>(std::move(post_fn));

    app->app()->register_message_handler(
        service_id,
        instance_id,
        method_id,
#if VSOMEIP_AVAILABLE
        [subscriber](const std::shared_ptr<vsomeip::message>& msg) {
            dispatch_message(msg, subscriber);
        }
#else
        [subscriber](const std::shared_ptr<void>&) {}
#endif
    );
    track_handler(handle, service_id, instance_id, method_id);
}

extern "C" void vsomeip_unregister_message_handler(void* handle,
                                                   uint16_t service_id,
                                                   uint16_t instance_id,
                                                   uint16_t method_id) {
    auto* app = get_app(handle);
    if (!app)
        return;
    app->app()->unregister_message_handler(service_id, instance_id, method_id);
}

// ── Request / response ──────────────────────────────────────────────────────────

#if VSOMEIP_AVAILABLE
// Build a request message with payload set. Used by both request and
// fire-and-forget paths.
static std::shared_ptr<vsomeip::message> build_request(uint16_t service_id,
                                                       uint16_t instance_id,
                                                       uint16_t method_id,
                                                       const uint8_t* payload_buf,
                                                       uint32_t payload_len) {
    auto rt = vsomeip::runtime::get();
    auto req = rt->create_request();
    req->set_service(service_id);
    req->set_instance(instance_id);
    req->set_method(method_id);
    if (payload_buf && payload_len > 0) {
        auto pl = rt->create_payload();
        pl->set_data(payload_buf, payload_len);
        req->set_payload(pl);
    }
    return req;
}
#endif

extern "C" void vsomeip_send_request(void* handle,
                                     uint16_t service_id,
                                     uint16_t instance_id,
                                     uint16_t method_id,
                                     const uint8_t* payload_buf,
                                     uint32_t payload_len,
                                     uint32_t timeout_ms,
                                     Dart_Port_DL result_port) {
    auto* app = get_app(handle);
    if (!app)
        return;
    if (payload_len > kMaxPayloadBytes)
        return;
#if VSOMEIP_AVAILABLE
    try {
        auto req = build_request(service_id, instance_id, method_id, payload_buf, payload_len);
        // Standard request — vsomeip allocates a session id and routes
        // the response to any registered handler for (svc, inst, method).
        // Result delivery happens via the existing message handler path,
        // not via result_port directly. Callers that need a per-call port
        // should register a handler for the response method id beforehand.
        app->app()->send(req);
    } catch (const std::exception& e) {
        std::cerr << "[vsomeip_bridge] send_request exception: " << e.what() << '\n';
    } catch (...) {
        std::cerr << "[vsomeip_bridge] send_request: unknown exception\n";
    }
#else
    (void)service_id;
    (void)instance_id;
    (void)method_id;
    (void)payload_buf;
    (void)payload_len;
#endif
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
    if (!app)
        return;
    if (payload_len > kMaxPayloadBytes)
        return;
#if VSOMEIP_AVAILABLE
    try {
        auto req = build_request(service_id, instance_id, method_id, payload_buf, payload_len);
        // Fire-and-forget: tell vsomeip not to expect a reply. The receiving
        // application sees a MT_REQUEST_NO_RETURN message.
        req->set_message_type(vsomeip::message_type_e::MT_REQUEST_NO_RETURN);
        app->app()->send(req);
    } catch (const std::exception& e) {
        std::cerr << "[vsomeip_bridge] send_fire_forget exception: " << e.what() << '\n';
    } catch (...) {
        std::cerr << "[vsomeip_bridge] send_fire_forget: unknown exception\n";
    }
#else
    (void)service_id;
    (void)instance_id;
    (void)method_id;
    (void)payload_buf;
    (void)payload_len;
#endif
}

extern "C" void vsomeip_send_response(void* handle,
                                      uint64_t request_id,
                                      const uint8_t* payload_buf,
                                      uint32_t payload_len) {
    auto* app = get_app(handle);
    if (!app)
        return;
    if (payload_len > kMaxPayloadBytes)
        return;
#if VSOMEIP_AVAILABLE
    try {
        // request_id is the 64-bit (client_id<<16 | session_id) of the
        // original request, packed by VsomeipSubscriber::on_message into
        // the wire header that Dart received.
        const uint16_t client_id = static_cast<uint16_t>((request_id >> 16) & 0xFFFF);
        const uint16_t session_id = static_cast<uint16_t>(request_id & 0xFFFF);
        const uint16_t service_id = static_cast<uint16_t>((request_id >> 48) & 0xFFFF);
        const uint16_t instance_id = static_cast<uint16_t>((request_id >> 32) & 0xFFFF);

        auto rt = vsomeip::runtime::get();
        auto resp = rt->create_response(rt->create_message());
        resp->set_service(service_id);
        resp->set_instance(instance_id);
        resp->set_client(client_id);
        resp->set_session(session_id);
        resp->set_message_type(vsomeip::message_type_e::MT_RESPONSE);
        if (payload_buf && payload_len > 0) {
            auto pl = rt->create_payload();
            pl->set_data(payload_buf, payload_len);
            resp->set_payload(pl);
        }
        app->app()->send(resp);
    } catch (const std::exception& e) {
        std::cerr << "[vsomeip_bridge] send_response exception: " << e.what() << '\n';
    } catch (...) {
        std::cerr << "[vsomeip_bridge] send_response: unknown exception\n";
    }
#else
    (void)request_id;
    (void)payload_buf;
    (void)payload_len;
#endif
}

// ── Service provider role ───────────────────────────────────────────────────────

extern "C" void vsomeip_offer_service(void* handle,
                                      uint16_t service_id,
                                      uint16_t instance_id,
                                      Dart_Port_DL requests_port) {
    auto* app = get_app(handle);
    if (!app)
        return;
    app->app()->offer_service(service_id, instance_id);
    (void)requests_port;
}

extern "C" void vsomeip_stop_offer_service(void* handle,
                                           uint16_t service_id,
                                           uint16_t instance_id) {
    auto* app = get_app(handle);
    if (!app)
        return;
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
    if (!app)
        return;
#if VSOMEIP_AVAILABLE
    std::set<vsomeip::eventgroup_t> groups;
    for (uint32_t i = 0; i < n_eventgroups; ++i) {
        groups.insert(eventgroup_ids[i]);
    }
    auto evt_type = is_field ? vsomeip::event_type_e::ET_FIELD : vsomeip::event_type_e::ET_EVENT;
    app->app()->offer_event(
        service_id, instance_id, event_id, groups, evt_type, std::chrono::milliseconds(cycle_ms));
#else
    (void)service_id;
    (void)instance_id;
    (void)event_id;
    (void)eventgroup_ids;
    (void)n_eventgroups;
    (void)is_field;
    (void)cycle_ms;
#endif
}

extern "C" void vsomeip_stop_offer_event(void* handle,
                                         uint16_t service_id,
                                         uint16_t instance_id,
                                         uint16_t event_id) {
    auto* app = get_app(handle);
    if (!app)
        return;
#if VSOMEIP_AVAILABLE
    app->app()->stop_offer_event(service_id, instance_id, event_id);
#else
    (void)service_id;
    (void)instance_id;
    (void)event_id;
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
    if (!app)
        return;
#if VSOMEIP_AVAILABLE
    auto rt = vsomeip::runtime::get();
    auto pl = rt->create_payload();
    pl->set_data(payload_buf, payload_len);
    app->app()->notify(service_id, instance_id, event_id, pl, force);
#else
    (void)service_id;
    (void)instance_id;
    (void)event_id;
    (void)payload_buf;
    (void)payload_len;
    (void)force;
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
    vsomeip_subscribe(handle, service_id, instance_id, eventgroup_id, event_id, events_port);
    (void)schema_id;
}

extern "C" void vsomeip_capnp_subscribe_decoded(void* handle,
                                                uint16_t service_id,
                                                uint16_t instance_id,
                                                uint16_t eventgroup_id,
                                                uint16_t event_id,
                                                uint32_t schema_id,
                                                Dart_Port_DL events_port) {
    vsomeip_subscribe(handle, service_id, instance_id, eventgroup_id, event_id, events_port);
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
    (void)schema_id;
    (void)fields_json;
    (void)json_len;
    // For now, delegate to normal notify with empty payload
    vsomeip_notify(handle, service_id, instance_id, event_id, nullptr, 0, force);
}

extern "C" void vsomeip_capnp_register_schema(void* handle,
                                              uint32_t schema_id,
                                              const char* schema_name) {
    (void)handle;
    (void)schema_id;
    (void)schema_name;
}

// ── Callback-based API (for Flutter — uses NativeCallable.listener) ─────────

extern "C" void* vsomeip_app_create_with_callback(void (*callback)(uint8_t,
                                                                   const uint8_t*,
                                                                   uint32_t),
                                                  const char* app_name,
                                                  const char* config_path) {
    try {
        auto post_fn = [callback](uint8_t disc, const uint8_t* data, uint32_t len) {
            if (callback)
                callback(disc, data, len);
        };

        auto app = std::make_unique<VsomeipApp>(
            app_name ? app_name : "vsomeip_dart", config_path, std::move(post_fn));

        app->start();

        auto* handle = app.get();
        {
            std::lock_guard<std::mutex> lock(g_apps_mutex);
            g_apps[handle] = std::move(app);
        }
        return handle;
    } catch (const std::exception&) {
        return nullptr;
    }
}

extern "C" void vsomeip_subscribe_with_callback(void* handle,
                                                uint16_t service_id,
                                                uint16_t instance_id,
                                                uint16_t eventgroup_id,
                                                uint16_t event_id,
                                                void (*callback)(uint8_t,
                                                                 const uint8_t*,
                                                                 uint32_t)) {
    auto* app = get_app(handle);
    if (!app)
        return;

    auto post_fn =
        [callback](
            const uint8_t* hdr, uint32_t hdr_len, const uint8_t* payload, uint32_t payload_len) {
            if (!callback)
                return;
            auto total = hdr_len + payload_len;
            auto* buf = new uint8_t[total];
            std::memcpy(buf, hdr, hdr_len);
            if (payload && payload_len > 0) {
                std::memcpy(buf + hdr_len, payload, payload_len);
            }
            callback(buf[0], buf + 1, static_cast<uint32_t>(total - 1));
            delete[] buf;
        };

    auto subscriber = std::make_shared<VsomeipSubscriber>(std::move(post_fn));

    app->app()->register_message_handler(
        service_id,
        instance_id,
        event_id,
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
    track_handler(handle, service_id, instance_id, event_id);
}
