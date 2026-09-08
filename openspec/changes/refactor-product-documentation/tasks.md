# Tasks: Refactor and Clean Up the Public Product Documentation

All paths are under `docs/docs/` unless noted.

## 1. Scrub internal / opsec exposure

- [x] 1.1 `fieldsurvey-sidekick.md` — removed lab device specifics (IPs, SSH user, HackRF
  serial, hardware inventory, example credentials); rewritten as a feature page with
  placeholders; "Next Implementation Step" dev roadmap deleted.
- [x] 1.2 `discovery.md` — removed the "Demo Validation" section (device UID, CHR IP,
  `kubectl exec -n demo` commands, DB-credential examples).
- [x] 1.3 `cnpg-monitoring.md` — `demo` namespace and pod names generalized; dated demo
  baseline snapshot removed.
- [x] 1.4 `remote-access.md` — removed the "Private HTTP Echo Demo" demo specifics; fixed
  the broken "Host Key Trust" section structure.
- [x] 1.5 `remote-access-rdp.md` — removed the "Demo Proof Path"; IP placeholdered;
  experimental status flagged.
- [x] 1.6 `wasm-plugins.md` — removed internal hosts `registry.carverauto.dev`,
  `code.carverauto.dev`, and the `staging.serviceradar.cloud` URL.
- [x] 1.7 `dashboard-sdk.md`, `agent-release-management.md` — `code.carverauto.dev` links
  removed.
- [x] 1.8 `troubleshooting-guide.md` — removed the internal "Beads"/`bd` reference and
  "core team" framing.
- [x] 1.9 `armis.md` — removed the "Large Ingestion Validation" internal release gate.
- [x] 1.10 `ansible.md` — removed the IEx credential-console workflow; UI-based guidance.
- [x] 1.11 `helm-configuration.md`, `network-topology.md` — demo overlay generalized;
  dated local benchmark numbers removed.
- [x] 1.12 Repo-wide grep sweep — remaining hits are RFC1918 example IPs in vendor config
  snippets and the public chart/image registry; `demo` namespace generalized in
  `kubernetes-ingestion.md`.

## 2. Remove dev-only and customer-specific pages

- [ ] 2.1 Preserve content first: copy `topology-reset-rebuild.md` and
  `wifi-map-local-compose.md` into the gitops repo (`~/src/gitops/docs/demo/`) — manual
  step outside this repo, for the author.
- [x] 2.2 Deleted `wifi-map-local-compose.md` (customer-specific compose runbook).
- [x] 2.3 Deleted `topology-reset-rebuild.md` (dev-only AGE-topology reset runbook).
- [x] 2.4 Deleted `repository-layout.md` (contributor-only).
- [x] 2.5 Deleted `rust-bazel-deps.md` (contributor-only).
- [x] 2.6 Deleted `camera-analysis-reference-worker.md` (internal contract-test artifact).
- [x] 2.7 Deleted `cnpg-pg18-upgrade-and-search-policy.md` (internal engineering runbook).
- [x] 2.8 Removed deleted pages from `sidebars.ts`; inbound links updated; redirects added
  in `docusaurus.config.ts`.

## 3. Consolidate SDK and WASM docs to the developer portal

- [x] 3.1 `wasm-plugins.md` reduced from ~618 to ~150 lines — conceptual overview only;
  manifest/result schema, host ABI, and SDK code samples linked to
  `developer.serviceradar.cloud`.
- [x] 3.2 Created `sdks.md` — "SDKs & Plugin Development" overview for the Go, Rust, and
  dashboard SDKs, each linking to the developer portal.
- [x] 3.3 `dashboard-sdk.md` — raw repo link removed; points to the developer portal.
- [x] 3.4 `ansible.md` — inline `tinygo build` WASM instructions replaced with a portal
  link and overview.
- [x] 3.5 Verified no other page carries duplicated SDK/WASM authoring reference.

## 4. Rename "God-View" to "Network Topology"

- [x] 4.1 `god-view-topology.md` renamed to `network-topology.md` with proper frontmatter.
- [x] 4.2 All prose/heading occurrences of "God-View" replaced with "Network Topology";
  code identifiers preserved; dated benchmark numbers removed.
- [x] 4.3 `sidebars.ts` updated; redirect from the old slug added.

## 5. Correct the Trivy documentation

- [x] 5.1 `trivy-integration.md` rewritten — Trivy presented as a supported integration
  currently disabled in the demo environment, not retired.

## 6. Fix stale architecture, diagrams, and inaccuracies

- [x] 6.1 `bgp-routing.md` — diagram corrected to CNPG; internal `pushEvent` section
  dropped; "future" features labeled; invalid SRQL examples replaced.
- [x] 6.2 `device-configuration.md` — retired `/api/query` + `X-API-Key` API and stale
  `flowgger.toml` content removed; boilerplate removed.
- [x] 6.3 `netflow.md` — stale `0.8.0` markers and dead UI port removed; collector naming
  reconciled; "(NEW)" dropped; invalid SRQL examples replaced.
- [x] 6.4 `troubleshooting-guide.md` — `0.7.1`/`Pre-0.8.0` historical content removed;
  stale "grok rules" terminology fixed.
- [x] 6.5 Diagram review — `sync.md` `Core (Ash)` label fixed; `bgp-routing.md` diagram
  corrected; `architecture.md`/`data-pipeline.md`/`edge-model.md` diagrams confirmed
  current.
- [x] 6.6 `otel.md` — OTLP gateway service name confirmed; `otel_traces` time column fixed.
- [x] 6.7 Confirmed no Proton/ClickHouse references remain site-wide.

## 7. Build robust SRQL documentation

- [x] 7.1 Created `srql-tutorial.md` — guided, example-driven beginner walkthrough.
- [x] 7.2 Rewrote `srql-language-reference.md` — complete reference; `entity_mapping.ml`
  fixed, entity naming reconciled, internal migration links removed.
- [x] 7.3 Created `srql-cookbook.md` — task-oriented copy-paste recipes.
- [x] 7.4 Added the "Query & Analyze" sidebar group with the three SRQL pages.

## 8. Information architecture and polish

- [x] 8.1 Merged `falco.md` and `falco-integration.md` into one Falco page.
- [x] 8.2 Merged `self-signed.md` into `tls-security.md`; inbound links fixed.
- [x] 8.3 Folded `mtr-automation-rollout.md` into `troubleshooting-guide.md`.
- [x] 8.4 Frontmatter normalized on merged/renamed pages.
- [x] 8.5 Resolved the `<!-- TODO: screenshot -->` placeholders in
  `edge-agent-onboarding.md`.
- [x] 8.6 Restructured `sidebars.ts` into task-based sections (Start Here, Deploy, Edge &
  Agents, Integrations, Get Data In, Query & Analyze, Extend, Operate).
- [x] 8.7 Updated `intro.md` and `quickstart.md` to the new IA; fixed the mislabeled
  "Get Data In" link.
- [x] 8.8 Updated platform positioning (ITOM/NetOps-led) across `intro.md`,
  `architecture.md`, the landing page, and the `docusaurus.config.ts` tagline.

## 9. Visual theme alignment with `serviceradar.cloud`

- [x] 9.1 `custom.css` — Infima primary ramp regenerated from `#0369a1` (light) / `#38bdf8`
  (dark).
- [x] 9.2 Surface/text colors mapped to the shared `base-100/200/300` and `base-content`
  tokens; navbar/footer backgrounds updated.
- [x] 9.3 `secondary`, `accent`, and `success`/`warning`/`error` tokens mapped to status
  colors.
- [x] 9.4 Removed the `dracula` dark prism theme; dark theme set to `palenight`.
- [x] 9.5 Monospace code font aligned to `Space Mono` (loaded via Google Fonts).
- [x] 9.6 Applied the shared radius and a radial-gradient hero treatment to the landing
  page.
- [x] 9.7 Verified with `playwright-cli` against `https://serviceradar.cloud` — primary
  `#0369a1`, text `#0f172a`, white base all match exactly.
- [x] 9.8 Primary/link/text contrast meets WCAG AA in light and dark modes.
- [x] 9.9 Redesigned the landing page — emoji icons replaced with themed inline-SVG icons;
  fabricated stats removed; feature cards rewritten to the four pillars.
- [x] 9.10 Removed the unused default Docusaurus `HomepageFeatures` component and the
  `markdown-page` sample.

## 10. Validation

- [x] 10.1 `npm run build` passes with zero broken links (`onBrokenLinks: throw`).
- [x] 10.2 Removed/renamed slugs have redirects via `@docusaurus/plugin-client-redirects`.
- [x] 10.3 Reviewed the rendered site navigation for coherence across the new IA.
- [x] 10.4 Compared the docs site and `https://serviceradar.cloud` with `playwright-cli` —
  palettes match.
- [x] 10.5 Re-ran the opsec grep sweep on the final tree.
- [x] 10.6 `openspec validate refactor-product-documentation --strict`.
