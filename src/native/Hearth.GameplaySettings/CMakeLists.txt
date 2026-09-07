cmake_minimum_required(VERSION 3.28)
project(Hearth.GameplaySettings LANGUAGES CXX VERSION 0.1.0)

include(CTest)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(HearthGameplaySettings SHARED
  src/GameplaySettingsPlugin.cpp
)

if(WIN32)
  target_compile_definitions(HearthGameplaySettings PRIVATE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    _CRT_SECURE_NO_WARNINGS
  )
  if(MSVC)
    target_compile_options(HearthGameplaySettings PRIVATE /W4 /permissive- /Zc:__cplusplus)
  else()
    target_compile_options(HearthGameplaySettings PRIVATE -Wall -Wextra -Werror -O2)
    target_link_options(HearthGameplaySettings PRIVATE
      -static-libgcc -static-libstdc++ -static
      -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive)
  endif()
  target_link_libraries(HearthGameplaySettings PRIVATE bcrypt)
endif()

set_target_properties(HearthGameplaySettings PROPERTIES
  PREFIX ""
  OUTPUT_NAME "HearthGameplaySettings"
  RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
  LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)

if(BUILD_TESTING AND WIN32)
  add_executable(HearthGameplaySettingsParserTests
    src/GameplaySettingsPlugin.cpp
    tests/GameplaySettingsParserTests.cpp
  )
  target_compile_definitions(HearthGameplaySettingsParserTests PRIVATE
    HEARTH_GAMEPLAY_SETTINGS_TEST
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    _CRT_SECURE_NO_WARNINGS
  )
  if(MSVC)
    target_compile_options(HearthGameplaySettingsParserTests PRIVATE /W4 /permissive- /Zc:__cplusplus)
  else()
    target_compile_options(HearthGameplaySettingsParserTests PRIVATE -Wall -Wextra -Werror -O2)
    target_link_options(HearthGameplaySettingsParserTests PRIVATE
      -static-libgcc -static-libstdc++ -static
      -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive)
  endif()
  target_link_libraries(HearthGameplaySettingsParserTests PRIVATE bcrypt)
  set_target_properties(HearthGameplaySettingsParserTests PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
  )
  add_test(NAME HearthGameplaySettingsParserTests
    COMMAND $<TARGET_FILE:HearthGameplaySettingsParserTests>)
endif()
