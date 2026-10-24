# FreeLingo 0.5.4: fix for GitHub Actions DMG error

From `logs_108781400808.zip`: `hdiutil: create failed - Resource busy`. The app compiled, four Rust tests passed. The model smoke test DID NOT RUN because packaging failed.

Changed: build-macos.sh retries DMG creation five times with sync and backoff, removes incomplete image and verifies final image. New offline test simulates transient and persistent hdiutil failures.

Upload this updated `FreeLingo-0.5.4-update.zip` (same filename) via https://github.com/igrizlikov/FreeLingo/upload/main, Commit changes and rerun Actions > Build FreeLingo DMG (Apple Silicon) > Run workflow. The existing GitHub workflow extracts this ZIP before each build.

Status: local static tests, NOT a verified macOS DMG. No claim that model downloading or translating has been fixed.
