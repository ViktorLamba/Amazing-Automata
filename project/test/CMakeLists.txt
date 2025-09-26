cmake_minimum_required(VERSION 3.10)

project(cpp_test VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(cpp_test src/main.cpp)
