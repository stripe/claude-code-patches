# claude-code-patches

Provides patches between the last ten **stable** Claude Code versions in `.bsdiff` format. Apply using `.bspatch`.

Each release `vX.Y.Z` contains `darwin-arm64-from-<old>.bsdiff` for up to ten of the most recent previously released versions. Every patch is verified to reproduce the upstream `darwin-arm64` binary whose SHA-256 matches the upstream manifest for `X.Y.Z`.

## How releases are produced

Publication is split into an untrusted preparation step and a trusted, approved publication step. Nothing that runs from a branch can create, edit or delete a release.

1. **Preparation** ([`auto-release.yaml`](.github/workflows/auto-release.yaml), every 6 hours or manual). Runs `./release.sh prepare` with a read-only token. It discovers the target version (upstream `stable` by default, or the `version` input: `X.Y.Z` or `npm`), downloads and checksum-verifies the binary, builds and round-trip verifies patches, and uploads them as a review artifact. When a new version exists the run ends with a *Release pending* notice. **It does not publish.** Scheduled runs previously published automatically; they now only signal that a new version is ready.
2. **Tagging** (authorized maintainer). Create the tag `vX.Y.Z` — exactly `v` followed by the upstream version — on a reviewed commit of `main`:

   ```sh
   git fetch origin && git tag vX.Y.Z origin/main && git push origin vX.Y.Z
   ```

   Never create a release tag on another branch or on an unreviewed commit. `release.sh` never creates tags; publication fails if the tag is missing.
3. **Publication** ([`publish-release.yaml`](.github/workflows/publish-release.yaml), triggered by the tag push).
   - `build` (read-only): checks the tagged commit is reachable from `main`, then runs `./release.sh build --tag vX.Y.Z --commit <sha>` from that commit. This verifies that the tag still resolves to the triggering commit and rebuilds and verifies the patches. It does no version discovery: the version comes only from the tag.
   - `publish` (`release` environment, `contents: write`): waits for approval, then runs `./release.sh publish` from the same commit. It re-checks the tag→commit binding, the manifest's repo/tag/version/commit, the upstream checksum, each patch's SHA-256, and each patch round trip. It also rejects any unlisted file. It then runs `gh release create vX.Y.Z --repo stripe/claude-code-patches --verify-tag --latest`. If the release already exists it is left untouched.

### Approver responsibilities

Before you approve a `release` deployment, check that:

- the tag name equals `v` + the upstream version being released, and the run's commit is the reviewed `main` commit the tag was created on;
- the tag was created by an authorized maintainer, and the `build` job passed;
- you are not the person who created the tag or triggered the run (self-review is disabled, but check anyway).

### Recovery

- **Tag on the wrong commit, or build failed:** do not approve. Reject the deployment. An authorized maintainer deletes the tag (a ruleset bypass is required), then re-tags the correct `main` commit.
- **Bad release published:** treat it as a security event. Mark the release as not latest or delete it through an administrator, record the run ID, approver, tag SHA and asset digests, and publish again from a corrected tag. `release.sh` never edits existing releases.
- **Release missing after a successful approval:** re-run the failed `publish` job for the same tag. The tag binding and digests are checked again.

## Required repository settings

The workflow files alone are **not** a security boundary. Anyone with write access can push a branch containing different YAML. The following settings are managed by repository administrators under **Settings → Rules / Environments / Actions**. They must be in place and verified before `publish-release.yaml` is merged. (If the `release` environment does not exist when the workflow first runs, GitHub creates it unprotected.)

- **Tag ruleset `release tags`** targeting `refs/tags/v*`: restricts creations, updates and deletions to a narrow list of release maintainers, with every bypass actor reviewed.
- **Branch ruleset on `main`**: requires pull requests with review, including for changes to `.github/workflows/**` and `release.sh`. Force pushes and deletion are blocked.
- **Environment `release`**: required reviewers drawn from an independent approver group, *Prevent self-review* enabled, administrator bypass disabled, and deployment refs limited to the **tag** pattern `v*` (selected tags only, no branches). Store no secrets here or anywhere else in this repository.
- **Actions**: default workflow permissions set to read-only, and Actions cannot create or approve pull requests.
- **Write-credential boundary**: GitHub lets any workflow on a writer-pushed branch request `contents: write` from `GITHUB_TOKEN`. Writers can also create releases directly with their own credentials. Before this is treated as remediated, administrators must confirm (with an adversarial branch test in an isolated repository) that branch workflows cannot mutate releases. If that cannot be shown, publish from a separately access-controlled repository and disable Actions here.

Verification (in an isolated test repository) and an audit of past manual runs are tracked in RUN_DEV_AGENT_LABS-6584 / SAT-32125.

## Development

```sh
./tests/release-policy-test.sh   # static workflow / release.sh policy checks
./tests/release-script-test.sh   # release.sh with mocked curl, npm, gh, bsdiff, bspatch
```

Both run in [`test.yaml`](.github/workflows/test.yaml) on pull requests and on pushes to `main`. To prepare patches locally without publishing, run `GH_HOST=github.com ./release.sh prepare --out ./out`.

## Notes on Anthropic's internal API

- Latest stable version: https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/stable
- Manifest for a particular version: https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.2/manifest.json
- Example download link: https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/2.1.2/darwin-arm64/claude
