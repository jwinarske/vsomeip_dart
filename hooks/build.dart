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
// Dart build hook that will:
//   1. Locate or build vsomeip from env / pkg-config / git submodule
//   2. Compile src/vsomeip_bridge.cpp against vsomeip headers + libs
//   3. Output libvsomeip_bridge.so as a CodeAsset
//
// This is a stub — full implementation lands in PR 3.

import 'dart:io';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // Stub: no native build yet.
    // Full CMake + vsomeip submodule build lands in PR 3.
    stdout.writeln(
      '[vsomeip_dart hook] Stub build hook — no native assets produced.',
    );
  });
}
