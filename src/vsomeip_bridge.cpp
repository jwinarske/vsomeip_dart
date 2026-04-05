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
// This file implements the lifecycle functions. Subscriber and service
// provider functions are added in later PRs.

#include "vsomeip_bridge.h"
#include "vsomeip_app.h"
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
