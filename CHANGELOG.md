## 0.2.0

- C++ bridge: vsomeip lifecycle, subscribe, register/unregister handler,
  request/response, fire-and-forget, service offer/notify (PRs 1–9).
- Cap'n Proto receive (Path A + B) and send paths (PRs 10–13).
- Two Cap'n Proto Dart generators: jwinarske/capnpc-dart (preferred,
  canonical wire format with full scalar/enum/Text/Data Reader and
  Builder support) wired into `hooks/build.dart` with the in-tree
  Python generator as fallback. New `third_party/capnpc-dart` submodule
  pinned at the upstream revision that adds Text/Data builders.
- Drone cockpit example with attitude indicator, compass, tapes, VSI,
  battery/signal/GPS indicators, sparklines, gimbal indicator, home
  arrow, warnings panel, animated state transitions, HUD info bar,
  watchdog auto-reconnect, and joysticks wired through
  `vsomeip_send_fire_forget`.
- Vehicle dashboard example.
- Reliability + security audit applied:
  - H1 unique_ptr-based post lifecycle (no leak / no double-free)
  - H2/H3 length-overflow guards + 1 MiB payload cap
  - H4 CAS start guard, always-join stop
  - H5 per-app handler tracking and unregister-before-stop
  - M1/M2 MedianFilter scratch preallocation
  - M3 try/catch around Boost.Asio dispatch
  - M4 serialized setenv+init for VsomeipApp
  - M6 NaN-safe filter param validation
  - M9 capnp_align_copy overflow guard
- 135 GoogleTest cases pass; clang-tidy and clang-format enforced.
- Coverage: `.codecov.yml`, `scripts/check_100pct_coverage.py`,
  `scripts/check_min_coverage.py`, and `.github/workflows/coverage.yml`
  enforcing 100% Dart and 95% C++ thresholds.
- CI patterned after jwinarske/pw_dart: dart-test, dart-doc,
  publish-dry-run, clang-format, clang-tidy, flutter-drone-cockpit,
  flutter-vehicle-app jobs in addition to existing build/ASAN/coverage.

## 0.1.0

- Initial scaffold: pubspec, build hook stub, CI, analysis options.
