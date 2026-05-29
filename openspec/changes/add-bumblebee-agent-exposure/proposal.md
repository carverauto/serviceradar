# Change: Add Bumblebee developer endpoint exposure scanning

## Why
Developer endpoints can carry compromised package, extension, and tool metadata that is not visible in deployed SBOMs or runtime telemetry. ServiceRadar agents need a read-only way to scan local developer state, compare it with a reviewed exposure catalog, and surface endpoint risk through the normal control-plane observability model.

## What Changes
- Add an opt-in root-owned Bumblebee scanner service for macOS and Linux hosts, with `serviceradar-agent` ingesting sanitized scan output while remaining non-root.
- Keep the base `serviceradar-agent` RPM/deb minimal; deploy the privileged scanner helper, config, and scheduler as an explicit native capability add-on rather than installing root components by default.
- Deliver Bumblebee scan configuration through the existing agent configuration flow, with local filesystem override support for emergency response.
- Add a control-plane exposure catalog model seeded from the upstream Bumblebee catalog and refreshed by an AshOban job.
- Normalize Bumblebee finding records into ServiceRadar observability events and device/agent risk posture without storing full local inventory by default.
- Associate Bumblebee posture with the canonical device record for the reporting agent.
- Provide operator-visible scan health, catalog version, coverage, and finding/risk summaries in device details.

## Impact
- Affected specs: `agent-configuration`, `ash-jobs`, `observability-signals`, `device-inventory`, `build-web-ui`
- Affected code: `go/cmd/agent`, Bumblebee scanner helper/add-on packaging, agent config protobufs/compilers, `elixir/serviceradar_core` Ash resources/jobs/migrations, agent-gateway ingest path, device detail APIs, web-ng risk/observability surfaces
- External dependency: vendored `github.com/perplexityai/bumblebee` scanner package, pinned and packaged with ServiceRadar release artifacts
