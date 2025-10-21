# Codex Agent Guide for ServiceRadar

This repository hosts the ServiceRadar monitoring platform. Use this file as the canonical guide when operating as a Codex agent.

## Project Overview

ServiceRadar is a multi-component system made up of Go services (core, sync, registry, poller, faker), OCaml SRQL service, Proton/Timeplus database integrations, a Next.js web UI, and supporting tooling. The repo contains Bazel and Go module definitions alongside Docker/Bazel image targets.

## Repository Layout

- `cmd/` – Go binaries (core, sync, poller, faker, kv, etc.).
- `pkg/` – Shared Go packages: identity map, registry, sync integrations, database clients.
- `ocaml/srql/` – SRQL translator and Dream-based service.
- `docs/docs/` – User and architecture documentation (notably `architecture.md`, `agents.md`).
- `k8s/demo/` – Demo cluster manifests (faker, core, sync, Proton, etc.).
- `docker/`, `docker/images/` – Container builds and push targets.
- `web/` – Next.js UI and API routes.
- `proto/` – Protobuf definitions and generated Go code.

## Build & Test Commands

- General Go lint/test: `make lint`, `make test`.
- Focused Go packages: `go test ./pkg/...`.
- OCaml SRQL tests: `cd ocaml && dune runtest srql/test`.
- Bazel tests/images: `bazel test --config=remote //...`, `bazel run //docker/images:<target>_push`.
- Web (Next.js) lint/build: `cd web && npm install && npm run lint && npm run build` (if needed).

Prefer Bazel targets when modifying code that already has BUILD files. Always run gofmt/dune fmt where applicable (Go formatting handled by `gofmt`, OCaml by dune).

## Coding Guidelines

- **Go**: run `gofmt` on modified files; keep imports organized; favor existing helper utilities in `pkg/`. Avoid introducing new dependencies without updating `go.mod` and Bazel `MODULE.bazel`/`MODULE.bazel.lock` if required.
- **OCaml**: use dune formatting; reuse existing modules under `ocaml/srql/`; add tests in `ocaml/srql/test` when touching translator logic.
- **Docs**: place new operational runbooks under `docs/docs/`; keep Markdown ASCII only.

## Operational Runbooks

Reference `docs/docs/agents.md` for: faker deployment details, Proton truncate/reseed steps, materialized view recreation, and stream replay commands. Use those instructions whenever resetting the demo environment or investigating canonical device counts.

## Common Commands & Tips

- Check demo pods: `kubectl get pods -n demo`.
- Scale sync: `kubectl scale deployment/serviceradar-sync -n demo --replicas=<n>`.
- Proton SQL helper (start toolbox pod with curl):
  ```bash
  kubectl run sql --rm -i --tty \
    --image=curlimages/curl:8.9.1 -n demo --restart=Never --command -- \
    sh -c "echo <BASE64_SQL> | base64 -d >/tmp/query.sql && \
           curl -sk -u default:<PASSWORD> --data-binary @/tmp/query.sql \
           https://serviceradar-proton:8443/?database=default"
  ```
- GH client is installed and authenticated
- 'bb' (BuildBuddy) client is available for any build issues
- bazel is our build system, we use it to build and push images
- Sysmon-vm hostfreq sampler buffers ~5 minutes of 250 ms samples; keep pollers querying at least once per retention window so cached CPU data stays fresh.

## Release Playbook

1. Prep metadata:
   - Update `VERSION` with the new semver (example: `1.0.54-pre1`).
   - Add a matching entry at the top of `CHANGELOG` that summarizes the release highlights.
   - Run `scripts/cut-release.sh --version <version> --dry-run` to confirm the changelog entry is detected before committing.
2. Tag the release:
   - Execute `scripts/cut-release.sh --version <version>` to stage `VERSION`/`CHANGELOG`, create the release commit, and author the annotated tag (append `--push` when you are ready to publish the refs).
3. Build and push Bazel images:
   - Authenticate to GHCR if needed: `./scripts/docker-login.sh`.
   - Run `bazel build --config=remote $(bazel query 'kind(oci_image, //docker/images:*)')` to ensure every container bakes successfully before publishing.
   - Run `bazel run --config=remote //docker/images:push_all`. This reuses the build artifacts, publishes `latest`, `sha-<commit>`, and short-digest tags, and refreshes the embedded `build-info.json`.
   - If a single image needs republishing, run `bazel run //docker/images:<target>_push` (for example `//docker/images:web_image_amd64_push`).
   - Capture the new image identifiers you care about (for example `git rev-parse HEAD` for the commit tag or the full digest printed during the push). You'll use these when refreshing Kubernetes.
4. Roll the demo namespace:
   - Restart workloads with `kubectl get deploy -n demo -o name | xargs -r -L1 kubectl rollout restart -n demo`.
   - Update any digest-pinned workloads (currently the `serviceradar-web` Deployment) so they point at the freshly pushed build, e.g. `kubectl set image deployment/serviceradar-web web=ghcr.io/carverauto/serviceradar-web:sha-$(git rev-parse HEAD) -n demo`.
   - Watch for readiness: `kubectl get pods -n demo` until all pods are `1/1` and `Running`.
5. Close out: verify the demo web UI reports the new version, file follow-up docs, and proceed with GitHub release packaging if required.

We track work in Beads instead of Markdown. Run `bd quickstart` to see how.

## When Updating This File

- Add new build/test commands when tooling changes.
- Document any new services, runbooks, or operational quirks using `bd`.
- Keep instructions synchronized with the latest bead notes and related documentation updates.
