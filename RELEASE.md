# Publishing ServiceRadar Releases with Bazel

This guide explains how to publish a ServiceRadar release from Bazel, including pushing container images and Helm charts to Harbor and uploading Debian/RPM packages to the GitHub release for the tagged version. The workflow is fully hermetic: Bazel builds every artifact and the publish steps reuse the generated outputs directly from the runfiles tree.

## GitHub Actions workflow

Tags that follow the `v*` convention automatically trigger `.github/workflows/release.yml`. The job:

- Ensures the tag matches the `VERSION` file and extracts the matching entry from `CHANGELOG` via `scripts/extract-changelog.py` (falling back to a default note when absent).
- Runs `bazel run -c opt --config=ci --stamp //build/release:publish_packages` so that Bazel builds and uploads every Debian/RPM asset to the GitHub release.
- Verifies the resulting release with the GitHub API and fails if no `.deb` or `.rpm` assets are present.
- Normalises the uploaded asset names to include the release version (for example `serviceradar-core_1.0.53-pre14_amd64.deb`).

Use `workflow_dispatch` to re-run or dry-run the pipeline with alternative options (draft releases, appending notes, skipping asset overwrites, etc.).

## Local release helper

The `scripts/cut-release.sh` helper automates routine git tasks before tagging a release:

```
./scripts/cut-release.sh --version 1.0.53-pre14 --push
```

The script validates that `CHANGELOG` already contains a section for the version, updates `VERSION`, and commits the change. It does not create the Git tag. After the release branch is merged to staging, wait for `LargeIngestionGate` success on that merge, then tag `origin/staging` and push the tag. Pass `--dry-run` to preview the actions or `--skip-changelog-check` when drafting notes. Run it from the repository root on a clean working tree.

## Prerequisites

- `bazel`/Bazelisk configured for this repository.
- A GitHub token with release write scope. Export it as `GITHUB_TOKEN` (or `GH_TOKEN`) in the environment that will run the publish step.
- Harbor robot credentials (see `docs/GHCR_PUBLISHING.md`) when pushing containers.

> **Tip:** Use `--stamp` on publish commands so Bazel injects the `STABLE_COMMIT_SHA` from `scripts/workspace_status.sh`.

## Step 1 – Publish verified container images

Use `.github/workflows/release.yml` for an authorized release. For a test build:

```bash
gh workflow run publish-oci.yml --repo carverauto/serviceradar \
  --ref <reviewed-branch> -f publish_scope=full -f expected_commit=<full-commit>
```

The workflow writes build artifacts to `serviceradar-builds`, signs and verifies
them, then promotes the exact graph into `serviceradar`. Require a successful
promotion receipt before deploying; pin deployment images by digest. Raw Bazel
`*_push` targets default to disposable storage and do not constitute publication.
The old Makefile and workstation publishing entrypoints fail closed.

## Step 2 – Publish Debian and RPM artifacts

```
bazel run --stamp //build/release:publish_packages -- \
  --tag v$(cat VERSION) \
  --notes_file release-notes/v$(cat VERSION).md
```

The `publish_packages` binary performs the following:

1. Builds the `pkg_deb` / `pkg_rpm` targets listed in `RELEASE_PACKAGES`
   (`build/packaging/packages.bzl`), exposed via
   `//build/release:package_artifacts`. That set is intentionally limited to
   edge installers (agent, NATS, CLI, collectors, and trapd). Control-plane
   services ship as container images / Helm only; individual packages remain
   buildable under `//build/packaging/<name>:<name>_deb` when needed.
2. Creates or updates the Forgejo release identified by `--tag` (optionally pointing to `--commit` or the stamped commit SHA).
3. Uploads each generated `.deb` and `.rpm` file, replacing existing assets when `--overwrite_assets` (default `true`).
4. After finalization, the release workflow runs
   `scripts/prune-forgejo-releases.sh` to keep only the newest 10 fat releases
   (large deb/rpm attachment sets). Git tags are retained.

### Useful flags

| Flag | Description |
|------|-------------|
| `--repo` | Repository, defaults to `carverauto/serviceradar`. |
| `--forgejo-url` | Forgejo base URL, defaults to `https://code.carverauto.dev` or `$FORGEJO_URL`. |
| `--name` | Release display name; defaults to the value of `--tag`. |
| `--commit` | Override the commit SHA for the release. Falls back to `GITHUB_SHA`, `COMMIT_SHA`, or `STABLE_COMMIT_SHA`. |
| `--notes` / `--notes_file` | Supply release notes inline or from a file (relative paths are resolved via Bazel runfiles). |
| `--append_notes` | Append notes when updating an existing release instead of replacing them. |
| `--overwrite_assets=false` | Skip uploading artifacts that already exist on the release. |
| `--dry_run` | Print the actions without calling the GitHub API (useful for validation). |

### Environment variables

- `FORGEJO_TOKEN` / `GITEA_TOKEN` / `GITHUB_TOKEN` / `GH_TOKEN` – Required unless `--dry_run` is set.
- `COMMIT_SHA`, `STABLE_COMMIT_SHA`, or `GITHUB_SHA` – Optional; used automatically when `--commit` is omitted.

## Step 3 – Verify the release

After the commands complete:

- Confirm container images in Harbor (`registry.carverauto.dev/serviceradar/serviceradar-*`).
- Verify at least one published image signature for `v$(cat VERSION)` with the
  commands in [Verifying published images](docs/sigstore/README.md#verifying-published-images).
- Run `make verify_publish VERIFY_TAG="v$(cat VERSION)" SIGNING_LEDGER=<signing-ledger artifact>` (the ledger is described in [RELEASE_PUBLISHING.md](docs/RELEASE_PUBLISHING.md#transparency-log-receipts-and-the-signing-ledger)) to confirm published image shape and runtime metadata for `latest`, `sha-<commit>`, and the release tag.
- Verify that the Forgejo release contains the expected `.deb` and `.rpm` assets.
- Optionally attach checksums or additional assets by re-running `publish_packages` with extra files staged in `build/release/package_manifest.txt`.

## Troubleshooting

- Use `--dry_run` to inspect which assets would be uploaded without touching Forgejo.
- The manifest `//build/release:package_manifest` lists every package path consumed by the publisher; inspect it with `bazel build //build/release:package_manifest && cat bazel-bin/build/release/package_manifest.txt` if you need to confirm coverage.
- If Bazel fails while building packages, rebuild the specific target (e.g., `bazel build //build/packaging/core:core_deb`) to diagnose before rerunning the publish command.

### Keep `VERSION` in sync with your tag

All `pkg_deb` and `pkg_rpm` targets derive their version from the repository `VERSION` file. The release pipeline now checks that the tag (with an optional leading `v` stripped) matches the contents of `VERSION` and aborts when they differ. Update the file before tagging (for example, `echo "1.0.53-pre11" > VERSION`) so every package filename and control file reflects the release number. Set `ALLOW_VERSION_MISMATCH=1` only when intentionally overriding this safety net.

For RPM builds the macro automatically splits pre-release strings (e.g. `1.0.53-pre11`) into `Version: 1.0.53` and `Release: pre11`, which means the generated file remains `serviceradar-<component>-1.0.53-pre11.x86_64.rpm` while still satisfying rpmbuild’s character restrictions.

## Retired aggregate release launcher

`//build/buildbuddy:release_pipeline` and `scripts/push_all_images.sh` now refuse
publication before invoking tools. Use the GitHub workflow above. Package-only
Bazel targets remain available, but they do not publish or promote container
images. Never restore protected writes to the retired aggregate launcher.
