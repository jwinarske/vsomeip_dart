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

// dart_api_dl.h — Dart API DL types for the bridge.
//
// Defines the Dart_CObject types needed for Dart_PostCObject_DL.
// When the real Dart SDK headers are available (via build hook), they
// replace this file. This minimal version enables compilation.

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int64_t Dart_Port_DL;

// Dart_CObject types used by the bridge
typedef enum {
    Dart_CObject_kNull = 0,
    Dart_CObject_kBool,
    Dart_CObject_kInt32,
    Dart_CObject_kInt64,
    Dart_CObject_kDouble,
    Dart_CObject_kString,
    Dart_CObject_kArray,
    Dart_CObject_kTypedData,
    Dart_CObject_kExternalTypedData,
    Dart_CObject_kSendPort,
    Dart_CObject_kCapability,
    Dart_CObject_kUnsupported,
    Dart_CObject_kNumberOfTypes
} Dart_CObject_Type;

typedef enum {
    Dart_TypedData_kByteData = 0,
    Dart_TypedData_kInt8,
    Dart_TypedData_kUint8,
    Dart_TypedData_kUint8Clamped,
    Dart_TypedData_kInt16,
    Dart_TypedData_kUint16,
    Dart_TypedData_kInt32,
    Dart_TypedData_kUint32,
    Dart_TypedData_kInt64,
    Dart_TypedData_kUint64,
    Dart_TypedData_kFloat32,
    Dart_TypedData_kFloat64,
    Dart_TypedData_kFloat32x4,
    Dart_TypedData_kInvalid
} Dart_TypedData_Type;

typedef struct _Dart_CObject Dart_CObject;

typedef void (*Dart_HandleFinalizer)(void* isolate_callback_data, void* peer);

struct _Dart_CObject {
    Dart_CObject_Type type;
    union {
        bool as_bool;
        int32_t as_int32;
        int64_t as_int64;
        double as_double;
        const char* as_string;
        struct {
            intptr_t length;
            Dart_CObject** values;
        } as_array;
        struct {
            Dart_TypedData_Type type;
            intptr_t length;
            const uint8_t* values;
        } as_typed_data;
        struct {
            Dart_TypedData_Type type;
            intptr_t length;
            uint8_t* data;
            void* peer;
            Dart_HandleFinalizer callback;
        } as_external_typed_data;
    } value;
};

// Dart_InitializeApiDL: initialise the Dart API dynamic linking.
// Returns 0 on success.
int Dart_InitializeApiDL(void* data);

// Dart_PostCObject_DL: post a Dart_CObject to a native port.
// Returns true on success.
bool Dart_PostCObject_DL(Dart_Port_DL port_id, Dart_CObject* message);

#ifdef __cplusplus
}
#endif
