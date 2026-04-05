cmake_minimum_required(VERSION 3.22)

# ── Platform guard ────────────────────────────────────────────────────────────
# vsomeip3 requires Linux: it uses Netlink sockets, /dev/shm shared memory, and
# other Linux-kernel APIs that are not available on macOS, Windows, or BSD.
# Fail immediately on any non-Linux host to avoid confusing toolchain errors.
if(NOT CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR
        "Unsupported host platform: '${CMAKE_HOST_SYSTEM_NAME}'.\n"
        "vsomeip3 requires Linux — it depends on Netlink sockets and other\n"
        "Linux-specific kernel APIs not available on this platform.\n"
        "\n"
        "If you are using CLion on Windows:\n"
        "  Settings → Build, Execution, Deployment → Toolchains\n"
        "  → add a 'WSL' toolchain, then set that toolchain for this CMake profile.\n"
        "\n"
        "Alternatively, build directly from a Linux/WSL terminal:\n"
        "  cmake -B build -DBUILD_TESTING=ON && cmake --build build")
endif()

project(vsomeip_bridge LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(BUILD_TESTING "Build unit tests" ON)
option(BUILD_VSOMEIP_BRIDGE "Build libvsomeip_bridge.so (requires vsomeip3)" OFF)
option(BUILD_VSOMEIP_TOOLS "Build standalone vsomeip tools (requires vsomeip3)" OFF)
option(ENABLE_ASAN "Enable AddressSanitizer" OFF)
option(ENABLE_COVERAGE "Enable gcov coverage" OFF)

if(ENABLE_ASAN)
    add_compile_options(-fsanitize=address -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address)
endif()

if(ENABLE_COVERAGE)
    add_compile_options(--coverage -fprofile-arcs -ftest-coverage)
    add_link_options(--coverage)
endif()

# ── vsomeip3 detection (only when needed) ────────────────────────────────────

if(BUILD_VSOMEIP_BRIDGE OR BUILD_VSOMEIP_TOOLS)
    include(FindPkgConfig)
    pkg_check_modules(VSOMEIP3 vsomeip3)

    if(NOT VSOMEIP3_FOUND)
        # Fallback: check standard paths
        find_path(VSOMEIP3_INCLUDE_DIR vsomeip/vsomeip.hpp
            PATHS /usr/include /usr/local/include)
        find_library(VSOMEIP3_LIB vsomeip3
            PATHS /usr/lib /usr/lib64 /usr/local/lib)
        if(VSOMEIP3_INCLUDE_DIR AND VSOMEIP3_LIB)
            set(VSOMEIP3_FOUND TRUE)
            set(VSOMEIP3_INCLUDE_DIRS ${VSOMEIP3_INCLUDE_DIR})
            set(VSOMEIP3_LIBRARIES ${VSOMEIP3_LIB})
        endif()
    endif()

    if(NOT VSOMEIP3_FOUND)
        message(WARNING "vsomeip3 not found — skipping bridge and tool targets")
    endif()
endif()

# ── Unit tests (no vsomeip dependency) ───────────────────────────────────────

if(BUILD_TESTING)
    enable_testing()
    find_package(GTest REQUIRED)

    # Tests that don't require vsomeip headers
    add_executable(vsomeip_bridge_tests
        test/test_types.cpp
        test/test_ring_buffer.cpp
        test/test_vsomeip_app.cpp
        test/test_subscriber.cpp
        test/test_request_response.cpp
        test/test_service.cpp
        test/test_capnp_bridge.cpp
        test/test_capnp_subscriber.cpp
        test/test_capnp_service.cpp
        vsomeip_subscriber.cpp
        vsomeip_service.cpp
        capnp_subscriber.cpp
        capnp_service.cpp
    )
    target_include_directories(vsomeip_bridge_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_link_libraries(vsomeip_bridge_tests PRIVATE GTest::gtest GTest::gtest_main pthread)

    include(GoogleTest)
    gtest_discover_tests(vsomeip_bridge_tests)
endif()

# ── Real bridge shared library (links vsomeip3) ─────────────────────────────

if(BUILD_VSOMEIP_BRIDGE AND VSOMEIP3_FOUND)
    add_library(vsomeip_bridge_so SHARED
        vsomeip_bridge.cpp
        vsomeip_app.cpp
        vsomeip_subscriber.cpp
        vsomeip_service.cpp
        capnp_subscriber.cpp
        capnp_service.cpp
        dart_api_dl.c
    )
    set_target_properties(vsomeip_bridge_so PROPERTIES
        OUTPUT_NAME vsomeip_bridge
        PREFIX "lib"
    )
    target_include_directories(vsomeip_bridge_so PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${VSOMEIP3_INCLUDE_DIRS}
    )
    target_link_libraries(vsomeip_bridge_so PRIVATE
        ${VSOMEIP3_LIBRARIES}
        boost_system boost_filesystem boost_thread
        pthread dl
    )
    message(STATUS "Building libvsomeip_bridge.so")
endif()

# ── Standalone vehicle simulator ─────────────────────────────────────────────

if(BUILD_VSOMEIP_TOOLS AND VSOMEIP3_FOUND)
    add_executable(vehicle_sim tools/vehicle_sim.cpp)
    target_include_directories(vehicle_sim PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${VSOMEIP3_INCLUDE_DIRS}
    )
    target_link_libraries(vehicle_sim PRIVATE
        ${VSOMEIP3_LIBRARIES}
        boost_system boost_thread
        pthread
    )
    message(STATUS "Building vehicle_sim")
endif()
