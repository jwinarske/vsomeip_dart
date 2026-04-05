cmake_minimum_required(VERSION 3.22)
project(vsomeip_bridge_tests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(BUILD_TESTING "Build unit tests" ON)

if(BUILD_TESTING)
    enable_testing()
    find_package(GTest REQUIRED)

    add_executable(vsomeip_bridge_tests
        test/test_types.cpp
        test/test_ring_buffer.cpp
    )
    target_include_directories(vsomeip_bridge_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_link_libraries(vsomeip_bridge_tests PRIVATE GTest::gtest GTest::gtest_main pthread)

    include(GoogleTest)
    gtest_discover_tests(vsomeip_bridge_tests)
endif()
