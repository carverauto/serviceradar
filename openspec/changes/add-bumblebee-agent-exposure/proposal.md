# Change: Add Bumblebee developer endpoint exposure scanning

## Why
Developer endpoints can carry compromised package, extension, and tool metadata that is not visible in deployed SBOMs or runtime telemetry. ServiceRadar agents need a read-only way to scan local developer state, compare it with a reviewed exposure catalog, and surface endpoint risk through the normal control-plane observability model.

## What Changes
- Add an opt-in root-owned Bumblebee scanner service for macOS and Linux hosts, with `serviceradar-agent` ingesting sanitized scan output while remaining non-root.
- Deliver Bumblebee scan configuration through the existing agent configuration flow, with local filesystem override support for emergency response.
- Add a control-plane exposure catalog model seeded from the upstream Bumblebee catalog and refreshed by an AshOban job.
- Normalize Bumblebee finding records into ServiceRadar observability events and device/agent risk posture without storing full local inventory by default.
- Associate Bumblebee posture with the canonical device record for the reporting agent.
- Provide operator-visible scan health, catalog version, coverage, and finding/risk summaries in device details.

## Impact
- Affected specs: `agent-configuration`, `ash-jobs`, `observability-signals`, `device-inventory`, `build-web-ui`
- Affected code: `go/cmd/agent`, Bumblebee scanner service packaging, agent config protobufs/compilers, `elixir/serviceradar_core` Ash resources/jobs/migrations, agent-gateway ingest path, device detail APIs, web-ng risk/observability surfaces
- External dependency: `github.com/perplexityai/bumblebee` CLI or vendored scan package, pinned and packaged with ServiceRadar release artifacts
