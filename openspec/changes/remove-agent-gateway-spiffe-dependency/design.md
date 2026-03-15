## Context
ServiceRadar already distinguishes between two mTLS worlds:
- internal platform gRPC, where SPIFFE or SPIRE remains a supported identity mechanism for Kubernetes workloads such as datasvc clients
- hosted edge-agent ingress, where agents connect to `serviceradar-agent-gateway` over public or semi-public gRPC using deployment-managed mTLS certificates

The hosted edge-agent path was intentionally moved away from requiring SPIFFE. The enrollment design already says gateway-issued certificates replace SPIFFE for edge agents, and the default demo and Helm docs treat SPIFFE as opt-in. However, the current gateway resolver still reads `component_type` from a SPIFFE URI SAN and rejects certificates that omit it.

That is the wrong long-term boundary. Hosted edge-agent ingress should remain secure through tenant CA validation and certificate subject parsing, but it should not require SPIFFE-specific identity material.

## Goals / Non-Goals
- Goals:
  - Remove SPIFFE as a required identity input for hosted edge-agent authentication.
  - Keep hosted edge-agent mTLS secure with tenant-scoped CA validation and certificate subject parsing.
  - Preserve backward compatibility with already-issued certificates that still include SPIFFE URI SANs.
  - Keep internal platform SPIFFE support unchanged.
- Non-Goals:
  - Remove SPIFFE support from internal platform gRPC.
  - Redesign the entire tenant or partition identity model.
  - Introduce a new external identity system for edge agents.

## Decisions
- Decision: Hosted edge-agent authentication will use tenant CA validation plus certificate CN parsing as the required identity path.
  - Rationale: This is already compatible with the gateway-issued certificate model and does not require SPIFFE infrastructure.

- Decision: For the hosted edge-agent path, `component_type` defaults to `agent` when the certificate lacks a SPIFFE SAN or other explicit type field.
  - Rationale: The hosted edge-agent ingress path currently serves agents. Requiring a SPIFFE SAN solely to restate `agent` creates unnecessary coupling to deprecated infrastructure.

- Decision: Existing SPIFFE URI SAN parsing remains supported as a compatibility input during transition, but absence of a SPIFFE SAN is not an authentication failure for hosted edge-agent traffic.
  - Rationale: This avoids breaking already-issued certificates while removing SPIFFE as a normative dependency.

- Decision: Gateway-issued agent certificates should no longer be required to embed a SPIFFE URI SAN for hosted edge-agent use.
  - Rationale: The issuer should produce certificates aligned with the supported default deployment path.

## Risks / Trade-offs
- Existing code paths may assume `component_type` always arrives from a SAN.
  - Mitigation: normalize hosted edge-agent `component_type` to `agent` before authorization.

- There may be older telemetry or audit fields that still refer to SPIFFE identity.
  - Mitigation: keep compatibility parsing and avoid removing observability fields immediately.

- Future non-agent edge clients may need explicit type discrimination again.
  - Mitigation: if that path appears, add a non-SPIFFE explicit identity field or issuance rule rather than reviving SPIFFE as a hard requirement.

## Migration Plan
1. Update the spec so hosted edge-agent identity no longer requires SPIFFE.
2. Update gateway certificate resolution to accept certificates without SPIFFE SANs.
3. Default hosted edge-agent `component_type` to `agent`.
4. Update gateway-issued certificate bundles to stop requiring SPIFFE SAN emission for hosted edge agents.
5. Keep compatibility tests for older certificates that still include SPIFFE SANs.

## Open Questions
- Should gateway-issued certificates continue emitting SPIFFE SANs behind an explicit compatibility flag for a short transition period, or should emission stop immediately once the gateway no longer requires them?
