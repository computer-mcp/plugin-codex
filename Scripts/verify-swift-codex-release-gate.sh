#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
PACKAGE="$ROOT_DIR/Package.swift"
RESOLVED="$ROOT_DIR/Package.resolved"
PACKAGE_FLAT=$(tr '\n' ' ' < "$PACKAGE")

if print -r -- "$PACKAGE_FLAT" | rg -q '\.package\([^)]*(path:|branch:|revision:)[^)]*swift-codex'; then
  echo "GitHub release gate blocked: swift-codex is still a local path dependency." >&2
  echo "Publish swift-codex, select a fixed tag, and replace it with an exact remote dependency." >&2
  exit 1
fi

if ! print -r -- "$PACKAGE_FLAT" | rg -q '\.package\(\s*url:\s*"https://github\.com/swift-library/swift-codex\.git"\s*,\s*exact:\s*"[0-9]+\.[0-9]+\.[0-9]+"\s*\)'; then
  echo "GitHub release gate blocked: swift-codex must be an exact remote dependency." >&2
  exit 1
fi

SDK_VERSION=$(print -r -- "$PACKAGE_FLAT" | sed -n \
  's/.*https:\/\/github\.com\/swift-library\/swift-codex\.git"[[:space:]]*,[[:space:]]*exact:[[:space:]]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p')
if ! jq -e --arg version "$SDK_VERSION" '
  [.pins[] | select(.identity == "swift-codex")]
  | length == 1
    and .[0].location == "https://github.com/swift-library/swift-codex.git"
    and .[0].state.version == $version
    and (.[0].state.revision | test("^[0-9a-f]{40}$"))
' "$RESOLVED" >/dev/null; then
  echo "GitHub release gate blocked: Package.resolved must match the exact SDK version." >&2
  exit 1
fi

SDK_REVISION=$(jq -r '.pins[] | select(.identity == "swift-codex") | .state.revision' "$RESOLVED")
if ! SDK_REFS=$(git ls-remote --exit-code https://github.com/swift-library/swift-codex.git \
  "refs/tags/v$SDK_VERSION" "refs/tags/v$SDK_VERSION^{}"); then
  echo "GitHub release gate blocked: the public SDK tag is unavailable." >&2
  exit 1
fi
SDK_REMOTE_REVISION=$(print -r -- "$SDK_REFS" | awk \
  '$2 ~ /\^\{\}$/ { peeled = $1 } { direct = $1 } END { print peeled ? peeled : direct }')
if [[ "$SDK_REMOTE_REVISION" != "$SDK_REVISION" ]]; then
  echo "GitHub release gate blocked: the public SDK tag does not match the resolved revision." >&2
  exit 1
fi

echo "swift-codex release dependency gate passed ($SDK_VERSION, $SDK_REVISION)."
