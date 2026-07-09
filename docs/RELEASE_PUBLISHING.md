# Publishing ServiceRadar Releases with Bazel

This guide explains how to publish a ServiceRadar release from Bazel, including pushing container images to GHCR, uploading Debian/RPM packages to a GitHub release, and attaching the agent self-update manifest assets consumed by the release-management UI. The workflow is fully hermetic: Bazel builds every packaged artifact and the publish step reuses the generated outputs directly from the runfiles tree.

## GitHub Actions workflow

Tags that follow the `v*` convention automatically trigger `.github/workflows/release.yml`. The job:

- Ensures the tag matches the `VERSION` file and extracts the matching entry from `CHANGELOG` via `scripts/extract-changelog.py` (falling back to a default note when absent).
- Runs `bazel run --config=remote --stamp //build/release:publish_packages` so that Bazel builds and uploads every Debian/RPM asset, the managed agent runtime archive, and the signed manifest assets to the GitHub release.
- Verifies the resulting release with the GitHub API and fails if the package assets or the agent manifest/signature assets are missing.
- Normalises the uploaded asset names to include the release version (for example `serviceradar-core_1.0.53-pre14_amd64.deb`).

Use `workflow_dispatch` to re-run or dry-run the pipeline with alternative options (draft releases, appending notes, skipping asset overwrites, etc.).

## Local release helper

The `scripts/cut-release.sh` helper automates the local release commit and tag, while keeping tag publication ordered behind the staging merge:

```
./scripts/cut-release.sh --version 1.0.53-pre14 --push
```

The script validates that `CHANGELOG` already contains a section for the version and that the release tag does not already exist locally or on `origin`, then updates `VERSION` and the Helm release metadata, commits the change, and creates an annotated tag (`v1.0.53-pre14` by default). Pass `--dry-run` to preview the actions or `--skip-changelog-check` when drafting notes. Run it from the repository root on a clean, non-`staging` release branch.

`--push` publishes only the current branch, using an explicit `refs/heads` refspec. It intentionally leaves the tag local because the release workflow rejects a tag whose commit is not yet reachable from `origin/staging`. Open and merge the release branch pull request before publishing the tag.

After the pull request is merged, refresh the remote staging ref and verify that the annotated tag resolves to a commit reachable from staging. Only publish the tag when the ancestry command exits successfully:

```bash
git fetch origin refs/heads/staging:refs/remotes/origin/staging
git merge-base --is-ancestor 'v1.0.53-pre14^{commit}' refs/remotes/origin/staging
git push origin refs/tags/v1.0.53-pre14:refs/tags/v1.0.53-pre14
```

With `--no-push` (the default), the helper leaves both refs local and prints the explicit release-branch push, post-merge ancestry check, and tag-push commands. Do not combine the branch and tag into one push, and do not publish the tag before the release commit reaches staging.

## Prerequisites

- `bazel`/Bazelisk configured for this repository.
- A GitHub personal access token with the `repo` scope. Export it as either `GITHUB_TOKEN` or `GH_TOKEN` in the environment that will run the publish step.
- A base64- or hex-encoded Ed25519 private key (32-byte seed or 64-byte private key) exported as `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY`, or stored on disk and referenced with `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY_FILE`, so the release publisher can sign `serviceradar-agent-release-manifest.json`.
- Docker credentials for GHCR (see `docs/GHCR_PUBLISHING.md`) when pushing containers.

> **Tip:** Use `--stamp` on publish commands so Bazel injects the `STABLE_COMMIT_SHA` from `scripts/workspace_status.sh`.

## Step 1 – Push container images

```
bazel run --stamp //:push -- --tag v$(cat VERSION)
```

Refer to `docs/GHCR_PUBLISHING.md` for more details on configuring registry credentials and tagging conventions.

## Step 2 – Publish Debian and RPM artifacts

```
bazel run --stamp //build/release:publish_packages -- \
  --tag v$(cat VERSION) \
  --notes_file release-notes/v$(cat VERSION).md
```

The `publish_packages` binary performs the following:

1. Builds every `pkg_deb` and `pkg_rpm` target declared via `build/packaging/packages.bzl` (transitively pulled in through `//build/release:package_artifacts`).
2. Creates or updates the GitHub release identified by `--tag` (optionally pointing to `--commit` or the stamped commit SHA).
3. Uploads each generated `.deb` and `.rpm` file, replacing existing assets when `--overwrite_assets` (default `true`).
4. Uploads a rollout-ready `serviceradar-agent_<version>_linux_amd64.tar.gz` runtime archive for self-update delivery.
5. Generates and signs `serviceradar-agent-release-manifest.json` plus `serviceradar-agent-release-manifest.sig`, then uploads both assets to the same GitHub release. The managed-agent manifest marks the archive with `capabilities: ["agent"]` and a `checksums.sha256` entry. Optional capability helpers such as the RDP adapter are not baked into alternate agent runtime bundles; they ship through the native add-on publishing/index pipeline.

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
- `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY` / `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY_FILE` – Required unless `--dry_run` is set so the publisher can sign the agent release manifest assets.
- `COMMIT_SHA`, `STABLE_COMMIT_SHA`, or `GITHUB_SHA` – Optional; used automatically when `--commit` is omitted.

### Agent manifest metadata

Each artifact may carry deployment metadata used by EdgeOps and one-click installs:

- `capabilities`: artifact feature labels such as `agent` or `remote_access.rdp`.
- `helper_protocol_version`: helper control protocol version, used by helper-backed artifacts.
- `compatible_agent_versions`: object with `min` / `max` bounds for helper compatibility.
- `checksums`, `signatures`, `sbom`, `license_review`: integrity and review references for the artifact and helper payloads.
- `deployment_requirements`: object describing required helper binaries, services, or host settings. Experimental RDP artifacts with `helper_connector_ready: false` must also include `helper_connector_ready_reason`.

Deployments that do not set `SERVICERADAR_REMOTE_ACCESS_DESKTOP_RDP_ENABLED=true` hide artifacts whose capabilities include `remote_access.rdp` or `remote_access.desktop`.

## Step 3 – Verify the release

After the commands complete:

- Confirm container images in GHCR (`ghcr.io/carverauto/serviceradar-*`).
- Run `make verify_publish VERIFY_TAG="v$(cat VERSION)"` to confirm published image shape and runtime metadata for `latest`, `sha-<commit>`, and the release tag.
- For releases that touch Armis sync, sync result streaming, ResultsRouter, inventory identity reconciliation, sweep ingestion, or mapper promotion, run `scripts/validate-large-ingestion.sh` against an isolated CNPG database before tagging.
- Verify that the GitHub release contains the expected `.deb`, `.rpm`, `serviceradar-agent_<version>_linux_amd64.tar.gz`, `serviceradar-agent-release-manifest.json`, and `serviceradar-agent-release-manifest.sig` assets.
- Optionally attach checksums or additional assets by re-running `publish_packages` with extra files staged in `build/release/package_manifest.txt`.

## Troubleshooting

- Use `--dry_run` to inspect which assets would be uploaded without touching GitHub.
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

- `GHCR_USERNAME`
- `GHCR_TOKEN`
- `GITHUB_TOKEN`
- `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY`
- `BUILDBUDDY_API_KEY` (or `BUILDBUDDY_ORG_API_KEY`) – required so Bazel’s `--config=remote` can authenticate to BuildBuddy inside the workflow.

Once the secrets are present, enable the “Release” workflow in BuildBuddy. A push to a `v*` tag (or a manual workflow dispatch) will authenticate to GHCR, push all images, and publish the Debian/RPM assets to the matching GitHub release.
