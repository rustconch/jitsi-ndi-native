cmake_minimum_required(VERSION 3.24)

project(jitsi_ndi_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(JNN_WITH_REAL_NDI "Build with real NDI SDK if found" ON)
option(JNN_WITH_NATIVE_WEBRTC "Build native libdatachannel receiver" ON)
option(JNN_FETCH_LIBDATACHANNEL "Fetch libdatachannel via CMake FetchContent" ON)

set(JNN_LIBDATACHANNEL_TAG "v0.24.2" CACHE STRING "libdatachannel git tag to fetch")

# vcpkg ffmpeg root. If you use a different vcpkg location, override it:
#   -DFFMPEG_ROOT="D:/your/vcpkg/installed/x64-windows"
set(FFMPEG_ROOT "D:/vcpkg/installed/x64-windows" CACHE PATH "vcpkg FFmpeg root")

if (MSVC)
    add_compile_options(/permissive- /W3 /EHsc)
    add_definitions(-D_CRT_SECURE_NO_WARNINGS -DNOMINMAX -DWIN32_LEAN_AND_MEAN)
endif()

set(SOURCES
    src/main.cpp
    src/AppConfig.cpp
    src/Logger.cpp
    src/TestPattern.cpp
    src/NDISender.cpp
    src/XmppWebSocketClient.cpp
    src/JingleSession.cpp
    src/NativeWebRTCAnswerer.cpp
    src/JitsiSignaling.cpp

    # Per-speaker native RTP -> decode -> NDI pipeline.
    src/RtpPacket.cpp
    src/JitsiSourceMap.cpp
    src/Vp8RtpDepacketizer.cpp
    src/FfmpegMediaDecoder.cpp
        src/Av1RtpFrameAssembler.cpp
src/PerParticipantNdiRouter.cpp
)

add_executable(jitsi-ndi-native ${SOURCES})

# v102: Release-mode CPU optimizations.
# /GL = Whole-Program Optimization (enables cross-TU inlining between all our .cpp files).
# /LTCG = Link-Time Code Generation (linker pass required by /GL).
# /Ot = Favor speed over size for individual functions.
# /fp:fast = Relaxed FP: allows reassociation, no denormal trapping. Safe for
#            our audio/video pipeline (values are always clamped before use).
# These apply only in Release so debug builds are unaffected.
if (MSVC)
    target_compile_options(jitsi-ndi-native PRIVATE
        $<$<CONFIG:Release>:/GL /Ot /fp:fast>
    )
    target_link_options(jitsi-ndi-native PRIVATE
        $<$<CONFIG:Release>:/LTCG>
    )
endif()

target_include_directories(jitsi-ndi-native PRIVATE
    src
    "${FFMPEG_ROOT}/include"
)

target_link_directories(jitsi-ndi-native PRIVATE
    "${FFMPEG_ROOT}/lib"
)

# IMPORTANT:
# avutil is NOT a vcpkg feature name, so do not install ffmpeg[avutil].
# But libavutil is a real FFmpeg library and must remain linked here.
target_link_libraries(jitsi-ndi-native PRIVATE
    avcodec
    avutil
    swscale
    swresample
)

if (WIN32)
    target_link_libraries(jitsi-ndi-native PRIVATE winhttp ws2_32 crypt32 secur32 bcrypt iphlpapi)
endif()

if (JNN_WITH_NATIVE_WEBRTC)
    include(FetchContent)

    if (JNN_FETCH_LIBDATACHANNEL)
        set(NO_EXAMPLES ON CACHE BOOL "" FORCE)
        set(NO_TESTS ON CACHE BOOL "" FORCE)
        set(NO_PROGRAMS ON CACHE BOOL "" FORCE)
        set(USE_GNUTLS OFF CACHE BOOL "" FORCE)
        set(USE_NICE OFF CACHE BOOL "" FORCE)
        set(USE_MBEDTLS OFF CACHE BOOL "" FORCE)
        set(USE_OPENSSL ON CACHE BOOL "" FORCE)

        FetchContent_Declare(
            libdatachannel
            GIT_REPOSITORY https://github.com/paullouisageneau/libdatachannel.git
            GIT_TAG ${JNN_LIBDATACHANNEL_TAG}
        )
        FetchContent_MakeAvailable(libdatachannel)
    else()
        find_package(libdatachannel CONFIG REQUIRED)
    endif()

    target_compile_definitions(jitsi-ndi-native PRIVATE JNN_WITH_NATIVE_WEBRTC=1)
    target_link_libraries(jitsi-ndi-native PRIVATE datachannel)
else()
    target_compile_definitions(jitsi-ndi-native PRIVATE JNN_WITH_NATIVE_WEBRTC=0)
endif()

# NDI SDK detection.
# We do NOT redistribute the SDK. Install it separately.
set(JNN_NDI_SDK_DIR "" CACHE PATH "Path to NDI SDK root, e.g. C:/Program Files/NDI/NDI 6 SDK")

if (NOT JNN_NDI_SDK_DIR AND DEFINED ENV{NDI_SDK_DIR})
    file(TO_CMAKE_PATH "$ENV{NDI_SDK_DIR}" JNN_NDI_SDK_DIR)
endif()

if (NOT JNN_NDI_SDK_DIR AND DEFINED ENV{NDI_HOME})
    file(TO_CMAKE_PATH "$ENV{NDI_HOME}" JNN_NDI_SDK_DIR)
endif()

set(_ndi_guess_paths
    "${CMAKE_CURRENT_SOURCE_DIR}/NDI 6 SDK"
    "${CMAKE_CURRENT_SOURCE_DIR}/NDI SDK"
    "C:/Program Files/NDI/NDI 6 SDK"
    "C:/Program Files/NDI/NDI 5 SDK"
    "C:/Program Files/NewTek/NDI SDK"
)

find_path(
    NDI_INCLUDE_DIR
    Processing.NDI.Lib.h
    HINTS ${JNN_NDI_SDK_DIR} ${_ndi_guess_paths}
    PATH_SUFFIXES Include include
)

find_library(
    NDI_LIBRARY
    NAMES Processing.NDI.Lib.x64 Processing.NDI.Lib
    HINTS ${JNN_NDI_SDK_DIR} ${_ndi_guess_paths}
    PATH_SUFFIXES Lib/x64 Lib/x86 lib/x64 lib
)

find_file(
    NDI_RUNTIME_DLL
    NAMES Processing.NDI.Lib.x64.dll Processing.NDI.Lib.dll
    HINTS ${JNN_NDI_SDK_DIR} ${_ndi_guess_paths}
    PATH_SUFFIXES Bin/x64 Bin
)

if (JNN_WITH_REAL_NDI AND NDI_INCLUDE_DIR AND NDI_LIBRARY)
    message(STATUS "NDI SDK found: ${NDI_INCLUDE_DIR} / ${NDI_LIBRARY}")
    target_compile_definitions(jitsi-ndi-native PRIVATE JNN_HAS_NDI=1)
    target_include_directories(jitsi-ndi-native PRIVATE ${NDI_INCLUDE_DIR})
    target_link_libraries(jitsi-ndi-native PRIVATE ${NDI_LIBRARY})
    if (NDI_RUNTIME_DLL)
        add_custom_command(TARGET jitsi-ndi-native POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${NDI_RUNTIME_DLL}"
                "$<TARGET_FILE_DIR:jitsi-ndi-native>"
        )
        message(STATUS "NDI runtime DLL will be copied: ${NDI_RUNTIME_DLL}")
    else()
        message(WARNING "NDI runtime DLL was not found; NDI source may not appear until Processing.NDI.Lib.x64.dll is next to the exe or in PATH")
    endif()
else()
    message(WARNING "NDI SDK not found. Building with mock NDI sender. Set -DJNN_NDI_SDK_DIR=... to enable real NDI.")
    target_compile_definitions(jitsi-ndi-native PRIVATE JNN_HAS_NDI=0)
endif()
