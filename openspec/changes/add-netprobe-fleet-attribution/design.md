## Context

netprobe is a native add-on delivering eBPF process attribution (flow→PID) plus an
optional passive packet-capture/DPI feature. Attribution is the high-value,
fleet-wide capability; capture/DPI is a targeted, interface-specific feature.

Today the two are entangled at three layers:
1. **Agent** — `applyVisibilityConfigLaunched` only started netprobe when
   `netprobeConfigHasWork` was true, and that required capture interfaces + device
   bindings. (Fixed in v1.2.90: it now starts on `enabled` alone.)
2. **Config schema / UI** — the operator form renders every property of the
   add-on's `config_schema`, capture fields included and unmarked, so a fleet
   rollout appears to demand per-agent NIC lists.
3. **Seeding** — `NetprobeAddonPackageSeeder` builds the `AddonPackage` from a
   hardcoded `@version "0.1.0"` and runtime-config artifact refs, no-ops without
   artifacts, and never re-derives version/schema from the in-image manifest. The
   demo package was therefore frozen at `0.1.0` with a stale schema.

## Goals / Non-Goals

- Goals: a single fleet-wide "Enable" produces attribution on any number of agents
  with zero interface config; published add-on version + schema reach operators on
  release; capture/DPI remain available but optional/advanced.
- Non-Goals: auto-selecting capture interfaces for the capture/DPI feature (a
  separate follow-up); changing the attribution correlation pipeline; per-tenant
  add-on catalogs.

## Decisions

- **Attribution is capture-independent.** netprobe's kprobes attach kernel-wide
  regardless of `capture_interfaces`; `enabled` alone is sufficient "work" to run
  and keep netprobe up. Capture/DPI engage only when interfaces/bindings are set.
- **Manifest is the source of truth for version + schema.** The seeder reads
  `version` and `config_schema` from the in-image `addons/netprobe/addon.yaml` +
  `config.schema.json` (already compiled in via `@config_schema`). Signed artifact
  refs (object_key/sha256/signature, OCI digest) still come from the published
  bundle config, because operators must never be able to assign artifacts the agent
  cannot verify. When the manifest version advances but no matching signed
  artifacts are configured, the seeder stages (does not approve) the new version so
  the gap is visible rather than silently frozen.
- **Advanced grouping via schema hints.** Mark capture/DPI/device-binding
  properties with an `x-serviceradar-ui-advanced` (or reuse the existing
  `x-serviceradar-ui-*`) hint; the web-ng config form renders flagged properties in
  a collapsed "Advanced" section and treats none of them as required. Attribution
  needs only `enabled`.
- **Republish on release** keeps the published artifacts and the seeder's manifest
  version aligned per release tag.

## Risks / Trade-offs

- Auto-enabling attribution fleet-wide increases eBPF load across many hosts →
  bounded: attribution is the lightweight kprobe path (ring-drain, ~0 idle CPU
  after the v1.2.86 rewrite); no AF_XDP/capture unless explicitly opted in.
- Manifest-driven seeding could surface a version with no signed artifacts → stage
  (not approve) so it is reviewable, never assignable unverified.
- UI advanced-collapse must not hide required fields → attribution requires no
  capture fields, so none of the collapsed fields are required.

## Migration Plan

- The frozen demo `netprobe@0.1.0` package is updated in place by the seeder once
  it re-derives version/schema from the manifest (no manual DB edit required after
  deploy). Existing assignments keep working; their params are normalized against
  the new schema.
- No data migration; schema/version changes are additive.

## Open Questions

- Should capture-interface auto-detection (default-route-aware, never the primary
  NIC) ship here or as a separate capture-focused change? (Proposed: separate.)
- Where do signed artifact refs live long-term — derived from the published import
  index automatically, vs. the current runtime config? (Proposed: wire the
  native-addons import index into the seeder config as a follow-up.)
