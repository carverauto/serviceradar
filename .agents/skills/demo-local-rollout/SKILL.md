---
name: demo-local-rollout
description: Roll unpublished sha-... test images to farm01 or the carverauto demo cluster. Use when the user asks to deploy, refresh, roll, patch, or test code in demo, farm01, or "the farm cluster" before a release. Pick the cluster first. Carverauto/demo images are built in-cluster by publish-oci.yml on a test/demo-test-NN branch, verified and signed with the OpenBao release key, then pinned by a PR into demo/prod-release. farm01 uses the same verified publication and a Helm digest-pin roll. Do not use for release cuts or Docker Compose.
---

# Test Image Rollout

Use this skill for unpublished `sha-<git-sha>` test tags. Formal releases use semver and `$release-cut-and-demo-roll`.

## Choose the cluster first

Do this before Harbor auth, Bazel, signing, or any cluster write.

| | **carverauto `demo`** | **farm01** |
|---|---|---|
| When | User says demo, carverauto, or does not name a cluster | User says farm01, farm cluster, or is already on the farm01 kubeconfig |
| Kubeconfig | `kubectl --context carverauto` | `export KUBECONFIG="$HOME/.kube/farm01.yaml"` |
| Namespace | `demo` | `serviceradar` |
| Image build | In-cluster: `publish-oci.yml` on a `test/demo-test-NN` branch | Prefer the same in-cluster build; use the same verified publication boundary |
| How it rolls | PR into `demo/prod-release`, then Argo auto-sync of `serviceradar-demo-prod` | `helm upgrade --reuse-values` |
| Admission | Kyverno: images **must** be signed with OpenBao `cosign-release` | Publication still signs and verifies before promotion; no manual signer access |
| Registry | Harbor `registry.carverauto.dev/serviceradar` | Same Harbor project (public; no pull secret) |
| Live tag source | `helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml` on `origin/demo/prod-release`, plus the Deployments in `demo` | `helm get values serviceradar -n serviceradar` (`global.imageTag`) |

Keep publication in the verified workflow for both clusters; use the correct deployment path. Never helm-upgrade farm01 thinking it is demo.

If only `elixir/web-ng/**` changed **and** the target is `demo`, consider `$demo-web-ng-fastpath`. That fast path is demo-only.

## Do not build demo images from a workstation

Do **not** run `bazel build --config=remote_base ... --remote_download_outputs=all`
(or `make push_all`, or any other full image-set build) on a workstation to
produce demo images. That build pulls every large CAS blob through
`cache-proxy.carverauto.dev`, which is served by the shared Envoy gateway. During
one such build the gateway was OOMKilled six times and went down for everything
behind it. The in-cluster `publish-oci.yml` run below builds and pushes the same
images without pulling them to a workstation.

## Rules for every roll

- Tag: `sha-<full 40-char commit SHA>` (what `--stamp` emits).
- Read the **currently deployed** tag on the chosen cluster before changing anything.
- Do not cut a release, edit `VERSION`, or create git tags. Do not roll
  `demo-staging`, production, or Docker Compose unless the user changes scope.
- Never push to `staging` or `demo/prod-release`. Push only new branches, always
  with an explicit refspec: `git push origin <local>:refs/heads/<branch>`.
- `origin` is GitHub (`git@github.com:carverauto/serviceradar.git`). There is no
  `github` remote.
- Never print, log, or paste a service-account JWT or a Vault token. Keep them in
  files under a private temp directory and delete them when signing is done.

---

## carverauto `demo` roll (in-cluster build, sign, pin PR)

### 1. Push a test branch at the commit

```bash
COMMIT="$(git rev-parse <commit-under-test>)"
git fetch origin
git ls-remote origin 'refs/heads/test/demo-test-*'   # pick the next unused NN
NN=<next number>
git push origin "${COMMIT}:refs/heads/test/demo-test-${NN}"
```

The commit must already contain the `publish-oci.yml` change that allows
`test/demo-test-<N>` in the signing step (`OPENBAO_SIGNING_ALLOWED_REFS_REGEX`
in "Publish images"). The workflow runs from the dispatched branch's own copy of
the file, so a branch cut from an older commit still refuses to sign and ends
red right after the pushes, with
`OpenBao signing is not allowed for ref 'refs/heads/test/demo-test-<N>'.`

### 2. Dispatch the full publish and wait

```bash
gh workflow run publish-oci.yml --ref "test/demo-test-${NN}" -f publish_scope=full
gh run list --workflow publish-oci.yml --branch "test/demo-test-${NN}" --limit 1
gh run watch <run-id> --exit-status
```

The run builds on RBE from the in-cluster `serviceradar-signing` ARC runner,
pushes every publishable image into the disposable build project, signs
each built digest with `hashivault://cosign-release`, and verifies it before promotion into the protected project. If it fails, read the failing step with
`gh run view <run-id> --log-failed` before retrying. A run that fails during signing or promotion has not produced a deployable receipt.
Repair the failed stage and rerun the verified workflow before rolling.

### 3. Require verified promotion

The workflow builds in the private `serviceradar-builds` project, signs and verifies
there, checks registry capacity, and promotes the complete artifact graph into
`serviceradar`. Require a successful run and retain its promotion receipt. Use the
receipt's `published` roots to select protected `repository@sha256:...` references.
A build upload alone is not deployable. Never repair a failed promotion with a
direct push, tag copy, or manual protected-project signature append.

Keep each unchanged service at its existing digest. Do not copy unchanged tags
forward to create a common tag across a mixed deployment.

### 4. Pin verified digests with a PR into `demo/prod-release`

Inspect `helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml` on
`origin/demo/prod-release` and the currently rendered images. Create a feature
branch from that deployment branch. Set `image.digests.<service>` to each changed
service's verified protected digest (`webNg` and `core` for the web stack).
Preserve every unchanged service's digest and existing chart version. If an
unchanged service still uses a tag, resolve its current protected digest before
making the deployment bundle explicit.

Push only the feature branch with an explicit refspec and open a GitHub PR into
`demo/prod-release`. Include the publish run, reviewed commit, and protected
digest receipt. Do not remove digest pins or substitute a global mutable tag.
Do not patch the Argo Application: its source file owns Helm parameters.

### 5. Let Argo roll it

`serviceradar-demo-prod` has automated sync on (prune and self-heal off), so
after the PR merges Argo picks up the new `demo/prod-release` revision by
itself. Do not sync manually and do not patch the Application. Confirm:

```bash
kubectl --context carverauto get application -n argocd serviceradar-demo-prod \
  -o jsonpath='{.status.sync.revision}{"|"}{.status.sync.status}{"|"}{.status.health.status}{"|"}{.status.operationState.phase}{"|"}{.status.operationState.operation.initiatedBy.automated}{"\n"}'
kubectl --context carverauto get deploy -n demo \
  serviceradar-web-ng serviceradar-core serviceradar-agent serviceradar-agent-gateway \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

The sync revision must be the merge commit of the pin PR. Kyverno sets
`mutateDigest: true`, so admitted pods show `:<tag>@sha256:...`; compare that
digest with the one you verified.

Do not call demo finished until new pods are Running on the verified protected digests and Argo
reports `Synced|Healthy|Succeeded` for that revision. Report the tag, test
branch, publish run id, the protected digests in the workflow promotion receipt, the pin PR, and the Argo status.

After testing, `$release-cut-and-demo-roll` returns demo to the semver path. Do
not push a `v*` release tag during the test window.

---

## farm01 roll

Publish with the same in-cluster `publish-oci.yml` workflow above and require its
verified promotion receipt. Raw Bazel push targets only upload disposable build
artifacts; retired workstation launchers refuse publication.

Inspect `helm get values serviceradar -n serviceradar` and the current chart
version. Keep the installed chart when the task changes only images. Use
`helm upgrade --reuse-values` with `--set image.digests.<service>=sha256:<digest>`
for each changed service, using only digests from the protected promotion receipt.
Keep unchanged digest pins. Preserve cluster-specific values and wait for rollout
completion. Record the same digest changes in the owning GitOps values file when
that repository update is within the authorized task.

Verify rendered workload references and actual running image IDs, then report the
publish run, protected digests, Helm revision, and any workload that is not Ready.

## Operational notes (any namespace)

### `kubectl set image` poisons later Helm upgrades

A hand-run `kubectl set image` takes server-side-apply ownership of
`.spec.template.spec.containers[].image` under the `kubectl-set` field manager,
and every later `helm upgrade` then fails with:

```
Apply failed with 1 conflict: conflict with "kubectl-set" using apps/v1
```

Resetting `metadata.managedFields` to `[{}]` does NOT fix it on its own -- the
fields are re-attributed to a synthetic `before-first-apply` manager and the
conflict count goes UP. The fix is Helm 4's `--force-conflicts`, which takes
ownership in place (unlike `--force-replace`, which recreates the resource):

```bash
helm upgrade serviceradar ./helm/serviceradar -n <ns> --reuse-values --force-conflicts \
  --set image.digests.core=sha256:...
```

### Forcing scheduled work instead of waiting

Oban-scheduled maintenance can trickle. Drive it directly over the release RPC
rather than waiting for the next tick:

```bash
kubectl exec -n <ns> <core-pod> -- /app/bin/serviceradar_core_elx rpc \
  'ServiceRadar.Inventory.Identity.DuplicateSweep.reconcile_duplicates() |> inspect() |> IO.puts()'
kubectl exec -n <ns> <core-pod> -- /app/bin/serviceradar_core_elx rpc \
  'ServiceRadar.Observability.NetflowExporterCacheRefreshWorker.perform(%Oban.Job{args: %{}}) |> inspect() |> IO.puts()'
```

Measured difference: the scheduled duplicate sweep was merging ~1 device per
run; the direct call merged all 11 outstanding in 1.5s.
