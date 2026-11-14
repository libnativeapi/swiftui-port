cmake_minimum_required(VERSION 3.16)
project(SwiftRuntimeProbe LANGUAGES CXX)

set(SWIFT_INPUTS "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.build/runtime")
# swiftrt.o registers the shared object's Swift metadata sections at load time.
add_library(swiftprobe SHARED probe.cpp arkui_probe.cpp gallery_host.cpp "${SWIFT_INPUTS}/Probe.o"
  "${SWIFT_INPUTS}/SwiftUIRuntime.o" "${SWIFT_INPUTS}/SwiftUI.o" "${SWIFT_INPUTS}/FluentIcons.o"
  "${SWIFT_INPUTS}/DazzUI.o" "${SWIFT_INPUTS}/swiftrt.o")
target_compile_features(swiftprobe PRIVATE cxx_std_17)
target_link_options(swiftprobe PRIVATE -Wl,--no-undefined -Wl,--exclude-libs,ALL)
target_link_libraries(swiftprobe PRIVATE
  -Wl,--start-group
  "${SWIFT_INPUTS}/libswiftCore.a"
  "${SWIFT_INPUTS}/libswift_Concurrency.a"
  "${SWIFT_INPUTS}/libswift_StringProcessing.a"
  "${SWIFT_INPUTS}/libswift_RegexParser.a"
  "${SWIFT_INPUTS}/libswiftMusl.a"
  "${SWIFT_INPUTS}/libswiftSynchronization.a"
  "${SWIFT_INPUTS}/libswiftDispatch.a"
  "${SWIFT_INPUTS}/libdispatch.a"
  "${SWIFT_INPUTS}/libBlocksRuntime.a"
  "${SWIFT_INPUTS}/libFoundation.a"
  "${SWIFT_INPUTS}/libFoundationEssentials.a"
  "${SWIFT_INPUTS}/libFoundationInternationalization.a"
  "${SWIFT_INPUTS}/libCoreFoundation.a"
  "${SWIFT_INPUTS}/lib_FoundationCShims.a"
  "${SWIFT_INPUTS}/lib_FoundationCollections.a"
  "${SWIFT_INPUTS}/lib_FoundationICU.a"
  "${SWIFT_INPUTS}/libfts.a"
  "${SWIFT_INPUTS}/libc++.a"
  "${SWIFT_INPUTS}/libc++abi.a"
  -Wl,--end-group
  libace_napi.z.so
  ace_ndk.z
  native_drawing
  c++_shared
  uv
  dl
  m
)
