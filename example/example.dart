// Canonical pub.dev example for vsomeip_dart.
//
// Spawns a real VsomeipClient with a worker isolate, subscribes to a
// SOME/IP event, prints decoded float32 samples, and shuts down cleanly
// after a fixed duration.
//
// ── vsomeip routing ──────────────────────────────────────────────────────
//
// vsomeip is a client/server stack: every process talks to a *routing
// host* over the Unix domain socket /run/vsomeip/vsomeip-0. Exactly one
// process in a vsomeip domain is the routing host (declared via
// `"routing": "<app_name>"` in the JSON config); all others are clients.
//
// If you run this example with no config and no routing host already
// running, vsomeip will spam reconnect warnings every 100 ms because the
// socket doesn't exist. To make this process its OWN routing host, point
// it at a config file whose `"routing"` field matches `--app` (default
// `vsomeip_example`).
//
// Two ways to do that:
//
//   1. Run a sibling process as the routing host (e.g. drone_sim or the
//      simulator under example/simulator/) and start this example after.
//
//   2. Pass a config file that names this process as the routing host:
//
//        dart run example/example.dart \
//            --config $PWD/example/simulator/vsomeip_local.json
//
//      and edit the config so `"routing": "vsomeip_example"`.
//
// You also need libvsomeip_bridge.so. Build it with `dart pub get`
// (which runs hooks/build.dart), or with the in-tree CMake build:
//
//     cmake -B build-real src/ -GNinja && cmake --build build-real
//
// and run from the package root so the example finds it.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:vsomeip_dart/vsomeip_dart.dart';

// Vehicle speed signal — match the simulator under example/simulator/.
const _speedService = 0x1234;
const _speedInstance = 0x0001;
const _speedEventgroup = 0x0001;
const _speedEvent = 0x8001;

Future<void> main(List<String> args) async {
  final parsed = _parseArgs(args);
  if (parsed.help) {
    _printHelp();
    return;
  }

  print('vsomeip_dart example: subscribe to vehicle speed');
  if (parsed.configPath != null) {
    print('  config: ${parsed.configPath}');
  } else {
    print('  config: (none — vsomeip will use default config search)');
    print('  hint:   pass --config <path/to/vsomeip.json> to silence the');
    print('          reconnect spam if no routing host is already running.');
  }
  print('  app:    ${parsed.appName}');
  print('  duration: ${parsed.durationSec}s');

  // 1. Create the client. spawn() launches a worker isolate that owns
  //    the native receive port, then starts the underlying vsomeip
  //    application. Native callbacks fire on Boost.Asio's io_service
  //    thread and are forwarded to the worker via Dart_PostCObject_DL.
  final client = await VsomeipClient.spawn(
    bindings: NativeVsomeipBindings.open(_findBridgeLibrary()),
    appName: parsed.appName,
    configPath: parsed.configPath,
  );

  // 2. Watch service availability (optional but useful for diagnostics).
  final availSub = client.availabilityChanges.listen((event) {
    print(
      '  availability: '
      'svc=0x${event.serviceId.toRadixString(16)} '
      'inst=0x${event.instanceId.toRadixString(16)} '
      '${event.available ? "UP" : "DOWN"}',
    );
  });

  // 3. Subscribe. The worker isolate writes throttled messages to a
  //    SendPort that the client multiplexes into a per-(svc,inst,evt)
  //    Stream. maxHz=60 caps the per-event rate to 60 Hz at the worker
  //    so a noisy 1 kHz CAN signal can't hammer the UI.
  final stream = client.subscribeEvent(
    serviceId: _speedService,
    instanceId: _speedInstance,
    eventgroupId: _speedEventgroup,
    eventId: _speedEvent,
    workerPort: 0, // worker auto-selects
    maxHz: 60,
  );

  var samples = 0;
  final msgSub = stream.listen((msg) {
    samples++;
    final payload = msg.payload;
    if (payload != null && payload.length >= 4) {
      final speedKmh = ByteData.sublistView(
        payload,
      ).getFloat32(0, Endian.little);
      print(
        '  #$samples speed=${speedKmh.toStringAsFixed(1)} km/h '
        '(${payload.length}B)',
      );
    } else {
      print('  #$samples (empty payload)');
    }
  });

  // 4. Run for a fixed window so the example terminates under `dart run`.
  await Future<void>.delayed(Duration(seconds: parsed.durationSec));

  print('Received $samples sample(s); shutting down.');

  // 5. Clean teardown — unsubscribe, cancel listeners, kill the worker.
  client.unsubscribeEvent(
    serviceId: _speedService,
    instanceId: _speedInstance,
    eventgroupId: _speedEventgroup,
  );
  await msgSub.cancel();
  await availSub.cancel();
  await client.close();
}

class _Args {
  final String? configPath;
  final String appName;
  final int durationSec;
  final bool help;
  const _Args({
    required this.configPath,
    required this.appName,
    required this.durationSec,
    required this.help,
  });
}

_Args _parseArgs(List<String> args) {
  String? config;
  var appName = 'vsomeip_example';
  var duration = 5;
  var help = false;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() {
      if (i + 1 >= args.length) {
        stderr.writeln('error: $a expects a value');
        exit(2);
      }
      return args[++i];
    }

    switch (a) {
      case '--config':
      case '-c':
        config = next();
      case '--app':
      case '-a':
        appName = next();
      case '--duration':
      case '-d':
        duration = int.tryParse(next()) ?? duration;
      case '--help':
      case '-h':
        help = true;
      default:
        stderr.writeln('error: unknown argument: $a');
        exit(2);
    }
  }
  return _Args(
    configPath: config,
    appName: appName,
    durationSec: duration,
    help: help,
  );
}

void _printHelp() {
  print('''
Usage: dart run example/example.dart [options]

Options:
  -c, --config <path>     Path to a vsomeip JSON config file. Use a config
                          whose "routing" field equals --app to make this
                          process its own routing host.
  -a, --app <name>        vsomeip application name (default: vsomeip_example).
                          Must match the "routing" field in --config to act
                          as the routing host.
  -d, --duration <sec>    How long to listen before shutting down (default: 5).
  -h, --help              Show this message.

Environment:
  VSOMEIP_BRIDGE_PATH     Absolute path to libvsomeip_bridge.so. If unset,
                          the example searches LD_LIBRARY_PATH and the
                          common build dirs (build-real/, build/).
''');
}

/// Locate libvsomeip_bridge.so without requiring it to be on the system
/// loader path. Resolution order:
///   1. VSOMEIP_BRIDGE_PATH environment variable (absolute file path)
///   2. Each directory in LD_LIBRARY_PATH
///   3. Common build output dirs relative to the package root
///   4. Bare name (last resort — uses the system loader)
String _findBridgeLibrary() {
  const soName = 'libvsomeip_bridge.so';
  final env = Platform.environment['VSOMEIP_BRIDGE_PATH'];
  if (env != null && File(env).existsSync()) return env;

  final ldPath = Platform.environment['LD_LIBRARY_PATH'] ?? '';
  for (final dir in ldPath.split(':')) {
    if (dir.isEmpty) continue;
    final p = '$dir/$soName';
    if (File(p).existsSync()) return p;
  }

  for (final p in [
    'build-real/$soName',
    'build/$soName',
    '../../build-real/$soName',
    '../../build/$soName',
  ]) {
    if (File(p).existsSync()) return p;
  }

  return soName;
}
