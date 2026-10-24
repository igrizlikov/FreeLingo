#!/bin/bash
set -euo pipefail

# Native macOS/Apple Silicon build. Produces an ad-hoc signed .app and DMG.
# An ad-hoc signature is NOT notarization / Developer ID certification.
# Can run on GitHub Actions: no developer tools are required on the user's Mac.
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: A real macOS SDK and hdiutil are required. Run the GitHub Actions workflow." >&2
  exit 1
fi
for tool in cargo rustup cmake git xcrun codesign hdiutil otool install_name_tool; do
  command -v "$tool" >/dev/null || { echo "ERROR: Missing $tool" >&2; exit 1; }
done
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "ERROR: The provided workflow targets Apple Silicon (arm64)" >&2
  exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=15.0
APP="$ROOT/dist/FreeLingo.app"
BIN="$APP/Contents/MacOS"
rm -rf "$APP"
mkdir -p "$BIN" "$APP/Contents/Resources"
cp assets/Info.plist "$APP/Contents/Info.plist"
cp assets/FreeLingo.icns "$APP/Contents/Resources/FreeLingo.icns"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSE "$APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# A fixed upstream tag avoids silently compiling an entirely different llama.cpp revision.
LLAMA_TAG="${LLAMA_TAG:-b11798}"
LLAMA_DIR="$ROOT/.build/llama.cpp"
if [[ ! -d "$LLAMA_DIR/.git" ]]; then
  mkdir -p "$ROOT/.build"
  git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
else
  cd "$LLAMA_DIR"
  git fetch --depth 1 origin "refs/tags/$LLAMA_TAG:refs/tags/$LLAMA_TAG"
  git checkout --detach "$LLAMA_TAG"
  cd "$ROOT"
fi
cmake -S "$LLAMA_DIR" -B "$ROOT/.build/llama-arm64" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_UI=OFF \
  -DLLAMA_USE_PREBUILT_UI=OFF \
  -DLLAMA_OPENSSL=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_OPENMP=OFF \
  -DGGML_NATIVE=OFF
cmake --build "$ROOT/.build/llama-arm64" --config Release --target llama-server -j 4
LLAMA_BIN="$ROOT/.build/llama-arm64/bin"
test -x "$LLAMA_BIN/llama-server"
cp "$LLAMA_BIN/llama-server" "$BIN/llama-server"
# Shared GGML/llama libraries, if produced by this pinned revision.
find "$LLAMA_BIN" -maxdepth 1 -type f \( -name '*.dylib' -o -name '*.metallib' \) -exec cp -L {} "$BIN/" \;
# Symlinks can be the only dylib names visible in build/bin.
find "$LLAMA_BIN" -maxdepth 1 -type l -name '*.dylib' -exec cp -L {} "$BIN/" \;
for binary in "$BIN/llama-server" "$BIN"/*.dylib; do
  [[ -f "$binary" ]] || continue
  # May already contain this rpath; ignore duplicate-rpath error only.
  install_name_tool -add_rpath '@executable_path' "$binary" 2>/dev/null || true
done

rustup target add aarch64-apple-darwin
cargo test --target aarch64-apple-darwin
cargo build --release --target aarch64-apple-darwin
xcrun --sdk macosx clang -arch arm64 -mmacosx-version-min=15.0 -fobjc-arc -fmodules \
  -Wno-deprecated-declarations -Wno-multichar \
  -I "$ROOT/native" "$ROOT/native/main.m" \
  "$ROOT/target/aarch64-apple-darwin/release/libfreelingo_core.a" \
  -framework Cocoa -framework Carbon -framework ApplicationServices \
  -framework CoreGraphics -framework Vision -framework QuartzCore \
  -framework Security -framework SystemConfiguration \
  -lresolv -liconv -o "$BIN/FreeLingo"

chmod +x "$BIN/FreeLingo" "$BIN/llama-server"
for component in "$BIN"/*.dylib "$BIN/llama-server"; do
  [[ -f "$component" ]] || continue
  codesign --force --sign - --timestamp=none "$component"
done
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --verbose=1 "$APP"
# Fail the build if any arm64 model-server library points into the CI build
# directory instead of being bundled with FreeLingo.
for binary in "$BIN/llama-server" "$BIN"/*.dylib; do
  [[ -f "$binary" ]] || continue
  otool -L "$binary"
done
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
"$BIN/llama-server" --version
file "$BIN/FreeLingo" "$BIN/llama-server"

STAGE="$ROOT/dist/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/FreeLingo.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$ROOT/dist/FreeLingo-0.5.4-AppleSilicon.dmg"
hdiutil create -volname "FreeLingo 0.5.4" -srcfolder "$STAGE" \
  -format UDZO -imagekey zlib-level=9 -ov "$ROOT/dist/FreeLingo-0.5.4-AppleSilicon.dmg"
hdiutil verify "$ROOT/dist/FreeLingo-0.5.4-AppleSilicon.dmg"
echo "DMG built: $ROOT/dist/FreeLingo-0.5.4-AppleSilicon.dmg"

# Record a reproducible checksum for the GitHub Actions artifact.
shasum -a 256 "$ROOT/dist/FreeLingo-0.5.4-AppleSilicon.dmg" > "$ROOT/dist/FreeLingo-0.5.4-AppleSilicon.dmg.sha256"
