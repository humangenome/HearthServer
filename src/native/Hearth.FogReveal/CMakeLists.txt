cmake_minimum_required(VERSION 3.28)
project(Hearth.FogReveal LANGUAGES CXX VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(HearthFogReveal SHARED
  src/FogRevealPlugin.cpp
)

if(WIN32)
  target_compile_definitions(HearthFogReveal PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
  if(MSVC)
    target_compile_options(HearthFogReveal PRIVATE /W4 /permissive- /Zc:__cplusplus)
  else()
    target_compile_options(HearthFogReveal PRIVATE -Wall -Wextra -Werror -O2)
    target_link_options(HearthFogReveal PRIVATE
      -static-libgcc -static-libstdc++ -static
      -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive)
  endif()
endif()

set_target_properties(HearthFogReveal PROPERTIES
  PREFIX ""
  OUTPUT_NAME "HearthFogReveal"
  RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
  LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
