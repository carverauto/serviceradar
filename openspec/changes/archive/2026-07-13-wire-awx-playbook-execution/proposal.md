# Wire AWX Playbook Execution End to End

## Why

The AWX/AAP inventory-sync half works on demo (registered `demo-awx` controller
+ token; 13 hosts synced with `metadata.awx`), and the device-correlation fix
makes AWX-synced devices ansible-managed and launchable. But the operator
use-case — "find a device that is also in the AWX inventory and deploy a playbook
against it" — cannot complete: the launch command is dispatched to the agent as
the raw verb `awx.launch_job`, and the **agent control stream has no route for
`awx.*` verbs** (`control_stream.go` only handles `plugin.run_action`,
`addon.run_command`, and built-in check types), so it replies `unsupported
command`. The catalog sync (`awx.list_templates`) fails the same way, so no
`Playbook` rows are produced automatically.

## What Changes

- **Agent: route AWX command verbs to the awx plugin.** Add handling in
  `control_stream.go` so `awx.*` command types invoke the awx WASM plugin's
  `run_check` entrypoint with the verb + payload (the plugin already dispatches
  on `cfg.Verb`: ping/list_*/launch_job/fetch_job/cancel_job/
  fetch_events_for_jobs). Report the plugin result back as the command result.
  This is an agent-binary change → local agent build + push to the in-cluster
  `k8s-agent`.
- **Keep the landed core fixes:** `run_launcher` derives the inventory ref from
  `metadata.awx`; `awx_client` drops the bogus `"http"` session-capability gate.
- **Catalog:** with verb routing fixed, `AwxCatalogSyncWorker` (`awx.list_templates`)
  populates `Playbook` rows from AWX job templates automatically.
- **Verification playbook:** a trivial AWX job template (e.g. "Smoke: ping all")
  is launched against a synced device (an agent host such as `192.168.2.22` added
  to the AWX inventory, or an existing synced host) and observed to reach a
  terminal state via `RunPulseWorker`/`fetch_events_for_jobs`.

## Impact

- Affected specs: `ansible-automation`.
- Affected code:
  - `go/pkg/agent/control_stream.go` (+ plugin invocation plumbing) — new agent
    route for `awx.*` verbs. **Agent rebuild + redeploy.**
  - `elixir/serviceradar_core/lib/serviceradar/automation/ansible/run_launcher.ex`,
    `awx_client.ex` — landed on `fix/awx-inventory-sync-and-playbook-run`.
  - `go/cmd/wasm-plugins/awx/` — ensure the deployed bridge is the current build
    (the demo v0.1.1 was stale and lacked launch verbs).
- Depends on the proxmox DIRE fix so the AWX host and the proxmox guest and the
  agent all collapse to one device the operator picks.
