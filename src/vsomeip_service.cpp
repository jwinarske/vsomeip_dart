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

#include "vsomeip_service.h"

void ServiceRegistry::add(uint16_t service_id, uint16_t instance_id, ServiceRequestFn request_fn) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto key = make_key(service_id, instance_id);
    services_[key] = OfferedService{
        .service_id = service_id,
        .instance_id = instance_id,
        .request_fn = std::move(request_fn),
        .events = {},
    };
}

void ServiceRegistry::remove(uint16_t service_id, uint16_t instance_id) {
    std::lock_guard<std::mutex> lock(mutex_);
    services_.erase(make_key(service_id, instance_id));
}

void ServiceRegistry::add_event(uint16_t service_id,
                                uint16_t instance_id,
                                uint16_t event_id,
                                const std::set<uint16_t>& eventgroup_ids,
                                bool is_field,
                                uint32_t cycle_ms) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto key = make_key(service_id, instance_id);
    auto it = services_.find(key);
    if (it == services_.end())
        return;

    it->second.events[event_id] = OfferedEvent{
        .event_id = event_id,
        .eventgroup_ids = eventgroup_ids,
        .is_field = is_field,
        .cycle_ms = cycle_ms,
    };
}

void ServiceRegistry::remove_event(uint16_t service_id, uint16_t instance_id, uint16_t event_id) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto key = make_key(service_id, instance_id);
    auto it = services_.find(key);
    if (it == services_.end())
        return;
    it->second.events.erase(event_id);
}

const OfferedService* ServiceRegistry::find(uint16_t service_id, uint16_t instance_id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = services_.find(make_key(service_id, instance_id));
    return it != services_.end() ? &it->second : nullptr;
}

const OfferedEvent* ServiceRegistry::find_event(uint16_t service_id,
                                                uint16_t instance_id,
                                                uint16_t event_id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto key = make_key(service_id, instance_id);
    auto sit = services_.find(key);
    if (sit == services_.end())
        return nullptr;
    auto eit = sit->second.events.find(event_id);
    return eit != sit->second.events.end() ? &eit->second : nullptr;
}

size_t ServiceRegistry::service_count() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return services_.size();
}

size_t ServiceRegistry::event_count(uint16_t service_id, uint16_t instance_id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = services_.find(make_key(service_id, instance_id));
    return it != services_.end() ? it->second.events.size() : 0;
}
