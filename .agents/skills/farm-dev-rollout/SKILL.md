---
name: farm-dev-rollout
description: Build and roll an unreleased ServiceRadar dev build into the farm01 cluster's `serviceradar` namespace using an immutable `sha-<full-git-sha>` tag. Use when the user asks to build, deploy, roll, test, or verify a fix on farm01 / the dev cluster / k8s-farm.carverauto.dev. Covers publishing images from a non-linux workstation via CI dispatch, farm01 kubeconfig and Helm values, and rollout verification. Do NOT use for the `demo` namespace or any semver release — `demo` is for official releases only.
---

# Farm01 Dev Rollout

## Overview

farm01 is the **development / integration cluster**. It is where unreleased fixes get
proven before they are merged. Rollouts here use immutable `sha-<full-git-sha>` image
tags and are driven by a plain `helm upgrade` against a values file in the `gitops` repo.

**`demo` is for official releases only.** Do not point `demo` at a `sha-` tag as part of
dev work, and do not use `$demo-local-rollout` or `$release-cut-and-demo-roll` here — those
carry ArgoCD, Kyverno, and OpenBao/cosign machinery that farm01 deliberately does not run.
farm01 has no signature-enforcement admission policy, so unsigned dev images are fine.

## Cluster Facts

- kubeconfig: `~/.kube/farm01.yaml`, context `farm01`. The `farmctl` alias wraps
  `kubectl --kubeconfig ~/.kube/farm01.yaml --context farm01`. (`tonkactl` is the other,
  unrelated production cluster — never roll dev builds there.)
- Namespace: `serviceradar`.
- Helm values: `~/src/gitops/clusters/farm01/serviceradar/values.yaml`. This file is the
  source of truth and is committed — change it there, not with ad-hoc `--set` flags that
  silently drift.
- Chart: `oci://registry.carverauto.dev/serviceradar/charts/serviceradar`.
- Ingress is the shared Envoy Gateway (`gatewayApi.mode: attach`), not an Ingress object.
  External collectors get MetalLB BGP addresses from the `192.168.7.0/24` pool.

## Workflow

1. Commit the fix on a branch and push it. The image tag is derived from the commit, so
   **push first** — an unpushed commit cannot be built by CI.
2. Publish images for that commit (see below).
3. Set `global.imageTag` in the farm01 values file to `sha-<full-40-char-sha>`.
4. `helm upgrade` the release.
5. Verify the rollout and the actual behaviour you were fixing.

## Publishing Images

Read the **Publishing container images** section of `AGENTS.md` before doing anything here.
The short version:

- The canonical command is
  `bazel run -c opt --config=ci --remote_download_outputs=all --stamp //:push`.
- **It only runs on linux/amd64.** `--config=ci` inherits `remote_base`, which pins
  `--platforms`, `--host_platform` and `--extra_execution_platforms` to
  `//build/rbe:rbe_platform`, so `_push` is a linux executable with linux runfiles (`jq`,
  `crane`). On macOS it dies with `cannot execute binary file: Exec format error`. That is
  correct behaviour — the image content must be linux.
- Do **not** work around it with `crane`, `skopeo`, `docker push`, or by swapping runfiles
  binaries. Do **not** add `@platforms//host` to `--extra_execution_platforms` — it drops
  the BuildBuddy crosstool and abseil fails with `requires GCC 7 or higher`.

From a macOS workstation, dispatch CI instead:

```bash
fj actions dispatch publish-oci.yml <branch>
fj actions tasks | head -3          # watch for the "publish" task
```

`publish-oci.yml` is `workflow_dispatch`-only (the `push:` trigger was removed on purpose)
and runs on `serviceradar-signing` linux runners with Harbor credentials and cosign.

`--stamp` yields the **full 40-char** SHA, e.g. `sha-b2477c2c808ff343f95bba0b53f05a7b5c8fb3ce`
— not the 12-char short form. Without `--stamp` the tag degrades to the literal `sha-dev`.

Confirm the tag actually landed before rolling — a green pipeline is not proof:

```bash
img=serviceradar-core-elx
tok=$(curl -sS "https://registry.carverauto.dev/service/token?service=harbor-registry&scope=repository:serviceradar/$img:pull" | jq -r .token)
curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $tok" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://registry.carverauto.dev/v2/serviceradar/$img/manifests/sha-<full-sha>"
```

The `Accept` header matters: omit the OCI media types and Harbor returns 404 for an image
that exists. Anonymous pulls work (the `serviceradar` project is public); a bare request
without the token dance returns 401.

## Roll It

```bash
helm upgrade --install serviceradar \
  oci://registry.carverauto.dev/serviceradar/charts/serviceradar \
  --version <chart-version> -n serviceradar \
  -f ~/src/gitops/clusters/farm01/serviceradar/values.yaml \
  --timeout 30m
```

Give it a **long timeout and run it in the background**. Helm upgrades here routinely
exceed 10 minutes because of migration hooks; a killed client leaves the release in
`pending-upgrade` and the failure surfaces as an unhelpful `context canceled`.

## Verify

```bash
farmctl -n serviceradar get pods
farmctl -n serviceradar rollout status deploy/serviceradar-core --timeout=10m
farmctl -n serviceradar get svc -o wide | grep LoadBalancer
```

Then verify the actual fix, not just pod health. Several farm01 defects presented as
"everything is Running and Ready" while ingestion was dead:

- A LoadBalancer with `externalTrafficPolicy: Local` only advertises its `/32` from nodes
  holding a **ready** endpoint. If the pod never passes its readiness probe, MetalLB
  withdraws the route and the collector silently stops receiving traffic — the service still
  shows an `EXTERNAL-IP`.
- Check JetStream directly rather than trusting the UI:
  `nats stream subjects events`, `nats consumer ls events`.

## Guardrails

- Never point `demo` at a `sha-` tag from this workflow.
- Never roll a dev build into the `tonka01` cluster.
- Do not `kubectl patch` chart-owned resources to unblock a stuck upgrade. It transfers
  field ownership to the `kubectl-patch` field manager and the next `helm upgrade` fails
  with a server-side-apply conflict, which then has to be cleared out of `managedFields`.
- Record any chart-level fix in the chart itself. A value overridden only in the farm01
  values file fixes farm01 and leaves every OSS installer broken.

## Report Back

State the image tag rolled, the chart version, pod status, and the evidence that the
specific fix works. If something was left broken, say so explicitly.
