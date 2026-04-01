# Publishing ServiceRadar Releases with Bazel

This guide explains how to publish a ServiceRadar release from Bazel, including pushing container images and Helm charts to Harbor and uploading Debian/RPM packages to the Forgejo release for the tagged version. The workflow is fully hermetic: Bazel builds every artifact and the publish steps reuse the generated outputs directly from the runfiles tree.

## Forgejo Actions workflow

Tags that follow the `v*` convention automatically trigger `.forgejo/workflows/release.yml`. The job:

- Ensures the tag matches the `VERSION` file and extracts the matching entry from `CHANGELOG` via `scripts/extract-changelog.py` (falling back to a default note when absent).
- Runs `bazel run --config=remote --stamp //build/release:publish_packages` so that Bazel builds and uploads every Debian/RPM asset to the Forgejo release.
- Verifies the resulting release with the Forgejo API and fails if no `.deb` or `.rpm` assets are present.
- Normalises the uploaded asset names to include the release version (for example `serviceradar-core_1.0.53-pre14_amd64.deb`).

Use `workflow_dispatch` to re-run or dry-run the pipeline with alternative options (draft releases, appending notes, skipping asset overwrites, etc.).

## Local release helper

The `scripts/cut-release.sh` helper automates routine git tasks before tagging a release:

```
./scripts/cut-release.sh --version 1.0.53-pre14 --push
```

The script validates that `CHANGELOG` already contains a section for the version, updates `VERSION`, commits the change, and creates an annotated tag (`v1.0.53-pre14` by default). Pass `--dry-run` to preview the actions or `--skip-changelog-check` when drafting notes. Run it from the repository root on a clean working tree.

## Prerequisites

- `bazel`/Bazelisk configured for this repository.
- A Forgejo personal access token with release write scope. Export it as `FORGEJO_TOKEN` (or `GITEA_TOKEN`) in the environment that will run the publish step.
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

1. Builds every `pkg_deb` and `pkg_rpm` target declared via `build/packaging/packages.bzl` (transitively pulled in through `//build/release:package_artifacts`).
2. Creates or updates the Forgejo release identified by `--tag` (optionally pointing to `--commit` or the stamped commit SHA).
3. Uploads each generated `.deb` and `.rpm` file, replacing existing assets when `--overwrite_assets` (default `true`).

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

## Automating with BuildBuddy Workflows

The repository includes a BuildBuddy workflow (`.buildbuddy/workflows.yaml`) that wires the publish steps into a fully automated pipeline:

- `run --config=remote //build/buildbuddy:release_pipeline`

`//build/buildbuddy:release_pipeline` bootstraps Docker auth with `./buildbuddy_setup_docker_auth.sh`, determines the release tag (from the workflow input, Git tag, or the `VERSION` file), pushes all container images, and then invokes `//build/release:publish_packages`. Useful environment variables:

- `RELEASE_TAG` / workflow `tag` input – forces the tag passed to both publish steps.
- `RELEASE_NOTES_FILE` / workflow `notes_file` input – points at a file that `publish_packages` should attach as the release body.
- `PUSH_DRY_RUN` & `RELEASE_DRY_RUN` / workflow `dry_run` input – add `--dry-run` to `oci_push` and `publish_packages` for validation runs (default `1`).
- `PUSH_EXTRA_ARGS` – extra flags forwarded to `oci_push` (for example, `--allow-nondistributable-artifacts`).
- `APPEND_NOTES`, `DRAFT_RELEASE`, `PRERELEASE`, `OVERWRITE_ASSETS` – mirror the corresponding flags of `publish_packages`.

Ensure the following BuildBuddy secrets are defined before enabling the workflow:

- `HARBOR_ROBOT_USERNAME`
- `HARBOR_ROBOT_SECRET`
- `FORGEJO_TOKEN`
- `BUILDBUDDY_API_KEY` (or `BUILDBUDDY_ORG_API_KEY`) – required so Bazel’s `--config=remote` can authenticate to BuildBuddy inside the workflow.

Once the secrets are present, enable the “Release” workflow in BuildBuddy. A push to a `v*` tag (or a manual workflow dispatch) will authenticate to Harbor, push all images, and publish the Debian/RPM assets to the matching release target configured by the workflow.
