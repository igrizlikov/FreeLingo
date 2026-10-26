#!/bin/bash
# Run after build-macos.sh; optional first argument saves AppKit view renders.
set -euo pipefail
cd "$(dirname "$0")/.."
CORE="${FL_TEST_CORE:-target/aarch64-apple-darwin/release/libfreelingo_core.a}"
SPARKLE="${FL_TEST_SPARKLE:-dist/FreeLingo.app/Contents/Frameworks}"
mkdir -p .build/GlassTests.app/Contents/MacOS .build/GlassTests.app/Contents/Resources
cp assets/FreeLingo.icns .build/GlassTests.app/Contents/Resources/
cp assets/Info.plist .build/GlassTests.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable glass-tests" .build/GlassTests.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.freelingo.glass-tests" .build/GlassTests.app/Contents/Info.plist
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=15.0 -fobjc-arc -fmodules \
  -fmodules-cache-path=.build/ModuleCache -Wno-deprecated-declarations -Wno-multichar \
  -F "$SPARKLE" -I native tests/glass_macos.m "$CORE" \
  -Wl,-rpath,"$PWD/$SPARKLE" -framework Sparkle \
  -framework Cocoa -framework Carbon -framework ApplicationServices \
  -framework CoreGraphics -framework Vision -framework QuartzCore \
  -framework Security -framework SystemConfiguration -framework ServiceManagement \
  -framework NaturalLanguage -lresolv -liconv -o .build/GlassTests.app/Contents/MacOS/glass-tests
.build/GlassTests.app/Contents/MacOS/glass-tests "$@"
