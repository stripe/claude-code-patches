#!/bin/bash
set -euo pipefail

STORAGE_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
WORK_DIR=$(mktemp -d)
echo "Working directory: $WORK_DIR"

# shellcheck disable=SC2064
trap "rm -rf $WORK_DIR" EXIT

# Determine version
if [ "${VERSION_INPUT:-}" = "npm" ]; then
  VERSION=$(npm show @anthropic-ai/claude-code version)
  echo "Using latest npm version: $VERSION"
elif [ -n "${VERSION_INPUT:-}" ]; then
  VERSION="${VERSION_INPUT}"
  echo "Using provided version: $VERSION"
else
  VERSION=$(curl -s "$STORAGE_BASE/stable")
  echo "Using latest stable version: $VERSION"
fi

RELEASE_TAG="v$VERSION"
echo "Checking for release tag: $RELEASE_TAG"

# Check if release exists
if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  echo "Release $RELEASE_TAG already exists"
  exit 0
fi

echo "Release $RELEASE_TAG does not exist"

# Get previous 3 versions from GitHub releases
echo "Fetching version history from GitHub releases..."
PREVIOUS_VERSIONS=$(gh release list --limit 100 --json tagName --jq '.[].tagName' | sort -r | head -n 3 | sed 's/^v//')

if [ -z "$PREVIOUS_VERSIONS" ]; then
  echo "No previous versions found, skipping patch generation"
  PREVIOUS_VERSIONS=""
fi

echo "Latest version: $VERSION"
echo "Previous versions:"
echo "$PREVIOUS_VERSIONS"

# Download latest version binary
echo "Downloading latest version $VERSION..."
LATEST_BIN="$WORK_DIR/claude-code-$VERSION"
curl -fsSL "$STORAGE_BASE/$VERSION/darwin-arm64/claude" -o "$LATEST_BIN"
chmod +x "$LATEST_BIN"

# Download manifest for checksum verification
echo "Downloading manifest..."
LATEST_SHASUM=$(curl -fsSL "$STORAGE_BASE/$VERSION/manifest.json" | jq -r '.["platforms"]["darwin-arm64"]["checksum"]')
echo "Expected shasum for latest: $LATEST_SHASUM"

# Verify latest binary checksum
ACTUAL_SHASUM=$(shasum -a 256 "$LATEST_BIN" | cut -d' ' -f1)
if [ "$ACTUAL_SHASUM" != "$LATEST_SHASUM" ]; then
  echo "ERROR: Checksum mismatch for latest version!"
  echo "Expected: $LATEST_SHASUM"
  echo "Got: $ACTUAL_SHASUM"
  exit 1
fi
echo "Latest binary checksum verified"

# Generate patches
PATCH_FILES=()
for OLD_VERSION in $PREVIOUS_VERSIONS; do
  echo ""
  echo "Processing version $OLD_VERSION..."

  OLD_BIN="$WORK_DIR/claude-code-$OLD_VERSION"
  PATCH_FILE="$WORK_DIR/darwin-arm64-from-$OLD_VERSION.bsdiff"

  # Download old version
  echo "  Downloading $OLD_VERSION..."
  if ! curl -fsSL "$STORAGE_BASE/$OLD_VERSION/darwin-arm64/claude" -o "$OLD_BIN"; then
    echo "  WARNING: Failed to download $OLD_VERSION, skipping..."
    continue
  fi
  chmod +x "$OLD_BIN"

  # Generate bsdiff patch
  echo "  Generating patch from $OLD_VERSION to $VERSION..."
  bsdiff "$OLD_BIN" "$LATEST_BIN" "$PATCH_FILE"

  # Verify patch
  echo "  Verifying patch..."
  PATCHED_BIN="$WORK_DIR/claude-code-$OLD_VERSION-patched"
  bspatch "$OLD_BIN" "$PATCHED_BIN" "$PATCH_FILE"

  PATCHED_SHASUM=$(shasum -a 256 "$PATCHED_BIN" | cut -d' ' -f1)
  if [ "$PATCHED_SHASUM" != "$LATEST_SHASUM" ]; then
    echo "  ERROR: Patch verification failed for $OLD_VERSION!"
    echo "  Expected: $LATEST_SHASUM"
    echo "  Got: $PATCHED_SHASUM"
    exit 1
  fi

  echo "  Patch verified successfully"
  PATCH_FILES+=("$PATCH_FILE")
done

# Create release
echo ""
echo "Creating release: $RELEASE_TAG"

RELEASE_NOTES="Version: $VERSION
Changelog: https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
Bump Claude Code using \`./claude-code/bump_claude_version.sh\`
React to this message with \`:create-minion-gocode:\` and claim the /++es!"

gh release create "$RELEASE_TAG" \
  --title "Anthropic just released $RELEASE_TAG!" \
  --notes "$RELEASE_NOTES" \
  --latest \
  "${PATCH_FILES[@]}"

echo "Successfully created release $RELEASE_TAG with ${#PATCH_FILES[@]} patch(es)"
