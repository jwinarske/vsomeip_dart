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

// dart_api_dl.c — Stub for Dart API DL initialisation.
//
// In production, this file includes dart_api_dl.c from the Dart SDK
// (via the native_assets_cli package) which provides the implementation
// of Dart_InitializeApiDL and Dart_PostCObject_DL.
//
// For unit testing without the Dart VM, this stub provides no-op
// implementations. The real Dart SDK file will replace this when the
// full build hook compiles the bridge against the Dart SDK headers.

#include "dart_api_dl.h"

// Placeholder: real implementation comes from the Dart SDK's dart_api_dl.c.
// The build hook links the real file; this stub enables compilation without
// the Dart SDK present.
