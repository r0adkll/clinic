#!/usr/bin/env bash
# Builds GhosttyKit.xcframework from the pinned vendor/ghostty submodule (ADR-008, ADR-014).
# Output: Packages/GhosttyBridge/GhosttyKit.xcframework (gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
OUT="$ROOT/Packages/GhosttyBridge/GhosttyKit.xcframework"
TARGET="${GHOSTTY_XCFRAMEWORK_TARGET:-native}"   # native | universal
OPTIMIZE="${GHOSTTY_OPTIMIZE:-ReleaseFast}"

if [ ! -f "$GHOSTTY/build.zig.zon" ]; then
  echo "error: submodule missing; run: git submodule update --init" >&2; exit 1
fi

REQUIRED_ZIG="$(sed -nE 's/.*minimum_zig_version = "([^"]+)".*/\1/p' "$GHOSTTY/build.zig.zon")"
SERIES="${REQUIRED_ZIG%.*}"   # Ghostty builds with exactly one Zig minor series; any patch release of it works.
ZIG="${ZIG:-}"
if [ -z "$ZIG" ]; then
  # The versioned keg first (zig@0.15 while it is the older series), then the unversioned
  # keg (Homebrew's current `zig`), then PATH.
  for candidate in "/opt/homebrew/opt/zig@${SERIES}/bin/zig" "/opt/homebrew/opt/zig/bin/zig" "$(command -v zig || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      v="$("$candidate" version)"
      if [ "${v%.*}" = "$SERIES" ] && [ "$(printf '%s\n%s\n' "$REQUIRED_ZIG" "$v" | sort -V | head -1)" = "$REQUIRED_ZIG" ]; then
        ZIG="$candidate"; break
      fi
    fi
  done
fi
if [ -z "$ZIG" ]; then
  echo "error: need zig $SERIES.x (>= $REQUIRED_ZIG). Try: brew install zig@${SERIES} (or brew install zig if $SERIES is current)" >&2; exit 1
fi
echo "using zig $("$ZIG" version) at $ZIG"

if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  echo "error: Metal Toolchain missing. Run: xcodebuild -downloadComponent MetalToolchain" >&2; exit 1
fi

cd "$GHOSTTY"
"$ZIG" build \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target="$TARGET" \
  -Doptimize="$OPTIMIZE" \
  "$@"

rm -rf "$OUT"
cp -R "$GHOSTTY/macos/GhosttyKit.xcframework" "$OUT"
echo "built $OUT"
