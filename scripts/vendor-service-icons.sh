#!/usr/bin/env bash
# Vendors the pull request panel's service artwork into the asset catalog (ADR-116).
#
# Each forge's own glyphs, pinned by version and fetched from npm through jsDelivr:
#   - Octicons      (@primer/octicons, MIT)  — GitHub's icon set and the GitHub mark
#   - GitLab SVGs   (@gitlab/svgs,     MIT)  — GitLab's icon set
#   - Simple Icons  (simple-icons,     CC0)  — the GitLab mark and CI provider marks
#
# Every SVG becomes a template imageset, so SwiftUI tints it with the service palette. Re-run after
# bumping a version or adding a name; the output is committed.
set -euo pipefail

OCTICONS=19.36.0
GITLAB_SVGS=3.164.0
SIMPLE_ICONS=16.30.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Sources/Clinic/Assets.xcassets/Service"

octicons=(
  mark-github
  git-pull-request git-pull-request-draft git-merge git-pull-request-closed
  check x alert dot-fill clock pencil eye comment comment-discussion checklist file-diff
  git-branch git-compare git-merge-queue code-review link-external
  check-circle-fill x-circle-fill skip stop circle-slash question
)
gitlab=(
  merge-request-open merge-request merge merge-request-close
  check close warning clock pencil eye comment comments pipeline doc-changes overview approval branch
  status_success_borderless status_failed_borderless status_running_borderless status_pending_borderless
  status_skipped_borderless status_canceled_borderless status_notfound_borderless external-link
)
brands=(
  gitlab githubactions codecov circleci buildkite vercel netlify travisci bitrise jenkins sonarqubecloud
)

rm -rf "$OUT"
mkdir -p "$OUT"
printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > "$OUT/Contents.json"

imageset() { # <asset name> <url>
  local dir="$OUT/$1.imageset"
  mkdir -p "$dir"
  if ! curl -fsSL "$2" -o "$dir/$1.svg"; then
    echo "missing: $2" >&2
    rm -rf "$dir"
    return 1
  fi
  cat > "$dir/Contents.json" <<EOF
{
  "images" : [ { "filename" : "$1.svg", "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "preserves-vector-representation" : true, "template-rendering-intent" : "template" }
}
EOF
}

for n in "${octicons[@]}"; do
  imageset "octicon.$n" "https://cdn.jsdelivr.net/npm/@primer/octicons@$OCTICONS/build/svg/$n-16.svg"
done
for n in "${gitlab[@]}"; do
  imageset "gitlab.$n" "https://cdn.jsdelivr.net/npm/@gitlab/svgs@$GITLAB_SVGS/dist/sprite_icons/$n.svg"
done
for n in "${brands[@]}"; do
  imageset "brand.$n" "https://cdn.jsdelivr.net/npm/simple-icons@$SIMPLE_ICONS/icons/$n.svg"
  # Simple Icons ship a bare viewBox; the asset catalogue wants an intrinsic size.
  sed -i '' 's/<svg /<svg width="24" height="24" /' "$OUT/brand.$n.imageset/brand.$n.svg"
done

echo "Vendored $(find "$OUT" -name '*.svg' | wc -l | tr -d ' ') SVGs into ${OUT#"$ROOT"/}"
