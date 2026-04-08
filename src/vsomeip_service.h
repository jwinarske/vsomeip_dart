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

// vsomeip_service.h — Service provider side of the vsomeip bridge.
//
// Manages offering services, offering events/fields, publishing
// notifications, and routing incoming requests to the Dart worker isolate.

#pragma once

#include <cstdint>
#include <functional>
#include <mutex>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

#include "vsomeip_types.h"

// Callback for posting incoming service requests to Dart.
using ServiceRequestFn = std::function<void(uint8_t disc, const uint8_t* data, uint32_t len)>;

// Tracks offered events and their eventgroup memberships.
struct OfferedEvent {
    uint16_t event_id;
    std::set<uint16_t> eventgroup_ids;
    bool is_field;
    uint32_t cycle_ms;
};

// Tracks an offered service and its associated events.
struct OfferedService {
    uint16_t service_id;
    uint16_t instance_id;
    ServiceRequestFn request_fn;
    std::unordered_map<uint16_t, OfferedEvent> events;  // event_id → OfferedEvent
};

// Registry of offered services, keyed by (service_id, instance_id).
class ServiceRegistry {
public:
    using Key = uint32_t;  // (service_id << 16) | instance_id

    static Key make_key(uint16_t service_id, uint16_t instance_id) {
        return (static_cast<uint32_t>(service_id) << 16) | instance_id;
    }

    void add(uint16_t service_id, uint16_t instance_id, ServiceRequestFn request_fn);

    void remove(uint16_t service_id, uint16_t instance_id);

    void add_event(uint16_t service_id,
                   uint16_t instance_id,
                   uint16_t event_id,
                   const std::set<uint16_t>& eventgroup_ids,
                   bool is_field,
                   uint32_t cycle_ms);

    void remove_event(uint16_t service_id, uint16_t instance_id, uint16_t event_id);

    // Look up an offered service. Returns nullptr if not found.
    const OfferedService* find(uint16_t service_id, uint16_t instance_id) const;

    // Look up an offered event. Returns nullptr if not found.
    const OfferedEvent* find_event(uint16_t service_id,
                                   uint16_t instance_id,
                                   uint16_t event_id) const;

    size_t service_count() const;
    size_t event_count(uint16_t service_id, uint16_t instance_id) const;

private:
    mutable std::mutex mutex_;
    std::unordered_map<Key, OfferedService> services_;
};
