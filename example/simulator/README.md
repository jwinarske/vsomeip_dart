# Vehicle Signal Simulator

Standalone signal simulator for testing the Flutter vehicle dashboard
without real vehicle hardware.

## Signals

| Event ID | Signal | Rate | Schema |
|----------|--------|------|--------|
| 0x8001 | Vehicle Speed | 100 Hz | VehicleSpeed (16 B) |
| 0x8002 | Engine RPM | 50 Hz | — |
| 0x8003 | Coolant Temp | 1 Hz | — |

All signals are published on service 0x1234, instance 0x0001, eventgroup 0x0001.

## Driving Profile

The simulator cycles through four phases:

1. **Idle** (2-7 s) — engine at 800 rpm, speed decaying to 0
2. **Accelerate** (5-15 s) — ramp to random target speed (30-130 km/h)
3. **Cruise** (10-30 s) — hold speed with sensor noise
4. **Brake** (3-8 s) — decelerate to near-zero

RPM is derived from speed via a 6-speed gearbox approximation.
Coolant temperature slowly tracks engine load.

## Quick Start

```bash
# Terminal 1: start the vsomeip routing manager
VSOMEIP_CONFIGURATION=example/simulator/vsomeip_local.json vsomeipd

# Terminal 2: start the simulator
VSOMEIP_CONFIGURATION=example/simulator/vsomeip_local.json \
  dart run example/simulator/vehicle_speed_sim.dart

# Terminal 3: start the Flutter dashboard
VSOMEIP_CONFIGURATION=example/simulator/vsomeip_local.json \
  cd example/flutter_vehicle_app && flutter run
```

## Configuration

`vsomeip_local.json` configures local-only routing with:
- Unicast on 127.0.0.1
- Service discovery via UDP multicast 224.224.224.1:30490
- Simulator as the routing manager (app ID 0x1001)
- Dashboard as a client (app ID 0x1002)
- Three events in one eventgroup on service 0x1234

## Without vsomeip

The simulator can run standalone to verify the driving profile:

```bash
dart run example/simulator/vehicle_speed_sim.dart
```

It prints speed/rpm/temperature to the console once per second regardless
of whether vsomeip is available.
