# This file tells CMake what to build: which source files make up each
# program, which C++ standard to use and which tests to run. CMake reads it and
# generates the build files that Ninja then uses to compile your code.

# 3.21 is the first version that reads version 3 CMakePresets.json files.
cmake_minimum_required(VERSION 3.21)

# All course code is C++. C is enabled only because the shared "clang" preset
# also sets CMAKE_C_COMPILER, which CMake would otherwise report as unused.
project(IB9JHO_Environment_Setup LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Enable the common warnings, using the spelling the compiler front end expects
# (clang-cl and MSVC take /W4; Clang, AppleClang and GCC take -Wall -Wextra).
if(CMAKE_CXX_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC")
    add_compile_options(/W4)
else()
    add_compile_options(-Wall -Wextra)
endif()

add_executable(my_program src/main.cpp)

enable_testing()
add_subdirectory(tests)
