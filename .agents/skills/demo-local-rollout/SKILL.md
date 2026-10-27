---
name: demo-local-rollout
description: Roll unpublished sha-... test images to farm01 or the carverauto demo cluster. Use when the user asks to deploy, refresh, roll, patch, or test code in demo, farm01, or "the farm cluster" before a release. Pick the cluster first. Carverauto/demo images are built in-cluster by publish-oci.yml on a test/demo-test-NN branch, verified and signed with the OpenBao release key, then pinned by a PR into demo/prod-release. farm01 is a helm --reuse-values roll with no signing. Do not use for release cuts or Docker Compose.
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
| Image build | In-cluster: `publish-oci.yml` on a `test/demo-test-NN` branch | Prefer the same in-cluster build; a workstation build only for one or two images (see the farm01 section) |
| How it rolls | PR into `demo/prod-release`, then Argo auto-sync of `serviceradar-demo-prod` | `helm upgrade --reuse-values` |
| Admission | Kyverno: images **must** be signed with OpenBao `cosign-release` | **No Kyverno.** Do **not** OpenBao-sign or port-forward the signer |
| Registry | Harbor `registry.carverauto.dev/serviceradar` | Same Harbor project (public; no pull secret) |
| Live tag source | `helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml` on `origin/demo/prod-release`, plus the Deployments in `demo` | `helm get values serviceradar -n serviceradar` (`global.imageTag`) |

Never apply the OpenBao / Kyverno / Argo path to farm01. Never helm-upgrade farm01 thinking it is demo.

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
pushes every publishable image as `sha-${COMMIT}` (and moves `latest`), signs
each pushed digest with `hashivault://cosign-release`, and runs
`scripts/verify-oci-publish.sh`. If it fails, read the failing step with
`gh run view <run-id> --log-failed` before retrying. A run that pushed and then
failed at signing still left usable images; continue to step 3, which signs
whatever is unsigned.

### 3. Verify every image, sign anything unsigned

A full-scope publish re-pushes even unchanged images, usually under new
digests, so a signature on the previous tag does not carry over. Check **every**
image demo pulls, not only the ones whose source changed.

Typical **demo** set: `arancini`, `serviceradar-agent`, `serviceradar-agent-gateway`, `serviceradar-core-elx`, `serviceradar-datasvc`, `serviceradar-db-event-writer`, `serviceradar-faker`, `serviceradar-flow-collector`, `serviceradar-log-collector`, `serviceradar-rperf-client`, `serviceradar-tools`, `serviceradar-trapd`, `serviceradar-trivy-sidecar`, `serviceradar-web-ng`, `serviceradar-zen`. Confirm against the live Deployments. `serviceradar-log-collector-tcp` shares the log-collector image.

```bash
for image in <each image in the set>; do
  ref="registry.carverauto.dev/serviceradar/${image}"
  digest="$(crane digest "${ref}:sha-${COMMIT}")" || { echo "MISSING  ${image}"; continue; }
  if cosign verify --key docs/cosign.pub --insecure-ignore-tlog=true "${ref}@${digest}" >/dev/null 2>&1; then
    echo "signed   ${ref}@${digest}"
  else
    echo "UNSIGNED ${ref}@${digest}"
  fi
done
```

`docs/cosign.pub` is the key the Kyverno `verify-serviceradar-images` policy
enforces. A `MISSING` image means the publish did not produce it; stop and
investigate rather than copying an old tag over it.

Sign each `UNSIGNED` digest by hand. OpenBao on the control plane is **HTTPS**;
a plaintext `http://127.0.0.1:18200` request returns
`Client sent an HTTP request to an HTTPS server`. In a separate shell:

```bash
kubectl --context carverauto port-forward -n openbao-system svc/openbao-active 18200:8200
```

Then mint a token for the `github-signing-runner` service account (namespace
`arc-systems`, the identity the workflow signs with) and log in with the
Kubernetes auth role of the same name. The JWT and Vault token stay in files:

```bash
SIGN_DIR="$(mktemp -d)"
chmod 700 "$SIGN_DIR"
OPENBAO_ADDR=https://127.0.0.1:18200
kubectl --context carverauto create token -n arc-systems github-signing-runner > "$SIGN_DIR/sa.jwt"
jq -n --arg role github-signing-runner --rawfile jwt "$SIGN_DIR/sa.jwt" \
  '{role: $role, jwt: ($jwt | rtrimstr("\n"))}' > "$SIGN_DIR/login.json"
curl -sS -k -X POST --data @"$SIGN_DIR/login.json" \
  "${OPENBAO_ADDR}/v1/auth/kubernetes/login" | jq -er '.auth.client_token' > "$SIGN_DIR/vault.token"

export VAULT_ADDR="$OPENBAO_ADDR"
export VAULT_TOKEN="$(cat "$SIGN_DIR/vault.token")"
export VAULT_SKIP_VERIFY=true
export COSIGN_KEY_REF=hashivault://cosign-release
export COSIGN_YES=true
export COSIGN_DOCKER_MEDIA_TYPES=1
export COSIGN_REFERRERS_MODE=legacy
export COSIGN_TLOG_UPLOAD=true
```

```bash
cosign sign --key "$COSIGN_KEY_REF" \
  registry.carverauto.dev/serviceradar/<image>@sha256:<digest>
```

Sign by digest, never by tag. Re-run the verify loop afterwards; every image
must report `signed`. Re-mint the Vault token on `403 permission denied`. When
done: `unset VAULT_TOKEN`, `rm -rf "$SIGN_DIR"`, and stop the port-forward.

### 4. Pin the tag with a PR into `demo/prod-release`

`serviceradar-demo-prod` tracks `helm/serviceradar` on the `demo/prod-release`
branch, and `helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml` in
that path REPLACES the Application's `spec.source.helm.parameters` at render
time. A `kubectl patch` of the Application parameters is inert: it persists in
the spec, the app reports `Synced|Healthy|Succeeded`, and the workload keeps the
old image (verified 2026-08-22 and 2026-08-23). Change the file, through a PR.

First check whether the chart differs between the branch and the build commit:

```bash
git fetch origin demo/prod-release
git diff --stat origin/demo/prod-release "${COMMIT}" -- helm/serviceradar/
```

If that is empty apart from the `.argocd-source-...` file, the tag is the only
change. If not, do not guess: the new images may need a chart change (bring
those hunks into the PR), or `demo/prod-release` may carry demo-only commits
that staging lacks (keep them). Review each hunk and say which it is in the PR
body.

```bash
SHORT="${COMMIT:0:10}"
git worktree add --no-track -b "demo/test-build-${SHORT}" \
  "/Volumes/Build/worktrees/demo-pin-${SHORT}" origin/demo/prod-release
cd "/Volumes/Build/worktrees/demo-pin-${SHORT}"
git config user.email   # check the commit identity before committing
# edit helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml:
#   the global.imageTag parameter value -> sha-<COMMIT>
git commit -am "ops(demo): roll test build ${SHORT}"
git push origin "demo/test-build-${SHORT}:refs/heads/demo/test-build-${SHORT}"
gh pr create --base demo/prod-release --head "demo/test-build-${SHORT}" \
  --title "ops(demo): roll test build ${SHORT}" \
  --body "<what the build contains, publish run id, verification and signing result>"
```

Check that the push line says `-> demo/test-build-<short>`, never
`-> demo/prod-release`.

Use `image.digests.<service>` parameters instead of `global.imageTag` only when
the user wants a single service moved. A digest pin overrides `global.imageTag`
for that service until someone removes it (see "The digest-pin trap" in
`$release-cut-and-demo-roll`).

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

Do not call demo finished until new pods are Running on `sha-<COMMIT>` and Argo
reports `Synced|Healthy|Succeeded` for that revision. Report the tag, test
branch, publish run id, which digests the workflow signed and which you signed
by hand, the pin PR, and the Argo status.

After testing, `$release-cut-and-demo-roll` returns demo to the semver path. Do
not push a `v*` release tag during the test window.

---

## farm01 roll (no signing)

### Get the images

Prefer the in-cluster build: steps 1 and 2 of the demo roll produce
`sha-<COMMIT>` for every image in the same Harbor project farm01 pulls from.
Skip demo steps 3 to 5; farm01 needs no signatures.

If a workstation build is unavoidable, the same warning applies: never run
`--remote_download_outputs=all` (or `make push_all`) over the full image set
from a workstation. It drags every large CAS blob through
`cache-proxy.carverauto.dev` and has taken the shared Envoy gateway down. Build
only the one or two images whose source changed, and copy the rest forward.

Changed-image map (`git diff --name-only <deployed>..HEAD`):

- `go/cmd/agent/**`, `go/pkg/agent/**`, `go/pkg/mtr/**` -> `serviceradar-agent`
- `elixir/serviceradar_agent_gateway/**`, shared agent control/proto -> `serviceradar-agent-gateway`
- `elixir/serviceradar_core/**`, `rust/srql/**` (NIF) -> `serviceradar-core-elx` (and usually `serviceradar-web-ng`)
- `elixir/web-ng/**` -> `serviceradar-web-ng`
- `proto/**` -> every image that consumes the changed generated code

Phoenix / mix.lock / `MODULE.bazel` / `rules_elixir` changes mean every Elixir
image changes; at that point use the in-cluster build.

Typical **farm01** set: `serviceradar-agent`, `serviceradar-agent-gateway`, `serviceradar-core-elx`, `serviceradar-datasvc`, `serviceradar-flow-collector`, `serviceradar-log-collector`, `serviceradar-rperf-client`, `serviceradar-tools`, `serviceradar-trapd`, `serviceradar-trivy-sidecar`, `serviceradar-web-ng`. farm01 usually has no faker, zen, bmp/`arancini`, or k8s-inventory. Do not copy demo-only images onto farm01.

#### Workstation build of one or two images

A worktree needs the gitignored Bazel rc files (BuildBuddy API key) or RBE
fails with `PERMISSION_DENIED: Missing API key`:

```bash
PRIMARY=/Users/mfreeman/src/serviceradar
WT="$(pwd)"
ln -sfn "$PRIMARY/.bazelrc.remote" "$WT/.bazelrc.remote"
test -e "$PRIMARY/.bazelrc.local" && ln -sfn "$PRIMARY/.bazelrc.local" "$WT/.bazelrc.local"
test -f "$WT/.bazelrc.remote"
```

Bazel profiles that exist: `remote` (RBE plus workstation-local caches),
`remote_base`, `cache_only`, `ci`. `remote_push` no longer exists. `crane` is on
`PATH` (Homebrew).

On Darwin, running an `oci_push` target through Bazel tries to execute
**linux** `jq`/`crane` from runfiles (`Exec format error`), so build the layout
and push with host `crane`. Name only the changed image targets, e.g.:

```bash
bazel build --config=remote_base --remote_download_outputs=toplevel --stamp \
  //docker/images:agent_image_amd64
```

Layouts land under `bazel-out/rbe_platform-opt/bin/docker/images/<name>_image_amd64`. Bazel blob files are often **symlinks** and **mode 0444**; `crane push` of the layout fails with `layout blob ... is a symlink`. Materialize, push by digest, tag **only** `sha-<commit>` (do not retag `latest`):

```bash
BIN="$(bazel info output_path)/rbe_platform-opt/bin/docker/images"
SRC="$BIN/agent_image_amd64"
DEST="$(mktemp -d)/sr-oci-agent"
mkdir -p "$DEST"
rsync -aL "$SRC/" "$DEST/"
chmod -R u+w "$DEST"
DIGEST=$(jq -r '.manifests[0].digest' "$DEST/index.json")
REPO=registry.carverauto.dev/serviceradar/serviceradar-agent
crane push "$DEST" "$REPO@$DIGEST"
crane tag "$REPO@$DIGEST" "sha-<commit>"
rm -rf "$DEST"
```

Copy every unchanged image forward from the tag farm01 runs:

```bash
crane copy \
  registry.carverauto.dev/serviceradar/<image>:<old-tag> \
  registry.carverauto.dev/serviceradar/<image>:sha-<new>
```

### Roll

```bash
export KUBECONFIG="$HOME/.kube/farm01.yaml"
helm get values serviceradar -n serviceradar
helm upgrade serviceradar "$CHECKOUT/helm/serviceradar" \
  -n serviceradar \
  --reuse-values \
  --set image.digests.<service>=sha256:<digest> \
  --rollback-on-failure \
  --timeout 15m
```

Use `global.imageTag=sha-<new>` ONLY when every first-party image should move
(the in-cluster build gives you all of them). For a change touching one or two
services, pin those with `image.digests.<service>` -- farm01 already carries
digest pins for `core` and `webNg`, so you are updating an existing pin, not
introducing a new mechanism. Service keys are the `image.tags` names (`core`,
`webNg`, `agent`, `agentGateway`, ...).

`--reuse-values` keeps farm01-only settings (MetalLB VIPs, Gateway API attach, Trivy sidecar, empty `registryPullSecret`, `local-path` storage). Do not replace the live values file unless the user wants those template/value changes applied.

Use the local chart when `helm/` matches the live chart version (`helm get metadata serviceradar -n serviceradar`). If `helm/` diverged and the user only asked for new images, keep the live chart and only change `global.imageTag` (OCI `oci://registry.carverauto.dev/serviceradar/charts/serviceradar --version <live>` plus `--reuse-values --set global.imageTag=...`).

Update `~/src/gitops/clusters/farm01/serviceradar/values.yaml` `global.imageTag` so GitOps matches live. Do **not** commit or push the gitops repo unless the user asks.

Verify:

```bash
for d in serviceradar-web-ng serviceradar-core serviceradar-agent serviceradar-agent-gateway; do
  kubectl rollout status deploy/"$d" -n serviceradar --timeout=180s
done
kubectl get deploy -n serviceradar \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
kubectl get pods -n serviceradar
```

Done when key deployments show `sha-<new>` and pods are Ready. Report the tag, how the images were built (in-cluster run id, or rebuilt vs copied), digests, helm revision, and any non-Ready pods. Do not mention signing.

---

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
