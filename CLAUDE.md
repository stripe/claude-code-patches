This is a project that is solely GitHub workflows, a shell script, and GitHub releases.

The goal is to:

- download the latest stable version of Claude Code, and the previous 10 released stable versions.
- run bsdiff from each old version to the latest version
- store the bsdiff in a GitHub release tagged with the latest version number
    - e.g. darwin-arm64-from-$oldVersionNumber.bsdiff is the filename, at v$latest
- before storing the bsdiff, make sure the bspatch applies and produces the correct shasum from the manifest

Security constraints (see README.md "How releases are produced"):

- `release.sh prepare` and `release.sh build` must stay read-only. Only `release.sh publish`, run by the
  `publish` job in `publish-release.yaml` behind the protected `release` environment, may create a release.
- Never create or move tags from scripts or workflows, never edit existing releases, and always pass
  `--repo stripe/claude-code-patches --verify-tag` to `gh release create`.
- Validate every version against the X.Y.Z grammar before using it in a URL or path.
- Run `./tests/release-policy-test.sh` and `./tests/release-script-test.sh` after changes.
