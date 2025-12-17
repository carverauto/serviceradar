# Change: Add Bazel build + packaging for web-ng Phoenix UI

## Why
- The Phoenix-based `web-ng` UI must ship the same way as the rest of ServiceRadar: reproducible Bazel builds, OCI images, and RPM/DEB packages.
- Today the Bazel + rules_pkg/rules_oci pipeline only targets the legacy Next.js UI; web-ng is Docker Compose-only and cannot be promoted to k8s or installers.
- We need consistent build inputs (OTP/Elixir/Node) and tagged artifacts so release/push workflows and demo cutovers can include web-ng.

## What Changes
- Introduce Bazel targets that run `mix assets.build` + `mix release` for `web-ng` with pinned OTP/Elixir/Node toolchains (RBE-friendly, no host deps).
- Add OCI image build(s) under `//docker/images` for `serviceradar-web-ng`, using the Phoenix release bundle and a lightweight base image.
- Add RPM/DEB packaging under `//packaging/web-ng` with systemd unit, config defaults, and versioning aligned to the repo `VERSION` file.
- Wire image + package push targets into existing `make push_all` / `bazel run //docker/images:push_all` flows and document the new outputs.
- Keep legacy `serviceradar-web` artifacts intact during transition; clearly mark new tags/package names to avoid collisions.

## Impact
- Affected specs: new `web-ng-build` capability (Bazel release, OCI, RPM/DEB, push integration).
- Affected code: `web-ng/**` (build tooling only), `docker/images/**`, `packaging/**`, `MODULE.bazel` (new toolchains), release/push scripts.
- Consumers: demo k8s/Helm, Docker Compose (optional), RPM/DEB users.
