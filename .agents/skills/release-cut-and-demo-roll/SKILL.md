---
name: release-cut-and-demo-roll
description: Cut a ServiceRadar release and roll the Kubernetes `demo` namespace to the resulting published semver image tag through ArgoCD Image Updater. Use when the user asks to update `VERSION` and `CHANGELOG`, run `scripts/cut-release.sh`, push the release refs, wait for published release artifacts, and then refresh `demo` to that released version. Do not use for pre-release local testing with unpublished images; use `$demo-local-rollout` or `$demo-web-ng-fastpath` for that.
---

# Release Cut And Demo Roll

## Overview

Use this skill for the formal release path: update release metadata, cut the release commit and tag, publish the refs, confirm that the release artifacts exist, and then roll `demo` to the released semver image tag, such as `v1.2.41`. Prefer the repo's existing release script, CI publish path, and ArgoCD Image Updater over ad hoc local image pushes.

## Workflow

1. Work from the repo root on the intended release branch.
2. Update `VERSION` and the top `CHANGELOG` entry for the new semver.
3. Dry-run the release cut to verify the changelog entry is wired correctly.
4. Run `scripts/cut-release.sh --version <version>` and append `--push` when ready to publish refs.
5. Confirm the release commit and tag landed where expected.
6. Wait for the published release artifacts to exist for the target semver tag.
7. Let ArgoCD Image Updater advance `demo` to `v<version>`, or patch the Argo app to `v<version>` if an immediate manual reconcile is required.
8. Watch Argo until `demo` reaches `Synced|Healthy|Succeeded`.
9. Report the release version, release commit, release tag, Image Updater status, and final demo rollout status.

## Guardrails

- Use this only for actual release cuts. Do not use it for one-off local testing or unpublished commits.
- Do not bypass `scripts/cut-release.sh` unless the user explicitly asks for a different path.
- Do not treat the release as deployable until the published artifacts for the release version actually exist.
- Prefer published release artifacts over rebuilding images locally in this workflow.
- Roll formal releases with the semver image tag, for example `v1.2.41`. The `sha-<commit>` path is for unpublished local demo testing only.
- Do not switch ArgoCD Image Updater back to `newest-build` over `sha-*` tags. Harbor tag timestamps can point demo at an older release; semver policy avoids that failure mode.

## Update Release Metadata

Before cutting the release:

- update `VERSION`
- add the matching top entry in `CHANGELOG`

Then dry-run the cut:

```bash
scripts/cut-release.sh --version <version> --dry-run
```

Fix metadata issues before continuing.

## Cut And Push The Release

Create the release commit and annotated tag:

```bash
scripts/cut-release.sh --version <version>
```

When the user wants the refs published immediately, use:

```bash
scripts/cut-release.sh --version <version> --push
```

Afterward, capture:

```bash
git rev-parse HEAD
git describe --tags --exact-match
```

Keep the release commit SHA for reporting and traceability. Use the release version as the demo image tag source: `v<version>`.

## Published Artifact Expectations

Do not roll `demo` until the release artifacts for the target semver tag exist.

Typical release build path from this repo:

```bash
./scripts/docker-login.sh
bazel build --config=remote $(bazel query 'kind(oci_image, //docker/images:*)')
make push_all_release
```

In practice, this usually runs in CI instead of locally. The important requirement is that the release images for the target version are published and signed before the `demo` rollout starts.

If only a single release image must be republished, use the matching Bazel push target. If only Wasm plugins are relevant, use `make push_wasm_plugins`.

## Roll Demo To The Release Tag

The steady-state `demo` path is ArgoCD Image Updater with a semver strategy. After the release images are published, force a reconcile if needed:

```bash
kubectl annotate imageupdater -n argocd serviceradar-demo-image-updater \
  force-reconcile="$(date +%s)" \
  --overwrite
```

Then check the Image Updater status:

```bash
kubectl get imageupdater -n argocd serviceradar-demo-image-updater \
  -o jsonpath='{.status.applicationsMatched}{"|"}{.status.imagesManaged}{"|"}{range .status.conditions[?(@.type=="Error")]}{.reason}{":"}{.status}{":"}{.message}{end}{"\n"}'
```

Expect one matched application, one managed image, and an `Error` condition with reason `NoErrors` and status `False`.

If an immediate manual override is required, patch the Argo application to the semver tag:

```bash
kubectl patch application -n argocd serviceradar-demo-prod \
  --type merge \
  -p '{"spec":{"source":{"helm":{"parameters":[{"name":"global.imageTag","value":"v<version>"}]}}}}'
```

Do not use `sr_demo_deploy` for formal releases; that helper rolls `demo` to a `sha-...` tag and is only appropriate for local unpublished test builds.

## Verify Demo Rollout

Watch the Argo app or Helm result until the deployment is healthy. For Argo-backed environments, wait for:

```text
Synced|Healthy|Succeeded
```

Useful checks:

```bash
kubectl get application -n argocd serviceradar-demo-prod \
  -o jsonpath='{.status.sync.status}{"|"}{.status.health.status}{"|"}{.status.operationState.phase}{"\n"}'

kubectl get pods -n demo

kubectl get deploy -n demo \
  serviceradar-web-ng serviceradar-core serviceradar-agent serviceradar-tools \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

Do not report the rollout finished until the key workloads are running the new `v<version>` tag and the environment is healthy.

## Report Back

Close with:

- release version
- release commit SHA
- release tag
- whether refs were pushed
- whether release artifacts were confirmed published
- Image Updater status
- final `demo` rollout status
- any residual risk or follow-up needed
