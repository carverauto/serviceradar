---
name: demo-local-rollout
description: Build, sign, and roll ServiceRadar changes into the Kubernetes `demo` namespace using locally built images and immutable `sha-...` tags. Use when the user asks to deploy, refresh, roll, patch, or test code in `demo` before a release. Covers changed-image detection, copying unchanged images forward, OpenBao cosign signing, Argo patching, and rollout verification. Do not use for release cuts, Docker Compose refreshes, or non-demo namespaces unless the user explicitly redirects you.
---

# Demo Local Rollout

## Overview

Use this skill to refresh the `demo` namespace with a locally built test tag before any formal release. Prefer the smallest safe rollout: rebuild only the images affected by the current diff, copy unchanged images forward to the new `sha-<git-sha>` tag, sign the changed digests with the OpenBao release signer, patch the Argo app, and verify that `demo` reaches `Synced|Healthy|Succeeded`.

## Workflow

1. Work from the repo root.
2. Determine the target tag with `git rev-parse HEAD` and format it as `sha-<commit>`.
3. Identify the currently deployed `demo` tag from the running deployments before changing anything.
4. Compare the current deployed commit against `HEAD` and decide which images actually changed.
5. Build and push only the changed images.
6. Copy all unchanged images from the current `demo` tag to the new tag.
7. Sign the changed digests with the OpenBao-backed `cosign-release` key.
8. Patch `serviceradar-demo-prod` to the new tag.
9. Watch Argo and the key `demo` workloads until rollout is complete.
10. Report the new tag, changed image digests, and final Argo status.

## Guardrails

- Use this skill for `demo` only. Do not roll `demo-staging`, production, or Docker Compose stacks unless the user explicitly changes scope.
- Do not cut a release, update `VERSION`, or create tags here. This path is for local test rollout only.
- Prefer the smallest rebuild set that is actually safe.
- If only `elixir/web-ng/**` changed, prefer the repo's documented `web-ng` fast path in [AGENTS.md](/home/mfreeman/src/serviceradar/AGENTS.md:70) instead of rebuilding everything.
- If shared files changed, widen the rebuild set conservatively. Examples: `proto/**` changes can affect multiple consumers; Go agent/MTR changes affect `serviceradar-agent` and often `serviceradar-agent-gateway`; Elixir core changes affect `serviceradar-core-elx`; `elixir/web-ng/**` affects `serviceradar-web-ng`.
- Do not assume the target tag already exists in the registry. Check or just build it.
- Sign by digest, not by tag, whenever possible.

## Changed Image Selection

Use `git diff --name-only <currently-deployed-sha>..HEAD` and map the diff to images.

Common mappings in this repo:

- `go/cmd/agent/**`, `go/pkg/agent/**`, `go/pkg/mtr/**` -> `serviceradar-agent`
- `go/cmd/agent-gateway/**`, shared agent control/proto wiring -> `serviceradar-agent-gateway`
- `elixir/serviceradar_core/**` -> `serviceradar-core-elx`
- `elixir/web-ng/**` -> `serviceradar-web-ng`
- `proto/**` -> rebuild every image that consumes the changed generated code

When in doubt, rebuild slightly too much rather than slightly too little.

## Standard Demo Images

These are the usual images carried on the immutable `demo` tag:

- `arancini`
- `serviceradar-agent`
- `serviceradar-agent-gateway`
- `serviceradar-core-elx`
- `serviceradar-datasvc`
- `serviceradar-db-event-writer`
- `serviceradar-faker`
- `serviceradar-flow-collector`
- `serviceradar-log-collector`
- `serviceradar-rperf-client`
- `serviceradar-tools`
- `serviceradar-trapd`
- `serviceradar-web-ng`
- `serviceradar-zen`

`serviceradar-log-collector-tcp` may be pinned independently; do not blindly rewrite it unless the user actually changed it.

## Registry And Signing Setup

Prepare Harbor auth first:

```bash
./buildbuddy_setup_docker_auth.sh
```

Prepare OpenBao signing env using the same flow as Forgejo jobs. This assumes the in-cluster signer is available through a port-forward:

```bash
kubectl port-forward -n openbao-system svc/openbao-active 18200:8200
```

Then mint a service account token and exchange it for a Vault token:

```bash
OPENBAO_ADDR=http://127.0.0.1:18200
OPENBAO_K8S_ROLE=forgejo-runner
sa_jwt="$(kubectl create token -n forgejo-actions forgejo-runner)"
vault_token="$({
  curl -fsSL \
    -H 'Content-Type: application/json' \
    -d "{\"role\":\"${OPENBAO_K8S_ROLE}\",\"jwt\":\"${sa_jwt}\"}" \
    "${OPENBAO_ADDR}/v1/auth/kubernetes/login"
} | jq -er '.auth.client_token')"
```

Export the signing environment:

```bash
export VAULT_ADDR="$OPENBAO_ADDR"
export VAULT_TOKEN="$vault_token"
export COSIGN_KEY_REF=hashivault://cosign-release
export COSIGN_YES=true
export COSIGN_DOCKER_MEDIA_TYPES=1
export COSIGN_REFERRERS_MODE=legacy
export COSIGN_TLOG_UPLOAD=true
```

Re-mint the Vault token if signing starts returning `403 permission denied`.

## Build And Push Changed Images

Use Bazel remote push targets for the changed images only. Typical examples:

```bash
bazel run --config=remote_push --stamp //docker/images:agent_image_amd64_push
bazel run --config=remote_push --stamp //docker/images:agent_gateway_image_amd64_push
bazel run --config=remote_push --stamp //docker/images:core_elx_image_amd64_push
bazel run --config=remote_push --stamp //docker/images:web_ng_image_amd64_push
```

These commands print the pushed digest. Capture it for signing and for the final report.

## Copy Unchanged Images Forward

For every standard demo image that did not change, copy it from the currently deployed tag to the new tag with `crane`:

```bash
/tmp/gobin/crane copy \
  registry.carverauto.dev/serviceradar/<image>:sha-<old> \
  registry.carverauto.dev/serviceradar/<image>:sha-<new>
```

This keeps the new immutable tag complete without rebuilding unchanged services.

## Sign Changed Digests

After push, sign each changed image by digest:

```bash
cosign sign --key "$COSIGN_KEY_REF" \
  registry.carverauto.dev/serviceradar/<image>@sha256:<digest>
```

Sign every changed digest before patching Argo so Kyverno admission will accept the rollout.

## Patch Demo Argo App

Patch the Argo application instead of editing chart values for a one-off test rollout:

```bash
kubectl patch application -n argocd serviceradar-demo-prod \
  --type merge \
  -p '{"spec":{"source":{"helm":{"parameters":[{"name":"global.imageTag","value":"sha-<new>"}]}}}}'
```

## Verify Rollout

Watch Argo until it reaches:

```text
Synced|Healthy|Succeeded
```

Use:

```bash
kubectl get application -n argocd serviceradar-demo-prod \
  -o jsonpath='{.status.sync.status}{"|"}{.status.health.status}{"|"}{.status.operationState.phase}{"\n"}'
```

Check the key deployments are on the new tag:

```bash
kubectl get deploy -n demo \
  serviceradar-web-ng serviceradar-core serviceradar-agent serviceradar-agent-gateway \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

If Argo is still `Progressing`, inspect pods and hook jobs:

```bash
kubectl get pods -n demo -o wide
kubectl get jobs -n demo
```

Do not call the rollout finished until the new pods are running and Argo reports `Succeeded`.

## Report Back

Close with:

- target immutable tag
- which images were rebuilt vs copied forward
- changed image digests that were signed
- final Argo status
- any pods still terminating or any residual risk
