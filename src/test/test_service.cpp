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

// test_service.cpp — Tests for service provider + notify.
//
// Covers:
//   - ServiceRegistry: add/remove services and events
//   - Event group membership tracking
//   - Lookup by service/instance/event
//   - Request callback dispatch
//   - Concurrent add/remove safety
//   - Notify payload encoding via VsomeipSubscriber::encode_header

#include <atomic>
#include <gtest/gtest.h>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

#include "../vsomeip_service.h"
#include "../vsomeip_subscriber.h"
#include "../vsomeip_types.h"

// ── ServiceRegistry tests ───────────────────────────────────────────────────────

TEST(Service, AddAndFindService) {
    ServiceRegistry reg;
    bool called = false;
    reg.add(0x1234, 0x0001, [&](uint8_t, const uint8_t*, uint32_t) { called = true; });

    EXPECT_EQ(reg.service_count(), 1u);
    auto* svc = reg.find(0x1234, 0x0001);
    ASSERT_NE(svc, nullptr);
    EXPECT_EQ(svc->service_id, 0x1234);
    EXPECT_EQ(svc->instance_id, 0x0001);
}

TEST(Service, FindNonexistentReturnsNull) {
    ServiceRegistry reg;
    EXPECT_EQ(reg.find(0x9999, 0x0001), nullptr);
}

TEST(Service, RemoveService) {
    ServiceRegistry reg;
    reg.add(0x1234, 0x0001, [](uint8_t, const uint8_t*, uint32_t) {});
    EXPECT_EQ(reg.service_count(), 1u);

    reg.remove(0x1234, 0x0001);
    EXPECT_EQ(reg.service_count(), 0u);
    EXPECT_EQ(reg.find(0x1234, 0x0001), nullptr);
}

TEST(Service, RemoveNonexistentIsNoop) {
    ServiceRegistry reg;
    reg.remove(0x9999, 0x0001);  // should not crash
    EXPECT_EQ(reg.service_count(), 0u);
}

TEST(Service, MultipleServices) {
    ServiceRegistry reg;
    reg.add(0x1000, 0x0001, [](uint8_t, const uint8_t*, uint32_t) {});
    reg.add(0x2000, 0x0001, [](uint8_t, const uint8_t*, uint32_t) {});
    reg.add(0x1000, 0x0002, [](uint8_t, const uint8_t*, uint32_t) {});

    EXPECT_EQ(reg.service_count(), 3u);
    EXPECT_NE(reg.find(0x1000, 0x0001), nullptr);
    EXPECT_NE(reg.find(0x2000, 0x0001), nullptr);
    EXPECT_NE(reg.find(0x1000, 0x0002), nullptr);
}

// ── Event management tests ──────────────────────────────────────────────────────

TEST(Service, AddEventToService) {
    ServiceRegistry reg;
    reg.add(0x1234, 0x0001, [](uint8_t, const uint8_t*, uint32_t) {});
    reg.add_event(0x1234, 0x0001, 0x8001, {0x01}, false, 0);

    EXPECT_EQ(reg.event_count(0x1234, 0x0001), 1u);
    auto* evt = reg.find_event(0x1234, 0x0001, 0x8001);
    ASSERT_NE(evt, nullptr);
    EXPECT_EQ(evt->event_id, 0x8001);
    EXPECT_FALSE(evt->is_field);
    EXPECT_EQ(evt->cycle_ms, 0u);
    EXPECT_EQ(evt->eventgroup_ids.size(), 1u);
    EXPECT_TRUE(evt->eventgroup_ids.count(0x01));
}

TEST(Service, AddEventToNonexistentServiceIsNoop) {
    ServiceRegistry reg;
    reg.add_event(0x9999, 0x0001, 0x8001, {0x01}, false, 0);
    EXPECT_EQ(reg.find_event(0x9999, 0x0001, 0x8001), nullptr);
}

TEST(Service, MultipleEventsOnSameService) {
    ServiceRegistry reg;
    reg.add(0x1234, 0x0001, [](uint8_t, const uint8_t*, uint32_t) {});
    reg.add_event(0x1234, 0x0001, 0x8001, {0x01}, false, 0);
    reg.add_event(0x1234, 0x0001, 0x8002, {0x01, 0x02}, true, 100);

    EXPECT_EQ(reg.event_count(0x1234, 0x0001), 2u);

    auto* e1 = reg.find_event(0x1234, 0x0001, 0x8001);
    ASSERT_NE(e1, nullptr);
    EXPECT_FALSE(e1->is_field);

    auto* e2 = reg.find_event(0x1234, 0x0001, 0x8002);
    ASSERT_NE(e2, nullptr);
    EXPECT_TRUE(e2->is_field);
    EXPECT_EQ(e2->cycle_ms, 100u);
    EXPECT_EQ(e2->eventgroup_ids.size(), 2u);
}

TEST(Service, RemoveEvent) {
    ServiceRegistry reg;
    reg.add(0x1234, 0x0001, [](uint8_t, const uint8_t*, uint32_t) {});
    reg.add_event(0x1234, 0x0001, 0x8001, {0x01}, false, 0);
    EXPECT_EQ(reg.event_count(0x1234, 0x0001), 1u);

    reg.remove_event(0x1234, 0x0001, 0x8001);
    EXPECT_EQ(reg.event_count(0x1234, 0x0001), 0u);
    EXPECT_EQ(reg.find_event(0x1234, 0x0001, 0x8001), nullptr);
}

TEST(Service, RemoveEventFromNonexistentServiceIsNoop) {
    ServiceRegistry reg;
    reg.remove_event(0x9999, 0x0001, 0x8001);  // no crash
}

TEST(Service, RemoveServiceClearsEvents) {
    ServiceRegistry reg;
    reg.add(0x1234, 0x0001, [](uint8_t, const uint8_t*, uint32_t) {});
    reg.add_event(0x1234, 0x0001, 0x8001, {0x01}, false, 0);
    reg.add_event(0x1234, 0x0001, 0x8002, {0x02}, false, 0);

    reg.remove(0x1234, 0x0001);
    EXPECT_EQ(reg.find_event(0x1234, 0x0001, 0x8001), nullptr);
    EXPECT_EQ(reg.find_event(0x1234, 0x0001, 0x8002), nullptr);
}

TEST(Service, FindEventOnNonexistentService) {
    ServiceRegistry reg;
    EXPECT_EQ(reg.find_event(0x9999, 0x0001, 0x8001), nullptr);
}

TEST(Service, EventCountOnNonexistentService) {
    ServiceRegistry reg;
    EXPECT_EQ(reg.event_count(0x9999, 0x0001), 0u);
}

// ── Request callback dispatch tests ─────────────────────────────────────────────

TEST(Service, RequestCallbackDispatches) {
    ServiceRegistry reg;
    std::vector<uint8_t> received_data;
    uint8_t received_disc = 0;

    reg.add(0x1234, 0x0001, [&](uint8_t disc, const uint8_t* data, uint32_t len) {
        received_disc = disc;
        received_data.assign(data, data + len);
    });

    auto* svc = reg.find(0x1234, 0x0001);
    ASSERT_NE(svc, nullptr);

    uint8_t payload[] = {0xDE, 0xAD};
    svc->request_fn(vsomeip_disc::kMessage, payload, 2);

    EXPECT_EQ(received_disc, vsomeip_disc::kMessage);
    ASSERT_EQ(received_data.size(), 2u);
    EXPECT_EQ(received_data[0], 0xDE);
    EXPECT_EQ(received_data[1], 0xAD);
}

// ── Notify header encoding tests ────────────────────────────────────────────────

TEST(Service, NotifyHeaderEncoding) {
    // Notification has message_type = 0x02 (NOTIFICATION)
    VsomeipMessageHeader hdr{
        .service_id = 0x1234,
        .instance_id = 0x0001,
        .method_id = 0x8001,   // event ID
        .message_type = 0x02,  // NOTIFICATION
        .return_code = 0x00,
        .request_id = 0,
        .payload_len = 10,
    };

    auto bytes = VsomeipSubscriber::encode_header(hdr);
    EXPECT_EQ(bytes[0], vsomeip_disc::kMessage);
    EXPECT_EQ(bytes[7], 0x02);  // NOTIFICATION type
}

TEST(Service, FieldNotifyHeaderEncoding) {
    // A field getter response also uses message type 0x80 (RESPONSE)
    VsomeipMessageHeader hdr{
        .service_id = 0x1234,
        .instance_id = 0x0001,
        .method_id = 0x0010,   // getter method
        .message_type = 0x80,  // RESPONSE (for field GET)
        .return_code = 0x00,
        .request_id = 0x00020003,
        .payload_len = 4,
    };

    auto bytes = VsomeipSubscriber::encode_header(hdr);
    EXPECT_EQ(bytes[7], 0x80);
}

// ── Concurrent access tests ─────────────────────────────────────────────────────

TEST(Service, ConcurrentAddRemove) {
    ServiceRegistry reg;
    constexpr int N = 500;

    std::thread adder([&] {
        for (int i = 0; i < N; ++i) {
            reg.add(static_cast<uint16_t>(i), 0x0001, [](uint8_t, const uint8_t*, uint32_t) {});
        }
    });

    std::thread remover([&] {
        for (int i = 0; i < N; ++i) {
            reg.remove(static_cast<uint16_t>(i), 0x0001);
        }
    });

    adder.join();
    remover.join();

    // Final count depends on race, but no crash/corruption
    EXPECT_LE(reg.service_count(), static_cast<size_t>(N));
}

TEST(Service, ConcurrentEventAddRemove) {
    ServiceRegistry reg;
    reg.add(0x1234, 0x0001, [](uint8_t, const uint8_t*, uint32_t) {});
    constexpr int N = 500;

    std::thread adder([&] {
        for (int i = 0; i < N; ++i) {
            reg.add_event(0x1234, 0x0001, static_cast<uint16_t>(i), {0x01}, false, 0);
        }
    });

    std::thread remover([&] {
        for (int i = 0; i < N; ++i) {
            reg.remove_event(0x1234, 0x0001, static_cast<uint16_t>(i));
        }
    });

    adder.join();
    remover.join();

    EXPECT_LE(reg.event_count(0x1234, 0x0001), static_cast<size_t>(N));
}

// ── Key composition tests ───────────────────────────────────────────────────────

TEST(Service, KeyComposition) {
    auto k1 = ServiceRegistry::make_key(0x1234, 0x0001);
    auto k2 = ServiceRegistry::make_key(0x1234, 0x0002);
    auto k3 = ServiceRegistry::make_key(0x5678, 0x0001);

    EXPECT_NE(k1, k2);
    EXPECT_NE(k1, k3);
    EXPECT_EQ(k1, ServiceRegistry::make_key(0x1234, 0x0001));
}
