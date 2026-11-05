cmake_minimum_required(VERSION 3.28)
project(Hearth.Identity LANGUAGES CXX VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(WIN32)
  add_library(HearthIdentity SHARED
    src/IdentityPlugin.cpp
    src/IdentityCore.cpp
  )
  target_compile_definitions(HearthIdentity PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
  if(MSVC)
    target_compile_options(HearthIdentity PRIVATE /W4 /permissive- /Zc:__cplusplus /EHsc)
  else()
    target_compile_options(HearthIdentity PRIVATE -Wall -Wextra -Werror -O2)
    target_link_options(HearthIdentity PRIVATE
      -static-libgcc -static-libstdc++ -static
      -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive)
  endif()

  set_target_properties(HearthIdentity PROPERTIES
    PREFIX ""
    OUTPUT_NAME "HearthIdentity"
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
  )
endif()

# the decision core also builds and runs on Linux (Checks): tests/identity_core_test.cpp
if(NOT WIN32)
  add_executable(identity_core_test tests/identity_core_test.cpp src/IdentityCore.cpp)
  target_include_directories(identity_core_test PRIVATE src)
  target_compile_options(identity_core_test PRIVATE -Wall -Wextra -Werror -O1)
endif()
