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

We track work in Beads instead of Markdown. Run `bd quickstart` to see how.

## When Updating This File

- Add new build/test commands when tooling changes.
- Document any new services, runbooks, or operational quirks.
- Keep instructions synchronized with `docs/docs/agents.md` and other documentation updates.

