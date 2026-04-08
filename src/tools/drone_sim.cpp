//
//    Copyright (c) 2026 Joel Winarske
//
//    Licensed under the Apache License, Version 2.0 (the "License");
//

// drone_sim.cpp — Standalone vsomeip drone telemetry simulator.
//
// Publishes plausible drone telemetry over real vsomeip IPC. The drone
// hovers, drifts, occasionally climbs and turns, and gradually drains
// its battery — providing a moving target for the flutter_drone_cockpit
// example app.
//
// Service:  0x2000  Instance: 0x0001
// Events:
//   0x9001  attitude     50 Hz   16 B  (pitch, roll, yaw, throttle)
//   0x9002  motion       10 Hz   16 B  (altitude_m, vsi_ms, gnd_speed_ms, distance_m)
//   0x9003  battery       1 Hz    8 B  (voltage_v, percent)
//   0x9004  status     onchg     4 B  (armed, flight_mode, gps_fix, sat_count)
//   0x9005  signal        2 Hz    4 B  (rssi_pct, link_quality)

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <random>
#include <set>
#include <thread>
#include <vsomeip/vsomeip.hpp>

static constexpr vsomeip::service_t SERVICE_ID = 0x2000;
static constexpr vsomeip::instance_t INSTANCE_ID = 0x0001;
static constexpr vsomeip::eventgroup_t EVENTGROUP = 0x0001;
static constexpr vsomeip::event_t ATTITUDE_EVT = 0x9001;
static constexpr vsomeip::event_t MOTION_EVT = 0x9002;
static constexpr vsomeip::event_t BATTERY_EVT = 0x9003;
static constexpr vsomeip::event_t STATUS_EVT = 0x9004;
static constexpr vsomeip::event_t SIGNAL_EVT = 0x9005;
static constexpr vsomeip::event_t GIMBAL_EVT = 0x9006;

// Method (cockpit → drone): control input. Fire-and-forget.
static constexpr vsomeip::method_t CTRL_INPUT_METHOD = 0xA001;

static std::atomic<bool> g_running{true};
static void signal_handler(int) {
    g_running = false;
}

// ── Drone simulation state ──────────────────────────────────────────────────

struct DroneState {
    // Attitude (radians)
    double pitch = 0;        // nose up/down
    double roll = 0;         // bank left/right
    double yaw = 0;          // heading 0..2π (north = 0)
    double throttle = 0.45;  // 0..1, hover ≈ 0.45

    // Motion
    double altitude_m = 2.5;  // meters above home
    double vsi_ms = 0;        // vertical speed
    double ground_speed_ms = 0;
    double distance_m = 0;  // horizontal distance from home

    // Battery
    double voltage_v = 16.8;  // 4S LiPo full
    double percent = 100;

    // Status
    uint8_t armed = 1;
    uint8_t flight_mode = 1;  // 0=manual, 1=stabilize, 2=loiter, 3=rth
    uint8_t gps_fix = 3;      // 0=none, 1=2D, 2=3D, 3=DGPS
    uint8_t sat_count = 14;

    // Signal
    uint8_t rssi_pct = 95;
    uint8_t link_quality = 99;

    // Gimbal (degrees)
    double gimbal_pitch_deg = 0;  // -90..0 (looking down to forward)
    double gimbal_roll_deg = 0;

    // Pilot input override (set by control input method).
    // When override_active is true, the pilot inputs replace the autopilot's
    // station-keeping behavior for a few seconds (then decays back to auto).
    double pilot_throttle = 0;    // -1..+1 (vertical)
    double pilot_yaw = 0;         // -1..+1
    double pilot_pitch = 0;       // -1..+1 (forward/back)
    double pilot_roll = 0;        // -1..+1
    double pilot_input_age = 99;  // seconds since last pilot input

    // Internals
    double sim_time = 0;
    std::mt19937 rng{1337};

    double noise(double amp) {
        std::uniform_real_distribution<double> d(-amp, amp);
        return d(rng);
    }

    void tick(double dt) {
        sim_time += dt;
        pilot_input_age += dt;

        // Pilot input is "fresh" if received in the last 1.5 seconds
        const bool pilot_active = pilot_input_age < 1.5;

        // Heading
        if (pilot_active) {
            yaw += pilot_yaw * 1.2 * dt;  // 1.2 rad/s max yaw rate
        } else {
            yaw += 0.05 * dt + noise(0.002);  // autopilot drift
        }
        if (yaw < 0)
            yaw += 2 * M_PI;
        if (yaw >= 2 * M_PI)
            yaw -= 2 * M_PI;

        // Attitude
        if (pilot_active) {
            // Pilot pitch/roll command directly bank/pitch the drone
            pitch = pilot_pitch * 0.4 + noise(0.005);  // ±23°
            roll = pilot_roll * 0.4 + noise(0.005);
        } else {
            pitch = 0.03 * std::sin(sim_time * 0.7) + noise(0.005);
            roll = 0.04 * std::sin(sim_time * 0.5 + 1.0) + noise(0.005);
        }

        // VSI
        if (pilot_active) {
            vsi_ms = pilot_throttle * 3.0 + noise(0.05);  // ±3 m/s climb/descent
        } else {
            // Periodic altitude changes — climb 30s, hold 30s, descend 30s
            const double cycle = std::fmod(sim_time, 90.0);
            if (cycle < 30.0) {
                vsi_ms = 0.8 + noise(0.1);
            } else if (cycle < 60.0) {
                vsi_ms = noise(0.05);
            } else {
                vsi_ms = -0.6 + noise(0.1);
            }
        }
        altitude_m += vsi_ms * dt;
        altitude_m = std::clamp(altitude_m, 0.0, 120.0);

        // Throttle tracks vsi (rough proxy)
        throttle = 0.45 + vsi_ms * 0.15;
        throttle = std::clamp(throttle, 0.0, 1.0);

        // Ground speed: from pitch/roll inputs (real drone physics)
        ground_speed_ms =
            std::min(8.0, std::abs(roll) * 12.0 + std::abs(pitch) * 12.0 + noise(0.2));
        ground_speed_ms = std::max(0.0, ground_speed_ms);

        // Distance from home accumulates roughly with ground speed
        distance_m += ground_speed_ms * dt * 0.3;

        // Gimbal slowly sweeps -45°..0° in a 12-second cycle
        gimbal_pitch_deg = -22.5 + 22.5 * std::sin(sim_time * 0.5);
        gimbal_roll_deg = noise(0.5);

        // Battery drains: ~5% per minute when active
        percent -= dt * (5.0 / 60.0);
        percent = std::clamp(percent, 0.0, 100.0);
        // Voltage curve: 4.2V/cell full → 3.5V/cell empty (4S)
        voltage_v = 14.0 + (percent / 100.0) * 2.8;

        // Signal quality wanders a bit
        const int rssi_noise = static_cast<int>(noise(2));
        int rssi = static_cast<int>(rssi_pct) + rssi_noise;
        rssi_pct = static_cast<uint8_t>(std::clamp(rssi, 70, 100));

        const int link_noise = static_cast<int>(noise(1));
        int link = static_cast<int>(link_quality) + link_noise;
        link_quality = static_cast<uint8_t>(std::clamp(link, 80, 100));

        // GPS sat count occasionally drops a sat
        if ((static_cast<int>(sim_time * 10) % 100) == 0) {
            sat_count = static_cast<uint8_t>(12 + (rng() % 4));
        }
    }
};

// ── Payload builders ────────────────────────────────────────────────────────

template <typename T>
static void pack(uint8_t* buf, size_t off, T value) {
    std::memcpy(buf + off, &value, sizeof(T));
}

static std::shared_ptr<vsomeip::payload> build_attitude(std::shared_ptr<vsomeip::runtime>& rt,
                                                        const DroneState& s) {
    uint8_t buf[16] = {};
    pack(buf, 0, static_cast<float>(s.pitch));
    pack(buf, 4, static_cast<float>(s.roll));
    pack(buf, 8, static_cast<float>(s.yaw));
    pack(buf, 12, static_cast<float>(s.throttle));
    auto pl = rt->create_payload();
    pl->set_data(buf, sizeof(buf));
    return pl;
}

static std::shared_ptr<vsomeip::payload> build_motion(std::shared_ptr<vsomeip::runtime>& rt,
                                                      const DroneState& s) {
    uint8_t buf[16] = {};
    pack(buf, 0, static_cast<float>(s.altitude_m));
    pack(buf, 4, static_cast<float>(s.vsi_ms));
    pack(buf, 8, static_cast<float>(s.ground_speed_ms));
    pack(buf, 12, static_cast<float>(s.distance_m));
    auto pl = rt->create_payload();
    pl->set_data(buf, sizeof(buf));
    return pl;
}

static std::shared_ptr<vsomeip::payload> build_battery(std::shared_ptr<vsomeip::runtime>& rt,
                                                       const DroneState& s) {
    uint8_t buf[8] = {};
    pack(buf, 0, static_cast<float>(s.voltage_v));
    pack(buf, 4, static_cast<float>(s.percent));
    auto pl = rt->create_payload();
    pl->set_data(buf, sizeof(buf));
    return pl;
}

static std::shared_ptr<vsomeip::payload> build_status(std::shared_ptr<vsomeip::runtime>& rt,
                                                      const DroneState& s) {
    uint8_t buf[4];
    buf[0] = s.armed;
    buf[1] = s.flight_mode;
    buf[2] = s.gps_fix;
    buf[3] = s.sat_count;
    auto pl = rt->create_payload();
    pl->set_data(buf, sizeof(buf));
    return pl;
}

static std::shared_ptr<vsomeip::payload> build_signal(std::shared_ptr<vsomeip::runtime>& rt,
                                                      const DroneState& s) {
    uint8_t buf[4];
    buf[0] = s.rssi_pct;
    buf[1] = s.link_quality;
    buf[2] = 0;
    buf[3] = 0;
    auto pl = rt->create_payload();
    pl->set_data(buf, sizeof(buf));
    return pl;
}

static std::shared_ptr<vsomeip::payload> build_gimbal(std::shared_ptr<vsomeip::runtime>& rt,
                                                      const DroneState& s) {
    uint8_t buf[8] = {};
    pack(buf, 0, static_cast<float>(s.gimbal_pitch_deg));
    pack(buf, 4, static_cast<float>(s.gimbal_roll_deg));
    auto pl = rt->create_payload();
    pl->set_data(buf, sizeof(buf));
    return pl;
}

// ── Main ────────────────────────────────────────────────────────────────────

int main() {
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    auto rt = vsomeip::runtime::get();
    auto app = rt->create_application("drone_sim");

    if (!app->init()) {
        std::cerr << "vsomeip init failed\n";
        return 1;
    }

    std::cout << "Drone Telemetry Simulator (vsomeip)\n"
              << "===================================\n"
              << "Service: 0x" << std::hex << SERVICE_ID << " Instance: 0x" << INSTANCE_ID
              << std::dec << "\n"
              << "Events: attitude(50Hz) motion(10Hz) battery(1Hz)\n";

    DroneState s;
    std::mutex pilot_mutex;

    app->register_state_handler([&](vsomeip::state_type_e state) {
        if (state == vsomeip::state_type_e::ST_REGISTERED) {
            std::cout << "[drone] Registered with routing manager\n";
            app->offer_service(SERVICE_ID, INSTANCE_ID);
            std::set<vsomeip::eventgroup_t> grp{EVENTGROUP};
            for (auto evt :
                 {ATTITUDE_EVT, MOTION_EVT, BATTERY_EVT, STATUS_EVT, SIGNAL_EVT, GIMBAL_EVT}) {
                app->offer_event(
                    SERVICE_ID, INSTANCE_ID, evt, grp, vsomeip::event_type_e::ET_EVENT);
            }
            std::cout << "[drone] Service offered with 6 events\n";
        }
    });

    // Control input method handler — fire-and-forget from cockpit.
    // Payload: 4 floats LE [throttle][yaw][pitch][roll], each -1..+1.
    app->register_message_handler(SERVICE_ID,
                                  INSTANCE_ID,
                                  CTRL_INPUT_METHOD,
                                  [&](const std::shared_ptr<vsomeip::message>& msg) {
                                      auto pl = msg->get_payload();
                                      if (!pl || pl->get_length() < 16)
                                          return;
                                      const uint8_t* d = pl->get_data();
                                      float thr, yaw, pitch, roll;
                                      std::memcpy(&thr, d + 0, sizeof(float));
                                      std::memcpy(&yaw, d + 4, sizeof(float));
                                      std::memcpy(&pitch, d + 8, sizeof(float));
                                      std::memcpy(&roll, d + 12, sizeof(float));

                                      std::lock_guard<std::mutex> lock(pilot_mutex);
                                      s.pilot_throttle = thr;
                                      s.pilot_yaw = yaw;
                                      s.pilot_pitch = pitch;
                                      s.pilot_roll = roll;
                                      s.pilot_input_age = 0;
                                  });

    std::thread vsomeip_thread([&] { app->start(); });
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    int tick_count = 0;
    uint8_t last_armed = 0xFF;
    uint8_t last_mode = 0xFF;
    uint8_t last_fix = 0xFF;
    uint8_t last_sats = 0xFF;

    constexpr int kTickHz = 50;  // 20 ms per tick
    constexpr double kDt = 1.0 / kTickHz;

    std::cout << "[drone] Publishing. Ctrl-C to stop.\n";

    while (g_running) {
        s.tick(kDt);

        // Attitude — every tick (50 Hz)
        app->notify(SERVICE_ID, INSTANCE_ID, ATTITUDE_EVT, build_attitude(rt, s));

        // Motion — every 5th tick (10 Hz)
        if (tick_count % 5 == 0) {
            app->notify(SERVICE_ID, INSTANCE_ID, MOTION_EVT, build_motion(rt, s));
        }

        // Gimbal — every 10th tick (5 Hz)
        if (tick_count % 10 == 0) {
            app->notify(SERVICE_ID, INSTANCE_ID, GIMBAL_EVT, build_gimbal(rt, s));
        }

        // Signal — every 25th tick (2 Hz)
        if (tick_count % 25 == 0) {
            app->notify(SERVICE_ID, INSTANCE_ID, SIGNAL_EVT, build_signal(rt, s));
        }

        // Battery — every 50th tick (1 Hz)
        if (tick_count % 50 == 0) {
            app->notify(SERVICE_ID, INSTANCE_ID, BATTERY_EVT, build_battery(rt, s));
        }

        // Status — only on change
        if (s.armed != last_armed || s.flight_mode != last_mode || s.gps_fix != last_fix ||
            s.sat_count != last_sats) {
            app->notify(SERVICE_ID, INSTANCE_ID, STATUS_EVT, build_status(rt, s));
            last_armed = s.armed;
            last_mode = s.flight_mode;
            last_fix = s.gps_fix;
            last_sats = s.sat_count;
        }

        // Console summary once per second
        if (tick_count % 50 == 0) {
            std::cout << "[drone] alt=" << std::fixed << std::setprecision(1) << s.altitude_m
                      << "m vsi=" << (s.vsi_ms >= 0 ? "+" : "") << s.vsi_ms
                      << "m/s spd=" << s.ground_speed_ms
                      << "m/s hdg=" << static_cast<int>(s.yaw * 180.0 / M_PI)
                      << "° batt=" << static_cast<int>(s.percent)
                      << "% sats=" << static_cast<int>(s.sat_count) << "\n";
        }

        ++tick_count;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }

    std::cout << "\n[drone] Stopping...\n";
    for (auto evt : {ATTITUDE_EVT, MOTION_EVT, BATTERY_EVT, STATUS_EVT, SIGNAL_EVT, GIMBAL_EVT}) {
        app->stop_offer_event(SERVICE_ID, INSTANCE_ID, evt);
    }
    app->stop_offer_service(SERVICE_ID, INSTANCE_ID);
    app->stop();
    if (vsomeip_thread.joinable())
        vsomeip_thread.join();
    return 0;
}
