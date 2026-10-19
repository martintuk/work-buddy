# shellcheck shell=bash
# Shared toolchain setup for the build and test scripts. Source, do not run.

# Starting with SDK 27, @State uses SwiftUIMacros, whose plugin ships with Xcode.
# Fall back to SDK 26 when the Command Line Tools lack that plugin.
DEVELOPER_DIR_PATH="$(xcode-select -p)"
LEGACY_SDK="$DEVELOPER_DIR_PATH/SDKs/MacOSX26.sdk"
if [[ -z "${SDKROOT:-}" && -d "$LEGACY_SDK" ]] \
    && ! find "$DEVELOPER_DIR_PATH" -name libSwiftUIMacros.dylib -print -quit 2>/dev/null | grep -q .; then
    export SDKROOT="$LEGACY_SDK"
fi
