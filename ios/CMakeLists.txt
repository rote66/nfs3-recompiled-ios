set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

file(GLOB CORE_SOURCES
    "${PROJECT_SOURCE_DIR}/src/lib/*.cpp"
    "${PROJECT_SOURCE_DIR}/src/lib/winapi/*.cpp"
    "${PROJECT_SOURCE_DIR}/src/lib/winapi/ddraw/*.cpp"
    "${PROJECT_SOURCE_DIR}/src/lib/winapi/dinput/*.cpp"
    "${PROJECT_SOURCE_DIR}/src/lib/winapi/dsound/*.cpp")
list(FILTER CORE_SOURCES EXCLUDE REGEX "/(window|renderer|gliderenderer|thread|timer|mutex)\\.cpp$")
list(APPEND CORE_SOURCES "${PROJECT_SOURCE_DIR}/src/lib/sdl-backend/file.cpp")
file(GLOB GAME_SOURCES "${PROJECT_SOURCE_DIR}/src/nfs3hp/disassembly/*.cpp")

set(METALLIB "${CMAKE_CURRENT_BINARY_DIR}/default.metallib")
if(CMAKE_OSX_SYSROOT MATCHES "iPhoneSimulator")
    set(METAL_MINIMUM "-mios-simulator-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
else()
    set(METAL_MINIMUM "-mios-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}")
endif()
add_custom_command(OUTPUT "${METALLIB}"
    COMMAND xcrun --toolchain Metal -sdk "${CMAKE_OSX_SYSROOT}" metal "${METAL_MINIMUM}" -std=ios-metal2.3 -c "${CMAKE_CURRENT_SOURCE_DIR}/Shaders.metal" -o "${CMAKE_CURRENT_BINARY_DIR}/Shaders.air"
    COMMAND xcrun --toolchain Metal -sdk "${CMAKE_OSX_SYSROOT}" metallib "${CMAKE_CURRENT_BINARY_DIR}/Shaders.air" -o "${METALLIB}"
    DEPENDS Shaders.metal VERBATIM)
set_source_files_properties("${METALLIB}" PROPERTIES GENERATED TRUE MACOSX_PACKAGE_LOCATION Resources)
set(GAME_FILES
    "${PROJECT_SOURCE_DIR}/nfs3hp/nfs3.exe"
    "${PROJECT_SOURCE_DIR}/nfs3hp/eacsnd.dll"
    "${PROJECT_SOURCE_DIR}/nfs3hp/softtria.dll"
    "${PROJECT_SOURCE_DIR}/nfs3hp/voodoo2a.dll"
    "${CMAKE_CURRENT_SOURCE_DIR}/Resources/GameFiles/install.win")
set_source_files_properties(${GAME_FILES} PROPERTIES MACOSX_PACKAGE_LOCATION Resources/GameFiles)
file(GLOB APP_ICONS "${CMAKE_CURRENT_SOURCE_DIR}/Resources/AppIcon*.png")
set_source_files_properties(${APP_ICONS} PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
set(LOCALIZED_STRINGS)
foreach(LANGUAGE en zh-Hans zh-Hant)
    set(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/Resources/${LANGUAGE}.lproj/Localizable.strings")
    set_source_files_properties("${STRINGS}" PROPERTIES MACOSX_PACKAGE_LOCATION "Resources/${LANGUAGE}.lproj")
    list(APPEND LOCALIZED_STRINGS "${STRINGS}")
endforeach()
add_executable(nfs3 MACOSX_BUNDLE ${CORE_SOURCES} ${GAME_SOURCES}
    Runtime.cpp ForceFeedback.cpp Haptics.mm ForceFeedbackDiagnostic.cpp MetalBackend.mm GraphicsDiagnostic.mm AudioBackend.mm TouchUI.mm LayoutEditor.mm App.mm "${METALLIB}" ${GAME_FILES} ${APP_ICONS} ${LOCALIZED_STRINGS})
target_include_directories(nfs3 PRIVATE
    "${PROJECT_SOURCE_DIR}/include" "${PROJECT_SOURCE_DIR}/src/nfs3hp/disassembly" "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_definitions(nfs3 PRIVATE NFS_IOS WITH_MMX)
target_compile_options(nfs3 PRIVATE -O2 -fno-strict-aliasing
    -Wno-cpp
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
    -Werror=unguarded-availability-new)
target_link_libraries(nfs3 PRIVATE "-framework UIKit" "-framework Foundation"
    "-framework CoreGraphics" "-framework QuartzCore"
    "-framework Metal" "-framework MetalKit" "-framework AVFoundation"
    "-framework GameController" "-framework CoreMotion" "-framework CoreHaptics" "-framework UniformTypeIdentifiers")
set_target_properties(nfs3 PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
    MACOSX_BUNDLE_GUI_IDENTIFIER "dev.motor.nfs3native"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    XCODE_ATTRIBUTE_ENABLE_BITCODE "NO")
