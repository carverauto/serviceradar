# Change: Harden Core-ELX Camera Ingress And Analysis Fetch

## Why
The security review baseline found two unowned trust-boundary gaps in `serviceradar_core_elx`: the core-side camera media gRPC ingress can still fail open on transport identity, and the analysis-worker HTTP dispatch/probe path will issue raw requests to configured worker URLs without outbound fetch validation.

## What Changes
- Require the core-elx camera media ingress gRPC service to run with mTLS only and fail closed when trust material is absent.
- Require core-elx analysis worker HTTP delivery and health probing to validate outbound targets and bind connections to the validated address instead of performing raw `Req` fetches.
- Tighten analysis worker endpoint handling so unsafe worker URLs are rejected before dispatch and probing.

## Impact
- Affected specs: `edge-architecture`, `camera-streaming`
- Affected code:
  - `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/application.ex`
  - `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/camera_relay/analysis_http_adapter.ex`
  - `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/camera_relay/analysis_worker_resolver.ex`
  - `elixir/serviceradar_core/lib/serviceradar/camera/analysis_worker.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/camera_analysis_worker_controller.ex`
