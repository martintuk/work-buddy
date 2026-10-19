#!/usr/bin/env bash
# Run the Swift tests. Extra arguments are passed to swift test.
#
# These flags support swift-testing with the Command Line Tools. SwiftPM omits
# the Testing.framework search path and lib_TestingInterop.dylib rpath, even
# though both are bundled. Without them, swift test reports no such module Testing.
# SwiftPM also omits the TestingMacros plugin, which lives in its own
# subdirectory. Without it, @Test and @Suite fail once the tests need rebuilding.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/toolchain.sh
source "$ROOT/scripts/lib/toolchain.sh"
FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
LIBS="$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"
PLUGINS="$DEVELOPER_DIR_PATH/usr/lib/swift/host/plugins/testing"

cd "$ROOT"

if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xswiftc -plugin-path -Xswiftc "$PLUGINS" \
        -Xlinker -F -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$LIBS" \
        "$@"
fi

# With full Xcode selected, SwiftPM resolves these paths itself.
exec swift test "$@"
