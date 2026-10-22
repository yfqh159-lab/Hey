cmake_minimum_required(VERSION 3.5.0)
project(heyvpn)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

set(HEYVPN_PREBUILT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/arm64-v8a)

add_library(heyvpn SHARED napi_init.cpp)
target_include_directories(heyvpn PRIVATE "${HEYVPN_PREBUILT_DIR}")
target_link_libraries(heyvpn PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libdl.so)

# libsingbox.so 由 scripts/build_libsingbox_ohos.sh 产出，作为可选预览内核；
# if(EXISTS) 守卫保证它还没编出来时不影响 Xray 主路径构建。
#
# 拷贝挂在一个 ALL 的独立目标上，而不是 heyvpn 的 POST_BUILD。原因：POST_BUILD 只在
# heyvpn 被重新链接时才触发；若只重编了 prebuilt 的 .so（没动任何 .cpp），heyvpn 不会
# 重链，旧 .so 就一直留在构建产物里被打进 HAP（bump sing-box 到 1.12 时踩过这个坑）。
# 无 OUTPUT 的 custom target 每次构建都判定为过期 → 命令必跑；copy_if_different 保证
# 没变化时是 no-op。
add_custom_target(copy_prebuilt_libs ALL)
add_dependencies(copy_prebuilt_libs heyvpn)
foreach(PREBUILT_LIB libxray.so libsingbox.so libheytun2socks.so libhevsocks5tun.so)
    if(EXISTS "${HEYVPN_PREBUILT_DIR}/${PREBUILT_LIB}")
        add_custom_command(TARGET copy_prebuilt_libs POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${HEYVPN_PREBUILT_DIR}/${PREBUILT_LIB}"
            "$<TARGET_FILE_DIR:heyvpn>/${PREBUILT_LIB}")
    endif()
endforeach()
