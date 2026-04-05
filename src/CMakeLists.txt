cmake_minimum_required(VERSION 3.22)
project(vsomeip_bridge_tests LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(BUILD_TESTING "Build unit tests" ON)
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
        vsomeip_subscriber.cpp
        vsomeip_service.cpp
    )
    target_include_directories(vsomeip_bridge_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_link_libraries(vsomeip_bridge_tests PRIVATE GTest::gtest GTest::gtest_main pthread)

    include(GoogleTest)
    gtest_discover_tests(vsomeip_bridge_tests)
endif()
