# Publishing ServiceRadar Releases with Bazel

This guide explains how to publish a ServiceRadar release from Bazel, including pushing container images to GHCR and uploading Debian/RPM packages to a GitHub release. The workflow is fully hermetic: Bazel builds every artifact and the publish steps reuse the generated outputs directly from the runfiles tree.

## Prerequisites

- `bazel`/Bazelisk configured for this repository.
- A GitHub personal access token with the `repo` scope. Export it as either `GITHUB_TOKEN` or `GH_TOKEN` in the environment that will run the publish step.
- Docker credentials for GHCR (see `docs/GHCR_PUBLISHING.md`) when pushing containers.

> **Tip:** Use `--stamp` on publish commands so Bazel injects the `STABLE_COMMIT_SHA` from `scripts/workspace_status.sh`.

## Step 1 – Push container images

```
bazel run --stamp //docker/images:push_all -- --tag v$(cat VERSION)
```

Refer to `docs/GHCR_PUBLISHING.md` for more details on configuring registry credentials and tagging conventions.

## Step 2 – Publish Debian and RPM artifacts

```
bazel run --stamp //release:publish_packages -- \
  --tag v$(cat VERSION) \
  --notes_file release-notes/v$(cat VERSION).md
```

The `publish_packages` binary performs the following:

1. Builds every `pkg_deb` and `pkg_rpm` target declared via `packaging/packages.bzl` (transitively pulled in through `//release:package_artifacts`).
2. Creates or updates the GitHub release identified by `--tag` (optionally pointing to `--commit` or the stamped commit SHA).
3. Uploads each generated `.deb` and `.rpm` file, replacing existing assets when `--overwrite_assets` (default `true`).

### Useful flags

| Flag | Description |
|------|-------------|
| `--repo` | GitHub repository, defaults to `carverauto/serviceradar`. |
| `--name` | Release display name; defaults to the value of `--tag`. |
| `--commit` | Override the commit SHA for the release. Falls back to `GITHUB_SHA`, `COMMIT_SHA`, or `STABLE_COMMIT_SHA`. |
| `--notes` / `--notes_file` | Supply release notes inline or from a file (relative paths are resolved via Bazel runfiles). |
| `--append_notes` | Append notes when updating an existing release instead of replacing them. |
| `--overwrite_assets=false` | Skip uploading artifacts that already exist on the release. |
| `--dry_run` | Print the actions without calling the GitHub API (useful for validation). |

### Environment variables

- `GITHUB_TOKEN` / `GH_TOKEN` – Required unless `--dry_run` is set.
- `COMMIT_SHA`, `STABLE_COMMIT_SHA`, or `GITHUB_SHA` – Optional; used automatically when `--commit` is omitted.

## Step 3 – Verify the release

After the commands complete:

- Confirm container images in GHCR (`ghcr.io/carverauto/serviceradar-*`).
- Verify that the GitHub release contains the expected `.deb` and `.rpm` assets.
- Optionally attach checksums or additional assets by re-running `publish_packages` with extra files staged in `release/package_manifest.txt`.

## Troubleshooting

- Use `--dry_run` to inspect which assets would be uploaded without touching GitHub.
- The manifest `//release:package_manifest` lists every package path consumed by the publisher; inspect it with `bazel build //release:package_manifest && cat bazel-bin/release/package_manifest.txt` if you need to confirm coverage.
- If Bazel fails while building packages, rebuild the specific target (e.g., `bazel build //packaging/core:core_deb`) to diagnose before rerunning the publish command.

### Keep `VERSION` in sync with your tag

All `pkg_deb` and `pkg_rpm` targets derive their version from the repository `VERSION` file. The release pipeline now checks that the tag (with an optional leading `v` stripped) matches the contents of `VERSION` and aborts when they differ. Update the file before tagging (for example, `echo "1.0.53-pre11" > VERSION`) so every package filename and control file reflects the release number. Set `ALLOW_VERSION_MISMATCH=1` only when intentionally overriding this safety net.

For RPM builds the macro automatically splits pre-release strings (e.g. `1.0.53-pre11`) into `Version: 1.0.53` and `Release: pre11`, which means the generated file remains `serviceradar-<component>-1.0.53-pre11.x86_64.rpm` while still satisfying rpmbuild’s character restrictions.

## Automating with BuildBuddy Workflows

The repository includes a BuildBuddy workflow (`.buildbuddy/workflows.yaml`) that wires the publish steps into a fully automated pipeline:

- `run --config=remote //:buildbuddy_setup_docker_auth`
- `run --config=remote //tools/buildbuddy:release_pipeline`

`//tools/buildbuddy:release_pipeline` is a thin shim over the manual commands: it determines the release tag (from the workflow input, Git tag, or the `VERSION` file), pushes all container images, and then invokes `//release:publish_packages`. Useful environment variables:

- `RELEASE_TAG` / workflow `tag` input – forces the tag passed to both publish steps.
- `RELEASE_NOTES_FILE` / workflow `notes_file` input – points at a file that `publish_packages` should attach as the release body.
- `PUSH_DRY_RUN` & `RELEASE_DRY_RUN` / workflow `dry_run` input – add `--dry-run` to `oci_push` and `publish_packages` for validation runs (default `1`).
- `PUSH_EXTRA_ARGS` – extra flags forwarded to `oci_push` (for example, `--allow-nondistributable-artifacts`).
- `APPEND_NOTES`, `DRAFT_RELEASE`, `PRERELEASE`, `OVERWRITE_ASSETS` – mirror the corresponding flags of `publish_packages`.

Ensure the following BuildBuddy secrets are defined before enabling the workflow:

- `GHCR_USERNAME`
- `GHCR_TOKEN`
- `GITHUB_TOKEN`
- `BUILDBUDDY_API_KEY` (or `BUILDBUDDY_ORG_API_KEY`) – required so Bazel’s `--config=remote` can authenticate to BuildBuddy inside the workflow.

Once the secrets are present, enable the “Release” workflow in BuildBuddy. A push to a `v*` tag (or a manual workflow dispatch) will authenticate to GHCR, push all images, and publish the Debian/RPM assets to the matching GitHub release.
