#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Command Line Tools ships Testing as a framework outside SwiftPM's default search path.
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
    swift test --disable-xctest -Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$(dirname "$frameworks")/usr/lib" "$@"
else
    swift test --disable-xctest "$@"
fi
