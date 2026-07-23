#!/usr/bin/env bash
set -euo pipefail

# Debug build with a STABLE code signature so macOS TCC (Documents / Desktop
# / Downloads folder access, Full Disk Access, etc.) grants persist across
# rebuilds. Without this, ad-hoc / linker-signed Debug builds trip the TCC
# consent dialog on every launch — TCC keys off the designated requirement,
# which changes on every ad-hoc re-sign.
#
# Preconditions on this machine:
#   - `Apple Development: Tomohiko Koyama (CH29255Y7T)` cert in login keychain
#   - Team G5G54TCH8W (Whatever Co.) — that's the cert's actual OU
#
# The Debug build's bundle ID is `sh.saqoo.Canopy.debug` (distinct from the
# Release `sh.saqoo.Canopy`) so TCC entries don't collide with the installed
# release copy. Grant Documents permission once in this build; it sticks.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

CERT_CN="Apple Development: Tomohiko Koyama (CH29255Y7T)"
TEAM_ID="G5G54TCH8W"
DEBUG_BUNDLE_ID="sh.saqoo.Canopy.debug"

mkdir -p "${BUILD_DIR}"

xcodegen generate --spec "${ROOT_DIR}/project.yml"

xcodebuild \
  -scheme Canopy \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "${BUILD_DIR}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${CERT_CN}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  PRODUCT_BUNDLE_IDENTIFIER="${DEBUG_BUNDLE_ID}" \
  build

echo ""
echo "Built app:"
echo "${BUILD_DIR}/Build/Products/Debug/Canopy.app"
echo ""
codesign -dvv "${BUILD_DIR}/Build/Products/Debug/Canopy.app" 2>&1 |
  grep -E 'Identifier|Authority|TeamIdentifier' | head -6
