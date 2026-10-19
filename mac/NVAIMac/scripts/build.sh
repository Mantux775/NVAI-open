#!/bin/zsh
# Builds NV-AI.app on the Mac (signed ad hoc, for tests).
#
#   ssh <mac> 'zsh ~/NVAIMac/scripts/build.sh'
#
# MLX needs xcodebuild (not swift build) and the Metal Toolchain
# (xcodebuild -downloadComponent MetalToolchain). Package sources stay in
# ~/NVAIMac/SourcePackages between builds.
set -e
ROOT=${ROOT:-$HOME/NVAIMac}
cd $ROOT
xcodebuild -project NVAIMac.xcodeproj -scheme NVAIMac -configuration Release \
  -derivedDataPath $ROOT/dd \
  -clonedSourcePackagesDirPath $ROOT/SourcePackages \
  -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY=- \
  build > $ROOT/build.log 2>&1 || true
grep -E "error:|warning: .*NVAIMac/Sources|BUILD (SUCCEEDED|FAILED)" $ROOT/build.log | grep -v "SourcePackages" | tail -60
app=$ROOT/dd/Build/Products/Release/NV-AI.app
if [ -d "$app" ] && grep -q "BUILD SUCCEEDED" $ROOT/build.log; then
  # Hand Package.resolved back for the repository.
  cp NVAIMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved $ROOT/Package.resolved 2>/dev/null || true
  echo "App: $app"
  du -sh "$app"
fi
