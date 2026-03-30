#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
SPARKLE_BIN="${BUILD_DIR}/SourcePackages/artifacts/sparkle/Sparkle/bin"

usage() {
  echo "Usage: $0 <version>"
  echo "Example: $0 1.0.1"
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

VERSION="$1"
TAG="v${VERSION}"

# Validate version format (X.Y.Z)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Invalid version format. Use X.Y.Z (e.g., 1.0.1)"
  exit 1
fi

cd "$ROOT_DIR"

echo "=== Releasing Canopy ${VERSION} ==="

# Get current build number and increment
CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | sed 's/.*: *"\([0-9]*\)".*/\1/')
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "=== Bumping version to ${VERSION} (build ${NEW_BUILD}) ==="

# Update version in project.yml
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"${VERSION}\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"/" project.yml

echo "=== Building and packaging DMG ==="
"${ROOT_DIR}/scripts/package_dmg.sh"

DMG_PATH="${BUILD_DIR}/Canopy-${VERSION}.dmg"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Error: DMG not found at $DMG_PATH"
  exit 1
fi

echo "=== Creating commit and tag ==="
jj describe -m "Release ${VERSION}

- Bump version to ${VERSION} (build ${NEW_BUILD})

Co-Authored-By: Claude ${MODEL_NAME:-Opus 4.6} <noreply@anthropic.com>"

# Move main bookmark to current commit and push
jj bookmark set main -r @
jj new
jj git push --bookmark main

# Create and push git tag (force-update if re-releasing the same version)
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists, updating to current commit"
  git tag -d "$TAG"
  git push origin ":refs/tags/$TAG" 2>/dev/null || true
fi
git tag "$TAG"
git push origin "$TAG"

echo "=== Creating GitHub Release ==="
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists, uploading DMG"
  gh release upload "$TAG" "$DMG_PATH" --clobber
else
  gh release create "$TAG" "$DMG_PATH" \
    --title "Canopy ${VERSION}" \
    --notes "$(cat <<EOF
### Changes
- (Add release notes here)
EOF
)"
fi

echo "=== Updating Sparkle appcast ==="
"${ROOT_DIR}/scripts/update_appcast.sh" "$VERSION"

echo "=== Cleaning up dev builds ==="
find "${BUILD_DIR}" -name "Canopy.app" -type d -exec rm -rf {} + 2>/dev/null || true
echo "Removed all .app bundles from ${BUILD_DIR}"

echo "=== Release complete ==="
echo "Version: ${VERSION}"
echo "Tag: ${TAG}"
echo "DMG: ${DMG_PATH}"
echo ""
echo "Don't forget to update the release notes on GitHub!"
