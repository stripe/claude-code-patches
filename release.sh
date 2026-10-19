#!/bin/bash
# Builds bsdiff patches from the last ten stable Claude Code releases to a new
# version and, only in the trusted publish mode, creates the GitHub release.
#
# Modes:
#   release.sh prepare [--out DIR]
#       Discover the target version (VERSION_INPUT: empty = upstream stable,
#       "npm" = latest npm version, or an explicit X.Y.Z), then build and
#       round-trip verify patches. Needs only read access. Never publishes.
#   release.sh build --tag vX.Y.Z --commit SHA --out DIR
#       Build and verify patches for an existing protected tag that must
#       resolve to SHA. No version discovery. Needs only read access.
#   release.sh publish --tag vX.Y.Z --commit SHA --dir DIR
#       Re-verify the output of `build` for the same tag/commit and create the
#       release for that pre-existing tag. Requires contents:write. Never
#       creates tags.
#
# Running with no mode is equivalent to `prepare`.
set -euo pipefail

REPO="stripe/claude-code-patches"
STORAGE_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
PLATFORM="darwin-arm64"
MAX_PREVIOUS=10
MANIFEST_NAME="release-manifest.json"

VERSION_RE='^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$'
COMMIT_RE='^[0-9a-f]{40}$'
SHA256_RE='^[0-9a-f]{64}$'

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

validate_version() {
  [[ "$1" =~ $VERSION_RE ]] || die "unsupported version '$1' (expected X.Y.Z)"
}

validate_tag() {
  [[ "$1" == v* ]] || die "unsupported tag '$1' (expected vX.Y.Z)"
  validate_version "${1#v}"
}

validate_commit() {
  [[ "$1" =~ $COMMIT_RE ]] || die "unsupported commit '$1' (expected 40-char lowercase SHA)"
}

validate_sha256() {
  [[ "$1" =~ $SHA256_RE ]] || die "unsupported sha256 '$1'"
}

sha256_of() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >>"$GITHUB_OUTPUT"
  fi
}

patch_name() {
  echo "$PLATFORM-from-$1.bsdiff"
}

release_exists() {
  gh release view "$1" --repo "$REPO" >/dev/null 2>&1
}

# Prints the commit SHA that refs/tags/$1 resolves to; fails if the tag is missing.
tag_commit() {
  gh api "repos/$REPO/commits/refs/tags/$1" --jq '.sha'
}

require_tag_commit() {
  local tag="$1" commit="$2" actual
  if ! actual=$(tag_commit "$tag"); then
    die "tag $tag does not exist in $REPO; tags must be created by an authorized maintainer"
  fi
  [ "$actual" = "$commit" ] || die "tag $tag resolves to '$actual', expected approved commit $commit"
  echo "Tag $tag resolves to approved commit $commit"
}

# Version discovery is only performed in prepare mode.
resolve_version() {
  local version
  case "${VERSION_INPUT:-}" in
  npm)
    version=$(npm show @anthropic-ai/claude-code version)
    echo "Using latest npm version: $version" >&2
    ;;
  "")
    version=$(curl -fsSL "$STORAGE_BASE/stable")
    echo "Using latest stable version: $version" >&2
    ;;
  *)
    version="$VERSION_INPUT"
    echo "Using provided version: $version" >&2
    ;;
  esac
  version=$(printf '%s' "$version" | tr -d '[:space:]')
  validate_version "$version"
  echo "$version"
}

# Ten most recent released versions (excluding the target), newest first.
previous_versions() {
  local target="$1" tag version
  gh release list --repo "$REPO" --limit 100 --json tagName --jq '.[].tagName' |
    while IFS= read -r tag; do
      version="${tag#v}"
      if [[ "$tag" != v* || ! "$version" =~ $VERSION_RE ]]; then
        echo "WARNING: ignoring release with unsupported tag '$tag'" >&2
        continue
      fi
      [ "$version" = "$target" ] || echo "$version"
    done | sort -r -V | head -n "$MAX_PREVIOUS"
}

upstream_checksum() {
  local version="$1" checksum
  checksum=$(curl -fsSL "$STORAGE_BASE/$version/manifest.json" |
    jq -r --arg p "$PLATFORM" '.platforms[$p].checksum')
  validate_sha256 "$checksum"
  echo "$checksum"
}

# Downloads and checksum-verifies the target binary into $2.
fetch_verified_latest() {
  local version="$1" dest="$2" expected actual
  echo "Downloading latest version $version..." >&2
  curl -fsSL "$STORAGE_BASE/$version/$PLATFORM/claude" -o "$dest"
  expected=$(upstream_checksum "$version")
  echo "Expected shasum for latest: $expected" >&2
  actual=$(sha256_of "$dest")
  if [ "$actual" != "$expected" ]; then
    echo "Expected: $expected" >&2
    echo "Got: $actual" >&2
    die "checksum mismatch for latest version $version"
  fi
  echo "Latest binary checksum verified" >&2
  echo "$expected"
}

# Applies patch $2 to old binary $1 and checks the result has sha256 $3.
verify_round_trip() {
  local old_bin="$1" patch="$2" expected="$3" patched actual
  patched="$old_bin-patched"
  bspatch "$old_bin" "$patched" "$patch"
  actual=$(sha256_of "$patched")
  rm -f "$patched"
  if [ "$actual" != "$expected" ]; then
    echo "  Expected: $expected" >&2
    echo "  Got: $actual" >&2
    return 1
  fi
}

# Builds verified patches for $version into $out and writes the manifest.
build_patches() {
  local mode="$1" version="$2" out="$3" commit="$4"
  local tag="v$version" latest_bin latest_sha old old_bin patch file
  local patches_json="[]"

  mkdir -p "$out"
  [ -z "$(ls -A "$out")" ] || die "output directory $out must be empty"

  latest_bin="$WORK_DIR/claude-code-$version"
  latest_sha=$(fetch_verified_latest "$version" "$latest_bin")

  echo "Fetching version history from GitHub releases..."
  local previous
  previous=$(previous_versions "$version")
  if [ -z "$previous" ]; then
    echo "No previous versions found, skipping patch generation"
  fi
  echo "Previous versions:"
  echo "$previous"

  for old in $previous; do
    validate_version "$old"
    echo ""
    echo "Processing version $old..."
    old_bin="$WORK_DIR/claude-code-$old"
    file=$(patch_name "$old")
    patch="$WORK_DIR/$file"

    echo "  Downloading $old..."
    if ! curl -fsSL "$STORAGE_BASE/$old/$PLATFORM/claude" -o "$old_bin"; then
      echo "  WARNING: Failed to download $old, skipping..."
      continue
    fi

    echo "  Generating patch from $old to $version..."
    bsdiff "$old_bin" "$latest_bin" "$patch"

    echo "  Verifying patch..."
    verify_round_trip "$old_bin" "$patch" "$latest_sha" ||
      die "patch verification failed for $old"
    echo "  Patch verified successfully"

    cp "$patch" "$out/$file"
    patches_json=$(jq -c --arg from "$old" --arg file "$file" --arg sha "$(sha256_of "$out/$file")" \
      '. + [{from: $from, file: $file, sha256: $sha}]' <<<"$patches_json")
  done

  jq -n \
    --arg mode "$mode" \
    --arg repo "$REPO" \
    --arg tag "$tag" \
    --arg version "$version" \
    --arg commit "$commit" \
    --arg platform "$PLATFORM" \
    --arg latest "$latest_sha" \
    --argjson patches "$patches_json" \
    '{mode: $mode, repo: $repo, tag: $tag, version: $version, commit: $commit,
      platform: $platform, latest_sha256: $latest, patches: $patches}' \
    >"$out/$MANIFEST_NAME"

  echo ""
  echo "Wrote $(jq '.patches | length' "$out/$MANIFEST_NAME") verified patch(es) and $MANIFEST_NAME to $out"
}

cmd_prepare() {
  local out="$1" version
  [ -n "$out" ] || out="$WORK_DIR/out"
  version=$(resolve_version)
  set_output version "$version"
  set_output tag "v$version"

  echo "Checking for release tag: v$version"
  if release_exists "v$version"; then
    echo "Release v$version already exists"
    set_output release_exists true
    return 0
  fi
  echo "Release v$version does not exist"
  set_output release_exists false

  build_patches prepare "$version" "$out" "${PREPARE_SOURCE_COMMIT:-}"
  set_output out "$out"
  echo ""
  echo "Prepared v$version. This mode never publishes. To publish, an authorized"
  echo "maintainer must create the protected tag v$version on an approved commit"
  echo "of main; the 'Publish release' workflow then requires 'release' approval."
}

cmd_build() {
  local tag="$1" commit="$2" out="$3"
  [[ -n "$tag" && -n "$commit" && -n "$out" ]] || usage
  validate_tag "$tag"
  validate_commit "$commit"
  require_tag_commit "$tag" "$commit"

  if release_exists "$tag"; then
    echo "Release $tag already exists; nothing to build"
    set_output release_exists true
    return 0
  fi
  set_output release_exists false
  build_patches build "${tag#v}" "$out" "$commit"
}

cmd_publish() {
  local tag="$1" commit="$2" dir="$3"
  [[ -n "$tag" && -n "$commit" && -n "$dir" ]] || usage
  validate_tag "$tag"
  validate_commit "$commit"
  local version="${tag#v}" manifest="$dir/$MANIFEST_NAME"

  require_tag_commit "$tag" "$commit"

  if release_exists "$tag"; then
    echo "Release $tag already exists; refusing to modify it"
    return 0
  fi

  [ -f "$manifest" ] || die "missing $manifest"
  local field expected
  for field in mode repo tag version commit platform; do
    case "$field" in
    mode) expected=build ;;
    repo) expected="$REPO" ;;
    tag) expected="$tag" ;;
    version) expected="$version" ;;
    commit) expected="$commit" ;;
    platform) expected="$PLATFORM" ;;
    esac
    [ "$(jq -r --arg f "$field" '.[$f] // empty | strings' "$manifest")" = "$expected" ] ||
      die "manifest $field does not match expected '$expected'"
  done

  local latest_sha upstream_sha
  latest_sha=$(jq -r '.latest_sha256 // empty | strings' "$manifest")
  validate_sha256 "$latest_sha"
  upstream_sha=$(upstream_checksum "$version")
  [ "$latest_sha" = "$upstream_sha" ] ||
    die "manifest latest_sha256 does not match upstream checksum for $version"

  jq -e '.patches | type == "array"' "$manifest" >/dev/null || die "manifest patches must be an array"

  # Every file in the directory must be the manifest or a listed patch.
  local listed=() entry from file sha old_bin seen=" "
  while IFS=$'\t' read -r from file sha; do
    [ -n "$from" ] || continue
    validate_version "$from"
    [ "$from" != "$version" ] || die "manifest contains a patch from the target version"
    [ "$file" = "$(patch_name "$from")" ] || die "unexpected patch file name '$file'"
    validate_sha256 "$sha"
    [[ "$seen" != *" $file "* ]] || die "duplicate patch entry $file"
    seen="$seen$file "
    [[ -f "$dir/$file" && ! -L "$dir/$file" ]] || die "missing patch file $file"
    [ "$(sha256_of "$dir/$file")" = "$sha" ] || die "digest mismatch for $file"

    echo "Re-verifying $file..."
    old_bin="$WORK_DIR/claude-code-$from"
    curl -fsSL "$STORAGE_BASE/$from/$PLATFORM/claude" -o "$old_bin" ||
      die "failed to download $from for verification"
    verify_round_trip "$old_bin" "$dir/$file" "$latest_sha" ||
      die "patch verification failed for $from"
    listed+=("$dir/$file")
  done < <(jq -r '.patches[] | [.from, .file, .sha256] | map(strings) | @tsv' "$manifest")

  [ "${#listed[@]}" -eq "$(jq '.patches | length' "$manifest")" ] || die "manifest contains malformed patch entries"
  [ "${#listed[@]}" -le "$MAX_PREVIOUS" ] || die "manifest lists more than $MAX_PREVIOUS patches"
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [ -e "$entry" ] || continue
    file=$(basename "$entry")
    [ "$file" = "$MANIFEST_NAME" ] || [[ "$seen" == *" $file "* ]] ||
      die "unexpected file in $dir: $file"
  done

  echo ""
  echo "Creating release: $tag"
  local notes="Version: $version
Changelog: https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"

  gh release create "$tag" \
    --repo "$REPO" \
    --verify-tag \
    --title "Anthropic just released $tag!" \
    --notes "$notes" \
    --latest \
    ${listed[@]+"${listed[@]}"}

  echo "Successfully created release $tag with ${#listed[@]} patch(es)"
}

main() {
  local mode="prepare" tag="" commit="" out="" dir=""
  if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
    mode="$1"
    shift
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
    --tag) tag="${2:-}" ;;
    --commit) commit="${2:-}" ;;
    --out) out="${2:-}" ;;
    --dir) dir="${2:-}" ;;
    -h | --help) usage ;;
    *) usage ;;
    esac
    shift 2 || usage
  done

  WORK_DIR=$(mktemp -d)
  trap 'rm -rf "$WORK_DIR"' EXIT
  echo "Working directory: $WORK_DIR"

  case "$mode" in
  prepare)
    [ -z "$tag$commit$dir" ] || usage
    cmd_prepare "$out"
    ;;
  build) cmd_build "$tag" "$commit" "$out" ;;
  publish) cmd_publish "$tag" "$commit" "$dir" ;;
  *) usage ;;
  esac
}

main "$@"
