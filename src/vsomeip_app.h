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

// vsomeip_app.h — C++ wrapper around vsomeip::application.
//
// Owns a dedicated std::thread for the vsomeip event loop (app->start()
// blocks forever). Registers state and availability handlers that post
// discriminated wire messages to the Dart worker isolate via the provided
// post function.

#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <thread>

#include "vsomeip_types.h"

// Forward declare vsomeip types to avoid requiring vsomeip headers in tests.
namespace vsomeip_v3 {
class application;
class runtime;
}  // namespace vsomeip_v3
namespace vsomeip = vsomeip_v3;

// Post function signature: sends a discriminated wire message to Dart.
// (discriminator byte, payload pointer, payload length)
using PostFn = std::function<void(uint8_t disc, const uint8_t* data, uint32_t len)>;

class VsomeipApp {
public:
    // Production constructor: creates a real vsomeip application.
    VsomeipApp(const std::string& app_name, const char* config_path, PostFn post_fn);

    // Test constructor: accepts an externally-provided application mock.
    // The caller owns the application lifetime.
    VsomeipApp(std::shared_ptr<vsomeip::application> app, PostFn post_fn);

    ~VsomeipApp();

    // Non-copyable, non-movable (owns a running thread).
    VsomeipApp(const VsomeipApp&) = delete;
    VsomeipApp& operator=(const VsomeipApp&) = delete;

    // Start the vsomeip event loop on a dedicated thread.
    // Must be called exactly once after construction.
    void start();

    // Stop the event loop and join the dedicated thread.
    void stop();

    // Access the underlying vsomeip application (for registering handlers).
    std::shared_ptr<vsomeip::application> app() const { return app_; }

    bool is_running() const { return running_.load(std::memory_order_acquire); }

private:
    void register_handlers();
    void on_state(bool registered);
    void on_availability(uint16_t service_id, uint16_t instance_id, bool available);

    std::shared_ptr<vsomeip::application> app_;
    PostFn post_fn_;
    std::string app_name_;
    std::thread thread_;
    std::atomic<bool> running_{false};
};
