---
name: demo-local-rollout
description: Build unpublished sha-... images and roll them to farm01 or the carverauto demo cluster. Use when the user asks to deploy, refresh, roll, patch, or test code in demo, farm01, or "the farm cluster" before a release. Pick the cluster first. Carverauto/demo requires OpenBao cosign and Argo. farm01 is a helm --reuse-values roll with no signing. Do not use for release cuts or Docker Compose.
---

# Local Image Rollout

Use this skill for unpublished `sha-<git-sha>` test tags. Formal releases use semver and `$release-cut-and-demo-roll`.

## Choose the cluster first

Do this before Harbor auth, Bazel, signing, or any cluster write.

| | **carverauto `demo`** | **farm01** |
|---|---|---|
| When | User says demo, carverauto, or does not name a cluster | User says farm01, farm cluster, or is already on the farm01 kubeconfig |
| Kubeconfig | default / carverauto control plane | `export KUBECONFIG="$HOME/.kube/farm01.yaml"` |
| Namespace | `demo` | `serviceradar` |
| How it rolls | Argo app `serviceradar-demo-prod` | `helm upgrade --reuse-values` |
| Admission | Kyverno: images **must** be signed with OpenBao `cosign-release` | **No Kyverno.** Do **not** OpenBao-sign or port-forward the signer |
| Registry | Harbor `registry.carverauto.dev/serviceradar` | Same Harbor project (public; no pull secret) |
| Live tag source | Deployments in `demo`, plus git override on `demo/prod-release` | `helm get values serviceradar -n serviceradar` (`global.imageTag`) |

Never apply the OpenBao / Kyverno / Argo path to farm01. Never helm-upgrade farm01 thinking it is demo.

If only `elixir/web-ng/**` changed **and** the target is `demo`, prefer `$demo-web-ng-fastpath`. That fast path is demo-only.

## Shared workflow

1. Work from the checkout that has the commits under test (often a git worktree).
2. Symlink gitignored Bazel rc files if this is not the primary clone (see below).
3. Tag: `sha-$(git rev-parse HEAD)` (full 40-char SHA; that is what `--stamp` emits).
4. Read the **currently deployed** tag on the chosen cluster before changing anything.
5. Map `git diff --name-only <deployed>..HEAD` to images. Rebuild only what changed.
6. Harbor auth: `./buildbuddy_setup_docker_auth.sh`
7. Build and push changed images. Copy unchanged images from the live tag to the new tag.
8. **Then** follow the cluster-specific roll section. Stop after that section; do not run the other cluster's roll.

Do not cut a release, edit `VERSION`, or create git tags. Do not roll `demo-staging`, production, or Docker Compose unless the user changes scope. Never push to `staging`.

## Worktree Bazel remotes

`.bazelrc` try-imports `%workspace%/.bazelrc.remote` and `.bazelrc.local`. Both are gitignored (BuildBuddy API key). `git worktree add` does not copy them. Without them, `--config=remote_base` / `--config=ci` fails with `PERMISSION_DENIED: Missing API key`.

From the primary clone that already has the files:

```bash
PRIMARY=/Users/mfreeman/src/serviceradar
WT="$(pwd)"
ln -sfn "$PRIMARY/.bazelrc.remote" "$WT/.bazelrc.remote"
test -e "$PRIMARY/.bazelrc.local" && ln -sfn "$PRIMARY/.bazelrc.local" "$WT/.bazelrc.local"
test -f "$WT/.bazelrc.remote"
```

## Changed image selection

```bash
git diff --name-only <currently-deployed-sha-or-tag>..HEAD
```

- `go/cmd/agent/**`, `go/pkg/agent/**`, `go/pkg/mtr/**` -> `serviceradar-agent`
- `elixir/serviceradar_agent_gateway/**`, shared agent control/proto -> `serviceradar-agent-gateway`
- `elixir/serviceradar_core/**`, `rust/srql/**` (NIF) -> `serviceradar-core-elx` (and usually `serviceradar-web-ng`)
- `elixir/web-ng/**` -> `serviceradar-web-ng`
- `proto/**` -> every image that consumes the changed generated code

When in doubt, rebuild slightly too much. Phoenix / mix.lock / `MODULE.bazel` / `rules_elixir` changes mean rebuild every Elixir image you will roll.

## Images that use `global.imageTag`

Copy or rebuild every first-party image the target cluster will pull at the new tag. Inspect live deployments; do not copy demo-only images onto farm01.

Typical **demo** set: `arancini`, `serviceradar-agent`, `serviceradar-agent-gateway`, `serviceradar-core-elx`, `serviceradar-datasvc`, `serviceradar-db-event-writer`, `serviceradar-faker`, `serviceradar-flow-collector`, `serviceradar-log-collector`, `serviceradar-rperf-client`, `serviceradar-tools`, `serviceradar-trapd`, `serviceradar-trivy-sidecar`, `serviceradar-web-ng`, `serviceradar-zen`.

Typical **farm01** set: `serviceradar-agent`, `serviceradar-agent-gateway`, `serviceradar-core-elx`, `serviceradar-datasvc`, `serviceradar-flow-collector`, `serviceradar-log-collector`, `serviceradar-rperf-client`, `serviceradar-tools`, `serviceradar-trapd`, `serviceradar-trivy-sidecar`, `serviceradar-web-ng`. farm01 usually has no faker, zen, bmp/`arancini`, or k8s-inventory.

`serviceradar-log-collector-tcp` shares the log-collector image. Do not invent a separate tag for it.

## Build and push changed images

`crane` is on `PATH` (Homebrew). Do not assume `/tmp/gobin/crane`.

Staging no longer defines the legacy `remote` / `remote_push` profiles; the
surviving ones are `remote_base`, `cache_only`, and `ci`.

On a Darwin workstation, running an `oci_push` target through Bazel builds
linux/amd64 on RBE and then tries to execute **linux** `jq`/`crane` from
runfiles (`Exec format error`). On macOS use `make push_all`, which routes
through `scripts/push_all_images.sh` and pushes with host `crane`.

Build the OCI layouts remotely, then push with host `crane`:

```bash
bazel build \
  --config=remote_base \
  --noenable_platform_specific_config \
  --remote_download_outputs=all \
  --compilation_mode=opt \
  --stamp \
  //docker/images:agent_image_amd64 \
  //docker/images:agent_gateway_image_amd64 \
  //docker/images:core_elx_image_amd64 \
  //docker/images:web_ng_image_amd64
```

Layouts land under `bazel-out/rbe_platform-opt/bin/docker/images/<name>_image_amd64`. Bazel blob files are often **symlinks** and **mode 0444**; `crane push` of the layout fails with `layout blob ... is a symlink`. Materialize, push by digest, tag **only** `sha-<commit>` (do not retag `latest`):

```bash
BIN="$(bazel info output_path)/rbe_platform-opt/bin/docker/images"
# or the execroot path printed by the build
SRC="$BIN/agent_image_amd64"
DEST=/tmp/sr-oci-agent
rm -rf "$DEST"
mkdir -p "$DEST"
rsync -aL "$SRC/" "$DEST/"
chmod -R u+w "$DEST"
DIGEST=$(jq -r '.manifests[0].digest' "$DEST/index.json")
REPO=registry.carverauto.dev/serviceradar/serviceradar-agent
crane push "$DEST" "$REPO@$DIGEST"
crane tag "$REPO@$DIGEST" "sha-<commit>"
rm -rf "$DEST"
```

Repeat for each rebuilt image. Capture every digest.

On a Linux host the push targets can be run directly, since the runfiles
`jq`/`crane` are the right architecture there. Use `remote_base` for the build;
the `remote_push` profile referenced by older runbooks no longer exists.

## Copy unchanged images forward

```bash
crane copy \
  registry.carverauto.dev/serviceradar/<image>:<old-tag> \
  registry.carverauto.dev/serviceradar/<image>:sha-<new>
```

`<old-tag>` is whatever the cluster is running (`v1.4.31`, `sha-<old>`, etc.). If `crane digest` of old and new match, the copy is a retag and existing signatures (if any) still apply.

---

## farm01 roll (no signing)

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

Use `global.imageTag=sha-<new>` ONLY when every first-party image should move.
For a change touching one or two services, pin those with
`image.digests.<service>` (see "Move only the services you changed") -- farm01
already carries digest pins for `core` and `webNg`, so you are updating an
existing pin, not introducing a new mechanism.

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

Done when key deployments show `sha-<new>` and pods are Ready. Report the tag, rebuilt vs copied images, digests, helm revision, and any non-Ready pods. Do not mention signing.

---

## carverauto `demo` roll (sign, then Argo)

`demo` admission is Kyverno-enforced. Sign every **rebuilt** digest with OpenBao `cosign-release` **before** changing the Argo app. Copied-forward images whose digest is unchanged keep their existing signatures.

OpenBao on the control plane is **HTTPS**. A plaintext `http://127.0.0.1:18200` health check returns `Client sent an HTTP request to an HTTPS server`.

```bash
kubectl port-forward -n openbao-system svc/openbao-active 18200:8200
```

```bash
OPENBAO_ADDR=https://127.0.0.1:18200
OPENBAO_K8S_ROLE=forgejo-signing-runner
sa_jwt="$(kubectl create token -n forgejo-actions forgejo-signing-runner)"
vault_token="$(curl -skS \
  -H 'Content-Type: application/json' \
  -d "{\"role\":\"${OPENBAO_K8S_ROLE}\",\"jwt\":\"${sa_jwt}\"}" \
  "${OPENBAO_ADDR}/v1/auth/kubernetes/login" | jq -er '.auth.client_token')"
export VAULT_ADDR="$OPENBAO_ADDR"
export VAULT_TOKEN="$vault_token"
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

Re-mint the Vault token on `403 permission denied`. Tear down the port-forward when signing is done.

### The Argo Application spec is NOT the lever

`serviceradar-demo-prod` tracks `helm/serviceradar` on the **`demo/prod-release`
branch of the serviceradar repo itself**, and that path contains
`.argocd-source-serviceradar-demo-prod.yaml`, whose `helm.parameters` OVERRIDE
the Application's own `spec.source.helm.parameters`.

Verified 2026-08-23: the Application spec said
`image.digests.webNg=sha256:457a2b5c...` while the running pod was
`sha256:94bf165f...`, and Argo still reported `Synced`. A
`kubectl patch application ... spec.source.helm.parameters` is reverted on the
next sync. **Edit the file on `demo/prod-release` and push**, then sync:

```bash
git worktree add --no-track -b <tmp> /tmp/wt-demo-release github/demo/prod-release
# edit helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml
git push github HEAD:refs/heads/demo/prod-release
kubectl patch application -n argocd serviceradar-demo-prod --type merge \
  -p '{"operation":{"sync":{"revision":"demo/prod-release"}}}'
```

If the Application parameter and the running image disagree while Argo says
`Synced`, that file is why -- do not "fix" it by patching the Application.

### Build from a fresh git worktree

Work in a worktree so concurrent agents do not share a checkout. Two things bite
on a *fresh* one, both verified 2026-08-23:

1. Symlink the gitignored Bazel rc files before any bazel command (repo Hard
   Rules). Without them RBE fails with `PERMISSION_DENIED: Missing API key`.

2. **Build once before `make push_all`.** `scripts/push_all_images.sh` resolves
   `bazel info bazel-bin` and then checks `! -d` on the result *before* it builds
   anything. On a fresh worktree that directory does not exist yet, so the script
   dies with:

   ```
   error: unable to resolve bazel-bin
   ```

   which reads like a credentials or config problem and is not. `bazel info`
   alone succeeds, which makes it more confusing. Prime the output tree first:

   ```bash
   bazel build -c opt --config=remote --remote_download_outputs=toplevel //docker/images:images
   make push_all PUSH_TAG="sha-$(git rev-parse HEAD)"
   ```

### Move only the services you changed

Use `image.digests.<service>`, not `global.imageTag`, unless every first-party
image really should move. `global.imageTag` rolls the whole set for a
two-service change; `image.digests.<service>` short-circuits ahead of it in
`serviceradar.imageRefSuffix`, so everything else stays on the release tag and
only the changed services need signing. Service keys are the `image.tags` names
(`core`, `webNg`, `agent`, `agentGateway`, ...).

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

### Argo / Image Updater

`serviceradar-demo-prod` uses argocd-image-updater with `write-back-method: git` to `demo/prod-release`.

**A live `kubectl patch` of `spec.source.helm.parameters` is INERT, not merely racy.** Verified
2026-08-22: `helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml` on `demo/prod-release`
REPLACES the parameter list at render time. A patched parameter persists in the Application spec
and the app reports `Synced|Healthy|Succeeded`, while the workload keeps the old image, because
only the parameters in that file reach Helm. Every parameter you need — `global.imageTag`, and
`image.digests.<service>` if you are moving a single service — must be committed to that file on
`demo/prod-release`. Do not diagnose this as a slow rollout; check the rendered image, not the
sync status.

Contention-free `sha-...` flow:

1. Advance `demo/prod-release` so chart content matches the images, and in the same commit set `global.imageTag: sha-<commit>` in `.argocd-source-serviceradar-demo-prod.yaml`.
2. Patch `spec.source.targetRevision` to that commit (and align the live `global.imageTag` parameter).
3. Do not push a `v*` release tag during the test window (`allow-tags` is `^v[0-9]+\.[0-9]+\.[0-9]+$`).
4. After testing, `$release-cut-and-demo-roll` returns demo to the semver / Image Updater path.

One-off parameter patch (can lose a race with git write-back):

```bash
kubectl patch application -n argocd serviceradar-demo-prod \
  --type merge \
  -p '{"spec":{"source":{"helm":{"parameters":[{"name":"global.imageTag","value":"sha-<new>"}]}}}}'
```

Wait for `Synced|Healthy|Succeeded`:

```bash
kubectl get application -n argocd serviceradar-demo-prod \
  -o jsonpath='{.status.sync.status}{"|"}{.status.health.status}{"|"}{.status.operationState.phase}{"\n"}'
kubectl get deploy -n demo \
  serviceradar-web-ng serviceradar-core serviceradar-agent serviceradar-agent-gateway \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

Do not call demo finished until new pods are Running and Argo reports `Succeeded`. Report the tag, rebuilt vs copied, signed digests, and Argo status.
