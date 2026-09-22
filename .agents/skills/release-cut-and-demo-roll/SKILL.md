---
name: release-cut-and-demo-roll
description: Cut a ServiceRadar release and roll the Kubernetes `demo` namespace to the resulting published semver image tag through the guarded ArgoCD release branch. Use when the user asks to update `VERSION` and `CHANGELOG`, run `scripts/cut-release.sh`, push the release refs, wait for published release artifacts, and then refresh `demo` to that released version. Do not use for pre-release local testing with unpublished images; use `$demo-local-rollout` or `$demo-web-ng-fastpath` for that.
---

# Release Cut And Demo Roll

## Overview

Use this skill for the formal release path: update release metadata, cut the release commit and tag, publish the refs, confirm that the release artifacts exist, and then verify the automatic `demo` rollout to the released semver image tag, such as `v1.2.41`. Prefer the repo's existing release script, CI publish path, guarded `demo/prod-release` branch, and conservative ArgoCD auto-sync over ad hoc local image pushes.

## Workflow

1. Work from the repo root on the intended release branch.
2. Update `VERSION` and the top `CHANGELOG` entry for the new semver.
3. Dry-run the release cut to verify the changelog entry is wired correctly.
4. Run `scripts/cut-release.sh --version <version> --push`; this publishes the release branch only and keeps the annotated tag local.
5. Open the release pull request and merge it into `staging` with `fj pr merge <PR> -M merge` after CI passes. Squash/rebase would discard the tagged commit.
6. Fetch `origin/staging`, prove the local tag commit is now an ancestor, and publish the tag with an explicit tag refspec.
7. Wait for the published release artifacts to exist for the target semver tag.
8. Confirm the release workflow advanced `demo/prod-release` and its Argo source file to `v<version>`.
9. Confirm `serviceradar-demo-prod` still has automated sync enabled with prune and self-heal disabled, and observe Argo pick up the guarded branch without an operator-triggered sync.
10. Review any residual drift and watch Argo until `demo` reaches `Synced|Healthy|Succeeded`; use a manual sync only as an investigated recovery action.
11. Report the release version, release commit, release tag, release-branch revision, automatic-sync result, and final demo rollout status.

## Guardrails

- Use this only for actual release cuts. Do not use it for one-off local testing or unpublished commits.
- Do not bypass `scripts/cut-release.sh` unless the user explicitly asks for a different path.
- Do not treat the release as deployable until the published artifacts for the release version actually exist.
- Prefer published release artifacts over rebuilding images locally in this workflow.
- Roll formal releases with the semver image tag, for example `v1.2.41`. The `sha-<commit>` path is for unpublished local demo testing only.
- Do not re-enable Image Updater, prune, or automated self-heal until the generated-secret, CNPG, and deployment drift called out in `k8s/argocd/applications/demo-prod.yaml` has been reviewed and normalized.
- While that hold is active, `serviceradar-demo-image-updater` is expected to report zero matched applications and zero managed images. Treat `0|0|NoErrors:False` as the configured hold state, not a failed release.
- Automatic sync is authorized only for the guarded, publication-verified `demo/prod-release` branch and must remain non-pruning and non-self-healing. Generated secrets, CNPG resources, and unrelated live drift still require explicit operator judgment.

## Pre-Cut Gates

Run all of these BEFORE touching `VERSION`. Each one has broken a release already.

1. **Every unit test, the way CI runs them.** A tag pins its own source, so a fix pushed to
   `staging` afterwards is invisible to a re-run of that tag — a broken test found after
   tagging costs a new tag, not a re-run.

   ```bash
   make test   # bazel test -c opt --config=ci //... --test_tag_filters=-integration_test,-acceptance_test
   ```

   Must end `Build completed successfully` with no `FAIL:`. `go test` / `cargo test` /
   `mix test` do NOT cover this: the Elixir unit shards exist only as bazel targets
   (`//elixir/serviceradar_core:unit_tests_*`, `//elixir/web-ng:unit_tests_*`), which is how
   two broken Elixir suites reached the v1.4.30 tag.

2. **Duplicate migration versions** — must print nothing:

   ```bash
   ls elixir/serviceradar_core/priv/repo/migrations/ | grep -oE '^[0-9]+' | sort | uniq -d
   ```

   This bit v1.3.9 badly: three migrations collided on `20260630120000`, and Ecto refuses to
   run *any* migration when versions collide, silently bricking auth, metrics and plugin
   assignment on every fresh install. CI passed because it does not migrate against a prior
   baseline. If it prints anything, renumber the extras before cutting.

3. **Prod release assembles** — broke v1.3.8. `cd elixir/serviceradar_core && MIX_ENV=prod mix release`
   must produce no "Duplicated modules" (the hackney/h2 vs grpcbox/chatterbox conflict).
   Gate on BOTH `serviceradar_core` and `serviceradar_core_elx`.

4. macOS needs `gsed` (`brew install gnu-sed`) — `cut-release.sh` uses GNU sed for in-place
   edits.

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

## Recovery: Release Published But `demo/prod-release` Was Not Advanced

The `Advance demo release source branch` step in `.github/workflows/release.yml`
is conditional: it runs only when the release is not a prerelease AND the
parallel-asset and finalize steps both succeeded. An unrelated asset failure --
a Wasm plugin publish, for example -- therefore leaves a fully published,
correctly signed release with `demo/prod-release` still pointing at the previous
version. The release is fine; only the deploy pointer is stale.

What that step actually does is force-push the release commit itself:

```bash
git push --force-with-lease demo-release "HEAD:refs/heads/demo/prod-release"
```

where `HEAD` is the release commit, `git rev-list -n1 "refs/tags/v<version>^{commit}"`.
So the recovery is to reproduce that push, NOT to hand-write a commit that edits
`.argocd-source-serviceradar-demo-prod.yaml`. `scripts/cut-release.sh` already
wrote `global.imageTag: v<version>` into that file at the release commit, and
that commit is also the only tree carrying the matching `Chart.yaml` version and
migration `expectedVersion`. Adding a tag-only commit on top of the stale branch
would run new images against the old chart.

Verify all of these BEFORE pushing, because the push is what rolls `demo`:

```bash
# 1. Release commit is the tag's commit and is reachable from staging.
RC="$(git rev-list -n1 'v<version>^{commit}')"
git merge-base --is-ancestor "$RC" refs/remotes/origin/staging
./scripts/validate-release-metadata.sh "v<version>" "$RC"

# 2. The file at that commit already carries the tag, with no digest pins.
git show "$RC:helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml"

# 3. Every image the chart renders exists and is signed with the key Kyverno
#    enforces. Render from the release tree, not the working tree.
helm template serviceradar <release-tree>/helm/serviceradar -n demo \
  -f <release-tree>/helm/serviceradar/values-demo.yaml \
  --set-string global.imageTag=v<version> |
  grep -oE 'registry[.]carverauto[.]dev/serviceradar/[a-z0-9.-]+:[^ "]+' | sort -u
cosign verify --key docs/cosign.pub --insecure-ignore-tlog=true <each image>
```

`docs/cosign.pub` is the same key the `verify-serviceradar-images` ClusterPolicy
carries; diff them rather than assuming. That policy sets `mutateDigest: true`,
so admitted pods show `:<tag>@sha256:...` -- comparing that digest against
`crane digest <image>:v<version>` is the proof of which artifact is running.

### The digest-pin trap

Between releases, `demo/prod-release` accumulates ad-hoc commits that add
`image.digests.<service>` parameters pinning individual services to `sha-...`
builds. Per `serviceradar.imageRefSuffix` in `templates/_helpers.tpl`, **a digest
pin completely overrides `global.imageTag`**. Bumping only the tag while those
pins remain is inert for exactly the services people care about most.

The force-push discards those commits, which is intended -- but confirm first
that nothing regresses. Map each pinned digest back to its build commit and
prove it is contained in the release:

```bash
for t in $(crane ls registry.carverauto.dev/serviceradar/<image> | grep '^sha-'); do
  [ "$(crane digest registry.carverauto.dev/serviceradar/<image>:$t)" = "<pinned digest>" ] && echo "$t"
done
git merge-base --is-ancestor <build-commit> 'v<version>^{commit}'
```

A pin whose build commit is NOT an ancestor is not automatically a regression --
branch builds are often squash-merged, so the work lands under a different SHA.
Resolve it by diffing the owning package between that commit and the release tag
rather than by trusting the ancestry check alone. Pinning commits also sometimes
carry chart edits that were never upstreamed; diff
`origin/demo/prod-release..v<version> -- helm/serviceradar/` and account for
every removal before pushing.

After pushing, Argo picks the new revision up on its own. Do not sync manually;
confirm the operation was automatic with
`.status.operationState.operation.initiatedBy.automated`.

## Roll Demo To The Release Tag

The release workflow advances `demo/prod-release` only after the complete
release, catalog, and security asset set verifies. Confirm that branch now
carries the target tag:

```bash
git fetch origin \
  refs/heads/demo/prod-release:refs/remotes/origin/demo/prod-release
git show origin/demo/prod-release:helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml
```

The source file must set `global.imageTag` to `v<version>`. Confirm the conservative automatic-sync policy is still active:

```bash
kubectl get application -n argocd serviceradar-demo-prod \
  -o jsonpath='{.spec.syncPolicy.automated.enabled}{"|"}{.spec.syncPolicy.automated.prune}{"|"}{.spec.syncPolicy.automated.selfHeal}{"\n"}'
```

Expect `true|false|false`. Then check the Image Updater hold state for context:

```bash
kubectl get imageupdater -n argocd serviceradar-demo-image-updater \
  -o jsonpath='{.status.applicationsMatched}{"|"}{.status.imagesManaged}{"|"}{range .status.conditions[?(@.type=="Error")]}{.reason}{":"}{.status}{":"}{.message}{end}{"\n"}'
```

Expect zero matched applications, zero managed images, and an `Error` condition with reason `NoErrors` and status `False` while the Image Updater hold is active.

Use an authenticated Argo CLI context or the Argo UI. The usual local CLI context expects the Argo server on `127.0.0.1:18443`; start its port-forward in a separate shell when it is not already reachable:

```bash
kubectl port-forward -n argocd svc/argocd-server 18443:443
argocd app get serviceradar-demo-prod --refresh
```

Do not use `--core`: it looks for `argocd-cm` in the active namespace and does not work with this cluster layout.

Refresh the application and inspect any residual drift while the guarded automatic sync progresses:

```bash
kubectl get application -n argocd serviceradar-demo-prod -o json |
  jq -r '.status.resources[] | select(.status != "Synced") | [.group, .kind, .namespace, .name, .status] | @tsv'
argocd app diff serviceradar-demo-prod --hard-refresh
kubectl get application -n argocd serviceradar-demo-prod -o yaml
```

`argocd app diff` exits 1 when a diff exists and intentionally omits Kubernetes Secrets. Inspect every non-release change in its output, inspect each OutOfSync Secret's owner/hook annotations separately, and review CNPG resources explicitly. Remove or account for stale live-only Application parameters rather than broadening the automatic policy.

Do not run an operator-triggered sync while the guarded automatic operation is progressing or has succeeded. If automatic sync fails or remains stuck after investigation, a reviewed recovery sync may be dry-run and executed without prune:

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
- automatic-sync result, or the investigated manual recovery result when one was required
- final `demo` rollout status
- any residual risk or follow-up needed
