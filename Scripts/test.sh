#!/usr/bin/env bash
# Run tests.
#
# These flags support swift-testing with the Command Line Tools. SwiftPM omits
# the Testing.framework search path and lib_TestingInterop.dylib rpath, even
# though both are bundled. Without them, swift test reports no such module Testing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
LIBS="$DEVELOPER/Library/Developer/usr/lib"

cd "$ROOT"

if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xlinker -F -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$LIBS" \
        "$@"
fi

# With full Xcode selected, SwiftPM resolves these paths itself.
exec swift test "$@"
