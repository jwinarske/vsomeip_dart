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

#include "vsomeip_app.h"

#include <cstring>
#include <mutex>
#include <stdexcept>
#include <vsomeip/vsomeip.hpp>

// Serializes process-wide setenv("VSOMEIP_CONFIGURATION") + init() so two
// concurrent VsomeipApp constructions cannot race the env var. vsomeip
// reads the env var inside init(), so we hold the lock across both.
static std::mutex& vsomeip_init_mutex() {
    static std::mutex m;
    return m;
}

// ── Production constructor ──────────────────────────────────────────────────────

VsomeipApp::VsomeipApp(const std::string& app_name, const char* config_path, PostFn post_fn)
    : post_fn_(std::move(post_fn)), app_name_(app_name) {
    auto runtime = vsomeip::runtime::get();
    app_ = runtime->create_application(app_name);

    if (!app_) {
        throw std::runtime_error("[vsomeip_dart] Failed to create vsomeip application: " +
                                 app_name);
    }

    {
        // M4: serialize env mutation + init across concurrent constructions.
        std::lock_guard<std::mutex> lock(vsomeip_init_mutex());
        if (config_path) {
            setenv("VSOMEIP_CONFIGURATION", config_path, 1);
        }
        if (!app_->init()) {
            throw std::runtime_error("[vsomeip_dart] vsomeip::application::init() failed for: " +
                                     app_name);
        }
    }

    register_handlers();
}

// ── Test constructor ────────────────────────────────────────────────────────────

VsomeipApp::VsomeipApp(std::shared_ptr<vsomeip::application> app, PostFn post_fn)
    : app_(std::move(app)), post_fn_(std::move(post_fn)) {
    register_handlers();
}

// ── Destructor ──────────────────────────────────────────────────────────────────

VsomeipApp::~VsomeipApp() {
    stop();
}

// ── Lifecycle ───────────────────────────────────────────────────────────────────

void VsomeipApp::start() {
    // H4: CAS-guard against concurrent or repeat start() calls. The previous
    // load/store pattern allowed two threads to both observe `running_==false`
    // and each spawn a thread.
    bool expected = false;
    if (!running_.compare_exchange_strong(
            expected, true, std::memory_order_acq_rel, std::memory_order_acquire)) {
        return;
    }
    thread_ = std::thread([this] {
        try {
            app_->start();  // blocks forever until stop() is called
        } catch (const std::exception& e) {
            // GCOV_EXCL_START — requires Boost.Asio to fail internally
            VsomeipError err{"vsomeip_app_start", e.what(), 1};
            auto msg = err.source + ": " + err.message;
            post_fn_(vsomeip_disc::kError,
                     reinterpret_cast<const uint8_t*>(msg.data()),
                     static_cast<uint32_t>(msg.size()));
            // GCOV_EXCL_STOP
        }
        running_.store(false, std::memory_order_release);
    });
}

void VsomeipApp::stop() {
    // H4: always attempt to join if a thread was spawned, regardless of the
    // running_ flag — the worker may have already cleared it on the way out
    // of an exception path. Calling app_->stop() on an already-stopped
    // application is safe per vsomeip docs.
    if (app_) {
        try {
            app_->stop();
        } catch (...) {
            // best-effort: don't throw out of a destructor path
        }
    }
    if (thread_.joinable()) {
        thread_.join();
    }
    running_.store(false, std::memory_order_release);
}

// ── Handler registration ────────────────────────────────────────────────────────

void VsomeipApp::register_handlers() {
    app_->register_state_handler([this](vsomeip::state_type_e state) {
        on_state(state == vsomeip::state_type_e::ST_REGISTERED);
    });

    app_->register_availability_handler(
        vsomeip::ANY_SERVICE,
        vsomeip::ANY_INSTANCE,
        [this](vsomeip::service_t svc, vsomeip::instance_t inst, bool avail) {
            on_availability(svc, inst, avail);
        });
}

// ── Callbacks ───────────────────────────────────────────────────────────────────

void VsomeipApp::on_state(bool registered) {
    VsomeipState state{registered, app_name_};
    // Encode as: [registered (1 byte)] [app_name bytes]
    std::vector<uint8_t> buf;
    buf.push_back(registered ? 1 : 0);
    buf.insert(buf.end(), state.app_name.begin(), state.app_name.end());
    post_fn_(vsomeip_disc::kState, buf.data(), static_cast<uint32_t>(buf.size()));
}

void VsomeipApp::on_availability(uint16_t service_id, uint16_t instance_id, bool available) {
    VsomeipAvailability avail{service_id, instance_id, available};
    // Encode as raw struct bytes (trivially copyable)
    post_fn_(vsomeip_disc::kAvailability,
             reinterpret_cast<const uint8_t*>(&avail),
             static_cast<uint32_t>(sizeof(avail)));
}
