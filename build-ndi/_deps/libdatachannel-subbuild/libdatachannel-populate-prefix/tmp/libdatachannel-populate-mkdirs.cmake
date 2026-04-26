# Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
# file Copyright.txt or https://cmake.org/licensing for details.

cmake_minimum_required(VERSION ${CMAKE_VERSION}) # this file comes with cmake

# If CMAKE_DISABLE_SOURCE_CHANGES is set to true and the source directory is an
# existing directory in our source tree, calling file(MAKE_DIRECTORY) on it
# would cause a fatal error, even though it would be a no-op.
if(NOT EXISTS "D:/MEDIA/Desktop/jitsi-ndi-native/build-ndi/_deps/libdatachannel-src")
  file(MAKE_DIRECTORY "D:/MEDIA/Desktop/jitsi-ndi-native/build-ndi/_deps/libdatachannel-src")
endif()
file(MAKE_DIRECTORY
  "D:/MEDIA/Desktop/jitsi-ndi-native/build-ndi/_deps/libdatachannel-build"
  "D:/MEDIA/Desktop/jitsi-ndi-native/build-ndi/_deps/libdatachannel-subbuild/libdatachannel-populate-prefix"
  "D:/MEDIA/Desktop/jitsi-ndi-native/build-ndi/_deps/libdatachannel-subbuild/libdatachannel-populate-prefix/tmp"
  "D:/MEDIA/Desktop/jitsi-ndi-native/build-ndi/_deps/libdatachannel-subbuild/libdatachannel-populate-prefix/src/libdatachannel-populate-stamp"
  "D:/MEDIA/Desktop/jitsi-ndi-native/build-ndi/_deps/libdatachannel-subbuild/libdatachannel-populate-prefix/src"
  "D:/MEDIA/Desktop/jitsi-ndi-native/build-ndi/_deps/libdatachannel-subbuild/libdatachannel-populate-prefix/src/libdatachannel-populate-stamp"
)

set(configSubDirs Debug)
foreach(subDir IN LISTS configSubDirs)
    file(MAKE_DIRECTORY "D:/MEDIA/Desktop/jitsi-ndi-native/build-ndi/_deps/libdatachannel-subbuild/libdatachannel-populate-prefix/src/libdatachannel-populate-stamp/${subDir}")
endforeach()
if(cfgdir)
  file(MAKE_DIRECTORY "D:/MEDIA/Desktop/jitsi-ndi-native/build-ndi/_deps/libdatachannel-subbuild/libdatachannel-populate-prefix/src/libdatachannel-populate-stamp${cfgdir}") # cfgdir has leading slash
endif()
