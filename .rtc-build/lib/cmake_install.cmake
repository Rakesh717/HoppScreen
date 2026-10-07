# Install script for directory: /Users/blackbox/Codes/pad6-display/vendor/libdatachannel

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "/usr/local")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "Release")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "FALSE")
endif()

# Set path to fallback-tool for dependency-resolution.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "/usr/bin/objdump")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE STATIC_LIBRARY FILES "/Users/blackbox/Codes/pad6-display/.rtc-build/lib/deps/usrsctp/usrsctplib/libusrsctp.a")
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libusrsctp.a" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libusrsctp.a")
    execute_process(COMMAND "/usr/bin/ranlib" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libusrsctp.a")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE STATIC_LIBRARY FILES "/Users/blackbox/Codes/pad6-display/.rtc-build/lib/deps/libsrtp/libsrtp2.a")
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libsrtp2.a" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libsrtp2.a")
    execute_process(COMMAND "/usr/bin/ranlib" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libsrtp2.a")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE STATIC_LIBRARY FILES "/Users/blackbox/Codes/pad6-display/.rtc-build/lib/deps/libjuice/libjuice.a")
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libjuice.a" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libjuice.a")
    execute_process(COMMAND "/usr/bin/ranlib" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libjuice.a")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE STATIC_LIBRARY FILES "/Users/blackbox/Codes/pad6-display/.rtc-build/lib/libdatachannel.a")
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libdatachannel.a" AND
     NOT IS_SYMLINK "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libdatachannel.a")
    execute_process(COMMAND "/usr/bin/ranlib" "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libdatachannel.a")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include/rtc" TYPE FILE FILES
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/candidate.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/channel.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/configuration.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/datachannel.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/dependencydescriptor.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/description.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/iceudpmuxlistener.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/mediahandler.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/rtcpreceivingsession.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/common.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/global.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/message.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/frameinfo.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/peerconnection.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/reliability.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/rtc.h"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/rtc.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/rtp.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/track.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/websocket.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/websocketserver.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/rtppacketizationconfig.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/rtcpsrreporter.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/rtppacketizer.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/rtpdepacketizer.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/h264rtppacketizer.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/h264rtpdepacketizer.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/nalunit.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/h265rtppacketizer.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/h265rtpdepacketizer.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/h265nalunit.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/av1rtppacketizer.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/rtcpnackresponder.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/utils.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/plihandler.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/pacinghandler.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/rembhandler.hpp"
    "/Users/blackbox/Codes/pad6-display/vendor/libdatachannel/include/rtc/version.h"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/LibDataChannel/LibDataChannelTargets.cmake")
    file(DIFFERENT _cmake_export_file_changed FILES
         "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/LibDataChannel/LibDataChannelTargets.cmake"
         "/Users/blackbox/Codes/pad6-display/.rtc-build/lib/CMakeFiles/Export/32c821eb1e7b36c3a3818aec162f7fd2/LibDataChannelTargets.cmake")
    if(_cmake_export_file_changed)
      file(GLOB _cmake_old_config_files "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/LibDataChannel/LibDataChannelTargets-*.cmake")
      if(_cmake_old_config_files)
        string(REPLACE ";" ", " _cmake_old_config_files_text "${_cmake_old_config_files}")
        message(STATUS "Old export file \"$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/LibDataChannel/LibDataChannelTargets.cmake\" will be replaced.  Removing files [${_cmake_old_config_files_text}].")
        unset(_cmake_old_config_files_text)
        file(REMOVE ${_cmake_old_config_files})
      endif()
      unset(_cmake_old_config_files)
    endif()
    unset(_cmake_export_file_changed)
  endif()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/LibDataChannel" TYPE FILE FILES "/Users/blackbox/Codes/pad6-display/.rtc-build/lib/CMakeFiles/Export/32c821eb1e7b36c3a3818aec162f7fd2/LibDataChannelTargets.cmake")
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Rr][Ee][Ll][Ee][Aa][Ss][Ee])$")
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/LibDataChannel" TYPE FILE FILES "/Users/blackbox/Codes/pad6-display/.rtc-build/lib/CMakeFiles/Export/32c821eb1e7b36c3a3818aec162f7fd2/LibDataChannelTargets-release.cmake")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/LibDataChannel" TYPE FILE FILES
    "/Users/blackbox/Codes/pad6-display/.rtc-build/lib/LibDataChannelConfig.cmake"
    "/Users/blackbox/Codes/pad6-display/.rtc-build/lib/LibDataChannelConfigVersion.cmake"
    )
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for each subdirectory.

endif()

string(REPLACE ";" "\n" CMAKE_INSTALL_MANIFEST_CONTENT
       "${CMAKE_INSTALL_MANIFEST_FILES}")
if(CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "/Users/blackbox/Codes/pad6-display/.rtc-build/lib/install_local_manifest.txt"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()
if(CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_COMPONENT MATCHES "^[a-zA-Z0-9_.+-]+$")
    set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INSTALL_COMPONENT}.txt")
  else()
    string(MD5 CMAKE_INST_COMP_HASH "${CMAKE_INSTALL_COMPONENT}")
    set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INST_COMP_HASH}.txt")
    unset(CMAKE_INST_COMP_HASH)
  endif()
else()
  set(CMAKE_INSTALL_MANIFEST "install_manifest.txt")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "/Users/blackbox/Codes/pad6-display/.rtc-build/lib/${CMAKE_INSTALL_MANIFEST}"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()
