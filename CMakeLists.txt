cmake_minimum_required(VERSION 3.29)

# Wink — an agentic-first web browser built on Chromium (via CEF) with a
# native AppKit/SwiftUI shell.
#
#   make bootstrap   # fetch the pinned Chromium engine
#   make             # configure + build build/Wink.app
#   make run
#
# Note: Objective-C++ (.mm) sources are intentionally compiled as CXX (we do
# not enable the OBJCXX language) so CEF's wrapper and our engine share flags.

set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")
project(Wink VERSION 0.2.0 LANGUAGES C CXX Swift)

if(NOT APPLE)
  message(FATAL_ERROR "Wink currently targets macOS only.")
endif()
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# Toolchain workaround: some Command Line Tools upgrades leave a stale
# usr/include/swift/module.modulemap beside bridging.modulemap, so every Swift
# compile fails with "redefinition of module 'SwiftBridging'". Hide the stale
# file from our compiles with a VFS overlay instead of modifying the system.
execute_process(COMMAND xcode-select -p OUTPUT_VARIABLE _dev_dir OUTPUT_STRIP_TRAILING_WHITESPACE)
set(_swift_include "${_dev_dir}/usr/include/swift")
if(EXISTS "${_swift_include}/module.modulemap" AND EXISTS "${_swift_include}/bridging.modulemap")
  file(READ "${_swift_include}/module.modulemap" _stale_modulemap)
  if(_stale_modulemap MATCHES "module SwiftBridging")
    set(_overlay_dir "${CMAKE_BINARY_DIR}/swift-overlay")
    file(WRITE "${_overlay_dir}/empty.modulemap" "")
    file(WRITE "${_overlay_dir}/overlay.yaml" "{
  \"version\": 0,
  \"case-sensitive\": \"false\",
  \"roots\": [ { \"type\": \"directory\", \"name\": \"${_swift_include}\",
    \"contents\": [ { \"type\": \"file\", \"name\": \"module.modulemap\",
                      \"external-contents\": \"${_overlay_dir}/empty.modulemap\" } ] } ]
}
")
    string(APPEND CMAKE_Swift_FLAGS " -vfsoverlay ${_overlay_dir}/overlay.yaml")
    message(STATUS "Swift: hiding stale ${_swift_include}/module.modulemap via VFS overlay")
  endif()
endif()

# ---------------------------------------------------------------------------
# Chromium engine (CEF)
# ---------------------------------------------------------------------------
set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/third_party/cef")
if(NOT EXISTS "${CEF_ROOT}/cmake/FindCEF.cmake")
  message(FATAL_ERROR "Chromium engine not found. Run `make bootstrap` first.")
endif()
if(NOT DEFINED PROJECT_ARCH)
  set(PROJECT_ARCH "${CMAKE_HOST_SYSTEM_PROCESSOR}")
endif()
list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

# cef_variables.cmake lowers these; restore ours for Wink's own targets.
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")
set(CMAKE_OSX_ARCHITECTURES "${PROJECT_ARCH}")

option(WINK_USE_SANDBOX "Run Chromium child processes in the macOS sandbox" ON)
option(WINK_DEV_MOCK_KEYCHAIN
       "Use Chromium's mock keychain (avoids Keychain prompts for ad-hoc signed dev builds)" ON)

set(WINK_CXX_FLAGS
  -std=c++20
  -fno-rtti
  -fno-exceptions
  -fno-strict-aliasing
  -fstack-protector
  -fvisibility=hidden
  -fvisibility-inlines-hidden
  -fobjc-call-cxx-cdtors
  -Wall
  -Wextra
  -Wno-unused-parameter
  -Wno-missing-field-initializers
  $<$<CONFIG:Release>:-O3>
  $<$<CONFIG:Debug>:-O0 -g>
)

set(WINK_FRAMEWORKS
  "-framework AppKit"
  "-framework Cocoa"
  "-framework IOSurface"
  "-framework QuartzCore"
)

# ---------------------------------------------------------------------------
# WinkEngine — Objective-C++ bridge over CEF, exposed to Swift as a module.
# ---------------------------------------------------------------------------
file(GLOB WINK_ENGINE_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/Engine/src/*.mm"
  "${CMAKE_CURRENT_SOURCE_DIR}/Engine/src/*.cc")
file(GLOB WINK_ENGINE_OBJC_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/Engine/src/*.mm")
set_source_files_properties(${WINK_ENGINE_OBJC_SOURCES} PROPERTIES COMPILE_OPTIONS "-fobjc-arc")

add_library(WinkEngine STATIC ${WINK_ENGINE_SOURCES})
add_dependencies(WinkEngine libcef_dll_wrapper)
target_compile_options(WinkEngine PRIVATE ${WINK_CXX_FLAGS})
target_include_directories(WinkEngine
  PUBLIC  "${CMAKE_CURRENT_SOURCE_DIR}/Engine/include"
  PRIVATE "${CEF_ROOT}" "${CMAKE_CURRENT_SOURCE_DIR}/Engine/src")
if(WINK_DEV_MOCK_KEYCHAIN)
  target_compile_definitions(WinkEngine PRIVATE WINK_DEV_MOCK_KEYCHAIN=1)
endif()
target_link_libraries(WinkEngine PUBLIC libcef_dll_wrapper ${WINK_FRAMEWORKS})

# ---------------------------------------------------------------------------
# Wink Helper — Chromium child process (renderer, GPU, utility, ...).
# ---------------------------------------------------------------------------
add_executable(WinkHelper "${CMAKE_CURRENT_SOURCE_DIR}/Helper/helper_main.mm")
add_dependencies(WinkHelper libcef_dll_wrapper)
set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/Helper/helper_main.mm"
  PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_compile_options(WinkHelper PRIVATE ${WINK_CXX_FLAGS})
target_include_directories(WinkHelper PRIVATE "${CEF_ROOT}")
if(WINK_USE_SANDBOX)
  target_compile_definitions(WinkHelper PRIVATE CEF_USE_SANDBOX=1)
endif()
target_link_libraries(WinkHelper PRIVATE libcef_dll_wrapper ${WINK_FRAMEWORKS})
target_link_options(WinkHelper PRIVATE "LINKER:-ObjC" "$<$<CONFIG:Release>:LINKER:-dead_strip>")
set_target_properties(WinkHelper PROPERTIES OUTPUT_NAME "Wink Helper")

# ---------------------------------------------------------------------------
# Wink — the browser app (Swift).
# ---------------------------------------------------------------------------
file(GLOB_RECURSE WINK_APP_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/App/*.swift")
add_executable(Wink ${WINK_APP_SOURCES})
target_link_libraries(Wink PRIVATE WinkEngine c++ sqlite3)
target_link_options(Wink PRIVATE "LINKER:-ObjC" "$<$<CONFIG:Release>:LINKER:-dead_strip>")
set_target_properties(Wink PROPERTIES
  Swift_MODULE_NAME WinkBrowser
  Swift_COMPILATION_MODE wholemodule)
target_compile_options(Wink PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-swift-version 5>"
  "$<$<AND:$<COMPILE_LANGUAGE:Swift>,$<CONFIG:Release>>:-O>")

# ---------------------------------------------------------------------------
# wink-mcp — tiny stdio <-> unix-socket bridge so any MCP client
# (Claude Code, Claude Desktop, ...) can drive Wink.
# ---------------------------------------------------------------------------
file(GLOB WINK_BRIDGE_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/Bridge/*.swift")
add_executable(wink-mcp ${WINK_BRIDGE_SOURCES})
set_target_properties(wink-mcp PROPERTIES
  Swift_MODULE_NAME WinkMCPBridge
  Swift_COMPILATION_MODE wholemodule)
target_compile_options(wink-mcp PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:SHELL:-swift-version 5>"
  "$<$<AND:$<COMPILE_LANGUAGE:Swift>,$<CONFIG:Release>>:-O>")

# ---------------------------------------------------------------------------
# Wink.app bundle assembly + ad-hoc signing.
# A different bundle id (e.g. app.wink.browser.dev) gives a side-by-side dev
# build its own preferences and data folder.
# ---------------------------------------------------------------------------
set(WINK_BUNDLE_ID "app.wink.browser" CACHE STRING "CFBundleIdentifier of Wink.app")
add_custom_target(bundle ALL
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/bundle.sh"
          --out "${CMAKE_BINARY_DIR}/Wink.app"
          --app "$<TARGET_FILE:Wink>"
          --helper "$<TARGET_FILE:WinkHelper>"
          --bridge "$<TARGET_FILE:wink-mcp>"
          --cef "${CEF_ROOT}/Release"
          --resources "${CMAKE_CURRENT_SOURCE_DIR}/Resources"
          --version "${PROJECT_VERSION}"
          --bundle-id "${WINK_BUNDLE_ID}"
  DEPENDS Wink WinkHelper wink-mcp
  COMMENT "Assembling Wink.app"
  VERBATIM
  USES_TERMINAL)

# ---------------------------------------------------------------------------
# Tests (pure C++, no Chromium): `cmake --build build --target wink_tests`
# ---------------------------------------------------------------------------
add_executable(wink_tests EXCLUDE_FROM_ALL
  "${CMAKE_CURRENT_SOURCE_DIR}/Tests/content_blocker_test.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/Engine/src/content_blocker.cc")
target_include_directories(wink_tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/Engine/src")
target_compile_options(wink_tests PRIVATE -std=c++20 -Wall -Wextra)
