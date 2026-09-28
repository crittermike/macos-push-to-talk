#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if xcrun --find xctest >/dev/null 2>&1; then
  exec swift test "$@"
fi

if [[ $# -gt 0 ]]; then
  echo "The portable runner executes all cases and does not accept test filters." >&2
  exit 2
fi

echo "XCTest is unavailable; running the same deterministic cases with the portable runner."
mkdir -p .build/portable-tests
swiftc -swift-version 5 -D PORTABLE_TESTS -parse-as-library \
  Sources/PushToTalk/TeamsController.swift \
  Sources/PushToTalk/TeamsAccessibility.swift \
  Sources/PushToTalk/ModeController.swift \
  Tests/PushToTalkTests/TeamsControllerTests.swift \
  Tests/PortableTestRunner.swift \
  -o .build/portable-tests/PushToTalkTests
TEST_COUNT="$(grep -c '    func test' Tests/PushToTalkTests/TeamsControllerTests.swift)"
.build/portable-tests/PushToTalkTests "$TEST_COUNT"
