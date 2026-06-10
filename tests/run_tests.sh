#!/bin/bash
# TerrainGridAccumulator 단위 테스트 실행 스크립트
#
# ARKit 의존성이 없는 순수 로직(누적/평균화/시프트)을 macOS에서 직접
# 컴파일·실행한다. Xcode 테스트 타깃 없이 동작하므로 CI/로컬 모두 사용 가능.
#
# 사용법: tests/run_tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(mktemp -d)/lidar_grid_tests"

xcrun swiftc \
    ios/GolfPuttingLiDAR/Utils/TerrainGridAccumulator.swift \
    tests/GridAccumulatorTests.swift \
    -o "$BIN"

"$BIN"
