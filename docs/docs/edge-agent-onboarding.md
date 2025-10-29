# Edge Agent & Checker Onboarding

This guide expands on the edge onboarding runbook and documents how pollers,
agents, and checkers fit together. Use it when modelling new edge sites, when
planning upcoming automation (GH-1909 / serviceradar-55), and when falling back
to today’s manual steps.

---

## 1. Roles & Relationships

| Component | Purpose | Parent | Downstream scope | KV document |
|-----------|---------|--------|------------------|-------------|
| Poller | Site gateway that maintains the control channel to Core and Data Service. | None | Agents | `config/pollers/<poller-id>` |
| Agent | Executes discovery tasks for a poller (SNMP, sysmon, custom scanners). | Poller | Checkers | `config/pollers/<poller-id>/agents/<agent-id>` |
| Checker | Device-specific worker (e.g. SNMP credential set, sysmon target). | Agent | N/A | `config/agents/<agent-id>/checkers/<checker-id>` |

Key rules:

- Agents cannot exist without a poller; checkers cannot exist without an agent.
- Poller IDs must be unique. Agent/checker IDs only need to be unique within
  their parent scope (`poller-id + agent-id`, `agent-id + checker-id`).
- Activation flows propagate upward: a checker activates only after its agent
  is active, which requires the parent poller to be active.

---

## 2. Operator Personas

- **Cluster admin** – issues packages, rotates credentials, and monitors status.
- **Edge site owner** – installs the poller/agent/checker containers on remote
  hosts using the generated archive.
- **Security reviewer** – audits package lineage and parent-child associations
  in Proton (`edge_onboarding_packages` and `edge_onboarding_events` tables).

---

## 3. Desired Flow (Post-Automation)

The UI and API expose a single onboarding surface with a `Component type`
selector. Each type captures a different set of inputs and triggers cascading KV
updates.

### 3.1 Common Inputs

| Field | Notes |
|-------|-------|
| Label | Human-readable name shown in the UI. Seeds the default ID. |
| Component type | Poller / Agent / Checker (mandatory). |
| Component ID | Optional for pollers (auto-slugged from label); required for agents/checkers. Provide a lowercase slug with hyphens only. |
| Parent | Auto-populated drop-down: pollers for agents, agents for checkers. Hidden for pollers. |
| SPIRE selectors | Optional extra selectors beyond the defaults. |
| Metadata JSON | Transport addresses, credentials and installer hints. |
| Join & download TTL | Defaults of 30 m / 15 m; override for slow sites. |
| Notes | Free-form operator context. |

### 3.2 Outcomes By Type

| Type | Package contents | KV mutation | Status transitions |
|------|------------------|-------------|--------------------|
| Poller | `edge-poller.env`, SPIRE join token, bundle | `config/pollers/<id>` → create/refresh with metadata (`status: pending`) | `issued → delivered → activated → revoked/expired` |
| Agent | `edge-agent.env`, SPIRE join token, bundle | `config/pollers/<poller-id>/agents/<agent-id>` (`status: pending`) | Same as poller; activation tied to agent status reports |
| Checker | `edge-checker.env`, optional SPIRE artefacts, checker metadata | `config/agents/<agent-id>/checkers/<checker-id>` (`status: pending`) | Same as poller; activation triggered by agent heartbeat |

On activation, Core updates the relevant KV node to `status: "active"` and
emits an audit event capturing the parent association.

---

## 4. CLI Surface

`serviceradar-cli edge package create` gains the following arguments:

- `--component-type (poller|agent|checker)`
- `--parent-id <poller-or-agent-id>` (required for agent/checker)
- `--checker-kind` and `--checker-config-file` (checker-only helpers)

Example agent issuance:

```bash
serviceradar-cli edge package create \
  --component-type agent \
  --parent-id sea-edge-01 \
  --label "sea-agent-01" \
  --metadata-json "$(cat agent-metadata.json)" \
  --checker-kind snmp \
  --api-key "$SERVICERADAR_API_KEY" \
  --bearer "$ADMIN_JWT" \
  --core-url https://demo.serviceradar.cloud
```

`serviceradar-cli edge package list` and `download` surface `component_type`
and `parent_id` columns so operators can confirm hierarchy from the terminal.

---

## 5. KV Automation Model

When Core accepts the creation request it performs the following:

1. **Validate parents** – ensure poller or agent exists (activated or pending).
2. **Persist package** – insert record into `edge_onboarding_packages` with the
   parent linkage fields.
3. **Update KV**:
   - Poller: upsert `config/pollers/<poller-id>` with metadata, `status` and a
     generated timestamp.
   - Agent: upsert `config/pollers/<poller-id>/agents/<agent-id>.json`.
   - Checker: upsert `config/agents/<agent-id>/checkers/<checker-id>.json`.
4. **Broadcast cache updates** – notify Core’s in-memory poller/agent registries
   so report-status calls accept the pending IDs immediately.

All KV writes use optimistic concurrency with revision checks to avoid clobbering
manual overrides. On failure, the API returns `409 Conflict` and the frontend
raises a toast instructing operators to refresh.

Activation transitions occur when Core observes the new component in its
reporting pipelines:

| Trigger | Condition | KV effect |
|---------|-----------|-----------|
| Poller report | `poller_id` matches pending package | `config/pollers/<id>.status = "active"` |
| Agent report | `agent_id` + `poller_id` matches pending agent | `.../agents/<agent-id>.status = "active"` |
| Checker report | agent heartbeat includes checker metrics / `checker_id` | `.../checkers/<checker-id>.status = "active"` |

Revocation and expiry events set `status: "disabled"` and cache evictions ensure
future reports are rejected until reissued.

---

## 6. Installer Expectations

Package archives expand into type-specific directories:

```
edge-<component>.env
metadata.json
spire/upstream-join-token
spire/upstream-bundle.pem
README.txt
```

Additional files for checkers may include credential bundles (encrypted ZIP) or
device target manifests. Install scripts (`edge-poller-restart.sh`,
`edge-agent-install.sh`, `edge-checker-install.sh`) consume the env file, apply
metadata, and restart Docker Compose services. The scripts must no-op if the
KV status is already `active` to keep replays idempotent.

---

## 7. Manual Workarounds (Current State)

Until GH-1909 lands, operators can emulate the flow:

1. Issue a poller package via the UI (only option presently).
2. For agents:
   - Duplicate the poller metadata, update addresses, and save as
     `agent-metadata.json`.
   - Issue another poller package solely to obtain SPIRE artefacts.
   - Rename `edge-poller.env` to `edge-agent.env` and adjust variables.
   - `serviceradar-cli kv get --key config/pollers/<poller-id>/agents/<agent-id>.json`
     → merge the new agent definition and `kv put` it back with `status: "pending"`.
3. For checkers:
   - Edit the agent’s KV blob under
     `config/agents/<agent-id>/checkers/<checker-id>.json`.
   - Restart the agent container so it reads the new checker.

Document every manual change in the site’s bead issue so the automation work can
fold those steps into the API updates.

---

## 8. Monitoring & Troubleshooting

- Proton dashboards: filter `edge_onboarding_packages` by `component_type` to
  spot large pending queues.
- Core metrics:
  - `edge_onboarding_packages_total{component_type}` – total packages issued.
  - `edge_onboarding_package_state{component_type,state}` – current status
    counts. Alert when pending > 5 for longer than 30 minutes.
- Logs:
  - Package creation logs include parent references (`parent_type`, `parent_id`)
    but never the plaintext download token.
  - Activation logs confirm KV updates by printing the revision number.

Failure modes:

| Symptom | Resolution |
|---------|------------|
| 409 on create | Refresh parent list; ensure parent not revoked. |
| Agent stays pending | Verify poller reports agent in status heartbeat; check KV revision to ensure automation updated entry. |
| Checker missing credentials | Confirm metadata JSON carried the credential payload; reissue package if file omitted. |

---

## 9. References

- Runbook overview: `docs/docs/edge-onboarding.md`
- Product requirements: [GH-1909](https://github.com/carverauto/serviceradar/issues/1909)
- Tracking bead: `serviceradar-55`

---

## 10. Implementation Plan (Draft)

### Backend (Core + DB)
- Extend `edge_onboarding_packages` schema with `component_type`, `parent_type`, `parent_id`, `checker_kind`, `checker_config_json`, and `kv_revision` columns. Update Proton migrations + Bazel targets.
- Update `models.EdgeOnboardingPackage` and related request structs to carry the new fields. Introduce enumerations for component/parent types.
- Adjust `edgeOnboardingService.CreatePackage` to validate parent existence via KV/cache, derive default IDs, and perform KV writes through `pkg/kv`.
- API payloads now include `component_id` (the new component identifier) and `parent_id` for agent/checker relationships.
- Emit parent linkage in audit events and include in cache refresh payloads.
- Update activation paths (`RecordActivation`, status reports) to promote agents/checkers and write KV revisions.
- Add metrics labels (`component_type` / `parent_type`) and logs.

### KV Integrations
- Build helper functions in `pkg/kv/edgeconfig` to upsert poller/agent/checker documents with optimistic revision checks.
- Ensure rollbacks handle partial failure (e.g., KV failure after package persistence) by revoking created SPIRE entries and marking package aborted.
- Cover new helpers with unit tests exercising pending→active transitions.
- `pkg/core/edge_onboarding.applyComponentKVUpdates` writes `pending` documents to the appropriate KV keys (`config/pollers/<poller>.json`, `config/pollers/<poller>/agents/<agent>.json`, `config/agents/<agent>/checkers/<checker>.json`).

### CLI
- Expand `serviceradar-cli edge package create/list/download` flags and output to surface component type, parent, and checker metadata.
- Add validation + help text updates (`pkg/cli/cli.go`, `pkg/cli/edge_onboarding.go`).
- Update integration tests under `pkg/cli` to exercise new arguments.

### Web UI
- Refactor create modal into a stepper supporting component selection, parent dropdowns (fed by `/api/admin/edge-packages?status=activated,issued` plus poller/agent caches), and type-specific metadata hints.
- Show component/parent badges in the table and drawer views; expand audit timeline with parent linkage.
- Expose download token copy helpers per type (rename env file names in success modal).
- Add form validation and error handling for parent conflicts (409 status).

### Docs & Runbooks
- Update `edge-onboarding.md` once the flow ships (replace “planned” sections with live instructions).
- Add CLI examples for agent/checker issuance.
- Cross-link any updated restart scripts or helper tools.

### Testing
- Add unit tests covering create/list/revoke flows for each component type.
- Extend API integration tests (Bazel target `//pkg/core:edge_onboarding_test`) to validate KV mutations and status transitions.
- Wire web e2e test stub (Playwright) to create dummy packages against mock API once available.
