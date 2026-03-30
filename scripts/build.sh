#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

CONFIGURATION="${1:-Debug}"

mkdir -p "${BUILD_DIR}"

# Regenerate Xcode project from project.yml
xcodegen generate --spec "${ROOT_DIR}/project.yml"

xcodebuild \
  -scheme Canopy \
  -configuration "${CONFIGURATION}" \
  -destination 'platform=macOS' \
  -derivedDataPath "${BUILD_DIR}" \
  build

echo "Built app:"
echo "${BUILD_DIR}/Build/Products/${CONFIGURATION}/Canopy.app"
