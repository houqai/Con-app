#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/.."
failed=0
for sdk in aarch64-swift-linux-musl x86_64-swift-linux-musl aarch64-unknown-linux-android28 x86_64-unknown-linux-android28; do
  SWIFT_SDK="$sdk" ./Scripts/check-shared-sdk.sh || failed=1
done
exit $failed
