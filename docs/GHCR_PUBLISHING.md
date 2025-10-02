# Publishing ServiceRadar Images to GHCR with Bazel

This note describes the Bazel-native workflow for building and pushing the ServiceRadar container images to the GitHub Container Registry (GHCR). It also covers the minimal secret configuration required in BuildBuddy so that CI runs can authenticate against `ghcr.io` without leaking credentials into the repository.

## Overview

- Each image defined in `docker/images/BUILD.bazel` now has a matching `oci_push` target that uploads the image to `ghcr.io/carverauto/<image-name>`.
- A helper binary, `//docker/images:push_all`, writes a temporary Docker config that contains the GHCR credentials and then sequentially runs each of the individual push targets.
- Tags are generated via Bazel stamping: every push always publishes a `latest` tag plus a `sha-<commit>` tag (falling back to `sha-dev` when Bazel runs without `--stamp`). Additional tags can be supplied at runtime via `--tag <value>` arguments passed to any `oci_push` target.

## Required secrets

Create a classic GitHub Personal Access Token (PAT) with the `write:packages` and `read:packages` scopes. Store the following secrets in BuildBuddy (Settings → Secrets):

| Secret name | Value                                             |
|-------------|---------------------------------------------------|
| `GHCR_USERNAME` | Your GitHub username (or org/bot account)       |
| `GHCR_TOKEN`    | The generated PAT                               |

If you prefer a different registry host (for example, GHES), you may also define an optional `GHCR_REGISTRY` secret (defaults to `ghcr.io`).

Alternatively, you can store an entire Docker auth configuration JSON in a single secret (for example `DOCKER_AUTH_CONFIG_JSON`) and let the helper script write it verbatim.

## Bootstrap script for BuildBuddy

The repository includes `buildbuddy_setup_docker_auth.sh` together with the Bazel target `//:buildbuddy_setup_docker_auth`. The script materialises `~/.docker/config.json` before any build steps run, so Rule-based tooling such as `rules_oci` can reuse the credentials transparently.

The script supports three input modes. Set exactly one of them via BuildBuddy secrets (replace placeholders with the matching `@@SECRET_NAME@@` syntax):

1. `DOCKER_AUTH_CONFIG_JSON` – a raw docker config snippet.
2. `GHCR_DOCKER_AUTH` – a base64 encoded `username:token` pair for the registry.
3. `GHCR_USERNAME` and `GHCR_TOKEN` – the script performs the base64 encoding for you. Optional `GHCR_REGISTRY` overrides `ghcr.io`.

Example BuildBuddy workflow fragment:

```toml
actions:
  - name: "Build, test and publish containers"
    bazel_commands = [
      "run --config=remote //:buildbuddy_setup_docker_auth",
      "build --config=remote //...",
      "test  --config=remote //...",
      "run  --config=remote --stamp //docker/images:push_all",
    ]
    env = {
      GHCR_USERNAME = "@@GHCR_USERNAME@@",
      GHCR_TOKEN = "@@GHCR_TOKEN@@",
      # Optional: GHCR_REGISTRY = "@@GHCR_REGISTRY@@",
    }
```

Running the auth bootstrap ensures that `rules_oci` can reuse the same credentials whether the later Bazel steps run locally or on BuildBuddy RBE.

## Passing secrets to Bazel in BuildBuddy Workflows

When configuring the BuildBuddy workflow that invokes the publish step, export the secrets as environment variables before Bazel runs. One simple option is to use an `env:` block in the workflow definition:

```yaml
steps:
  - name: "Push GHCR images"
    env:
      GHCR_USERNAME: "@@GHCR_USERNAME@@"
      GHCR_TOKEN: "@@GHCR_TOKEN@@"
      # Optional override if you are not pushing to ghcr.io
      # GHCR_REGISTRY: "@@GHCR_REGISTRY@@"
    script: |
      bazel run --config=remote --stamp //docker/images:push_all -- --tag "v${BUILD_TAG}"
```

BuildBuddy replaces the `@@SECRET_NAME@@` placeholders with the stored secret values while keeping them out of the Bazel command line history.

If you prefer the BuildBuddy script style locally, just run:

```bash
bazel run //:buildbuddy_setup_docker_auth
```

For local pushes without the script you can export the same environment variables manually:

```bash
export GHCR_USERNAME="carver-bot"
export GHCR_TOKEN="ghp_xxx"
# Optional
# export GHCR_REGISTRY="ghcr.io"

bazel run --stamp //docker/images:push_all -- --tag "v$(git describe --tags --always)"
```

## Command usage

- `bazel run --stamp //docker/images:push_all` – pushes all images with the default `latest` and `sha-<commit>` tags.
- `bazel run --stamp //docker/images:core_image_amd64_push -- --tag 1.2.3` – pushes only the `core` image and adds an extra `1.2.3` tag.
- `bazel run --config=remote --stamp //docker/images:push_all -- --tag $GIT_COMMIT` – builds using BuildBuddy remote execution, then pushes from the local workflow runner.

When credentials are supplied via environment variables the push helper writes an ephemeral Docker config into `$DOCKER_CONFIG`, otherwise it reuses the config created by the bootstrap script (or an existing `docker login`) so no secrets are leaked.

## Notes

- Always run publish commands with `--stamp` so that Bazel injects the `STABLE_COMMIT_SHA` into the tag file. Without stamping, the fallback tag `sha-dev` is used.
- The `push_all` helper accepts any flags supported by the underlying `oci_push` binaries (e.g. `--allow-nondistributable-artifacts`). These flags are forwarded to each image push in sequence.
- CI systems that cannot expose environment variables globally can instead `source` a file containing the JSON docker config and set `DOCKER_CONFIG` before invoking `bazel run`. The helper script respects pre-set `DOCKER_CONFIG` values by simply overwriting the target directory.
