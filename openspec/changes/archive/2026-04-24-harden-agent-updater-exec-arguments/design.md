## Context
Managed release activation is split across two steps:

1. The agent validates and stages the release payload.
2. The agent spawns `serviceradar-agent-updater` with the staged version plus command metadata used for activation reporting.

The trust-boundary hardening in SR-2026-001 already fixed which updater binary runs and which release verification key is authoritative. SR-2026-002 is narrower: it closes the remaining gap where network-sourced strings are forwarded into updater argv without a dedicated validation boundary at exec time.

## Goals / Non-Goals
- Goals:
  - Ensure the updater only receives canonical managed-release activation arguments.
  - Fail closed before `exec` when gateway-provided command metadata is malformed or unexpected.
  - Keep the command metadata that feeds activation reporting aligned with the control-plane contract.
- Non-Goals:
  - Reworking the updater CLI shape.
  - Adding a generic command-validation framework for every agent command.
  - Changing the release staging signature/digest verification model.

## Decisions
- Decision: Validate the updater-bound release version with a strict safe-token format.
  - Rationale: the current directory-safety check prevents path traversal but still accepts characters that have no business crossing an exec boundary.
- Decision: Require `command_id` to be a canonical UUID.
  - Rationale: the protobuf contract and control-plane persistence already model release command IDs as UUIDs.
- Decision: Restrict `command_type` to the managed release command type set, currently only `agent.update_release`.
  - Rationale: the updater activation path exists specifically for managed release activation, not arbitrary command replay.
- Decision: Reject any control characters, including NUL, in updater-bound activation arguments.
  - Rationale: this keeps argv and log surfaces deterministic even if future updater code or wrappers change.

## Risks / Trade-offs
- If an older or non-conforming control-plane component emits malformed release command metadata, activation will now fail closed.
  - Mitigation: this is the desired security posture, and the current release manager already issues UUID command IDs and the canonical release command type.
- Tightening version format may reject unusual historical version strings.
  - Mitigation: keep the allowed character set aligned with existing release tags and bounded in length.

## Open Questions
- Should activation reject non-canonical-but-parseable UUID forms, or only reject values that are not UUIDs at all?
- Should the updater binary itself also revalidate these fields for defense in depth, or is agent-side validation sufficient for now?
