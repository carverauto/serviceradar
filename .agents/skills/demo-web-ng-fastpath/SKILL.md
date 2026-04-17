---
name: demo-web-ng-fastpath
description: Refresh the Kubernetes `demo` namespace with a web-ng-only change using the ServiceRadar fast path. Use when the diff only touches `elixir/web-ng/**` and the user wants a faster local demo rollout without rebuilding the full image graph. Covers scope verification, copying unchanged images forward, rebuilding the production `serviceradar-web-ng` release locally, pushing with `crane`, signing with the OpenBao release key, patching Argo, and verifying the rollout. Do not use when non-web-ng services changed or when cutting a release.
---

# Demo Web-NG Fast Path

## Overview

Use this skill when a change is isolated to `elixir/web-ng/**` and the goal is to test it in `demo` quickly. Rebuild only `serviceradar-web-ng`, copy the other `demo` images forward to the new immutable tag, sign the new web-ng image, patch Argo, and verify the rollout.

## Workflow

1. Work from the repo root.
2. Determine the new immutable tag from `git rev-parse HEAD`.
3. Verify the diff only touches `elixir/web-ng/**`.
4. Identify the currently deployed `demo` tag.
5. Copy every unchanged `demo` image from the old tag to the new tag.
6. Build a local production `web-ng` release.
7. Package and push the new `serviceradar-web-ng` image with `crane`.
8. Sign the new web-ng digest with the OpenBao-backed release key.
9. Patch `serviceradar-demo-prod` to the new tag.
10. Watch Argo and the key workloads until the rollout completes.

## Guardrails

- Use this only when the diff is actually `web-ng`-only. If anything outside `elixir/web-ng/**` changed, fall back to `$demo-local-rollout`.
- Do not use this for release cuts or any namespace other than `demo` unless the user explicitly redirects you.
- Do not skip signing. `demo` admission is Kyverno-enforced.
- Sign by digest, not by tag, whenever possible.
- Keep the other demo images identical by copying them forward from the currently deployed tag.

## Verify The Scope First

Run:

```bash
git diff --name-only <currently-deployed-sha>..HEAD
```

Proceed only if every changed file is under `elixir/web-ng/`.

## Copy Unchanged Images Forward

Copy the unchanged images from the current demo tag to the new tag with `crane`:

```bash
/tmp/gobin/crane copy \
  registry.carverauto.dev/serviceradar/<image>:sha-<old> \
  registry.carverauto.dev/serviceradar/<image>:sha-<new>
```

Repeat for:

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
- `serviceradar-zen`

Leave `serviceradar-log-collector-tcp` alone unless the user explicitly changed that path too.

## Build The Production Web-NG Release

From `elixir/web-ng`:

```bash
MIX_ENV=prod HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 mix deps.compile
MIX_ENV=prod HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 mix compile
MIX_ENV=prod HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 mix assets.deploy
MIX_ENV=prod HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=120 mix release --path /tmp/serviceradar_web_ng_release_<shortsha>
```

## Package And Push The Web-NG Image

Create the image layer tarball:

```bash
tar --owner=10001 --group=10001 --transform='s,^,app/,' \
  -cf /tmp/serviceradar_web_ng_layer_<shortsha>.tar \
  -C /tmp/serviceradar_web_ng_release_<shortsha> .
```

Append the release onto the pinned Elixir base image and then mutate the runtime config:

```bash
/tmp/gobin/crane append \
  --platform linux/amd64 \
  -b index.docker.io/hexpm/elixir:1.19.4-erlang-28.3-debian-bookworm-20251208-slim \
  -f /tmp/serviceradar_web_ng_layer_<shortsha>.tar \
  -t registry.carverauto.dev/serviceradar/serviceradar-web-ng:sha-<new>

/tmp/gobin/crane mutate \
  --platform linux/amd64 \
  --tag registry.carverauto.dev/serviceradar/serviceradar-web-ng:sha-<new> \
  --entrypoint /app/bin/serviceradar_web_ng \
  --cmd start \
  --env HOME=/app \
  --env PATH=/app/bin:/usr/local/bin:/usr/bin:/bin \
  --env PHX_SERVER=true \
  --env MIX_ENV=prod \
  --exposed-ports 4000/tcp \
  --user 10001:10001 \
  --workdir /app \
  registry.carverauto.dev/serviceradar/serviceradar-web-ng:sha-<new>
```

Capture the pushed digest with:

```bash
/tmp/gobin/crane digest registry.carverauto.dev/serviceradar/serviceradar-web-ng:sha-<new>
```

## Prepare OpenBao Signing Env

Port-forward the signer if needed:

```bash
kubectl port-forward -n openbao-system svc/openbao-active 18200:8200
```

Mint a Forgejo runner service-account token and exchange it for a Vault token:

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

Export:

```bash
export VAULT_ADDR="$OPENBAO_ADDR"
export VAULT_TOKEN="$vault_token"
export COSIGN_KEY_REF=hashivault://cosign-release
export COSIGN_YES=true
export COSIGN_DOCKER_MEDIA_TYPES=1
export COSIGN_REFERRERS_MODE=legacy
export COSIGN_TLOG_UPLOAD=true
```

If signing fails with `403 permission denied`, mint a fresh Vault token and retry.

## Sign The Web-NG Digest

```bash
cosign sign --key "$COSIGN_KEY_REF" \
  registry.carverauto.dev/serviceradar/serviceradar-web-ng@sha256:<digest>
```

## Patch Demo Argo App

```bash
kubectl patch application -n argocd serviceradar-demo-prod \
  --type merge \
  -p '{"spec":{"source":{"helm":{"parameters":[{"name":"global.imageTag","value":"sha-<new>"}]}}}}'
```

## Verify Rollout

Wait for:

```text
Synced|Healthy|Succeeded
```

Use:

```bash
kubectl get application -n argocd serviceradar-demo-prod \
  -o jsonpath='{.status.sync.status}{"|"}{.status.health.status}{"|"}{.status.operationState.phase}{"\n"}'
```

Check the key deployments:

```bash
kubectl get deploy -n demo \
  serviceradar-web-ng serviceradar-core serviceradar-agent serviceradar-tools \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

Inspect pods and jobs if Argo is still `Progressing`:

```bash
kubectl get pods -n demo -o wide
kubectl get jobs -n demo
```

Do not report success until the new `serviceradar-web-ng` pod is running on the new tag and Argo reaches `Succeeded`.

## Report Back

Close with:

- target immutable tag
- old tag that was copied forward
- web-ng digest that was signed
- final Argo status
- any lingering rollout risk
