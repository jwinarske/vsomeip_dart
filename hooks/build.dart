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

// hooks/build.dart
//
// Dart build hook that:
//   1. Checks for a pre-installed vsomeip (system library or submodule)
//   2. Builds vsomeip from the git submodule if needed
//   3. Compiles src/vsomeip_bridge.cpp against vsomeip headers + libs
//   4. Outputs libvsomeip_bridge.so as a CodeAsset
//
// Environment variables that control the hook:
//   VSOMEIP_PATH       — path to a pre-built vsomeip install (optional)
//   VSOMEIP_SKIP_BUILD — set to "1" to skip bridge compilation entirely

import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (Platform.environment['VSOMEIP_SKIP_BUILD'] == '1') {
      stdout.writeln(
        '[vsomeip_dart hook] VSOMEIP_SKIP_BUILD=1 — skipping native build.',
      );
      return;
    }

    final pkgDir = input.packageRoot.toFilePath();
    final outDir = input.outputDirectory.toFilePath();
    final os = input.config.code.targetOS;

    // ── Locate vsomeip ──────────────────────────────────────────────────────
    // Priority: VSOMEIP_PATH env → system pkg-config → git submodule build
    final (vsomeipInclude, vsomeipLib) = await _locateVsomeip(pkgDir, outDir);

    // ── Generate Cap'n Proto Dart bindings ──────────────────────────────────
    // Priority: jwinarske/capnpc-dart plugin → fall back to the in-tree
    // Python packed-layout generator. The plugin produces canonical
    // wire-format readers; the Python script produces the legacy packed
    // layout used by older committed bindings. We never overwrite hand-
    // edited files (the plugin overwrites; the Python script skips).
    if (Platform.environment['VSOMEIP_SKIP_CAPNP'] != '1') {
      await _generateCapnpDart(pkgDir, outDir);
    }

    // ── Compile the bridge ──────────────────────────────────────────────────
    final ext = os == OS.macOS ? '.dylib' : '.so';
    final libOut = '$outDir/libvsomeip_bridge$ext';

    await _run('clang++', [
      '-std=c++17',
      '-fPIC',
      '-shared',
      '-O3',
      '-DNDEBUG',
      '-I',
      vsomeipInclude,
      '-I',
      '$pkgDir/src',
      '$pkgDir/src/vsomeip_bridge.cpp',
      '$pkgDir/src/vsomeip_app.cpp',
      '$pkgDir/src/vsomeip_service.cpp',
      '$pkgDir/src/vsomeip_subscriber.cpp',
      '$pkgDir/src/dart_api_dl.c',
      '-L',
      vsomeipLib,
      '-lvsomeip3',
      '-lboost_system',
      '-lboost_filesystem',
      '-lboost_thread',
      '-lpthread',
      '-ldl',
      '-o',
      libOut,
      '-Wl,-rpath,\$ORIGIN',
    ]);

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'vsomeip_bridge',
        linkMode: DynamicLoadingBundled(),
        file: Uri.file(libOut),
      ),
    );

    // Track source files for incremental rebuilds
    for (final f in [
      'vsomeip_bridge.cpp',
      'vsomeip_app.cpp',
      'vsomeip_subscriber.cpp',
      'vsomeip_service.cpp',
      'vsomeip_bridge.h',
      'vsomeip_types.h',
      'ring_buffer.h',
    ]) {
      output.dependencies.add(Uri.file('$pkgDir/src/$f'));
    }
  });
}

// ── vsomeip location logic ─────────────────────────────────────────────────────

Future<(String, String)> _locateVsomeip(String pkgDir, String outDir) async {
  // 1. Explicit env override
  final envPath = Platform.environment['VSOMEIP_PATH'];
  if (envPath != null && Directory(envPath).existsSync()) {
    return ('$envPath/interface', '$envPath/lib');
  }

  // 2. System pkg-config
  final pkgResult = await Process.run('pkg-config', ['--cflags', 'vsomeip3']);
  if (pkgResult.exitCode == 0) {
    final incDir = pkgResult.stdout
        .toString()
        .trim()
        .replaceAll('-I', '')
        .trim();
    final libResult = await Process.run('pkg-config', [
      '--libs-only-L',
      'vsomeip3',
    ]);
    final libDir = libResult.stdout
        .toString()
        .trim()
        .replaceAll('-L', '')
        .trim();
    return (incDir, libDir);
  }

  // 3. Build from submodule
  return await _buildVsomeipSubmodule(pkgDir, outDir);
}

Future<(String, String)> _buildVsomeipSubmodule(
  String pkgDir,
  String outDir,
) async {
  final sdkDir = '$pkgDir/third_party/vsomeip';
  final buildDir = '$outDir/vsomeip_build';

  if (!Directory(sdkDir).existsSync()) {
    throw StateError(
      '[vsomeip_dart hook] vsomeip submodule not found at $sdkDir.\n'
      'Run: git submodule update --init --recursive\n'
      'Or set VSOMEIP_PATH to a pre-built vsomeip install.',
    );
  }

  final stamp = File('$outDir/.vsomeip_built');
  if (!stamp.existsSync()) {
    stdout.writeln('[vsomeip_dart hook] Building vsomeip from submodule...');
    await _run('cmake', [
      '-B',
      buildDir,
      sdkDir,
      '-GNinja',
      '-DCMAKE_BUILD_TYPE=Release',
      '-DCMAKE_INSTALL_PREFIX=$outDir/vsomeip_install',
      '-DENABLE_SIGNAL_HANDLING=1',
      '-DDIAGNOSIS_ADDRESS=0x01',
    ]);
    await _run('ninja', ['-C', buildDir]);
    await _run('ninja', ['-C', buildDir, 'install']);
    stamp.writeAsStringSync(DateTime.now().toIso8601String());
  }

  return ('$outDir/vsomeip_install/include', '$outDir/vsomeip_install/lib');
}

// ── Cap'n Proto Dart binding generation ─────────────────────────────────────────
//
// Resolution order for the `capnpc-dart` plugin:
//   1. CAPNPC_DART env var pointing at the binary
//   2. `capnpc-dart` on PATH
//   3. Build it from the third_party/capnpc-dart submodule and cache the
//      binary under $outDir/capnpc-dart-build/capnpc-dart.
//
// If `capnp` itself is not on PATH, or all of the above fail, fall back to
// `tool/capnp_dart_gen.py` (pure-Python, packed layout). The fallback never
// breaks the build — capnp Dart bindings are optional codegen.

Future<void> _generateCapnpDart(String pkgDir, String outDir) async {
  final schemaDir = '$pkgDir/schemas';
  final libGen = '$pkgDir/lib/generated';
  if (!Directory(schemaDir).existsSync()) {
    return;
  }

  // Need `capnp` itself for either path.
  final capnpAvail = await _which('capnp');
  if (capnpAvail == null) {
    stdout.writeln(
      '[vsomeip_dart hook] capnp not on PATH — skipping Cap\'n Proto Dart codegen',
    );
    return;
  }

  final plugin = await _locateCapnpcDart(pkgDir, outDir);
  final schemas = Directory(schemaDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.capnp'))
      .toList();

  if (plugin != null) {
    stdout.writeln('[vsomeip_dart hook] Using capnpc-dart plugin: $plugin');
    // Make the plugin discoverable to `capnp compile -odart` by ensuring its
    // directory is on PATH for the child process.
    final pluginDir = File(plugin).parent.path;
    final env = <String, String>{
      'PATH': '$pluginDir:${Platform.environment['PATH'] ?? ''}',
    };
    Directory(libGen).createSync(recursive: true);
    for (final schema in schemas) {
      // capnpc-dart writes <schema>.capnp.dart next to the schema. We move
      // it into lib/generated/ after to keep schemas/ clean.
      try {
        await _runEnv('capnp', ['compile', '-odart', schema.path], env: env);
        final produced = File('${schema.path}.dart');
        if (produced.existsSync()) {
          final dest = '$libGen/${schema.uri.pathSegments.last}.dart';
          produced.renameSync(dest);
          stdout.writeln(
            '[vsomeip_dart hook]   ${schema.uri.pathSegments.last} -> $dest',
          );
        }
      } catch (e) {
        stderr.writeln(
          '[vsomeip_dart hook] capnpc-dart failed for ${schema.path}: $e',
        );
        // Don't fall back per-file — bail out and let the Python fallback
        // run for the whole batch instead.
        await _generateCapnpDartPython(pkgDir);
        return;
      }
    }
    return;
  }

  // No plugin available — fall back to the Python generator.
  await _generateCapnpDartPython(pkgDir);
}

Future<String?> _locateCapnpcDart(String pkgDir, String outDir) async {
  // 1. Explicit env override.
  final env = Platform.environment['CAPNPC_DART'];
  if (env != null && File(env).existsSync()) {
    return env;
  }

  // 2. Already on PATH.
  final onPath = await _which('capnpc-dart');
  if (onPath != null) {
    return onPath;
  }

  // 3. Build from submodule (cached under outDir).
  final srcDir = '$pkgDir/third_party/capnpc-dart';
  if (!Directory(srcDir).existsSync()) {
    return null;
  }
  final buildDir = '$outDir/capnpc-dart-build';
  final binary = '$buildDir/capnpc-dart';
  if (File(binary).existsSync()) {
    return binary;
  }
  stdout.writeln(
    '[vsomeip_dart hook] Building capnpc-dart plugin from submodule...',
  );
  try {
    await _run('cmake', [
      '-B',
      buildDir,
      srcDir,
      '-GNinja',
      '-DCMAKE_BUILD_TYPE=Release',
    ]);
    await _run('ninja', ['-C', buildDir, 'capnpc-dart']);
  } catch (e) {
    stderr.writeln(
      '[vsomeip_dart hook] capnpc-dart submodule build failed: $e',
    );
    return null;
  }
  return File(binary).existsSync() ? binary : null;
}

Future<void> _generateCapnpDartPython(String pkgDir) async {
  final script = '$pkgDir/tool/capnp_dart_gen.py';
  if (!File(script).existsSync()) {
    return;
  }
  stdout.writeln(
    '[vsomeip_dart hook] Falling back to Python capnp_dart_gen.py (packed layout)',
  );
  try {
    await _run('python3', [
      script,
      '--schema-dir',
      '$pkgDir/schemas',
      '--output-dir',
      '$pkgDir/lib/generated',
    ]);
  } catch (e) {
    stderr.writeln('[vsomeip_dart hook] Python capnp generator failed: $e');
  }
}

Future<String?> _which(String exe) async {
  try {
    final r = await Process.run('which', [exe]);
    if (r.exitCode != 0) return null;
    final p = r.stdout.toString().trim();
    return p.isEmpty ? null : p;
  } catch (_) {
    return null;
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────────

Future<void> _run(
  String exe,
  List<String> args, {
  String? workingDirectory,
}) async {
  stdout.writeln('[vsomeip_dart hook] $exe ${args.join(' ')}');
  final r = await Process.run(
    exe,
    args,
    workingDirectory: workingDirectory,
    runInShell: true,
  );
  if (r.exitCode != 0) {
    stderr.writeln(r.stderr);
    throw ProcessException(exe, args, r.stderr.toString(), r.exitCode);
  }
}

Future<void> _runEnv(
  String exe,
  List<String> args, {
  Map<String, String>? env,
  String? workingDirectory,
}) async {
  stdout.writeln('[vsomeip_dart hook] $exe ${args.join(' ')}');
  final r = await Process.run(
    exe,
    args,
    environment: env,
    includeParentEnvironment: true,
    workingDirectory: workingDirectory,
    runInShell: true,
  );
  if (r.exitCode != 0) {
    stderr.writeln(r.stderr);
    throw ProcessException(exe, args, r.stderr.toString(), r.exitCode);
  }
}
