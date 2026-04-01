# Publishing ServiceRadar Images to Harbor with Bazel

This note describes the Bazel-native workflow for building and pushing the ServiceRadar container images to Harbor. It also covers the minimal secret configuration required in BuildBuddy so that CI runs can authenticate against `registry.carverauto.dev` without leaking credentials into the repository.

## Overview

- Each image defined in `docker/images/BUILD.bazel` now has a matching `oci_push` target that uploads the image to `registry.carverauto.dev/serviceradar/<image-name>`.
- The canonical aggregate publish target is `//:push`, which delegates to `//docker/images:push_all`.
- `//docker/images:push_all` writes a temporary Docker config that contains the Harbor credentials and runs the per-image push targets in parallel via `rules_multirun` with `jobs = 0`.
- Tags are generated via Bazel stamping: every push always publishes a `latest` tag plus a `sha-<commit>` tag (falling back to `sha-dev` when Bazel runs without `--stamp`). Additional tags can be supplied at runtime via `--tag <value>` arguments passed to any `oci_push` target.

## Required secrets

Create a Harbor robot account with push/pull permission on the `serviceradar` project. Store the following secrets in BuildBuddy (Settings -> Secrets):

| Secret name | Value                                             |
|-------------|---------------------------------------------------|
| `OCI_USERNAME` | Harbor robot username (for example `robot$serviceradar-ci`) |
| `OCI_TOKEN`    | Harbor robot secret                                         |

Set `OCI_REGISTRY=registry.carverauto.dev` when the workflow does not already export it.

Alternatively, you can store an entire Docker auth configuration JSON in a single secret (for example `DOCKER_AUTH_CONFIG_JSON`) and let the helper script write it verbatim.

## Bootstrap script for BuildBuddy

The repository includes `buildbuddy_setup_docker_auth.sh`. The script materialises `~/.docker/config.json` before any build steps run, so rule-based tooling such as `rules_oci` can reuse the credentials transparently.

The script supports three input modes. Set exactly one of them via BuildBuddy secrets (replace placeholders with the matching `@@SECRET_NAME@@` syntax):

1. `DOCKER_AUTH_CONFIG_JSON` – a raw docker config snippet.
2. `OCI_DOCKER_AUTH` – a base64 encoded `username:token` pair for the registry.
3. `OCI_USERNAME` and `OCI_TOKEN` – the script performs the base64 encoding for you. Optional `OCI_REGISTRY` overrides `registry.carverauto.dev`.

Example BuildBuddy workflow fragment:

```toml
actions:
  - name: "Build, test and publish containers"
    bazel_commands = [
      "build --config=remote //...",
      "test  --config=remote //...",
      "run  --config=remote_push --stamp //:push",
    ]
    env = {
      OCI_REGISTRY = "registry.carverauto.dev",
      OCI_USERNAME = "@@OCI_USERNAME@@",
      OCI_TOKEN = "@@OCI_TOKEN@@",
    }
```

Running the auth bootstrap ensures that `rules_oci` can reuse the same credentials whether the later Bazel steps run locally or on BuildBuddy RBE.

## Passing secrets to Bazel in BuildBuddy Workflows

When configuring the BuildBuddy workflow that invokes the publish step, export the secrets as environment variables before Bazel runs. One simple option is to use an `env:` block in the workflow definition:

```yaml
steps:
  - name: "Push Harbor images"
    env:
      OCI_REGISTRY: "registry.carverauto.dev"
      OCI_USERNAME: "@@OCI_USERNAME@@"
      OCI_TOKEN: "@@OCI_TOKEN@@"
    script: |
      bazel run --config=remote_push --stamp //:push -- --tag "v${BUILD_TAG}"
```

BuildBuddy replaces the `@@SECRET_NAME@@` placeholders with the stored secret values while keeping them out of the Bazel command line history.

If you prefer the script style locally, just run:

```bash
./buildbuddy_setup_docker_auth.sh
```

For local pushes without the script you can export the same environment variables manually:

```bash
export OCI_REGISTRY="registry.carverauto.dev"
export OCI_USERNAME='robot$serviceradar-ci'
export OCI_TOKEN="replace-with-harbor-robot-secret"

make push_all PUSH_TAG="v$(git describe --tags --always)"
```

## Command usage

- `make push_all` – pushes all images with the default `latest` and `sha-<commit>` tags, then verifies the published Harbor state.
- `make push_all PUSH_TAG=v1.2.3` – pushes all images with an extra tag and verifies `latest`, `sha-<commit>`, and `v1.2.3`.
- `bazel build --config=remote //:images` – builds the canonical publishable image set, including current multi-arch image indexes.
- `bazel run --stamp //:push` – pushes all images with the default `latest` and `sha-<commit>` tags.
- `bazel run --stamp //docker/images:core_elx_image_amd64_push -- --tag 1.2.3` – pushes only the core-elx image and adds an extra `1.2.3` tag.
- `bazel run --config=remote_push --stamp //:push -- --tag $GIT_COMMIT` – builds using BuildBuddy remote execution, downloads the OCI artifacts locally, then pushes from the workflow runner.

When credentials are supplied via environment variables the push helper writes an ephemeral Docker config into `$DOCKER_CONFIG`, otherwise it reuses the config created by the bootstrap script (or an existing `docker login`) so no secrets are leaked.

## Notes

- Always run publish commands with `--stamp` so that Bazel injects the `STABLE_COMMIT_SHA` into the tag file. Without stamping, the fallback tag `sha-dev` is used.
- The aggregate `//:push` target accepts any flags supported by the underlying `oci_push` binaries (e.g. `--allow-nondistributable-artifacts`). These flags are forwarded to each image push.
- CI systems that cannot expose environment variables globally can instead `source` a file containing the JSON docker config and set `DOCKER_CONFIG` before invoking `bazel run`. The helper script respects pre-set `DOCKER_CONFIG` values by simply overwriting the target directory.

## Verification

After publishing, run the repo-local verification script against the tag you care about, or use `make verify_publish`:

```bash
make verify_publish
make verify_publish VERIFY_TAG="v$(git describe --tags --always)"
./scripts/verify-oci-publish.sh latest "sha-$(git rev-parse HEAD)"
```

The script checks:

- single-arch repos still publish single OCI manifests where expected
- multi-arch repos publish OCI indexes with `linux/amd64` and `linux/arm64/v8`
- critical runtime metadata such as `Entrypoint`, `Cmd`, `WorkingDir`, and selected environment values still match the Bazel image declarations
