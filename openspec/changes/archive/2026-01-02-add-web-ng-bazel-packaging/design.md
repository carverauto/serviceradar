## Context
The Phoenix/LiveView `web-ng` app currently builds via Mix/Compose only. All other components ship through Bazel with rules_oci + rules_pkg for OCI images and RPM/DEB installers. Kubernetes cutover tasks (add-serviceradar-web-ng-foundation §7) depend on having Bazel-built images. We need a hermetic, RBE-friendly path to compile assets, run `mix release`, and package the release for containers and system packages without relying on host toolchains.

## Goals / Non-Goals
- Goals: hermetic Bazel targets for `mix assets.build` + `mix release`; OCI image under //docker/images; RPM/DEB packages under //packaging using existing macros; push targets wired into push_all; docs/runbooks updated.
- Non-Goals: removing the legacy `serviceradar-web` targets; redesigning Phoenix runtime configuration; introducing a new router/ingress story (covered by existing k8s cutover tasks).

## Decisions
- Toolchains: add `rules_elixir` (with Erlang/Elixir pinned) and reuse existing `rules_nodejs`/`aspect_rules_js` for npm/esbuild/tailwind; configure hex/rebar caches for RBE.
- Build shape: create `mix_release` (or equivalent genrule) producing a tarball artifact; feed that into both OCI layer and pkg rules. Compile assets via `mix assets.build` inside the Bazel action.
- Base image: prefer Debian bookworm-slim (already pulled as `@debian_bookworm_slim`) for GLIBC-compatible Phoenix release; keep PATH/env consistent with other images.
- Packaging layout: install release under `/usr/local/share/serviceradar-web-ng`, place config in `/etc/serviceradar/web-ng.env` (or `.json`), ship systemd unit `serviceradar-web-ng.service` that runs the release start script.
- Versioning/tagging: derive package versions from repo `VERSION`; image tags follow existing ghcr patterns (`:sha-<commit>` + `:latest`), and write `build-info.json` like other images.

## Risks / Trade-offs
- Hermetic toolchains will increase fetch time (Erlang/Elixir + Node) but reduce flakiness; mitigate with shared RBE caches.
- Phoenix releases need runtime secrets (DB creds, SRQL settings); packaging must default to env-based config without baking secrets into images.
- Asset build reproducibility depends on npm registry availability; may need offline cache/bazel fetch pins.
- Size: including full release + assets may inflate RPM/DEB; ensure `priv/static` is minified and node_modules not shipped.

## Migration Plan
1) Add Bazel toolchains and basic release target; prove `bazel build //web-ng:release_tar` works locally + RBE.
2) Add OCI image and push target; smoke test container boot with env overrides.
3) Add RPM/DEB packaging; validate in minimal Debian/EL containers.
4) Wire push_all/Makefile + docs; keep legacy web targets until k8s/compose consumers switch to `serviceradar-web-ng`.

## Open Questions
- Do we need multi-arch (arm64) immediately, or is amd64 sufficient for demo/k8s? (default to amd64 first.)
- Should the package name be `serviceradar-web-ng` or replace `serviceradar-web`? (assume new name to avoid collisions.)
- Which config file format best aligns with Phoenix runtime—ENV (.env) vs JSON? (leaning .env to match release expectations.)
- Do we need Kong/Nginx sidecars in the OCI image, or will Phoenix serve directly? (assume Phoenix-only image; ingress handled by deployment.)
