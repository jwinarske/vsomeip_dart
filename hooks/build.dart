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
