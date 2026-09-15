#!/usr/bin/env bash
# Sourced by release.sh and publish.sh. Reads the version out of Version.xcconfig and checks it is
# semver (ADR-153). Exports VERSION, TAG, BUILD and PRERELEASE (non-empty for 0.2.0-beta.1 and the like).
VERSION="$(sed -nE 's/^MARKETING_VERSION *= *(.*)$/\1/p' Version.xcconfig | head -1 | tr -d '[:space:]')"
[ -n "$VERSION" ] || { echo "error: no MARKETING_VERSION in Version.xcconfig" >&2; exit 1; }
if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "error: MARKETING_VERSION '$VERSION' is not semver (MAJOR.MINOR.PATCH[-prerelease])" >&2; exit 1
fi
TAG="$VERSION"   # the tag is the bare version, no "v" (ADR-153)
PRERELEASE="${BASH_REMATCH[4]}"
BUILD="$(git rev-list --count HEAD)"
export VERSION TAG BUILD PRERELEASE
