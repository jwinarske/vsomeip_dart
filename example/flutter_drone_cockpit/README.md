# Drone Cockpit — vsomeip_dart Flutter example

A drone telemetry cockpit displaying:

- **Artificial horizon** (attitude indicator) — pitch + roll with sky/ground gradient and pitch ladder
- **Compass / heading tape** — horizontal scrolling with cardinal labels
- **Altitude tape** — vertical scrolling with major/minor ticks
- **Ground speed tape** — same style as altitude
- **VSI** — vertical speed indicator with bidirectional fill
- **Battery** — percent + voltage with color zones
- **Signal strength** — RSSI percentage
- **GPS** — fix type + satellite count
- **Two virtual joysticks** — touch input (mode 2: throttle/yaw + pitch/roll)
- **Flight mode** — STABILIZE / LOITER / RTH / MANUAL
- **Armed status** — top-left badge

## Architecture

Same patterns as `flutter_vehicle_app`:

| Layer | Pattern |
|---|---|
| C → Dart transport | `Dart_PostCObject_DL` with `kExternalTypedData` (port-based) |
| High-frequency telemetry | `ValueNotifier<double>` per signal |
| Painters | `CustomPainter` with `super(repaint:)` |
| Layer isolation | `RepaintBoundary` around each instrument |
| Low-frequency widgets | `ValueListenableBuilder` (battery, signal, GPS) |
| Native smoothing | EMA filter on attitude pitch (heaviest jitter source) |

The artificial horizon uses two listenables (`pitch` + `roll`) merged via
`Listenable.merge` so the painter repaints on either change.

## Quick start

```bash
# 1. Build the bridge + simulators (from app/vsomeip_dart/)
cmake -B build-real src/ -GNinja
cmake --build build-real

# 2. Start the drone simulator (terminal 1)
VSOMEIP_CONFIGURATION=example/flutter_drone_cockpit/vsomeip_drone.json \
  ./build-real/drone_sim

# 3. Run the cockpit (terminal 2)
cd example/flutter_drone_cockpit
LD_LIBRARY_PATH=../../build-real \
VSOMEIP_CONFIGURATION=../../example/flutter_drone_cockpit/vsomeip_drone.json \
flutter run
```

Tap **CONNECT** at the top to subscribe. The drone will start in loiter
mode at 2.5 m altitude, slowly climbing/descending in 90-second cycles
while the battery drains at ~5%/min.

## SOME/IP signals

Service `0x2000`, instance `0x0001`, eventgroup `0x0001`:

| Event | Rate | Payload |
|---|---|---|
| `0x9001` attitude | 50 Hz | `[float32 pitch][float32 roll][float32 yaw][float32 throttle]` (radians) |
| `0x9002` motion | 10 Hz | `[float32 alt_m][float32 vsi_ms][float32 gnd_speed_ms][float32 distance_m]` |
| `0x9003` battery | 1 Hz | `[float32 voltage_v][float32 percent]` |
| `0x9004` status | on change | `[u8 armed][u8 mode][u8 gps_fix][u8 sat_count]` |
| `0x9005` signal | 2 Hz | `[u8 rssi_pct][u8 link_quality][u8][u8]` |

## Known limitations (this example)

- Joystick input is captured locally but not yet sent back to the drone
  (would need a `vsomeip_send_request` round-trip — left as an exercise).
- Only one vsomeip routing manager can run on a host at a time. If you
  also have `vehicle_sim` running with `vsomeip_local.json` configured
  as routing manager, stop it before starting `drone_sim`.
