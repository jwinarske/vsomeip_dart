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

// vehicle_sim.cpp — Standalone vsomeip vehicle speed signal simulator.
//
// Publishes VehicleSpeed notifications at 100 Hz over real vsomeip IPC
// with a realistic driving profile (accelerate → cruise → brake → idle).
//
// Usage:
//   VSOMEIP_CONFIGURATION=example/simulator/vsomeip_local.json ./vehicle_sim

#include <vsomeip/vsomeip.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <random>
#include <set>
#include <thread>

// SOME/IP identifiers — must match vsomeip_local.json and dashboard
static constexpr vsomeip::service_t   SERVICE_ID   = 0x1234;
static constexpr vsomeip::instance_t  INSTANCE_ID  = 0x0001;
static constexpr vsomeip::eventgroup_t EVENTGROUP   = 0x0001;
static constexpr vsomeip::event_t     SPEED_EVENT  = 0x8001;

static std::atomic<bool> g_running{true};

static void signal_handler(int) { g_running = false; }

// ── Driving profile simulator ───────────────────────────────────────────────

enum class Phase { idle, accelerate, cruise, brake };

struct DrivingSim {
    double speed_kmh = 0;
    double rpm = 800;
    double coolant_temp = 70;
    Phase  phase = Phase::idle;
    double phase_timer = 0;
    double target_speed = 0;
    std::mt19937 rng{42};

    double noise(double amp) {
        std::uniform_real_distribution<double> d(-amp, amp);
        return d(rng);
    }

    double gear(double spd) {
        if (spd < 15) return 1;
        if (spd < 30) return 2;
        if (spd < 50) return 3;
        if (spd < 80) return 4;
        if (spd < 120) return 5;
        return 6;
    }

    void next_phase() {
        std::uniform_real_distribution<double> d(0, 1);
        switch (phase) {
            case Phase::idle:
                phase = Phase::accelerate;
                target_speed = 30 + d(rng) * 100;
                phase_timer = 5 + d(rng) * 10;
                break;
            case Phase::accelerate:
                phase = Phase::cruise;
                phase_timer = 10 + d(rng) * 20;
                break;
            case Phase::cruise:
                phase = Phase::brake;
                phase_timer = 3 + d(rng) * 5;
                break;
            case Phase::brake:
                phase = Phase::idle;
                phase_timer = 2 + d(rng) * 5;
                break;
        }
    }

    void tick(double dt) {
        phase_timer -= dt;
        if (phase_timer <= 0) next_phase();

        switch (phase) {
            case Phase::accelerate:
                speed_kmh += std::clamp((target_speed - speed_kmh) * 0.5 * dt,
                                        0.0, 40.0 * dt);
                speed_kmh += noise(0.3);
                break;
            case Phase::cruise:
                speed_kmh += noise(0.5);
                speed_kmh = std::clamp(speed_kmh, 0.0, 250.0);
                break;
            case Phase::brake:
                speed_kmh -= std::clamp(speed_kmh * 0.8 * dt, 0.0, 60.0 * dt);
                speed_kmh += noise(0.2);
                speed_kmh = std::max(0.0, speed_kmh);
                break;
            case Phase::idle:
                speed_kmh = std::max(0.0, speed_kmh - 5 * dt);
                break;
        }

        if (speed_kmh < 1) {
            rpm = 800 + noise(20);
        } else {
            auto g = gear(speed_kmh);
            rpm = std::clamp(speed_kmh * 60 / (g * 3.6), 800.0, 7000.0)
                  + noise(30);
        }

        double target_temp = 85 + (rpm / 7000.0) * 15 + noise(0.5);
        coolant_temp += (target_temp - coolant_temp) * 0.01 * dt;
        coolant_temp = std::clamp(coolant_temp, 60.0, 120.0);
    }

    const char* phase_name() const {
        switch (phase) {
            case Phase::idle:       return "idle";
            case Phase::accelerate: return "accel";
            case Phase::cruise:     return "cruise";
            case Phase::brake:      return "brake";
        }
        return "?";
    }
};

// ── Build VehicleSpeed payload (matches VehicleSpeedBuilder layout) ──────────

static std::shared_ptr<vsomeip::payload> build_speed_payload(
    std::shared_ptr<vsomeip::runtime>& rt,
    float speed_kmh, uint64_t timestamp, uint16_t sensor_id,
    uint8_t quality_flag = 0) {

    // Layout: [float32 LE][uint64 LE][uint16 LE][uint8][uint8] = 16 bytes
    uint8_t buf[16] = {};
    std::memcpy(buf + 0,  &speed_kmh,  sizeof(float));
    std::memcpy(buf + 4,  &timestamp,  sizeof(uint64_t));
    std::memcpy(buf + 12, &sensor_id,  sizeof(uint16_t));
    buf[14] = quality_flag;

    auto pl = rt->create_payload();
    pl->set_data(buf, sizeof(buf));
    return pl;
}

// ── Main ────────────────────────────────────────────────────────────────────

int main() {
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    auto rt  = vsomeip::runtime::get();
    auto app = rt->create_application("vehicle_sim");

    if (!app->init()) {
        std::cerr << "vsomeip init failed\n";
        return 1;
    }

    std::cout << "Vehicle Signal Simulator (vsomeip)\n"
              << "===================================\n"
              << "Service: 0x" << std::hex << SERVICE_ID
              << " Instance: 0x" << INSTANCE_ID << std::dec << "\n"
              << "Speed event: 0x" << std::hex << SPEED_EVENT
              << " @ 100 Hz\n" << std::dec;

    app->register_state_handler([&](vsomeip::state_type_e state) {
        if (state == vsomeip::state_type_e::ST_REGISTERED) {
            std::cout << "[sim] Registered with routing manager\n";
            app->offer_service(SERVICE_ID, INSTANCE_ID);

            std::set<vsomeip::eventgroup_t> groups{EVENTGROUP};
            app->offer_event(SERVICE_ID, INSTANCE_ID, SPEED_EVENT, groups,
                             vsomeip::event_type_e::ET_EVENT);

            std::cout << "[sim] Service offered, event offered\n";
        }
    });

    // Start vsomeip event loop on background thread
    std::thread vsomeip_thread([&] { app->start(); });

    // Wait for registration
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    DrivingSim sim;
    int tick = 0;

    std::cout << "[sim] Publishing at 100 Hz. Ctrl-C to stop.\n";

    while (g_running) {
        sim.tick(0.01);  // 10 ms step

        auto now = std::chrono::system_clock::now();
        auto us  = std::chrono::duration_cast<std::chrono::microseconds>(
                       now.time_since_epoch()).count();

        float speed_f = static_cast<float>(sim.speed_kmh);
        auto pl = build_speed_payload(rt, speed_f,
                                      static_cast<uint64_t>(us),
                                      0x0001);
        app->notify(SERVICE_ID, INSTANCE_ID, SPEED_EVENT, pl);

        // Print once per second
        if (++tick % 100 == 0) {
            std::cout << "[sim] speed=" << std::fixed
                      << std::setprecision(1) << sim.speed_kmh
                      << " km/h  rpm=" << std::setprecision(0) << sim.rpm
                      << "  temp=" << std::setprecision(1) << sim.coolant_temp
                      << " C  phase=" << sim.phase_name() << "\n";
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    std::cout << "\n[sim] Stopping...\n";
    app->stop_offer_event(SERVICE_ID, INSTANCE_ID, SPEED_EVENT);
    app->stop_offer_service(SERVICE_ID, INSTANCE_ID);
    app->stop();
    if (vsomeip_thread.joinable()) vsomeip_thread.join();
    std::cout << "[sim] Done.\n";
    return 0;
}
