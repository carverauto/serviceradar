## Context
We need a practical debugging tool for mapper topology fidelity. The tool must let engineers run the existing discovery engine outside the scheduled agent flow, capture the raw mapper outputs, and compare those outputs with downstream ingestion and rendering behavior.

The critical boundary is credentials. Discovery controller secrets are stored under Elixir/Ash resources with AshCloak/Vault-managed handling. Reimplementing that decryption path in Go would create a shadow secret-access path and couple the tool to storage internals.

## Goals
- Reuse the existing Go mapper/discovery library rather than building a parallel probe stack.
- Allow focused baselines against one seed, one SNMP target, or one controller.
- Produce machine-readable outputs that can be diffed against CNPG/runtime graph evidence.
- Keep secret resolution inside ServiceRadar-managed Ash/Vault paths.

## Non-Goals
- Direct decryption of AshCloak-managed secrets from Postgres inside the Go CLI.
- A full UI for baseline runs in the first phase.
- Replacing scheduled mapper jobs or agent delivery.

## Design
### Phase 1: Standalone Go baseline runner
Add a standalone CLI command that wraps the existing mapper/discovery engine and accepts explicit credentials/config via flags or JSON input.

Supported modes:
- SNMP baseline against one or more targets
- UniFi baseline with explicit controller URL + API key
- MikroTik baseline with explicit base URL + username/password

Outputs:
- raw discovered devices
- raw discovered interfaces
- raw topology links
- aggregate counts by protocol/evidence/confidence
- optional stable JSON report file for later comparison

### Phase 2: Ash-managed config export
If engineers want to run a saved mapper job or controller config without manually re-entering credentials, provide an Elixir-managed export path that resolves and decrypts the saved credentials through the existing Ash/Vault boundary and emits a minimal runtime config for the Go CLI.

Acceptable implementations:
- an authenticated admin API endpoint
- a protected Mix task
- another Elixir-side operator tool

The Go CLI consumes the exported config but does not decrypt CNPG rows directly.

### Security boundary
- Go baseline CLI may consume plaintext credentials supplied explicitly by an operator or exported by a ServiceRadar-managed helper.
- Go baseline CLI must not query CNPG encrypted credential columns and must not implement its own AshCloak/Vault decryption logic.

### Comparison workflow
The tool should be shaped so a later phase can compare:
1. raw mapper outputs
2. ingested CNPG topology rows
3. God View snapshot projections

That comparison does not need to ship in phase 1, but phase 1 output must be stable enough to support it.
