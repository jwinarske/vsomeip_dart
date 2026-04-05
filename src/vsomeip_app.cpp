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

#include <vsomeip/vsomeip.hpp>

#include <cstring>
#include <stdexcept>

// ── Production constructor ──────────────────────────────────────────────────────

VsomeipApp::VsomeipApp(const std::string& app_name,
                       const char* config_path,
                       PostFn post_fn)
    : post_fn_(std::move(post_fn)), app_name_(app_name) {
    auto runtime = vsomeip::runtime::get();
    app_ = runtime->create_application(app_name);

    if (!app_) {
        throw std::runtime_error(
            "[vsomeip_dart] Failed to create vsomeip application: " + app_name);
    }

    if (config_path) {
        // vsomeip uses VSOMEIP_CONFIGURATION env to locate the config file.
        // Setting it before init() takes effect.
        setenv("VSOMEIP_CONFIGURATION", config_path, 1);
    }

    if (!app_->init()) {
        throw std::runtime_error(
            "[vsomeip_dart] vsomeip::application::init() failed for: " +
            app_name);
    }

    register_handlers();
}

// ── Test constructor ────────────────────────────────────────────────────────────

VsomeipApp::VsomeipApp(std::shared_ptr<vsomeip::application> app,
                       PostFn post_fn)
    : app_(std::move(app)), post_fn_(std::move(post_fn)) {
    register_handlers();
}

// ── Destructor ──────────────────────────────────────────────────────────────────

VsomeipApp::~VsomeipApp() {
    stop();
}

// ── Lifecycle ───────────────────────────────────────────────────────────────────

void VsomeipApp::start() {
    if (running_.load(std::memory_order_acquire)) return;

    running_.store(true, std::memory_order_release);
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
    if (!running_.load(std::memory_order_acquire) && !thread_.joinable()) return;

    app_->stop();
    if (thread_.joinable()) {
        thread_.join();
    }
    running_.store(false, std::memory_order_release);
}

// ── Handler registration ────────────────────────────────────────────────────────

void VsomeipApp::register_handlers() {
    app_->register_state_handler(
        [this](vsomeip::state_type_e state) {
            on_state(state == vsomeip::state_type_e::ST_REGISTERED);
        });

    app_->register_availability_handler(
        vsomeip::ANY_SERVICE, vsomeip::ANY_INSTANCE,
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

void VsomeipApp::on_availability(uint16_t service_id, uint16_t instance_id,
                                 bool available) {
    VsomeipAvailability avail{service_id, instance_id, available};
    // Encode as raw struct bytes (trivially copyable)
    post_fn_(vsomeip_disc::kAvailability,
             reinterpret_cast<const uint8_t*>(&avail),
             static_cast<uint32_t>(sizeof(avail)));
}
