# Builds libshortplay_crypto.so from the shared dependency-free crypto core
# plus the Android JNI bridge. libmpv is NOT linked here: the crypto:// stream
# code resolves mpv_stream_cb_add_ro at runtime via dlsym from the libmpv that
# media_kit already loads into the process.
cmake_minimum_required(VERSION 3.18.1)
project(shortplay_crypto C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Path to the repo-root shared core (../../../../../native relative to this file:
# android/app/src/main/cpp -> ../main -> ../src -> ../app -> ../android -> repo native/).
set(CORE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/crypto_core)

add_library(shortplay_crypto SHARED
    ${CORE_DIR}/aes.c
    ${CORE_DIR}/mp4_cenc.c
    ${CORE_DIR}/crypto_stream.c
    ${CORE_DIR}/mpv_adapter.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../native/android/jni_bridge.c
)

target_include_directories(shortplay_crypto PRIVATE ${CORE_DIR})

# Warnings on; the core compiles clean under -Wall -Wextra.
target_compile_options(shortplay_crypto PRIVATE -Wall -Wextra -O2)

# dlsym/dlopen (libdl) + Android log.
find_library(log-lib log)
target_link_libraries(shortplay_crypto ${log-lib} dl)
