---
name: demo-web-ng-fastpath
description: Refresh the Kubernetes `demo` namespace with a web-ng-only change using the ServiceRadar fast path. Use when the diff only touches `elixir/web-ng/**` and the user wants a faster demo rollout than the full image graph. Covers scope verification, the in-cluster `publish-oci.yml` web-stack-commit-only build, copying unchanged images forward, signing with the OpenBao release key, the pin PR into `demo/prod-release`, and verifying the rollout. Do not use when non-web-ng services changed or when cutting a release.
---

# Demo Web-NG Fast Path

## Overview

Use this skill when a change is isolated to `elixir/web-ng/**` and the goal is to test it in `demo` quickly. Build only `serviceradar-web-ng` (and `serviceradar-core-elx`, which the same build step produces) in-cluster, copy the other `demo` images forward to the new immutable tag, sign the new digests, pin the tag with a PR into `demo/prod-release`, and verify the rollout.

Formal releases use semver tags, such as `v1.2.41`, and `$release-cut-and-demo-roll`. This skill is only for temporary unpublished `sha-...` demo testing. The signing commands, the pin PR, and the Argo checks are shared with `$demo-local-rollout` (demo roll, steps 3 to 5); follow them there rather than keeping a second copy here.

## Workflow

1. Work from the repo root.
2. Determine the new immutable tag: `sha-$(git rev-parse <commit>)`.
3. Verify the diff only touches `elixir/web-ng/**`.
4. Identify the currently deployed `demo` tag.
5. Push a `test/demo-test-NN` branch at the commit and dispatch `publish-oci.yml` with `publish_scope=web-stack-commit-only`.
6. Copy every other `demo` image from the old tag to the new tag.
7. Verify every image at the new tag and sign the new web-ng and core-elx digests.
8. Open the pin PR into `demo/prod-release`.
9. After merge, watch Argo and the key workloads until the rollout completes.

## Guardrails

- Use this only when the diff is actually `web-ng`-only. If anything outside `elixir/web-ng/**` changed, fall back to `$demo-local-rollout`.
- Do not use this for release cuts or any namespace other than `demo` unless the user explicitly redirects you.
- Do not build the image on a workstation. A workstation Bazel build of the image set pulls large CAS blobs through `cache-proxy.carverauto.dev` and has OOMKilled the shared Envoy gateway; the in-cluster build avoids that.
- Do not leave a formal release rollout on a `sha-...` tag. After testing is complete, use `$release-cut-and-demo-roll` to return `demo` to the published semver path.
- Do not skip signing. `demo` admission is Kyverno-enforced, and the web-stack-commit-only publish does not sign.
- Sign by digest, not by tag.
- Never push to `staging` or `demo/prod-release`; push new branches with an explicit refspec (`git push origin <local>:refs/heads/<branch>`).

## Verify The Scope First

Run:

```bash
git fetch origin demo/prod-release
git show origin/demo/prod-release:helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml
git diff --name-only <currently-deployed-sha>..<commit>
```

Proceed only if every changed file is under `elixir/web-ng/`.

## Build In-Cluster

```bash
COMMIT="$(git rev-parse <commit>)"
git ls-remote origin 'refs/heads/test/demo-test-*'   # pick the next unused NN
git push origin "${COMMIT}:refs/heads/test/demo-test-<NN>"
gh workflow run publish-oci.yml --ref "test/demo-test-<NN>" \
  -f publish_scope=web-stack-commit-only -f expected_commit="${COMMIT}"
gh run list --workflow publish-oci.yml --branch "test/demo-test-<NN>" --limit 1
gh run watch <run-id> --exit-status
```

`expected_commit` must equal the branch head exactly or the run refuses to
publish. The run pushes only `serviceradar-core-elx:sha-<COMMIT>` and
`serviceradar-web-ng:sha-<COMMIT>` (no `latest`), writes both digests to the
step summary, and does **not** sign them.

## Copy Unchanged Images Forward

Copy the other images from the current demo tag to the new tag with `crane` (on `PATH` via Homebrew):

```bash
crane copy \
  registry.carverauto.dev/serviceradar/<image>:<old-tag> \
  registry.carverauto.dev/serviceradar/<image>:sha-<new>
```

Repeat for:

- `arancini`
- `serviceradar-agent`
- `serviceradar-agent-gateway`
- `serviceradar-datasvc`
- `serviceradar-db-event-writer`
- `serviceradar-faker`
- `serviceradar-flow-collector`
- `serviceradar-log-collector`
- `serviceradar-rperf-client`
- `serviceradar-tools`
- `serviceradar-trapd`
- `serviceradar-trivy-sidecar`
- `serviceradar-zen`

Do not copy `serviceradar-core-elx` or `serviceradar-web-ng`; the run already
pushed them at the new tag. A copy keeps the digest, so the copied images keep
their existing signatures. Leave `serviceradar-log-collector-tcp` alone; it
shares the log-collector image.

## Verify And Sign

Run the verify loop from `$demo-local-rollout` (demo roll, step 3) over all 15
images at `sha-<new>`. Expect `serviceradar-web-ng` and `serviceradar-core-elx`
to be `UNSIGNED`; sign those digests with the `github-signing-runner` flow in
that step, then re-run the loop until every image reports `signed`.

## Pin And Roll

Open the pin PR into `demo/prod-release` setting `global.imageTag` to
`sha-<new>`, and confirm the automated Argo sync, exactly as in
`$demo-local-rollout` (demo roll, steps 4 and 5). List existing
`image.digests.<service>` parameters in
`helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml` and remove the
pin for every service that should move in the same PR: a digest pin overrides
`global.imageTag`. Do not patch the Argo
Application: the `.argocd-source-...` file replaces its parameters (see
Verified Facts).

## Verified Facts (2026-08-22, live run)

These were each confirmed against the live `carverauto` cluster during a real web-ng roll.
Do not re-derive them.

- For the OpenBao endpoint, signing identity, and token handling, follow
  `$demo-local-rollout` (demo roll, step 3).
- **`.argocd-source-serviceradar-demo-prod.yaml` REPLACES `helm.parameters` at render time.**
  This is stronger than a race: a `kubectl patch` of `spec.source.helm.parameters` on
  `serviceradar-demo-prod` persists in the Application spec, syncs `Synced|Healthy|Succeeded`,
  and is still **completely ignored** -- only the parameters listed in that file on
  `demo/prod-release` reach Helm. Any parameter you need (`global.imageTag`,
  `image.digests.*`) must be committed to that file on `demo/prod-release`.
- **`image.digests.<service>` is a real per-service escape hatch** (`_helpers.tpl`
  `serviceradar.imageRefSuffix`): it short-circuits ahead of the tag, so you can move ONE
  service and leave every other image on the already-signed release tag -- one signature
  instead of fifteen. Service key for web-ng is `webNg`. It still has to go in the
  `.argocd-source-...` file to take effect.
- **A full-scope publish moves `latest`** on every image (`oci_push` carries
  `static_tags = ["latest"]`; this covers `publish-oci.yml` `publish_scope=full` and the
  workstation `make push_all`). The `web-stack-commit-only` scope pushes only `sha-<commit>`.
  It does NOT move `v<VERSION>`: `scripts/workspace_status.sh` emits `STABLE_VERSION dev`
  unless a matching `v<VERSION>` git tag points at HEAD, and `container_tags.bzl` filters
  `vdev`. Verify with `git tag --points-at HEAD` before pushing.
- **Claude Code auto mode blocks the signing flow** unless these allow rules exist in
  `.claude/settings.local.json`, and the commands are run discretely (a `bash -c '...'`
  wrapper defeats prefix matching):
  `Bash(kubectl --context carverauto create token:*)`,
  `Bash(curl -sS -k -X POST --data:*)`,
  `Bash(cosign sign:*)`, `Bash(cosign verify:*)`.
  Keep the JWT and Vault token in files; never put them on a command line.

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

Do not report success until the new `serviceradar-web-ng` pod is running on the new tag and Argo reaches `Succeeded` for the pin PR's merge revision (`.status.sync.revision`).

## Report Back

Close with:

- target immutable tag
- old tag that was copied forward
- publish run id and test branch
- web-ng and core-elx digests that were signed
- pin PR
- final Argo status
- any lingering rollout risk
