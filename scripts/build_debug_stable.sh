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
# project.yml's Debug config owns the bundle ID (`sh.saqoo.Canopy.debug`,
# distinct from the Release `sh.saqoo.Canopy`) so TCC entries don't collide
# with the installed release copy. Grant Documents permission once in this
# build; it sticks.
#
# This script deliberately does NOT pass PRODUCT_BUNDLE_IDENTIFIER. It used
# to, and that is worse than redundant: an xcodebuild command-line setting
# OVERRIDES the project, so the script would silently win any disagreement
# and pin a stale value while claiming project.yml was authoritative. Do NOT
# move the ID back here either — the routes that never run this script
# (scripts/build.sh, scripts/auto-adopt.sh, an Xcode GUI build, the CI job)
# would then build Debug under the Release bundle ID and register throwaway
# builds with LaunchServices under the shipped app's identity. That is the
# measured harm; see the project.yml comment, which also records a stale TCC
# row found alongside it and explains why that row is NOT evidence here.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

CERT_CN="Apple Development: Tomohiko Koyama (CH29255Y7T)"
TEAM_ID="G5G54TCH8W"

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
  build

echo ""
echo "Built app:"
echo "${BUILD_DIR}/Build/Products/Debug/Canopy.app"
echo ""
codesign -dvv "${BUILD_DIR}/Build/Products/Debug/Canopy.app" 2>&1 |
  grep -E 'Identifier|Authority|TeamIdentifier' | head -6
