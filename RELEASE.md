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

## Step 1 – Push container images

```
bazel run --stamp //docker/images:push_all -- --tag v$(cat VERSION)
```

Refer to `docs/GHCR_PUBLISHING.md` for more details on configuring Harbor credentials and tagging conventions.

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
   edge installers (agent, NATS, CLI, collectors, trapd, rperf server, and
   rperf-checker client). Control-plane services ship as container images /
   Helm only; individual packages remain buildable under
   `//build/packaging/<name>:<name>_deb` when needed.
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
- Verify at least one published image signature with the public key in [docs/cosign.pub](/Users/mfreeman/src/serviceradar/docs/cosign.pub):

  ```bash
  cosign verify \
    --experimental-oci11 \
    --key docs/cosign.pub \
    registry.carverauto.dev/serviceradar/serviceradar-core-elx:v$(cat VERSION)
  ```

- For self-hosted keyless signing, verify with the published trusted root in [docs/sigstore/README.md](/home/mfreeman/src/serviceradar/docs/sigstore/README.md):

  ```bash
  cosign verify \
    --experimental-oci11 \
    --trusted-root docs/sigstore/trusted-root.json \
    --certificate-identity-regexp '<issuer-specific SAN regex>' \
    --certificate-oidc-issuer https://issuer.example.com \
    registry.carverauto.dev/serviceradar/serviceradar-core-elx:v$(cat VERSION)
  ```

- Run `make verify_publish VERIFY_TAG="v$(cat VERSION)"` to confirm published image shape and runtime metadata for `latest`, `sha-<commit>`, and the release tag.
- Verify that the Forgejo release contains the expected `.deb` and `.rpm` assets.
- Optionally attach checksums or additional assets by re-running `publish_packages` with extra files staged in `build/release/package_manifest.txt`.

## Troubleshooting

- Use `--dry_run` to inspect which assets would be uploaded without touching Forgejo.
- The manifest `//build/release:package_manifest` lists every package path consumed by the publisher; inspect it with `bazel build //build/release:package_manifest && cat bazel-bin/build/release/package_manifest.txt` if you need to confirm coverage.
- If Bazel fails while building packages, rebuild the specific target (e.g., `bazel build //build/packaging/core:core_deb`) to diagnose before rerunning the publish command.

### Keep `VERSION` in sync with your tag

All `pkg_deb` and `pkg_rpm` targets derive their version from the repository `VERSION` file. The release pipeline now checks that the tag (with an optional leading `v` stripped) matches the contents of `VERSION` and aborts when they differ. Update the file before tagging (for example, `echo "1.0.53-pre11" > VERSION`) so every package filename and control file reflects the release number. Set `ALLOW_VERSION_MISMATCH=1` only when intentionally overriding this safety net.

For RPM builds the macro automatically splits pre-release strings (e.g. `1.0.53-pre11`) into `Version: 1.0.53` and `Release: pre11`, which means the generated file remains `serviceradar-<component>-1.0.53-pre11.x86_64.rpm` while still satisfying rpmbuild’s character restrictions.

## Running the Bazel release pipeline

The repository exposes the release sequence as a manual Linux/BuildBuddy-runner Bazel entry point.
No checked-in BuildBuddy workflow currently dispatches it automatically:

```bash
bazel run -c opt --config=ci //build/buildbuddy:release_pipeline
```

Do not run that aggregate Linux launcher directly on macOS. Use `scripts/push_all_images.sh` for
the Darwin-safe image publish path, and run the package publisher separately from a supported
Linux/BuildBuddy runner when cutting a full release.

`//build/buildbuddy:release_pipeline` bootstraps Docker auth with `./buildbuddy_setup_docker_auth.sh`, determines the release tag (from `RELEASE_TAG`, the legacy `WORKFLOW_INPUT_tag`, a Git tag, or the `VERSION` file), pushes all container images, and then invokes `//build/release:publish_packages`. Useful environment variables:

- `RELEASE_TAG` (or legacy `WORKFLOW_INPUT_tag`) – forces the tag passed to both publish steps.
- `RELEASE_NOTES_FILE` – points at a file that `publish_packages` should attach as the release body.
- `PUSH_DRY_RUN` and `RELEASE_DRY_RUN` – add `--dry-run` to `oci_push` and `publish_packages` for validation runs (default `0`).
- `PUSH_EXTRA_ARGS` – extra flags forwarded to `oci_push` (for example, `--allow-nondistributable-artifacts`).
- `APPEND_NOTES`, `DRAFT_RELEASE`, `PRERELEASE`, `OVERWRITE_ASSETS` – mirror the corresponding flags of `publish_packages`.

Ensure the following variables and BuildBuddy secrets are present in the Linux/BuildBuddy runner
environment before invoking the manual target:

- `OCI_USERNAME` and `OCI_TOKEN` (or another input mode accepted by
  `buildbuddy_setup_docker_auth.sh`)
- `FORGEJO_TOKEN`
- `BUILDBUDDY_API_KEY` (or `BUILDBUDDY_ORG_API_KEY`) – required so Bazel's `--config=ci` can authenticate to BuildBuddy inside the workflow.
- `PLUGIN_UPLOAD_SIGNING_KEY_ID` plus either an OpenBao Transit session
  (`VAULT_ADDR`/`VAULT_TOKEN` and `PLUGIN_UPLOAD_SIGNING_TRANSIT_KEY=plugin-upload-signing`)
  or the legacy `PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY` – required for a live Wasm
  plugin publish; they are not required when `PUSH_DRY_RUN=1`. Prefer Transit.

With those variables present, the command authenticates to Harbor, pushes the images, and
publishes the Debian/RPM assets to the matching release target.
