---
name: demo-web-ng-fastpath
description: Refresh the Kubernetes `demo` namespace with a web-ng-only change using the ServiceRadar fast path. Use when the diff only touches `elixir/web-ng/**` and the user wants a faster demo rollout than the full image graph. Covers scope verification, the in-cluster `publish-oci.yml` web-stack-commit-only build, verified promotion, preserving unchanged digests, the pin PR into `demo/prod-release`, and verifying the rollout. Do not use when non-web-ng services changed or when cutting a release.
---

# Demo Web-NG Fast Path

## Overview

Use this skill when a change is isolated to `elixir/web-ng/**` and the goal is to test it in `demo` quickly. Build only `serviceradar-web-ng` (and `serviceradar-core-elx`, which the same build step produces) in-cluster, preserve other services at their existing digests, require verified promotion, and pin the changed digests with a PR into `demo/prod-release`, and verify the rollout.

Formal releases use semver tags, such as `v1.2.41`, and `$release-cut-and-demo-roll`. This skill is only for temporary unpublished `sha-...` demo testing. The verified publication receipt, pin PR, and Argo checks are shared with `$demo-local-rollout` (demo roll, steps 3 to 5); follow them there rather than keeping a second copy here.

## Workflow

1. Verify that the changed files fit the web stack scope.
2. Publish the reviewed commit with `publish-oci.yml` and `web-stack-commit-only`.
3. Require successful signing, verification, and protected promotion.
4. Pin only the changed services to receipt digests in the deployment PR.
5. Preserve unchanged service digests and verify the Argo rollout.

## Guardrails

- Use this only when the diff is actually `web-ng`-only. If anything outside `elixir/web-ng/**` changed, fall back to `$demo-local-rollout`.
- Do not use this for release cuts or any namespace other than `demo` unless the user explicitly redirects you.
- Do not build the image on a workstation. A workstation Bazel build of the image set pulls large CAS blobs through `cache-proxy.carverauto.dev` and has OOMKilled the shared Envoy gateway; the in-cluster build avoids that.
- Do not leave a formal release rollout on a `sha-...` tag. After testing is complete, use `$release-cut-and-demo-roll` to return `demo` to the published semver path.
- Do not skip signing. `demo` admission is Kyverno-enforced, and the publishing workflow signs before protected promotion.
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
promotion receipt after signing and verification.

## Pin And Roll

Use the workflow's promotion receipt to pin `image.digests.webNg` and
`image.digests.core` to their protected digests in
`helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml`. Preserve unchanged
service digests and the existing chart version. Do not copy tags forward, remove
digest pins, or manually sign artifacts in the protected project.

Open the pin PR into `demo/prod-release` and follow `$demo-local-rollout` for the
rollout checks. That source file owns rendered Helm parameters; patching the Argo
Application does not replace the source-controlled deployment configuration.
Require the workflow to finish promotion successfully before any rollout.

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

Do not report success until the new `serviceradar-web-ng` pod is running on the verified digest and Argo reaches `Succeeded` for the pin PR's merge revision (`.status.sync.revision`).

## Report Back

Close with:

- target immutable tag
- unchanged service digests preserved
- publish run id and test branch
- web-ng and core-elx digests that were signed
- pin PR
- final Argo status
- any lingering rollout risk
