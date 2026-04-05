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

// dart_api_dl.h — Minimal Dart API DL types for the bridge.
//
// In production, the build hook provides the real dart_api_dl.h from
// the Dart SDK. This header defines the subset of types needed by the
// bridge C ABI so that compilation succeeds without the full SDK.

#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int64_t Dart_Port_DL;

// Dart_InitializeApiDL: initialise the Dart API dynamic linking.
// Returns 0 on success.
int Dart_InitializeApiDL(void* data);

// Dart_PostCObject_DL: post a Dart_CObject to a native port.
// Returns true on success.
bool Dart_PostCObject_DL(Dart_Port_DL port, void* message);

#ifdef __cplusplus
}
#endif
