## Context

The ServiceRadar public docs live in `docs/docs/` and are built by Docusaurus
(`docs/docusaurus.config.ts`, `docs/sidebars.ts`) and published to
`docs.serviceradar.cloud`. `onBrokenLinks` is set to `throw`, so any dangling internal
link fails the build — removals and renames must be done carefully.

A separate developer portal exists at `developer.serviceradar.cloud` and already hosts
versioned SDK docs (e.g. `dashboard-sdk.md` links to
`developer.serviceradar.cloud/docs/v2/dashboard-sdk`). The team wants exactly one home for
SDK and WASM plugin authoring reference.

A full read of all 53 pages produced the issue inventory in `tasks.md`. This change is
content + navigation only; no runtime code changes.

## Goals / Non-Goals

**Goals**
- No internal infrastructure detail, credentials, customer identity, or dev-run snapshots
  on the public site.
- One source of truth for SDK/WASM authoring: the developer portal.
- A learnable SRQL documentation set for both new and experienced users.
- Accurate architecture, diagrams, and integration status.
- A coherent, task-based information architecture.
- A visual theme that matches `serviceradar-web` so all ServiceRadar web properties share
  one design identity.

**Non-Goals**
- No changes to `developer.serviceradar.cloud` content (that work is tracked separately).
- No application, API, or schema changes.
- No new product features — this is documentation only.
- Not rewriting every page from scratch; pages that are already accurate (e.g.
  `data-pipeline.md`, `kubernetes-ingestion.md`, `network-sweeps.md`, `rule-builder.md`)
  are left largely as-is.

## Decisions

### Decision: Remove dev-only/contributor pages rather than keep a "Develop" section
Pages that only serve contributors or internal operators are removed from the published
site: `repository-layout.md`, `rust-bazel-deps.md`, `topology-reset-rebuild.md`,
`camera-analysis-reference-worker.md`, `cnpg-pg18-upgrade-and-search-policy.md`.
Contributor guidance belongs in the repo (`CONTRIBUTING`, `AGENTS.md`, inline READMEs),
not the customer-facing docs site.
- *Alternative considered:* a dedicated "Develop / Contribute" sidebar section. Rejected —
  it still mixes audiences on the customer site and invites the same drift.

### Decision: Preserve before delete
`topology-reset-rebuild.md` and `wifi-map-local-compose.md` have ongoing internal value.
Their content is copied into the `gitops` repo (`~/src/gitops/docs/demo/`) **before** the
files are deleted here, so no operational knowledge is lost. This relocation is a manual
step performed by the author outside this repo and is not gated by this change.

### Decision: Developer portal is the single source of truth for SDK/WASM authoring
`wasm-plugins.md` is reduced from a 618-line reference to a conceptual overview: what WASM
plugins are, the sandbox/capability model at a high level, the upload/import/approval
workflow, and deployment/storage configuration (operator concerns stay). The manifest
schema, result schema, host ABI, and SDK code samples move out, replaced by a link to
`developer.serviceradar.cloud`. SDK pages (`dashboard-sdk.md` and a consolidated SDK
overview) describe each SDK at a high level and link to the portal; raw repo URLs on
`code.carverauto.dev` are removed. `ansible.md`'s inline `tinygo build` instructions are
replaced with the same link.

### Decision: "Network Topology" as the public name
The feature is documented as "Network Topology". `god-view-topology.md` →
`network-topology.md`; sidebar id and label updated. Code identifiers
(`SERVICERADAR_GOD_VIEW_ENABLED`, `GodViewStream.*`, `god_view_disabled`) remain unchanged
and are still shown verbatim where operators must set or read them.

### Decision: SRQL becomes a three-page section
A new "Query with SRQL" group replaces the single `srql-language-reference.md`:
- **SRQL Tutorial** — a guided, example-driven walkthrough for first-time users.
- **SRQL Reference** — complete grammar, entities, fields, operators, functions; internal
  inaccuracies fixed (e.g. `entity_mapping.ml` is wrong — the engine is Rust under
  `rust/srql`; entity/section naming reconciled with `in:` names; remove links into
  internal migration files).
- **SRQL Cookbook** — copy-paste recipes for common operator tasks (find devices, inspect
  events, NetFlow/BGP queries, build alert rules).

### Decision: Target information architecture
The sidebar is reorganized into task-based sections:

```
Start Here      Introduction · Quickstart · Architecture
Deploy          Docker Compose · Kubernetes (Helm) · Kubernetes Ingestion ·
                Service Port Map · TLS & mTLS · Authentication
Edge & Agents   Edge Model · Edge Onboarding · Agent Release Management ·
                Discovery · Network Sweeps · SYN Scanner Tuning · Sysmon Profiles
Integrations    Armis · NetBox · Ansible · Proxmox VE · Falco · Trivy ·
                Remote Access · Remote Access: RDP
Get Data In     Data Pipeline · Device Configuration · Syslog · SNMP ·
                NetFlow · BGP Routing · OTEL
Query & Analyze SRQL Tutorial · SRQL Reference · SRQL Cookbook · Rule Builder ·
                Network Topology
Extend          SDKs & Plugin Development · WASM Plugins · FieldSurvey Sidekick
Operate         Tools Pod · Database Bootstrap · CNPG Monitoring ·
                Observability Rollup Recovery · Object Store Retention · Troubleshooting
```

Removed from the sidebar: Repository Layout, Rust Bazel Dependencies, Topology
Reset/Rebuild, Camera Analysis Worker, CNPG PG18 Upgrade, WiFi Map Local Compose,
Self-Signed Certificates (merged into TLS & mTLS). `falco.md` and `falco-integration.md`
merge into one Falco page. `mtr-automation-rollout.md` is folded into Troubleshooting or
Remote Access diagnostics rather than standing alone.

### Decision: Re-theme the docs site to the shared `serviceradar-web` palette

`https://serviceradar.cloud` is the authoritative design reference for the shared
ServiceRadar palette. `serviceradar-web` (`assets/css/app.css`) defines the same palette as
daisyUI tokens and is the documented starting point below; the values are verified against
the live `serviceradar.cloud` site with `playwright-cli` before the docs theme is finalized.
The docs site adopts the palette by mapping the tokens onto the Docusaurus Infima variables
in `docs/src/css/custom.css`. The current stock indigo (`#4f46e5`) primary and the Dracula
prism theme are replaced.

Starting palette (from `serviceradar-web`, to be confirmed against `serviceradar.cloud`):

| Token            | Light       | Dark        |
|------------------|-------------|-------------|
| base-100 (bg)    | `#ffffff`   | `#132033`   |
| base-200         | `#f8fafc`   | `#0b1628`   |
| base-300         | `#e2e8f0`   | `#08111f`   |
| base-content     | `#0f172a`   | `#eff6ff`   |
| primary          | `#0369a1`   | `#38bdf8`   |
| secondary        | `#0f766e`   | `#2dd4bf`   |
| accent           | `#f97316`   | `#fb923c`   |
| success          | `#059669`   | `#34d399`   |
| warning          | `#d97706`   | `#f59e0b`   |
| error            | `#dc2626`   | `#fb7185`   |

Mapping rules:
- `--ifm-color-primary` (and its `-dark/-darker/-darkest/-light/-lighter/-lightest` ramp)
  is generated from the `primary` token per theme — the light site uses `#0369a1`, the dark
  site uses `#38bdf8`.
- Page background, surfaces, and text map to `base-100/200/300` and `base-content`;
  navbar/footer backgrounds use the `base` surfaces rather than ad-hoc grays.
- `secondary` and `accent` are exposed for links/callouts/admonitions where Docusaurus
  allows; `success/warning/error` map to admonition accent colors.
- Prism: drop `dracula`. Keep `github` for light; use a dark theme that sits well on the
  `#132033` navy base (`vsDark`, `oceanicNext`, or `palenight`) — pick during implementation
  by eye against the navy surface.
- Code font: align with `serviceradar-web`'s `"Space Mono"` stack (loaded as a web font or
  via `--ifm-font-family-monospace`).
- The `serviceradar-web` radius tokens (`--radius-box: 0.75rem`) and subtle radial-gradient
  hero treatment are applied lightly to the docs landing page for family resemblance —
  without copying the full app chrome.

*Alternatives considered:* importing `serviceradar-web`'s `app.css` directly — rejected,
it is Tailwind/daisyUI-specific and incompatible with Infima. A shared npm theme package —
rejected as over-engineering for two consumers; a documented token table is enough.

## Risks / Trade-offs

- **Broken external deep links.** Removing/renaming pages breaks bookmarks and search
  results. → Add Docusaurus client redirects (`@docusaurus/plugin-client-redirects`) or
  `docusaurus.config.ts` redirects for removed/renamed slugs where practical.
- **Build breakage from `onBrokenLinks: throw`.** Every removed/renamed page must have its
  inbound links updated in the same change. → A full `npm run build` is the validation
  gate (task section 9).
- **Knowledge loss on deletion.** → Mitigated by the preserve-before-delete decision.
- **Audit completeness.** The deep-dive read all 53 pages, but new internal references can
  reappear. → Add a CI grep guard (optional, task 9.4) for known internal markers
  (`carverauto.dev`, `192.168.`, `-n demo`).
- **Theme drift over time.** The docs and the other web properties keep separate palette
  definitions, so they can drift. → Record the token table in `design.md` and as comments
  in `custom.css` citing `serviceradar.cloud` as the authoritative reference (with
  `serviceradar-web/assets/css/app.css` as the concrete token source).
- **Contrast/accessibility.** Re-theming can break text contrast. → Verify primary, link,
  and admonition colors meet WCAG AA against both `base-100` surfaces.

## Migration Plan

1. Land content edits, removals, and the new SRQL pages in one branch.
2. Update `sidebars.ts` and inbound links; add redirects for removed/renamed slugs.
3. Run `npm run build` until it passes with zero broken links.
3a. Verify theme consistency: use `playwright-cli` (installed on this system) to screenshot
   the docs site and `https://serviceradar.cloud` and compare rendered palette/layout colors
   in light and dark modes.
4. Author manually copies preserved dev/demo content into the `gitops` repo.
5. Rollback is a straight `git revert` — no data or runtime impact.

## Open Questions

- Should `mtr-automation-rollout.md` be folded into Troubleshooting, merged into Remote
  Access diagnostics, or kept as a slim standalone page? (Default: fold into Troubleshooting.)
- Is `@docusaurus/plugin-client-redirects` already available, or should redirects be added
  to `docusaurus.config.ts` directly? (Resolve during implementation.)
- Does `developer.serviceradar.cloud` already have landing pages for `serviceradar-sdk-go`
  and `serviceradar-sdk-rust` to link to, or do those need to be created there first?
- Which dark prism theme best matches the `#132033` navy base — `vsDark`, `oceanicNext`,
  or `palenight`? (Decide by eye during implementation.)
- Do the live `serviceradar.cloud` colors exactly match the `serviceradar-web` tokens, or
  do the starting tokens need correction once verified with `playwright-cli`?
- Should `developer.serviceradar.cloud` be re-themed to the same palette in a follow-up so
  all properties match, or is it already aligned?
