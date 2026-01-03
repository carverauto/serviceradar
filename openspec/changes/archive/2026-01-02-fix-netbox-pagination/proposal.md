# Change: Fetch all NetBox devices across paginated API responses

## Why
The NetBox sync integration currently fetches device inventory from `/api/dcim/devices/` but does not implement pagination. NetBox paginates list responses (default 50), so environments with >50 devices silently miss inventory and can incorrectly retract previously discovered devices during reconciliation.

## What Changes
- Follow NetBox pagination (`next`) until all device pages are retrieved for both discovery (`Fetch`) and reconciliation (`Reconcile`).
- Ensure pagination failures (HTTP status, decode errors) abort the operation rather than producing partial results.
- Improve discovery/reconciliation logging to reflect the total devices processed across all pages (optionally include API `count` and pages fetched).
- Add regression tests simulating paginated NetBox responses.

## Impact
- Affected specs: `netbox-integration` (new capability spec via this change)
- Affected code: `pkg/sync/integrations/netbox/netbox.go`, tests under `pkg/sync/integrations/netbox/`
- Compatibility:
  - **Behavioral change**: discovery and reconciliation will now operate on the full NetBox device set (previously only the first page).
  - Potentially increased NetBox API requests for large inventories (mitigation: use larger `limit` where supported and/or follow NetBox rate-limit guidance).

## Acceptance Criteria
- When NetBox returns paginated device responses, the integration fetches and processes devices from all pages.
- Reconciliation does not generate retractions for devices that exist on subsequent pages.
- Any pagination failure causes the operation to fail fast and avoids emitting partial discovery results or submitting retractions.
- Unit tests cover multi-page success and mid-pagination failure behavior.

## Rollout Plan
- Land code + tests, then validate against a NetBox instance with >50 devices.
- Monitor sync logs for total discovered devices matching NetBox `count` and for absence of unexpected retractions.

## References
- GitHub issue: https://github.com/carverauto/serviceradar/issues/2149

