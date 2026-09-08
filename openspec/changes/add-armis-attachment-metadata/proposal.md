# Change: Preserve Armis attachment metadata

## Why
Operators need to reconcile Armis device posture with ServiceRadar reachability and topology evidence. Live CNPG inspection showed active Armis-discovered devices are stored without the Armis UI fields that identify wired attachment context, such as Access Switch, VLAN, DHCP lease type, and connection type.

## What Changes
- Pass non-secret integration source settings to sync agents so Armis field selection can be configured per source.
- Enrich v1 AQL sync pages with configured Armis v3 asset fields by Armis asset ID when v3 credentials are present.
- Preserve Armis attachment fields from raw asset/device payloads under stable `armis_*` metadata keys.
- Add local probe tooling for sampling Armis AQL queries and validating v3 field behavior without deploying ServiceRadar.
- Add operator-facing Armis v3 OAuth credential fields while retaining the existing v1 credential path.
- Keep current Armis v1 sync behavior compatible while allowing tenant-specific Armis field names to be captured when the API returns them.

## Impact
- Affected specs: `sync-service-integrations`, `device-inventory`
- Affected code: Armis sync-source driver, Armis API client, sync config generator, sync source model, integration source UI, local tools, tests
- Operational impact: existing Armis sources continue to sync with default behavior; deployments can add source settings to request/preserve attachment fields.
