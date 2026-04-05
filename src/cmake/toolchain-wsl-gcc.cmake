# cmake/toolchain-wsl-gcc.cmake
#
# WSL / Linux GCC toolchain.
#
# Usage (CLion CMake profile → CMake options):
#   -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-wsl-gcc.cmake
#
# Or from a WSL terminal:
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-wsl-gcc.cmake

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)   # change to aarch64 if targeting ARM

# Use GCC from the WSL distro's PATH.  Override with absolute paths if needed.
find_program(CMAKE_C_COMPILER   gcc  REQUIRED)
find_program(CMAKE_CXX_COMPILER g++  REQUIRED)

# Prefer libraries / headers that live inside WSL, not on the Windows host.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

