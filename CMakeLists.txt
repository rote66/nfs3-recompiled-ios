cmake_minimum_required(VERSION 3.15)
project(nfs3 LANGUAGES C CXX)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "This repository builds NFS3 for iOS. Run ./build.sh or ./build.sh simulator.")
endif()

enable_language(OBJCXX)
add_subdirectory(ios)
