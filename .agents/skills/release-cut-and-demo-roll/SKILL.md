---
name: release-cut-and-demo-roll
description: Cut a ServiceRadar release and roll the Kubernetes `demo` namespace to the resulting published immutable tag. Use when the user asks to update `VERSION` and `CHANGELOG`, run `scripts/cut-release.sh`, push the release refs, wait for published release artifacts, and then refresh `demo` to that released tag. Do not use for pre-release local testing with unpublished images; use `$demo-local-rollout` or `$demo-web-ng-fastpath` for that.
---

# Release Cut And Demo Roll

## Overview

Use this skill for the formal release path: update release metadata, cut the release commit and tag, publish the refs, confirm that the release artifacts exist, and then roll `demo` to the released immutable `sha-<commit>` tag. Prefer the repo’s existing release script and published artifact path over ad hoc local image pushes.

## Workflow

1. Work from the repo root on the intended release branch.
2. Update `VERSION` and the top `CHANGELOG` entry for the new semver.
3. Dry-run the release cut to verify the changelog entry is wired correctly.
4. Run `scripts/cut-release.sh --version <version>` and append `--push` when ready to publish refs.
5. Confirm the release commit and tag landed where expected.
6. Wait for the published release artifacts to exist for the target commit/tag.
7. Roll `demo` to `sha-<release-commit>` using the published immutable tag.
8. Watch Argo until `demo` reaches `Synced|Healthy|Succeeded`.
9. Report the release version, release commit, release tag, and final demo rollout status.

## Guardrails

- Use this only for actual release cuts. Do not use it for one-off local testing or unpublished commits.
- Do not bypass `scripts/cut-release.sh` unless the user explicitly asks for a different path.
- Do not treat the release as deployable until the published artifacts for the release commit actually exist.
- Prefer published release artifacts over rebuilding images locally in this workflow.
- Roll `demo` with the immutable `sha-<commit>` image tag, not a floating version tag.

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

Use the resulting commit SHA as the immutable image tag source: `sha-<commit>`.

## Published Artifact Expectations

Do not roll `demo` until the release artifacts for the target commit exist.

Typical release build path from this repo:

```bash
./scripts/docker-login.sh
bazel build --config=remote $(bazel query 'kind(oci_image, //docker/images:*)')
make push_all_release
```

In practice, this may run in CI instead of locally. The important requirement is that the release images for the target commit are published and signed before the `demo` rollout starts.

If only a single release image must be republished, use the matching Bazel push target. If only Wasm plugins are relevant, use `make push_wasm_plugins`.

## Roll Demo To The Release Tag

Use the published release commit SHA as the demo image tag:

```bash
helm upgrade --install serviceradar ./helm/serviceradar \
  -n demo \
  -f helm/serviceradar/values-demo.yaml \
  --set global.imageTag="sha-<release-commit>" \
  --rollback-on-failure
```

If the local helper exists and the user wants the shortcut, this is equivalent:

```bash
sr_demo_deploy <sha-...|git-sha>
```

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

Do not report the rollout finished until the key workloads are running the new `sha-<release-commit>` tag and the environment is healthy.

## Report Back

Close with:

- release version
- release commit SHA
- release tag
- whether refs were pushed
- whether release artifacts were confirmed published
- final `demo` rollout status
- any residual risk or follow-up needed
