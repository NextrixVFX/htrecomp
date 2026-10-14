cmake_minimum_required(VERSION 3.25)

if(POLICY CMP0091)
    cmake_policy(SET CMP0091 NEW)
endif()

# Default OFF since rexglue-sdk v0.9.0+. This is set before add_subdirectory,
# so it applies to the SDK targets too - and rexruntime and rexgpu-xenos are
# both SHARED. The static CRT therefore gives the executable and each DLL its
# own CRT instance: separate heaps, separate STL state, separate CRT globals.
#
# That breaks this architecture in at least two places, both of which kill the
# process with STATUS_STACK_BUFFER_OVERRUN (0xC0000409) via __fastfail - which
# bypasses SEH, so the crash handler in src/main.cpp never runs and no
# crash_dump.txt is written. The process simply disappears:
#
#   * GetExecutablePath() reading _wpgmptr, a CRT global that only the
#     executable's CRT startup populates (fixed SDK-side, but it was a symptom)
#   * InitializeShaderStorage passing std::filesystem::path across the module
#     boundary and spawning threads
#
# ON is kept available because it is what a redistributable build wants - no
# dependency on the VC++ runtime. If you turn it back on, expect to chase
# every place a C++ object crosses a module boundary.
#
# OFF makes the build depend on MSVCP140.dll / VCRUNTIME140.dll, so shipping
# one means shipping those or requiring the VC++ redistributable.
option(HTRECOMP_STATIC_MSVC_RUNTIME
    "Link Windows MSVC-ABI builds with the static Visual C++ runtime (see note above)"
    OFF)
if(HTRECOMP_STATIC_MSVC_RUNTIME)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

project(hydrothunder VERSION 1.0.0 LANGUAGES CXX)

if(WIN32)
    enable_language(RC)
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(CMAKE_SYSTEM_PROCESSOR MATCHES "AMD64|x86_64")
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
        add_compile_options(-march=x86-64 -mtune=generic -mssse3)
    endif()
    set(SNAPPY_REQUIRE_AVX OFF CACHE BOOL "Do not require AVX" FORCE)
    set(SNAPPY_REQUIRE_AVX2 OFF CACHE BOOL "Do not require AVX2" FORCE)
    set(SNAPPY_HAVE_SSSE3 0 CACHE INTERNAL "Keep Snappy scalar" FORCE)
    set(SNAPPY_HAVE_X86_CRC32 0 CACHE INTERNAL "Keep Snappy scalar" FORCE)
    set(SNAPPY_HAVE_BMI2 0 CACHE INTERNAL "Keep Snappy scalar" FORCE)
endif()

set(REXSDK_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/rexglue-sdk"
    CACHE PATH "Path to the rexglue SDK source tree")
set(HT_GAME_DATA_ROOT
    "${CMAKE_CURRENT_SOURCE_DIR}/game_data"
    CACHE PATH "Path to an extracted Hydro Thunder retail game dump")

file(TO_CMAKE_PATH "${CMAKE_CURRENT_SOURCE_DIR}" HT_SOURCE_DIR_CONFIG)
file(TO_CMAKE_PATH "${HT_GAME_DATA_ROOT}" HT_GAME_DATA_ROOT_CONFIG)

set(HT_CODEGEN_ARGS "")
# hydrothunder_overrides.toml is listed as well as the generated functions file:
# it carries top-level scalars (setjmp_address) that live outside [functions],
# and tools/curate_function_config.py only merges the [functions] table across.
# Its [functions] entries therefore appear twice; merge semantics are last-wins
# with identical values, so that is harmless.
set(HT_FUNCTION_CONFIG_INCLUDES
    "  \"${HT_SOURCE_DIR_CONFIG}/config/hydrothunder_functions.toml\",\n  \"${HT_SOURCE_DIR_CONFIG}/config/hydrothunder_overrides.toml\",")
find_package(Python3 REQUIRED COMPONENTS Interpreter)

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/manifests")

configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/manifests/hydrothunder.toml.in
    ${CMAKE_CURRENT_BINARY_DIR}/manifests/hydrothunder.toml
    @ONLY
)

set(REXGLUE_ENABLE_TRACY OFF CACHE BOOL "Disable Tracy instrumentation for normal builds" FORCE)
set(REXGLUE_ENABLE_PERF_COUNTERS OFF CACHE BOOL "Enable lightweight rexglue perf counter instrumentation")

# Include rexglue targets
add_subdirectory(third_party/rexglue-sdk)

include(cmake/CodegenTargets.cmake)

set(HT_SOURCES
    src/main.cpp
    src/ht_settings_overlay.cpp
    src/ht_fps_overlay.cpp
    src/ht_setup.cpp
)

# Executable icon. enable_language(RC) is set above; the .rc references
# icon.ico relative to its own directory.
if(WIN32)
    list(APPEND HT_SOURCES resources/htrecomp.rc)
endif()

if(WIN32)
    add_executable(hydrothunder WIN32 ${HT_SOURCES})
else()
    add_executable(hydrothunder ${HT_SOURCES})
endif()

target_include_directories(hydrothunder PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_BINARY_DIR}/include
    ${REXSDK_DIR}/thirdparty/imgui
    ${CMAKE_CURRENT_BINARY_DIR}/third_party/rexglue-sdk/include
)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/generated/sources.cmake")
    include(generated/sources.cmake)
    target_sources(hydrothunder PRIVATE ${GENERATED_SOURCES})
    target_include_directories(hydrothunder PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/generated)
    set_source_files_properties(${GENERATED_SOURCES} PROPERTIES COMPILE_OPTIONS "-include;${CMAKE_CURRENT_SOURCE_DIR}/fix_stdio.h")
else()
    message(STATUS "generated/sources.cmake not found; run the generate-all target before building")
endif()

target_link_libraries(hydrothunder PRIVATE rex::runtime)
# rexglue SDK provides a helper to apply standard config to the host target.
#
# GPU_PLUGINS xenos is required from SDK v0.9.0 onward and did NOT exist at
# v0.8.0, which is the era this project was originally written against
# (manifests/hydrothunder.toml.in still declares sdk_version 0.8.1.19). The
# Xenos GPU emulation moved out of rexruntime into a runtime-loaded plugin -
# rexgpu-xenos.dll / librexgpu-xenos.so / .dylib - which rexruntime resolves by
# LoadLibrary from the executable's own folder (src/system/gpu_plugin_loader.cpp).
#
# Without this argument the plugin is neither built nor staged, because it is
# not a link dependency of this target. The build succeeds and the game then
# fails at startup with:
#
#   GPU plugin 'xenos' not found at <exe dir>/rexgpu-xenos.dll. Stage it next
#   to the executable (GPU_PLUGINS xenos in rexglue_configure_target).
#
# Passing it adds the build dependency, stages the plugin beside the executable
# on every link, and on APPLE also stages the macOS Vulkan runtime
# (libvulkan / libMoltenVK) that the Vulkan backend loads at runtime.
if(COMMAND rexglue_configure_target)
    rexglue_configure_target(hydrothunder GPU_PLUGINS xenos)
endif()

if(WIN32)
    # winmm: timeBeginPeriod, used to fix guest vblank pacing (see src/main.cpp)
    target_link_libraries(hydrothunder PRIVATE comdlg32 winhttp d3dcompiler gdiplus winmm)
endif()

# Headless package importer.
#
# src/ht_setup.cpp's first-run wizard needs a file dialog, and PickFile() /
# AskYesNo() are stubbed to return false outside _WIN32 - so on macOS and Linux
# there is no way to import a game package at all. This gives every platform a
# scriptable one, built on the same SDK STFS device the wizard uses.
#
# Not part of ALL: it is a setup utility, not something a player needs.
add_executable(ht_import EXCLUDE_FROM_ALL tools/ht_import.cpp)
target_link_libraries(ht_import PRIVATE rex::runtime)
target_include_directories(ht_import PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}/third_party/rexglue-sdk/include)
if(COMMAND rexglue_apply_target_settings)
    rexglue_apply_target_settings(ht_import)
endif()
if(MSVC)
    target_compile_options(ht_import PRIVATE /utf-8)
else()
    target_compile_options(ht_import PRIVATE -finput-charset=UTF-8 -fexec-charset=UTF-8)
endif()
# Needs rexruntime beside it at run time, same as the game.
add_custom_command(TARGET ht_import POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "$<TARGET_FILE:rexruntime>" "$<TARGET_FILE_DIR:ht_import>"
    VERBATIM
)

add_custom_target(ht_stage_runtime_library
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:hydrothunder>"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "$<TARGET_FILE:rexruntime>"
        "$<TARGET_FILE_DIR:hydrothunder>"
    DEPENDS rexruntime
    VERBATIM
)
add_dependencies(hydrothunder ht_stage_runtime_library)

if(MSVC)
    target_compile_options(hydrothunder PRIVATE /utf-8)
else()
    target_compile_options(hydrothunder PRIVATE -finput-charset=UTF-8 -fexec-charset=UTF-8)
endif()
