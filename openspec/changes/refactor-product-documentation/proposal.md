# Change: Refactor and Clean Up the Public Product Documentation

## Why

The public Docusaurus docs site (`docs/docs/`, served at `docs.serviceradar.cloud`) has
drifted. A full audit of all 53 pages found:

- **Internal and customer-specific content is published.** `fieldsurvey-sidekick.md`
  exposes a real lab device (IPs `192.168.1.73/74`, SSH user `mfreeman`, a HackRF
  hardware serial, `test-token` credentials). `wifi-map-local-compose.md` is an entire
  runbook for one named customer's proprietary data. Multiple pages hardcode the `demo`
  namespace, demo pod names, internal hosts (`code.carverauto.dev`,
  `registry.carverauto.dev`, `staging.serviceradar.cloud`), internal tooling (`Beads`/`bd`),
  and dated benchmark/snapshot data from local dev runs.
- **SDK and WASM plugin reference is maintained twice.** `wasm-plugins.md` (618 lines) and
  the SDK pages duplicate material that belongs on `developer.serviceradar.cloud`. The
  team does not want to maintain two sources of truth for `serviceradar-sdk-go`,
  `serviceradar-sdk-rust`, `serviceradar-sdk-dashboard`, and WASM plugin authoring.
- **Stale and inaccurate content.** `trivy-integration.md` wrongly says the integration
  was "retired" (it was only switched off in the demo environment). `device-configuration.md`
  documents the retired Go-core `/api/query` + `X-API-Key` HTTP API. `bgp-routing.md`'s
  architecture diagram says "TimescaleDB" and uses a stale stream name. `netflow.md` and
  `troubleshooting-guide.md` carry `0.7.1`/`0.8.0`-era content and a dead UI port.
- **Naming.** "God-View" reads unprofessionally in published docs.
- **Weak SRQL onboarding.** SRQL is a core differentiator but has a single dense reference
  page with internal inaccuracies and no learning path.
- **Incoherent information architecture.** Contributor-only pages, dev-only runbooks,
  near-duplicate Falco pages, inconsistent frontmatter, and unresolved `TODO` placeholders
  make the site hard to navigate for both new and experienced users.
- **Inconsistent visual identity.** The docs site uses a stock Docusaurus look — an indigo
  (`#4f46e5`) primary and the Dracula code theme — that does not match the ServiceRadar web
  app (`serviceradar-web`), which uses a sky/teal/orange palette on a navy dark base. The
  docs, the app, and the developer portal should share one design theme.

The goal is to remove stale and internal content and reorganize what remains into a
cohesive, concise documentation system that new and experienced users can use to learn the
platform, deploy it, get data in, query it, and troubleshoot.

## What Changes

- **Scrub internal/opsec exposure** from all pages: remove real device identifiers,
  internal hostnames, demo-environment specifics, credentials, internal tooling references,
  and dated dev-run snapshots; replace with placeholders or generic guidance.
- **Remove customer-specific content.** Delete `wifi-map-local-compose.md` (a single
  customer's proprietary-data runbook). **BREAKING** for anyone deep-linking it.
- **Remove dev-only and contributor-only pages from the public site:**
  `repository-layout.md`, `rust-bazel-deps.md`, `topology-reset-rebuild.md`,
  `camera-analysis-reference-worker.md`, and `cnpg-pg18-upgrade-and-search-policy.md`.
  Content with ongoing internal value (topology reset, wifi-map) is preserved by relocating
  it to the gitops repo before deletion.
- **Make `developer.serviceradar.cloud` the single source of truth for SDKs and WASM
  plugin authoring.** Reduce `wasm-plugins.md` and the SDK pages to high-level conceptual
  overviews ("what it is, when to use it, the import/approval workflow") that link to the
  developer portal; remove duplicated manifest/result schemas, build instructions, and SDK
  code samples.
- **Rename "God-View" to "Network Topology"** in all prose, headings, the page filename,
  and the sidebar. Code identifiers (`SERVICERADAR_GOD_VIEW_ENABLED`, `GodViewStream`,
  `god_view_disabled`) are unchanged.
- **Correct the Trivy documentation:** present the Trivy integration as supported but
  currently disabled in the demo environment, not retired.
- **Fix stale architecture and diagrams:** correct the BGP and other diagrams to the
  current platform (Elixir control plane, CNPG + TimescaleDB + AGE, NATS JetStream,
  agent-gateway), remove the retired `/api/query` API docs and version-specific historical
  content, and reconcile inconsistent service names.
- **Build robust SRQL documentation:** a multi-page "Query with SRQL" section — a guided
  Tutorial, a complete Reference, and a task-oriented Cookbook.
- **Reorganize the information architecture:** task-based sidebar sections, consistent
  frontmatter on every page, merged duplicate Falco pages, merged self-signed stub into
  TLS, resolved `TODO`/screenshot placeholders, and a docs build that passes with no
  broken links.
- **Re-theme the docs site to match `serviceradar.cloud`:** adopt the shared sky/teal/orange
  palette on a navy dark base by mapping the color tokens onto the Docusaurus Infima
  variables, drop the Dracula code theme for a coordinated one, and align the code font, so
  the docs site, the web app, and the developer portal present one consistent design theme.
- **Refresh positioning and the landing page:** reposition ServiceRadar as an IT operations
  and network management platform with built-in observability and security analytics
  (updating the hero, `intro.md`, and the site tagline from "a distributed network
  monitoring system"), replace the landing page's emoji feature icons with clean themed
  icons, and remove the fabricated usage statistics.

## Impact

- Affected specs: `product-documentation` (new capability)
- Affected code:
  - `docs/docs/*.md` — content edits, removals, new SRQL pages
  - `docs/sidebars.ts` — restructured navigation
  - `docs/docusaurus.config.ts` — prism theme swap, code font, redirects for removed pages
  - `docs/src/css/custom.css` — palette re-theme to match `serviceradar-web`
  - No application or runtime code changes
- Reference: `https://serviceradar.cloud` is the authoritative design reference for the
  shared palette; `~/src/serviceradar-web/assets/css/app.css` provides the documented
  starting tokens, to be verified against the live site.
- Out of scope: changes to `developer.serviceradar.cloud`; relocating preserved
  dev/demo content into the `gitops` repo is a manual follow-up the author performs
  outside this repo.
