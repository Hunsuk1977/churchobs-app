cmake_minimum_required(VERSION 3.28...3.30)
if(NOT APPLE)
  message(FATAL_ERROR "The native frontend requires macOS and Xcode")
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")
enable_language(OBJCXX Swift)

# Build only the engine modules this frontend uses. OBS's Qt frontend stays OFF.
foreach(module IN ITEMS mac-avcapture mac-capture mac-videotoolbox obs-filters obs-ffmpeg obs-x264 obs-outputs rtmp-services obs-transitions image-source)
  add_subdirectory("${CMAKE_SOURCE_DIR}/plugins/${module}" "${CMAKE_BINARY_DIR}/churchobs-modules/${module}")
endforeach()

# Pinned OBS capture API compatibility is applied and verified by prepare_obs.py.

add_executable(churchobs MACOSX_BUNDLE
  StageCard.mm StageCard.h YouTubeBridge.mm YouTubeBridge.h YouTubeAPI.mm YouTubeAPI.h
  StudioControls.mm StudioControls.h StudioLayout.h
  StudioBridge.h SwiftBridge.inc GraphState.h GraphGeometry.h GraphEngine.inc
  swift/SceneModels.swift swift/ShowStore.swift swift/SceneSheets.swift
    swift/MediaGraphicsPanels.swift swift/Typography.swift swift/Glass.swift swift/ScreenPermission.swift swift/NetworkStatus.swift swift/SceneEditorView.swift swift/LiveSceneDeck.swift swift/CanvasEditor.swift swift/StudioMonitors.swift swift/AccountService.swift swift/AccountViews.swift swift/NativeStudio.swift swift/ChurchStudioView.swift swift/WordaliveFeed.swift swift/WordaliveStudio.swift swift/SourceMonitor.swift swift/YouTubePlayer.swift swift/TextObjects.swift
  Main.mm StudioUI.inc StudioSources.inc StudioUITest.inc StudioTiming.h Engine.mm Engine.h PreviewView.mm PreviewView.h
  SmokeTest.mm SmokeTest.h FaceTracker.mm FaceTracker.h
  filters/face_geometry.c filters/face_geometry.h
  filters/face_frame.c filters/face_frame.h
  SourceLifetime.c SourceLifetime.h
  VirtualCam.mm VirtualCam.h
  ShapeMask.mm ShapeMask.h
  Captions.mm Captions.h
  Slides.mm Slides.h
  AppAudio.mm AppAudio.h
  LookFilter.mm LookFilter.h
  filters/skin_filter.c filters/skin_filter.h
  filters/test_pattern.c filters/test_pattern.h
  filters/face_test_input.c filters/face_test_input.h
  resources/skin-soften.effect resources/shape-mask.effect resources/camera-look.effect resources/ChurchOBS.icns resources/church-obs-wordmark.png resources/church-obs-symbol.png resources/face-reference.bgra resources/face-reference-LICENSE.txt
)
set_source_files_properties(StudioUI.inc StudioSources.inc StudioUITest.inc SwiftBridge.inc GraphEngine.inc PROPERTIES HEADER_FILE_ONLY TRUE)
target_compile_features(churchobs PRIVATE cxx_std_17)
set_source_files_properties(resources/skin-soften.effect resources/shape-mask.effect resources/camera-look.effect resources/ChurchOBS.icns resources/church-obs-wordmark.png resources/church-obs-symbol.png resources/face-reference.bgra resources/face-reference-LICENSE.txt PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
target_include_directories(churchobs PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
# Main.mm owns the NSApplication entry point; Swift files contain library types only.
target_compile_options(churchobs PRIVATE
  "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
  "$<$<COMPILE_LANGUAGE:Swift>:-parse-as-library>"
)
target_link_libraries(churchobs PRIVATE OBS::libobs "-lc++"
  "$<LINK_LIBRARY:FRAMEWORK,AppKit.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,WebKit.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,ScreenCaptureKit.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,CoreImage.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,CoreAudio.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,CoreGraphics.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,Security.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,AVFoundation.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,Vision.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,CoreVideo.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,ImageIO.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,CoreMedia.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,CoreMediaIO.framework>"
  "$<LINK_LIBRARY:FRAMEWORK,QuickLookThumbnailing.framework>"
)
set_target_properties(churchobs PROPERTIES
  OUTPUT_NAME "ChurchOBS"
  Swift_MODULE_NAME ChurchOBSNative
  Swift_LANGUAGE_VERSION 5
  LINKER_LANGUAGE Swift
  XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
  # 새 Xcode SDK의 deprecation 경고가 빌드를 막지 않도록 (경고는 그대로 표시됨)
  COMPILE_WARNING_AS_ERROR OFF
  XCODE_ATTRIBUTE_SWIFT_TREAT_WARNINGS_AS_ERRORS NO
  XCODE_ATTRIBUTE_GCC_TREAT_WARNINGS_AS_ERRORS NO
  XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/StudioBridge.h"
  XCODE_ATTRIBUTE_CLANG_ENABLE_MODULES YES
  XCODE_ATTRIBUTE_ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES YES
  XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET "14.0"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/resources/Info.plist.in"
  BUILD_WITH_INSTALL_RPATH TRUE
  INSTALL_RPATH "@executable_path/../Frameworks"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "org.mmcnyc.churchobs"
  XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "-"
  XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Manual"
  XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME NO
  XCODE_ATTRIBUTE_GENERATE_INFOPLIST_FILE NO
  XCODE_EMBED_FRAMEWORKS_REMOVE_HEADERS_ON_COPY YES
  XCODE_EMBED_FRAMEWORKS_CODE_SIGN_ON_COPY YES
  XCODE_EMBED_PLUGINS_REMOVE_HEADERS_ON_COPY YES
  XCODE_EMBED_PLUGINS_CODE_SIGN_ON_COPY YES
)
# Use the same upstream dependency collector as OBS, without its Qt interface.
set_property(GLOBAL PROPERTY OBS_MODULES_ENABLED mac-avcapture mac-capture mac-videotoolbox obs-filters obs-x264 obs-ffmpeg obs-outputs rtmp-services obs-transitions image-source)
set_property(TARGET churchobs APPEND PROPERTY XCODE_EMBED_FRAMEWORKS libobs libobs-opengl)
add_dependencies(churchobs libobs-opengl)
if(TARGET libobs-metal)
  set_property(TARGET churchobs APPEND PROPERTY XCODE_EMBED_FRAMEWORKS libobs-metal)
  add_dependencies(churchobs libobs-metal)
endif()
_bundle_dependencies(churchobs)

# ffmpeg_muxer spawns this sibling executable during MKV recording.
add_dependencies(churchobs obs-ffmpeg-mux)
add_custom_command(TARGET churchobs POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:obs-ffmpeg-mux>"
    "$<TARGET_BUNDLE_CONTENT_DIR:churchobs>/MacOS/"
)
target_add_resource(churchobs "${WORSHIP_SOURCE_DIR}/LICENSE")
install(TARGETS churchobs BUNDLE DESTINATION "." COMPONENT ChurchOBS)

# Church OBS 공용 Google OAuth(Desktop app) 설정. 있으면 앱에 넣어, 사용자가 JSON을 따로 불러오지 않아도 유튜브에 연결된다.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/resources/youtube-oauth.json")
  target_sources(churchobs PRIVATE resources/youtube-oauth.json)
  set_source_files_properties(resources/youtube-oauth.json PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
endif()
