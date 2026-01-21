#!/bin/bash
set -euo pipefail

# Determine version
if [ "${VERSION_INPUT:-}" = "npm" ]; then
  VERSION=$(npm show @anthropic-ai/claude-code version)
  echo "Using latest npm version: $VERSION"
elif [ -n "${VERSION_INPUT:-}" ]; then
  VERSION="${VERSION_INPUT}"
  echo "Using provided version: $VERSION"
else
  VERSION=$(curl https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/stable)
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
echo "Creating release: $RELEASE_TAG"

# Create release
gh release create "$RELEASE_TAG" \
  --title "Anthropic just released $RELEASE_TAG!" \
  --notes "Version: $VERSION
Changelog: https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
Bump Claude Code using \`./claude-code/bump_claude_version.sh\`
React to this message with \`:create-minion-gocode:\` and claim the /++es!" \
  --latest

echo "Successfully created release $RELEASE_TAG"
