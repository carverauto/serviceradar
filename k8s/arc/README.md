# ARC runner notes

We need a custom ARC runner image because the stock GitHub runner image is
missing tools we use in CI/CD (cmake, flex, protoc, perl/OpenSSL, rpmbuild,
etc.).

As of 2026-03-13, GitHub has deprecated runner `v2.330.0`. The last broken
image we deployed was `ghcr.io/carverauto/arc-runner@sha256:3c64956f...`, and
it was still based on `actions/runner` `v2.330.0`. The refreshed image built
from this repo is `ghcr.io/carverauto/arc-runner@sha256:cd933c5c...` and is
tagged `sha-42bebef8e816-runner-2.332.0`.

Current upstream references when this file was updated:
- `actions/runner` latest release: `v2.332.0` (published 2026-02-25)
- `actions-runner-controller` latest chart release: `gha-runner-scale-set-0.13.1` (published 2025-12-23)

## Important repo caveat

`docker/arc-runner/Dockerfile` is the source of the custom runner image, but
`bazel run //docker/images:arc_runner_image_amd64_push` does not build from that
Dockerfile today. It only re-publishes the already-pushed
`ghcr.io/carverauto/arc-runner` image pinned in `MODULE.bazel`.

For runner upgrades, rebuild/push the image from `docker/arc-runner/` directly,
then update the digests in this repo.

## Upgrade the custom runner image

1. Build and push a fresh runner image from `docker/arc-runner/`.

```bash
GIT_SHA=$(git rev-parse --short=12 HEAD)
docker buildx build \
  --platform linux/amd64 \
  -t ghcr.io/carverauto/arc-runner:sha-${GIT_SHA}-runner-2.332.0 \
  --push \
  docker/arc-runner
```

2. Capture the pushed digest.

```bash
GIT_SHA=$(git rev-parse --short=12 HEAD)
skopeo inspect docker://ghcr.io/carverauto/arc-runner:sha-${GIT_SHA}-runner-2.332.0 | jq -r .Digest
```

3. Update these pins to the pushed digest:
- `k8s/arc/runner-values.yaml`
- `MODULE.bazel` `arc_runner` pull

4. Commit the repo changes before rolling the cluster.

## Install or upgrade ARC

Install or upgrade the controller chart with `k8s/arc/values.yaml`:

```bash
helm upgrade --install arc-controller \
  --namespace arc-systems \
  --create-namespace \
  --version 0.13.1 \
  -f ./k8s/arc/values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
```

Install or upgrade the runner scale set with `k8s/arc/runner-values.yaml`:

```bash
helm upgrade --install arc-runner-set \
  --namespace arc-runners \
  --create-namespace \
  --version 0.13.1 \
  -f ./k8s/arc/runner-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

Adjust names, namespaces, GitHub auth secret, and labels as needed.

## Runner values example

```yaml
runnerScaleSetName: serviceradar
githubConfigUrl: <REPO_URL>
githubConfigSecret:
  github_token: <PAT>
template:
  spec:
    containers:
    - name: runner
      image: ghcr.io/carverauto/arc-runner@sha256:<pushed_digest>
      command:
        - /home/runner/run.sh
      args:
        - --jitconfig
        - $(ACTIONS_RUNNER_INPUT_JITCONFIG)
        - --once
      env:
        - name: ACTIONS_RUNNER_LABELS
          value: self-hosted,Linux,X64,arc-runner-set
```

## Verification

Verify the runner version after rollout:

```bash
kubectl logs -n arc-runners deploy/arc-runner-set-listener | rg "Current runner version"
kubectl logs -n arc-runners -l app.kubernetes.io/component=runner --tail=50 | rg "Current runner version"
```

The runner pods should report `Current runner version: '2.332.0'` or newer.

Symptom/resolution notes:
- If runners start and immediately exit/Complete, ensure the command/args above are set so the runner actually launches `/home/runner/run.sh --jitconfig ... --once` with the desired labels.
- If the pod still reports `2.330.0`, the scale set is still pinned to an old `ghcr.io/carverauto/arc-runner` digest even if the controller chart was upgraded.
