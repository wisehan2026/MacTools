#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
echo "App: $(pwd)/build/Build/Products/Release/MacTools.app"
