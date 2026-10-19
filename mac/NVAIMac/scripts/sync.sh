#!/usr/bin/env bash
# Copies the source from this machine to the build Mac and generates the Xcode project there.
# The source of truth is this folder; never edit on the Mac: ~/NVAIMac/Sources is replaced
# on every sync.
#
#   MAC_HOST=my-mac mac/NVAIMac/scripts/sync.sh      # default host: macmini (an ssh alias)
#
# Requires XcodeGen on the Mac (XCODEGEN, default: xcodegen on PATH or ~/tools/xcodegen/bin).
# Package.resolved (pinned package versions) is copied to where Xcode expects it.
set -euo pipefail
host="${MAC_HOST:-macmini}"
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
files=(project.yml Sources Resources scripts)
[ -f Package.resolved ] && files+=(Package.resolved)
tar -czf - "${files[@]}" | ssh -o BatchMode=yes "$host" '
  set -e
  mkdir -p ~/NVAIMac && cd ~/NVAIMac
  rm -rf Sources scripts
  tar -xzf -
  XCODEGEN=${XCODEGEN:-$(command -v xcodegen || echo ~/tools/xcodegen/bin/xcodegen)}
  "$XCODEGEN" generate --quiet
  if [ -f Package.resolved ]; then
    mkdir -p NVAIMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
    cp Package.resolved NVAIMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  fi
  echo "Synced: ~/NVAIMac"
'
