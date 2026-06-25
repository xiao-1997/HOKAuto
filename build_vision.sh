#!/bin/bash
# Vision Engine build script for Codemagic (iOS arm64)
set -e

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
ARCH="arm64"
MIN_IOS="13.0"
CXXFLAGS="-arch $ARCH -mios-version-min=$MIN_IOS -isysroot $SDK -std=c++17 -O2 -Wno-deprecated-declarations"

echo "=== Building VisionEngine ==="

# Compile
clang++ $CXXFLAGS -c VisionEngine/vision_core.cpp \
    -o vision_core.o -framework IOKit

# Create static lib
ar rcs libVisionEngine.a vision_core.o

echo "=== Done: libVisionEngine.a ==="
