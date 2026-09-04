#!/usr/bin/env bash
# Corre los tests.
#
# Los flags son para que swift-testing funcione con las Command Line Tools:
# SwiftPM no le pasa el search path de Testing.framework ni el rpath de
# lib_TestingInterop.dylib, aunque los dos vienen incluidos. Sin esto, `swift
# test` falla con "no such module 'Testing'".
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

# Con Xcode como developer dir activo, SwiftPM resuelve todo solo.
exec swift test "$@"
