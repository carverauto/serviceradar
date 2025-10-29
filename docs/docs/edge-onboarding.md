# Secure Edge Onboarding

This runbook explains how to issue ServiceRadar onboarding packages for hosts that
run outside the Kubernetes demo cluster. It captures the current poller flow and
lays out the forthcoming agent/checker enhancements so operators know what to
gather before a rollout. See `docs/docs/edge-agent-onboarding.md` for the
component-by-component breakdown and KV automation model.

> **Status overview**
>
> - **Poller onboarding** is live today via the edge onboarding service in Core.
> - **Agent and checker onboarding** leverage the same package machinery but
>   still require manual KV updates. The backend/API work (GH-1904 /
>   serviceradar-54) will automate those steps in an upcoming release.
> - **Next milestone (GH-1909)** tracks the multi-component UI/API so operators
>   can issue packages for pollers, agents, and checkers from one flow.

---

## Component scope and relationships

| Component | Parent association | Package artifacts | KV path updated on create | Notes |
|-----------|-------------------|-------------------|---------------------------|-------|
| Poller    | None              | `edge-poller.env`, SPIRE join token + bundle | `config/pollers/<poller-id>` | Establishes the edge site and acts as the control plane for downstream agents. |
| Agent     | Poller            | `edge-agent.env`, SPIRE join token + bundle | `config/pollers/<poller-id>/agents/<agent-id>` | Agents inherit connectivity details from their parent poller and surface checker slots. |
| Checker   | Agent             | `edge-checker.env` (planned), SPIRE assets when needed | `config/agents/<agent-id>/checkers/<checker-id>` | Checkers depend on an agent for dispatch and credential management. |

When the new onboarding UI lands, the operator must declare the component type
up front. Selecting *Agent* requires choosing a poller parent; selecting
*Checker* requires choosing an agent parent (which implicitly ties it to that
agent’s poller). During package creation Core will update the parent KV
document, marking the new child as `pending` so it activates automatically once
the installer reports back.

---

## 1. Prerequisites

| Requirement | Notes |
|-------------|-------|
| Demo cluster access | You need `kubectl` + admin access to the `demo` namespace. |
| Admin credentials | API key (`serviceradar-secrets`), and an admin JWT (login to the web app or call `/auth/login`). |
| External endpoints | From the edge host, Core/SPIRE/KV must be reachable:<br />- Core gRPC: `23.138.124.18:50052`<br />- Core SPIFFE ID: `spiffe://carverauto.dev/ns/demo/sa/serviceradar-core`<br />- KV gRPC: `23.138.124.23:50057`<br />- KV SPIFFE ID: `spiffe://carverauto.dev/ns/demo/sa/serviceradar-datasvc`<br />- SPIRE server gRPC: `23.138.124.18:18081` |
| CLI tools | `serviceradar-cli`, `docker`, `docker compose`, `tar`, `jq`, `kubectl`. |
| Repo | Clone `github.com/carverauto/serviceradar` on the edge host. |

---

## 2. Metadata Template

Every onboarding package embeds an `edge-poller.env` file generated from
metadata you supply. Use this baseline JSON and adjust values only when your
load balancers change:

```json
{
  "core_address": "23.138.124.18:50052",
  "core_spiffe_id": "spiffe://carverauto.dev/ns/demo/sa/serviceradar-core",
  "kv_address": "23.138.124.23:50057",
  "kv_spiffe_id": "spiffe://carverauto.dev/ns/demo/sa/serviceradar-datasvc",
  "spire_upstream_address": "23.138.124.18",
  "spire_upstream_port": "18081",
  "spire_parent_id": "spiffe://carverauto.dev/ns/edge/poller-nested-spire",
  "agent_address": "agent:50051",
  "agent_spiffe_id": "spiffe://carverauto.dev/services/agent",
  "log_level": "debug",
  "logs_dir": "./logs",
  "nested_spire_assets": "./spire",
  "serviceradar_templates": "./packaging/core/config",
  "nested_spire_wait_attempts": "120",
  "spire_insecure_bootstrap": "false"
}
```

> Keep the metadata focused on connectivity. Arbitrary keys are persisted but
> ignored by the bootstrap scripts.

---

## 3. Poller Onboarding (Current)

### 3.1 Issue a package

1. Log into the web UI as an admin and open **Admin → Edge Onboarding**.
2. Click **Issue new installer** and provide:
   - **Component type**: Set to *Poller*. (The multi-component selector ships
     with GH-1909; until then the form defaults to pollers.)
   - **Component ID**: Leave blank to auto-generate a slug from the label, or
     provide a custom lowercase identifier (hyphen-separated).
   - **Label** (required): Friendly name; also seeds the poller ID.
   - **Poller ID** (optional): Override the generated slug.
   - **Site** (optional): Free-form location tag.
   - **Downstream SPIFFE ID** (optional): Leave blank to auto-generate
     `spiffe://carverauto.dev/ns/edge/<poller-id>`.
   - **SPIRE selectors**: Leave empty unless you need extra selectors. We always
     include the defaults (`unix:uid:0`, `unix:gid:0`, `unix:user:root`,
     `unix:group:root`).
   - **Metadata JSON**: Paste the template from §2 (adjust endpoints if needed).
   - **Join/Download TTLs**: Defaults (30m / 15m) are fine for most cases.
   - **Notes**: Optional operator guidance.
3. Submit. The UI returns a join token, download token, and bundle PEM. Copy
   them somewhere secure—they are displayed once.

CLI equivalent:

```bash
serviceradar-cli edge package create \
  --core-url https://demo.serviceradar.cloud \
  --api-key "$SERVICERADAR_API_KEY" \
  --bearer "$ADMIN_JWT" \
  --label "Reno Edge Poller" \
  --metadata-json "$(cat metadata.json)"
```

### 3.2 Download the artifacts

- **UI**: Click **Download** while the package status is *Issued*.
- **CLI**:
  ```bash
  serviceradar-cli edge package download \
    --core-url https://demo.serviceradar.cloud \
    --api-key "$SERVICERADAR_API_KEY" \
    --bearer "$ADMIN_JWT" \
    --id <PACKAGE_ID> \
    --download-token <DOWNLOAD_TOKEN> \
    --output edge-package.tar.gz
  ```

The archive contains:

```
README.txt
metadata.json
edge-poller.env
spire/upstream-join-token
spire/upstream-bundle.pem
```

### 3.3 Bootstrap the Docker stack

1. Copy the archive onto the edge host (repo root).
2. Extract it: `tar -xzvf edge-package.tar.gz`.
3. Run the automated restart:
   ```bash
   docker/compose/edge-poller-restart.sh \
     --env-file edge-poller.env \
     --skip-refresh   # uses the packaged join token/bundle
   ```
   This script wipes stale volumes, regenerates configs, injects the metadata,
   and brings `serviceradar-poller` + `serviceradar-agent` online in SPIFFE mode.
4. Verify:
   ```bash
   docker compose --env-file edge-poller.env -f docker/compose/poller-stack.compose.yml ps
   docker logs serviceradar-poller | grep -i spire
   docker logs serviceradar-agent | head
   ```

### 3.4 Activation check

- In Core, the package transitions from *Issued → Delivered* once the download
  succeeds, then *Activated* after the new poller reports in.
- `kubectl logs deployment/serviceradar-core -n demo | grep <poller-id>`
  should show the poller entering the allowed list.

### 3.5 Revoking a poller (optional)

```bash
serviceradar-cli edge package revoke \
  --core-url https://demo.serviceradar.cloud \
  --api-key "$SERVICERADAR_API_KEY" \
  --bearer "$ADMIN_JWT" \
  --id <PACKAGE_ID> \
  --reason "Retired edge host"
```

Core deletes the downstream SPIRE entry, clears the tokens, and marks the
package *Revoked*.

---

## 4. Agent Onboarding (Planned Enhancement)

> The service currently issues poller installers only. The next milestone adds
> agent support so Core can publish a package that targets an existing poller
> and pre-wires KV.

### Target flow

1. Operator selects **Component type → Agent** in the onboarding form.
2. UI prompts for **Associated poller** and surfaces pollers that are active or
   have pending packages.
3. Optional presets let the operator choose common agent roles (SNMP gateway,
   sysmon collector, etc.) to scaffold metadata.
4. Core issues a package containing:
   - SPIRE join token/bundle for the agent workload entry.
   - `edge-agent.env` with Core/KV endpoints, the parent poller ID, and any
     metadata captured in the form.
5. Core immediately updates the poller’s KV document at
   `config/pollers/<poller-id>/agents/<agent-id>` with `status: "pending"` so
   the poller starts streaming tasks to the agent on activation.
6. Activation events flip the KV entry to `active` and add an audit record that
   references the parent poller.

### Interim workaround (manual)

Until the automation lands:

1. Duplicate the poller metadata JSON, set `"agent_address"` to the new agent’s
   reachable endpoint, and issue a poller package (for SPIRE assets).
2. Extract `edge-poller.env`, rename to `edge-agent.env`, and tailor the env for
   the agent container.
3. Update KV manually:
   - `serviceradar-cli kv get --key config/pollers/<poller-id>/agents/<agent-id>.json`
   - Merge the new agent definition, set `status: "pending"`.
   - `serviceradar-cli kv put --key config/pollers/<poller-id>/agents/<agent-id>.json --file updated.json`

---

## 5. Checker Onboarding (Planned Enhancement)

Checkers (SNMP, sysmon-vm, custom scanners) will reuse the same framework. The
UX will prompt for:

- Checker type.
- Parent agent.
- Any device-specific credentials.

Core will then:

1. Require **Component type → Checker** and selection of the parent agent (with
   an inline reminder of the agent’s parent poller).
2. Issue SPIRE credentials for the checker workload (if needed).
3. Update the agent’s KV entry at
   `config/agents/<agent-id>/checkers/<checker-id>` with `status: "pending"`,
   checker kind, and metadata (targets, credentials). The agent promotes the
   checker to `active` once it reports back.

### Manual procedure today

1. Add the checker JSON under the agent’s KV config.
2. Restart the agent container so it re-reads configuration.
3. For SPIFFE-enabled checkers, craft join tokens via
   `serviceradar-cli spire-join-token` and distribute them separately.

---

## 6. Troubleshooting

| Symptom | Checks |
|---------|--------|
| `PermissionDenied: no identity issued` in poller logs | The join token may have expired or been consumed. Generate a fresh package, extract, and rerun `edge-poller-restart.sh --skip-refresh`. |
| `/api/admin/edge-packages` download returns 409 | The download token was already used—issue a new package. |
| Agent never appears under the poller | Verify KV config for the poller lists the agent; if not, reapply the edits (manual step until agent onboarding is automated). |
| Nested SPIRE server loops | Clear `compose_poller-spire-runtime` (`docker volume rm`) before running the restart script to avoid stale sockets. |

---

## 7. Next Steps

- Finish the API/UI work for agent and checker packages so metadata + KV updates
  are produced automatically (serviceradar-54 / GH-1904, successor GH-1909).
- Add UI presets so operators can choose “Edge poller” / “Edge agent” /
  “Edge checker” without pasting JSON.
- Extend the restart script to install agents/checkers once the new packages are
  available.

---

## Tracking

- **GitHub:** [GH-1909](https://github.com/carverauto/serviceradar/issues/1909)
  “Edge onboarding: support agents and checkers”.
- **Beads:** New follow-up issue to succeed `serviceradar-54` once the docs are
  updated (see repo `.beads` index).
