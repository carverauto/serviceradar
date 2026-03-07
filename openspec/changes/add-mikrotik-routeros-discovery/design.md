## Context

ServiceRadar already supports provider-specific API discovery for UniFi through a provider-specific resource (`MapperUnifiController`), compiler output (`unifi_apis`), and Go poller (`ubnt_poller.go`). MikroTik support should follow that proven edge-executed pattern instead of moving discovery into Elixir/core.

Two RouterOS API surfaces are relevant:

- The official RouterOS API service (`8728`/`8729`), referenced in issue `#2793`.
- The RouterOS REST API available on newer RouterOS releases, which maps naturally to the existing HTTP-based mapper architecture and matches the `mikrotik_api` Hex package the user linked.

The linked `mikrotik_api` Hex package is useful as a reference for endpoint coverage and expected behavior, but it is not an appropriate runtime dependency for this feature because discovery must execute from `serviceradar-agent` in Go.

The repo also already contains:

- MikroTik device enrichment rules in `elixir/serviceradar_core/priv/device_enrichment/rules/mikrotik.yaml`
- Sync-side vendor/model inference hooks for MikroTik OIDs
- Test fixtures and topology assertions mentioning MikroTik devices

What is missing is an actual API-backed discovery source.

## Goals

- Add a read-only RouterOS discovery source that runs inside the Go mapper/agent.
- Reuse existing mapper jobs, scheduled execution, result publishing, and ingestion paths.
- Persist RouterOS connection settings securely in core with the same admin UX model used for UniFi.
- Use RouterOS data to improve inventory quality even when SNMP is incomplete.
- Validate against the live MikroTik CHR target in `demo`.

## Non-Goals

- Full generic controller abstraction across UniFi, MikroTik, Aruba, and future vendors.
- Support for both RouterOS REST and binary APIs in the first release.
- Push/configuration workflows.
- WiFi-specific RouterOS features.

## Decisions

### Decision: Implement RouterOS collection in Go mapper, not Elixir/core

The mapper already runs on edge agents close to the target network and already handles provider API polling for UniFi. Adding RouterOS there preserves the current deployment model, avoids exposing RouterOS reachability to core, and keeps discovery collection consistent across providers.

This change explicitly rejects an architecture where the agent exposes a raw RouterOS socket back to core-elx or tunnels RouterOS sessions over the existing gRPC pipeline so Elixir can own the client protocol. That approach would add:

- a stateful transport proxy inside the agent
- a second protocol hop for every RouterOS request
- split responsibility for secrets, retries, and session lifecycle
- a more fragile failure model than direct edge-side collection

If RouterOS support needs a non-REST transport later, that transport should still be implemented inside the Go agent/mapper boundary.

### Decision: Target RouterOS REST API first

The first implementation should use RouterOS REST API over HTTPS.

Why:

- It aligns with the existing UniFi HTTP client pattern in `go/pkg/mapper/ubnt_poller.go`.
- It avoids introducing a second transport/protocol stack into mapper before the shape of the feature is proven.
- It matches the `mikrotik_api` Hex package closely enough to use that package as a reference model for endpoint coverage without depending on Elixir at runtime.
- The live CHR validation target is expected to be on RouterOS 7, where REST API support is practical.

Alternative considered:

- RouterOS binary API first. Rejected for the initial proposal because it adds protocol complexity, session/state handling, and new parsing/runtime concerns without a clear product need yet. We can add it later if REST proves insufficient.

### Decision: Use a dedicated RouterOS source resource, not a generic controller table

The current codebase is still provider-specific end to end:

- `MapperUnifiController`
- `unifi_apis`
- `unifi_api_urls`
- `unifi_api_names`

Forcing a generic abstraction first would turn this proposal into a broader refactor and block value on a large prerequisite. The first MikroTik change should add a dedicated resource and compiler output with shared conventions where practical, while leaving room for a later consolidation change.

### Decision: Keep the first pass strictly read-only discovery

This proposal is about discovery parity, not device management. The RouterOS source must only collect metadata required for:

- device identity/inventory enrichment
- interface inventory
- bridge/VLAN relationships
- topology/neighbor evidence

No write, exec, or configuration endpoints should be used.

## Proposed Data Coverage

The first pass should collect, where available:

- Device identity: system identity, board/model, RouterOS version, serial number, architecture
- Interface inventory: ethernet, bridge, VLAN, bonding, loopback/tunnel-style interfaces as exposed by RouterOS
- L2/L3 context: bridge port membership, VLAN membership, IP addresses
- Topology evidence: LLDP or RouterOS neighbor data sufficient to emit mapper topology links when reliable
- Metadata hints for inventory: vendor/model/os/hardware fields and RouterOS-specific provenance markers

## Integration Shape

### Core / Ash

- Add a `MapperMikrotikController`-style resource under `ServiceRadar.NetworkDiscovery`
- Store endpoint, username, password/token, TLS settings, optional scope selectors
- Encrypt secrets with AshCloak
- Attach resources to existing `MapperJob`
- Extend mapper compiler output to include RouterOS endpoints and per-job selector options

### Go Mapper

- Add a RouterOS poller alongside the UniFi poller
- Reuse existing scheduled job execution and result publication
- Normalize RouterOS responses into existing `DiscoveredDevice`, `DiscoveredInterface`, and `TopologyLink` structures
- Mark metadata/source provenance so ingestion can distinguish `mikrotik-api` evidence from `snmp`, `lldp`, and `unifi-api`

### Inventory / Ingestion

- Merge RouterOS-derived metadata into the existing device enrichment and DIRE pipeline
- Prefer RouterOS vendor/model/version/serial signals when they are stronger than existing placeholders
- Preserve existing MikroTik SNMP enrichment rules as fallback behavior

## Risks / Trade-offs

- RouterOS REST coverage varies by firmware/version.
  - Mitigation: treat unsupported resources as partial discovery, not hard failure.
- RouterOS API data may overlap with SNMP and create duplicate evidence.
  - Mitigation: tag source provenance clearly and merge on stable device/interface identifiers.
- Provider-specific resources can multiply over time.
  - Mitigation: keep naming and compiler conventions aligned so a later generic controller refactor remains possible.

## Validation Plan

- Unit tests for RouterOS response normalization and selector handling.
- Integration tests for Ash resource validation, compiler output, and mapper ingestion.
- Live validation against the demo MikroTik CHR target in the `demo` environment, including:
  - successful authentication
  - device identity ingestion
  - interface inventory publication
  - at least one topology or neighbor evidence path if the target exposes it

### Demo Baseline Note

On 2026-03-06, the known demo CHR device (`sr:36e0e348-6da6-4474-bb3c-f7af1eb4d5b8`, management IP `192.168.6.167`) was inspected directly in CNPG before deploying the new RouterOS API path. The current live baseline is:

- `vendor_name = MikroTik`
- `model = RouterOS`
- `os = {}`
- `hw_info = {}`
- no `mapper_topology_links` rows for that device

This confirms the target exists and is suitable for validation, but it also confirms that post-deploy verification is still required to prove RouterOS version, serial, architecture, and neighbor evidence ingestion end to end.

## References

- Issue `#2793`
- MikroTik RouterOS API docs: `https://help.mikrotik.com/docs/spaces/ROS/pages/47579160/API`
- MikroTik RouterOS REST API docs: `https://help.mikrotik.com/docs/spaces/ROS/pages/47579162/REST+API`
- `mikrotik_api` Hex package: `https://hexdocs.pm/mikrotik_api/readme.html`
