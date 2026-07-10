---
name: release-cut-and-demo-roll
description: Cut a ServiceRadar release and roll the Kubernetes `demo` namespace to the resulting published semver image tag through the guarded ArgoCD release branch. Use when the user asks to update `VERSION` and `CHANGELOG`, run `scripts/cut-release.sh`, push the release refs, wait for published release artifacts, and then refresh `demo` to that released version. Do not use for pre-release local testing with unpublished images; use `$demo-local-rollout` or `$demo-web-ng-fastpath` for that.
---

# Release Cut And Demo Roll

## Overview

Use this skill for the formal release path: update release metadata, cut the release commit and tag, publish the refs, confirm that the release artifacts exist, and then roll `demo` to the released semver image tag, such as `v1.2.41`. Prefer the repo's existing release script, CI publish path, guarded `demo/prod-release` branch, and explicit reviewed ArgoCD sync over ad hoc local image pushes.

## Workflow

1. Work from the repo root on the intended release branch.
2. Update `VERSION` and the top `CHANGELOG` entry for the new semver.
3. Dry-run the release cut to verify the changelog entry is wired correctly.
4. Run `scripts/cut-release.sh --version <version> --push`; this publishes the release branch only and keeps the annotated tag local.
5. Open the release pull request and merge it into `staging` with `fj pr merge <PR> -M merge` after CI passes. Squash/rebase would discard the tagged commit.
6. Fetch `origin/staging`, prove the local tag commit is now an ancestor, and publish the tag with an explicit tag refspec.
7. Wait for the published release artifacts to exist for the target semver tag.
8. Confirm the release workflow advanced `demo/prod-release` and its Argo source file to `v<version>`.
9. Review the Argo diff, then explicitly sync `serviceradar-demo-prod`; automated sync is intentionally disabled while live drift is under review.
10. Watch Argo until `demo` reaches `Synced|Healthy|Succeeded`.
11. Report the release version, release commit, release tag, release-branch revision, manual-sync result, and final demo rollout status.

## Guardrails

- Use this only for actual release cuts. Do not use it for one-off local testing or unpublished commits.
- Do not bypass `scripts/cut-release.sh` unless the user explicitly asks for a different path.
- Do not treat the release as deployable until the published artifacts for the release version actually exist.
- Prefer published release artifacts over rebuilding images locally in this workflow.
- Roll formal releases with the semver image tag, for example `v1.2.41`. The `sha-<commit>` path is for unpublished local demo testing only.
- Do not re-enable Image Updater or automated self-heal until the generated-secret, CNPG, and deployment drift called out in `k8s/argocd/applications/demo-prod.yaml` has been reviewed and normalized.
- While that hold is active, `serviceradar-demo-image-updater` is expected to report zero matched applications and zero managed images. Treat `0|0|NoErrors:False` as the configured hold state, not a failed release.
- Never sync before reviewing the diff. Generated secrets and CNPG resources require explicit operator judgment; a published release alone is not approval to reconcile unrelated live drift.

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

Create the release commit and annotated tag, then publish the release branch
while retaining the tag locally:

```bash
scripts/cut-release.sh --version <version> --push
```

Do not run the no-push form first and then rerun with `--push`; the first run
already creates the local tag, so the second correctly refuses to proceed.

Open the resulting release pull request and use the ancestry-preserving merge
commit method:

```bash
fj pr merge <PR> -M merge
```

Do not squash or rebase the release PR because that changes or discards the
tagged commit. Only after that commit is on `staging`, publish the tag with the
mechanically chained ancestry check printed by the script:

```bash
git fetch origin refs/heads/staging:refs/remotes/origin/staging
git merge-base --is-ancestor 'v<version>^{commit}' \
  refs/remotes/origin/staging && \
  git push origin refs/tags/v<version>:refs/tags/v<version>
```

Afterward, capture:

```bash
git rev-parse HEAD
git describe --tags --exact-match
```

Keep the release commit SHA for reporting and traceability. Use the release version as the demo image tag source: `v<version>`.

## Published Artifact Expectations

Do not roll `demo` until the release artifacts for the target semver tag exist.
Forgejo Actions is the supported formal publisher because the complete release
also includes packages, the Helm chart, managed-agent assets, native add-ons,
Wasm plugins, signatures, both import catalogs, and source/image security
bundles. `make push_all_release` only covers the container/Wasm portion and is
not a complete release recovery. Rerun the appropriate Forgejo workflow at the
release tag when recovery is required.

## Roll Demo To The Release Tag

The release workflow advances `demo/prod-release` only after the complete
release, catalog, and security asset set verifies. Confirm that branch now
carries the target tag:

```bash
git fetch origin \
  refs/heads/demo/prod-release:refs/remotes/origin/demo/prod-release
git show origin/demo/prod-release:helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml
```

The source file must set `global.imageTag` to `v<version>`. Check the Image Updater hold state for context:

```bash
kubectl get imageupdater -n argocd serviceradar-demo-image-updater \
  -o jsonpath='{.status.applicationsMatched}{"|"}{.status.imagesManaged}{"|"}{range .status.conditions[?(@.type=="Error")]}{.reason}{":"}{.status}{":"}{.message}{end}{"\n"}'
```

Expect zero matched applications, zero managed images, and an `Error` condition with reason `NoErrors` and status `False` while the manual-sync hold is active.

Use an authenticated Argo CLI context or the Argo UI. The usual local CLI context expects the Argo server on `127.0.0.1:18443`; start its port-forward in a separate shell when it is not already reachable:

```bash
kubectl port-forward -n argocd svc/argocd-server 18443:443
argocd app get serviceradar-demo-prod --refresh
```

Do not use `--core`: it looks for `argocd-cm` in the active namespace and does not work with this cluster layout.

List the complete drift set, then refresh and review the application before changing live state:

```bash
kubectl get application -n argocd serviceradar-demo-prod -o json |
  jq -r '.status.resources[] | select(.status != "Synced") | [.group, .kind, .namespace, .name, .status] | @tsv'
argocd app diff serviceradar-demo-prod --hard-refresh
kubectl get application -n argocd serviceradar-demo-prod -o yaml
```

`argocd app diff` exits 1 when a diff exists and intentionally omits Kubernetes Secrets. Inspect every non-release change in its output, inspect each OutOfSync Secret's owner/hook annotations separately, and review CNPG resources explicitly. Remove or account for stale live-only Application parameters before approving the sync.

Dry-run and then perform the initial operator-triggered reconcile without prune. Deletion is unrelated to advancing the release tag and requires a separate explicit review:

```bash
argocd app sync serviceradar-demo-prod --dry-run
argocd app sync serviceradar-demo-prod --assumeYes
```

Do not patch `global.imageTag` directly for a formal release. That creates another live-only override and bypasses the verified `demo/prod-release` source.

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
- `demo/prod-release` revision and image tag
- Image Updater hold status
- reviewed manual-sync result
- final `demo` rollout status
- any residual risk or follow-up needed
