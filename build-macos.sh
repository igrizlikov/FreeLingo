#!/bin/bash
set -euo pipefail

# Native macOS/Apple Silicon build. Produces a .app and DMG.
# SIGNING_IDENTITY and SIGNING_KEYCHAIN opt in to a persistent code-signing identity.
# An ad-hoc signature (default) changes its designated requirement every build;
# macOS may therefore require Accessibility permission after each update.
 # A private/self-signed certificate is intended for controlled personal machines,
 # not public Gatekeeper distribution. Developer ID + notarization is recommended.
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
# Fail closed on release builds: never ship a release without an update verification key.
if [[ "${REQUIRE_SPARKLE_SIGNING:-0}" == "1" ]]; then
  [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]] || { echo 'ERROR: SPARKLE_PUBLIC_ED_KEY is not configured' >&2; exit 1; }
  [[ "$(printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" == "32" ]] || {
    echo 'ERROR: Sparkle public key must be base64 of 32 bytes' >&2; exit 1;
  }
fi
# Public key is not secret; must match the private EdDSA key used for Releases.
if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
fi
cp assets/FreeLingo.icns "$APP/Contents/Resources/FreeLingo.icns"
cp assets/MenubarIcon-72.png "$APP/Contents/Resources/MenubarIcon.png"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSE "$APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Pinned, pre-built Sparkle 2 updater; don't rely on an auto-updated dependency.
SPARKLE_VERSION=2.9.6
SPARKLE_DIST="$ROOT/.build/Sparkle-${SPARKLE_VERSION}"
if [[ ! -d "$SPARKLE_DIST/Sparkle.framework" ]]; then
  mkdir -p "$SPARKLE_DIST"
  curl --fail --location --retry 3 --silent --show-error \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
    -o "$ROOT/.build/Sparkle-${SPARKLE_VERSION}.tar.xz"
  tar -xJf "$ROOT/.build/Sparkle-${SPARKLE_VERSION}.tar.xz" -C "$SPARKLE_DIST"
fi
[[ -d "$SPARKLE_DIST/Sparkle.framework" ]] || { echo 'ERROR: Sparkle.framework missing' >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
# Ditto preserves Sparkle's nested symlinks and helper signatures.
ditto "$SPARKLE_DIST/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

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
  -F "$SPARKLE_DIST" -Wl,-rpath,@executable_path/../Frameworks -framework Sparkle \
  -I "$ROOT/native" "$ROOT/native/main.m" \
  "$ROOT/target/aarch64-apple-darwin/release/libfreelingo_core.a" \
  -framework Cocoa -framework Carbon -framework ApplicationServices \
  -framework CoreGraphics -framework Vision -framework QuartzCore \
  -framework Security -framework SystemConfiguration -framework ServiceManagement \
  -lresolv -liconv -o "$BIN/FreeLingo"

chmod +x "$BIN/FreeLingo" "$BIN/llama-server"
# The same identity must sign EVERY RELEASE to retain macOS TCC Accessibility grants.
# EdDSA archive signing alone does not provide stable macOS code identity.
IDENTITY="${SIGNING_IDENTITY:--}"
if [[ "${REQUIRE_STABLE_SIGNING:-0}" == "1" && "$IDENTITY" == "-" ]]; then
  echo 'ERROR: Stable signing identity required; refusing an ad-hoc release.' >&2
  exit 1
fi
SIGN_ARGS=(--force --sign "$IDENTITY" --timestamp=none)
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then
  [[ -f "$SIGNING_KEYCHAIN" ]] || { echo 'ERROR: signing keychain missing' >&2; exit 1; }
  SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
fi
if [[ "${SIGNING_DEVELOPER_ID:-0}" == "1" ]]; then
  [[ "$IDENTITY" != "-" ]] || { echo 'ERROR: Developer ID cannot use ad-hoc signing' >&2; exit 1; }
  SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime --timestamp)
  if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN"); fi
fi
for component in "$BIN"/*.dylib "$BIN/llama-server"; do
  [[ -f "$component" ]] || continue
  codesign "${SIGN_ARGS[@]}" "$component"
done
codesign "${SIGN_ARGS[@]}" "$APP"
if [[ "$IDENTITY" != "-" ]]; then
  codesign -dvv "$APP" 2>&1 | grep -E 'Authority=|TeamIdentifier=|Signature='
  codesign -d --requirements - "$APP" 2>&1 | grep -F 'designated =>'
fi
# Ensure the app resolves Sparkle from the bundle, never the CI build machine.
otool -L "$BIN/FreeLingo" | grep -F '@rpath/Sparkle.framework/Versions/'
[[ -f "$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist" ]] || \
  [[ -L "$APP/Contents/Frameworks/Sparkle.framework/Resources" ]]
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
# macOS runners sporadically report EBUSY just after copying the stage.
# Retrying image creation does not alter the compiled app.
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG_OUTPUT="$ROOT/dist/FreeLingo-${APP_VERSION}-AppleSilicon.dmg"
DMG_OK=0
for attempt in 1 2 3 4 5; do
  echo "DMG create: attempt $attempt/5"
  sync
  sleep "$((attempt * 3))"
  rm -f "$DMG_OUTPUT"
  if hdiutil create -volname "FreeLingo ${APP_VERSION}" -srcfolder "$STAGE" \
      -format UDZO -imagekey zlib-level=9 -ov "$DMG_OUTPUT"; then
    if hdiutil verify "$DMG_OUTPUT"; then
      DMG_OK=1
      break
    fi
    echo "WARNING: DMG verification failed on attempt $attempt" >&2
  else
    echo "WARNING: hdiutil create failed on attempt $attempt" >&2
  fi
done
if [[ "$DMG_OK" -ne 1 ]]; then
  echo "ERROR: Could not create a verified DMG after 5 attempts" >&2
  hdiutil info || true
  exit 1
fi
echo "DMG built: $ROOT/dist/FreeLingo-${APP_VERSION}-AppleSilicon.dmg"

# Record a reproducible checksum for the GitHub Actions artifact.
shasum -a 256 "$ROOT/dist/FreeLingo-${APP_VERSION}-AppleSilicon.dmg" > "$ROOT/dist/FreeLingo-${APP_VERSION}-AppleSilicon.dmg.sha256"

# Sparkle update archive: avoids distributing a DMG for in-app updates.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/FreeLingo-${APP_VERSION}-AppleSilicon.zip"
