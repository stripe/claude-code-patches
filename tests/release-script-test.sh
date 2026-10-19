#!/bin/bash
# Mocked tests for release.sh. curl, npm, gh, bsdiff and bspatch are replaced
# with stubs backed by a fixture directory, so no network access or release
# write credential is used.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RELEASE_SH="$ROOT/release.sh"
STORAGE_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
REPO="stripe/claude-code-patches"
COMMIT="0123456789abcdef0123456789abcdef01234567"
OTHER_COMMIT="fedcba9876543210fedcba9876543210fedcba98"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASSED=0
FAILED=0

# ---------------------------------------------------------------- mocks

write_mocks() {
  local bin="$1"
  mkdir -p "$bin"

  cat >"$bin/curl" <<'MOCK'
#!/bin/bash
url="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
  -o) out="$2"; shift ;;
  http*) url="$1" ;;
  esac
  shift
done
echo "curl $url" >>"$FIX/calls.log"
path="$FIX/storage/${url#"$STORAGE_BASE"/}"
[ -f "$path" ] || exit 22
if [ -n "$out" ]; then cp "$path" "$out"; else cat "$path"; fi
MOCK

  cat >"$bin/npm" <<'MOCK'
#!/bin/bash
echo "npm $*" >>"$FIX/calls.log"
[ "$*" = "show @anthropic-ai/claude-code version" ] || exit 1
echo "$MOCK_NPM_VERSION"
MOCK

  cat >"$bin/gh" <<'MOCK'
#!/bin/bash
echo "gh $*" >>"$FIX/calls.log"
case "$1 $2" in
"release view")
  [ "$4 $5" = "--repo $REPO" ] || exit 9
  [ -e "$FIX/releases/$3" ] ;;
"release list")
  [ "$3 $4" = "--repo $REPO" ] || exit 9
  cat "$FIX/release-list" ;;
"release create")
  : >"$FIX/create-args"
  for a in "$@"; do printf '%s\n' "$a" >>"$FIX/create-args"; done
  mkdir -p "$FIX/releases/$3" ;;
api\ repos/*)
  tag="${2#"repos/$REPO/commits/refs/tags/"}"
  [ "$tag" != "$2" ] || exit 9
  [ -f "$FIX/tags/$tag" ] || { echo "HTTP 404" >&2; exit 1; }
  cat "$FIX/tags/$tag" ;;
*) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
MOCK

  # Fake bsdiff format: sha256 of the old file, newline, then the new file.
  cat >"$bin/bsdiff" <<'MOCK'
#!/bin/bash
echo "bsdiff" >>"$FIX/calls.log"
{ shasum -a 256 "$1" | cut -c1-64; cat "$2"; } >"$3"
if [ -n "${MOCK_CORRUPT_PATCH:-}" ]; then printf 'x' >>"$3"; fi
MOCK

  cat >"$bin/bspatch" <<'MOCK'
#!/bin/bash
echo "bspatch" >>"$FIX/calls.log"
[ "$(head -n1 "$3")" = "$(shasum -a 256 "$1" | cut -c1-64)" ] || exit 1
tail -n +2 "$3" >"$2"
MOCK

  chmod +x "$bin"/*
}

add_upstream_version() {
  local v="$1" dir="$FIX/storage/$1"
  mkdir -p "$dir/darwin-arm64"
  printf 'claude binary %s\n' "$v" >"$dir/darwin-arm64/claude"
  jq -n --arg c "$(shasum -a 256 "$dir/darwin-arm64/claude" | cut -c1-64)" \
    '{platforms: {"darwin-arm64": {checksum: $c}}}' >"$dir/manifest.json"
}

# Fresh fixture: upstream 2.1.0..2.1.12 (stable 2.1.12), releases for
# 2.1.0..2.1.11 plus two unsupported tags, and a tag v2.1.12 -> $COMMIT.
setup() {
  FIX="$TMP_ROOT/case$((PASSED + FAILED))"
  mkdir -p "$FIX/releases" "$FIX/tags" "$FIX/storage"
  : >"$FIX/calls.log"
  : >"$FIX/release-list"
  local i
  for i in $(seq 0 12); do add_upstream_version "2.1.$i"; done
  for i in $(seq 0 11); do
    echo "v2.1.$i" >>"$FIX/release-list"
    mkdir -p "$FIX/releases/v2.1.$i"
  done
  echo "vbad" >>"$FIX/release-list"
  echo "v2.1.99-beta" >>"$FIX/release-list"
  printf '2.1.12\n' >"$FIX/storage/stable"
  echo "$COMMIT" >"$FIX/tags/v2.1.12"
  OUT="$FIX/out"
  export FIX STORAGE_BASE REPO
  export MOCK_NPM_VERSION="2.1.12"
  unset MOCK_CORRUPT_PATCH VERSION_INPUT PREPARE_SOURCE_COMMIT
  export GITHUB_OUTPUT="$FIX/github-output"
  : >"$GITHUB_OUTPUT"
}

run_release() {
  PATH="$TMP_ROOT/bin:$PATH" "$RELEASE_SH" "$@" >"$FIX/stdout" 2>&1
}

# ---------------------------------------------------------------- helpers

fail() {
  echo "    $*" >&2
  return 1
}

expect_success() {
  run_release "$@" || { cat "$FIX/stdout" >&2; fail "expected success: release.sh $*"; }
}

expect_failure() {
  local pattern="$1"
  shift
  if run_release "$@"; then
    cat "$FIX/stdout" >&2
    fail "expected failure: release.sh $*"
  fi
  grep -q -- "$pattern" "$FIX/stdout" || { cat "$FIX/stdout" >&2; fail "missing '$pattern' in output"; }
}

assert_eq() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

assert_no_create() {
  [ ! -e "$FIX/create-args" ] || fail "gh release create was called"
  ! grep -Eq '^gh release (create|edit|delete|upload)' "$FIX/calls.log" || fail "release mutation attempted"
}

assert_output() {
  grep -qx "$1" "$GITHUB_OUTPUT" || fail "GITHUB_OUTPUT missing '$1'"
}

manifest() {
  jq -r "$1" "$OUT/release-manifest.json"
}

build_ok() {
  expect_success build --tag v2.1.12 --commit "$COMMIT" --out "$OUT"
}

run_test() {
  local name="$1"
  setup
  if (set -e; "$name"); then
    PASSED=$((PASSED + 1))
    echo "ok   $name"
  else
    FAILED=$((FAILED + 1))
    echo "FAIL $name"
  fi
}

# ---------------------------------------------------------------- prepare

test_prepare_stable_builds_last_ten_without_publishing() {
  expect_success prepare --out "$OUT"
  assert_eq "$(manifest .mode)" prepare
  assert_eq "$(manifest .version)" 2.1.12
  assert_eq "$(manifest '.patches | length')" 10
  assert_eq "$(manifest '[.patches[].from] | join(" ")')" "2.1.11 2.1.10 2.1.9 2.1.8 2.1.7 2.1.6 2.1.5 2.1.4 2.1.3 2.1.2"
  assert_eq "$(find "$OUT" -name '*.bsdiff' | wc -l | tr -d ' ')" 10
  assert_eq "$(manifest .latest_sha256)" "$(jq -r '.platforms["darwin-arm64"].checksum' "$FIX/storage/2.1.12/manifest.json")"
  grep -q "ignoring release with unsupported tag 'vbad'" "$FIX/stdout"
  grep -q "ignoring release with unsupported tag 'v2.1.99-beta'" "$FIX/stdout"
  assert_output tag=v2.1.12
  assert_output release_exists=false
  assert_no_create
}

test_default_mode_is_prepare() {
  expect_success --out "$OUT"
  assert_eq "$(manifest .mode)" prepare
  assert_no_create
}

test_prepare_npm_version() {
  export VERSION_INPUT=npm MOCK_NPM_VERSION=2.1.11
  rm -rf "$FIX/releases/v2.1.11"
  expect_success prepare --out "$OUT"
  assert_eq "$(manifest .version)" 2.1.11
  grep -q '^npm show @anthropic-ai/claude-code version$' "$FIX/calls.log"
  # The target version itself is never a patch source.
  assert_eq "$(manifest '[.patches[].from] | index("2.1.11")')" null
  assert_no_create
}

test_prepare_explicit_version() {
  export VERSION_INPUT=2.1.12
  expect_success prepare --out "$OUT"
  assert_eq "$(manifest .version)" 2.1.12
  ! grep -q "/stable$" "$FIX/calls.log" || fail "explicit version should not query stable"
}

test_prepare_rejects_malformed_versions() {
  local v
  # shellcheck disable=SC2016 # literal shell metacharacters are the point
  for v in '2.1' 'v2.1.12' '2.1.12-beta' '../2.1.12' '2.1.12; touch pwned' '$(id)' '02.1.12' ' '; do
    export VERSION_INPUT="$v"
    : >"$FIX/calls.log"
    expect_failure "unsupported version" prepare --out "$OUT"
    ! grep -q '^curl' "$FIX/calls.log" || fail "downloaded for malformed version '$v'"
  done
  [ ! -e "$ROOT/pwned" ] || fail "version input was executed"
}

test_prepare_rejects_malformed_upstream_versions() {
  printf '2.1.12/../../evil\n' >"$FIX/storage/stable"
  expect_failure "unsupported version" prepare --out "$OUT"
  export VERSION_INPUT=npm MOCK_NPM_VERSION="1.0.0-rc.1"
  expect_failure "unsupported version" prepare --out "$OUT"
}

test_prepare_upstream_stable_failure() {
  rm "$FIX/storage/stable"
  expect_failure "" prepare --out "$OUT"
  [ ! -e "$OUT/release-manifest.json" ] || fail "manifest written"
}

test_prepare_checksum_mismatch() {
  printf 'tampered\n' >"$FIX/storage/2.1.12/darwin-arm64/claude"
  expect_failure "checksum mismatch for latest version" prepare --out "$OUT"
}

test_prepare_invalid_upstream_checksum() {
  echo '{"platforms":{}}' >"$FIX/storage/2.1.12/manifest.json"
  expect_failure "unsupported sha256" prepare --out "$OUT"
}

test_prepare_existing_release_is_noop() {
  mkdir -p "$FIX/releases/v2.1.12"
  expect_success prepare --out "$OUT"
  grep -q "Release v2.1.12 already exists" "$FIX/stdout"
  assert_output release_exists=true
  [ ! -e "$OUT" ] || fail "output produced for existing release"
  ! grep -q '^curl.*/claude$' "$FIX/calls.log" || fail "downloaded binaries for existing release"
}

test_prepare_zero_prior_versions() {
  : >"$FIX/release-list"
  expect_success prepare --out "$OUT"
  assert_eq "$(manifest '.patches | length')" 0
  grep -q "No previous versions found" "$FIX/stdout"
}

test_prepare_skips_missing_prior_version() {
  rm "$FIX/storage/2.1.5/darwin-arm64/claude"
  expect_success prepare --out "$OUT"
  assert_eq "$(manifest '.patches | length')" 9
  grep -q "Failed to download 2.1.5, skipping" "$FIX/stdout"
}

test_prepare_patch_corruption_fails() {
  export MOCK_CORRUPT_PATCH=1
  expect_failure "patch verification failed for 2.1.11" prepare --out "$OUT"
}

test_prepare_rejects_publish_arguments() {
  expect_failure "Modes:" prepare --tag v2.1.12 --out "$OUT"
}

# ---------------------------------------------------------------- build

test_build_binds_tag_and_commit() {
  build_ok
  assert_eq "$(manifest .mode)" build
  assert_eq "$(manifest .commit)" "$COMMIT"
  assert_eq "$(manifest .tag)" v2.1.12
  assert_eq "$(manifest .repo)" "$REPO"
  assert_eq "$(manifest '.patches | length')" 10
  ! grep -Eq '^npm|/stable$' "$FIX/calls.log" || fail "build performed version discovery"
  assert_no_create
}

test_build_ignores_version_input() {
  export VERSION_INPUT=2.1.11
  build_ok
  assert_eq "$(manifest .version)" 2.1.12
}

test_build_missing_tag_fails() {
  rm "$FIX/tags/v2.1.12"
  expect_failure "tag v2.1.12 does not exist" build --tag v2.1.12 --commit "$COMMIT" --out "$OUT"
}

test_build_tag_commit_mismatch_fails() {
  echo "$OTHER_COMMIT" >"$FIX/tags/v2.1.12"
  expect_failure "expected approved commit" build --tag v2.1.12 --commit "$COMMIT" --out "$OUT"
}

test_build_rejects_malformed_inputs() {
  expect_failure "unsupported tag" build --tag 2.1.12 --commit "$COMMIT" --out "$OUT"
  expect_failure "unsupported version" build --tag 'v2.1.12;id' --commit "$COMMIT" --out "$OUT"
  expect_failure "unsupported commit" build --tag v2.1.12 --commit main --out "$OUT"
  expect_failure "Modes:" build --tag v2.1.12 --out "$OUT"
}

test_build_existing_release_is_noop() {
  mkdir -p "$FIX/releases/v2.1.12"
  expect_success build --tag v2.1.12 --commit "$COMMIT" --out "$OUT"
  assert_output release_exists=true
  [ ! -e "$OUT" ] || fail "output produced for existing release"
}

# ---------------------------------------------------------------- publish

test_publish_exact_gh_arguments() {
  build_ok
  : >"$FIX/calls.log"
  expect_success publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  local expected
  expected=$(
    printf '%s\n' release create v2.1.12 --repo "$REPO" --verify-tag \
      --title 'Anthropic just released v2.1.12!' --notes 'Version: 2.1.12' \
      'Changelog: https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md' --latest
    for v in 11 10 9 8 7 6 5 4 3 2; do echo "$OUT/darwin-arm64-from-2.1.$v.bsdiff"; done
  )
  assert_eq "$(cat "$FIX/create-args")" "$expected"
  # Publication re-verified every patch round trip.
  assert_eq "$(grep -c '^bspatch$' "$FIX/calls.log")" 10
  ! grep -q '^bsdiff$' "$FIX/calls.log" || fail "publisher regenerated patches"
  ! grep -Eq '^npm|/stable$' "$FIX/calls.log" || fail "publisher performed version discovery"
  grep -q "Successfully created release v2.1.12 with 10 patch(es)" "$FIX/stdout"
}

test_publish_zero_patches() {
  : >"$FIX/release-list"
  build_ok
  expect_success publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  assert_eq "$(tail -n1 "$FIX/create-args")" --latest
}

test_publish_existing_release_is_untouched() {
  build_ok
  mkdir -p "$FIX/releases/v2.1.12"
  expect_success publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  grep -q "refusing to modify it" "$FIX/stdout"
  assert_no_create
}

test_publish_missing_tag_fails_closed() {
  build_ok
  rm "$FIX/tags/v2.1.12"
  expect_failure "does not exist" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  assert_no_create
}

test_publish_tag_moved_fails_closed() {
  build_ok
  echo "$OTHER_COMMIT" >"$FIX/tags/v2.1.12"
  expect_failure "expected approved commit" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  assert_no_create
}

test_publish_tag_version_mismatch_fails_closed() {
  build_ok
  echo "$COMMIT" >"$FIX/tags/v2.1.11"
  rm -rf "$FIX/releases/v2.1.11"
  expect_failure "manifest tag does not match" publish --tag v2.1.11 --commit "$COMMIT" --dir "$OUT"
  assert_no_create
}

test_publish_rejects_malformed_inputs() {
  build_ok
  expect_failure "unsupported tag" publish --tag latest --commit "$COMMIT" --dir "$OUT"
  expect_failure "unsupported version" publish --tag v2.1 --commit "$COMMIT" --dir "$OUT"
  expect_failure "unsupported commit" publish --tag v2.1.12 --commit "${COMMIT:0:7}" --dir "$OUT"
  expect_failure "Modes:" publish --tag v2.1.12 --commit "$COMMIT"
  assert_no_create
}

test_publish_rejects_prepare_output() {
  export PREPARE_SOURCE_COMMIT="$COMMIT"
  expect_success prepare --out "$OUT"
  expect_failure "manifest mode does not match" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  assert_no_create
}

test_publish_missing_manifest() {
  mkdir -p "$OUT"
  expect_failure "missing" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  assert_no_create
}

tamper_manifest() {
  jq "$1" "$OUT/release-manifest.json" >"$FIX/m.json"
  mv "$FIX/m.json" "$OUT/release-manifest.json"
}

test_publish_rejects_manifest_commit_mismatch() {
  build_ok
  tamper_manifest ".commit = \"$OTHER_COMMIT\""
  expect_failure "manifest commit does not match" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  assert_no_create
}

test_publish_rejects_latest_checksum_mismatch() {
  build_ok
  tamper_manifest ".latest_sha256 = \"$(printf '0%.0s' $(seq 64))\""
  expect_failure "does not match upstream checksum" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  assert_no_create
}

test_publish_rejects_digest_mismatch() {
  build_ok
  printf 'x' >>"$OUT/darwin-arm64-from-2.1.7.bsdiff"
  expect_failure "digest mismatch for darwin-arm64-from-2.1.7.bsdiff" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  assert_no_create
}

test_publish_rejects_corrupt_patch_with_matching_digest() {
  build_ok
  local f="$OUT/darwin-arm64-from-2.1.7.bsdiff"
  printf 'x' >>"$f"
  tamper_manifest "(.patches[] | select(.from == \"2.1.7\") | .sha256) = \"$(shasum -a 256 "$f" | cut -c1-64)\""
  expect_failure "patch verification failed for 2.1.7" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  assert_no_create
}

test_publish_rejects_unlisted_files() {
  build_ok
  printf '#!/bin/sh\ntouch pwned\n' >"$OUT/evil.sh"
  expect_failure "unexpected file in" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  assert_no_create
}

test_publish_rejects_bad_patch_entries() {
  build_ok
  cp "$OUT/release-manifest.json" "$FIX/orig.json"
  tamper_manifest '.patches[0].file = "../../etc/passwd"'
  expect_failure "unexpected patch file name" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  cp "$FIX/orig.json" "$OUT/release-manifest.json"
  tamper_manifest '.patches[0].from = "2.1.12;id"'
  expect_failure "unsupported version" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  cp "$FIX/orig.json" "$OUT/release-manifest.json"
  tamper_manifest '.patches += [.patches[0]]'
  expect_failure "duplicate patch entry" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  cp "$FIX/orig.json" "$OUT/release-manifest.json"
  tamper_manifest '.patches = {}'
  expect_failure "patches must be an array" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  cp "$FIX/orig.json" "$OUT/release-manifest.json"
  tamper_manifest '.patches[0].from = 7'
  expect_failure "" publish --tag v2.1.12 --commit "$COMMIT" --dir "$OUT"
  assert_no_create
}

# ---------------------------------------------------------------- main

write_mocks "$TMP_ROOT/bin"

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  run_test "$t"
done

echo ""
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
