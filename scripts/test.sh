#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh
build/Build/Products/Release/MacTools.app/Contents/MacOS/MacTools --self-test
build/Build/Products/Release/MacTools.app/Contents/MacOS/MacTools --meme-cache-self-test
build/Build/Products/Release/MacTools.app/Contents/MacOS/MacTools --meme-sources-self-test
build/Build/Products/Release/MacTools.app/Contents/MacOS/MacTools --local-memes-self-test
build/Build/Products/Release/MacTools.app/Contents/MacOS/MacTools --video-self-test
