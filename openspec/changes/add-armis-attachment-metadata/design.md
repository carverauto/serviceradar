## Context
Armis exposes endpoint attachment context in the UI, including Access Switch, VLAN, connection type, and DHCP lease type. ServiceRadar currently ingests Armis device identity and posture fields but does not persist these attachment fields in CNPG metadata or topology tables.

The current Go Armis sync driver uses the Armis v1 search endpoint and maps only known struct fields. Unknown response fields are dropped during JSON decoding, so tenant-specific field names cannot be captured without code support.

## Goals
- Preserve attachment evidence when Armis returns it in device or asset payloads.
- Let operators configure additional Armis field names without rebuilding the product.
- Request configured attachment fields from Armis v3 by asset ID after the existing v1 AQL search identifies each page of devices.
- Provide operator-facing storage for Armis v3 OAuth client credentials needed by the enrichment request.
- Provide a local probe tool that can sample production AQL queries and discover tenant field behavior without a full ServiceRadar build/deployment.
- Store attachment evidence as source metadata until a later topology-normalization change can promote it into a first-class topology edge model.
- Avoid changing current Armis v1 sync behavior for deployments that do not configure extra fields.

## Non-Goals
- Infer ServiceRadar topology links from Armis attachment strings.
- Treat endpoint NIC inventory (`network_interfaces`) as switch attachment evidence.

## Decisions
- Decision: Preserve raw configured/default Armis attachment fields under normalized metadata keys with the `armis_` prefix.
  - Rationale: The Armis tenant can expose field names that are not represented in the current struct. Capturing selected raw fields avoids dropping data needed for reports and later topology normalization.
- Decision: Pass a sanitized `settings` map from `IntegrationSource.settings` to agent sync configuration.
  - Rationale: Source-owned settings are the existing control-plane mechanism for per-integration tuning. Credentials remain in the credential payload, while field selection and metadata-capture options live in settings.
- Decision: Use Armis v3 asset search only as an enrichment step after v1 AQL results are fetched.
  - Rationale: Existing integration sources already rely on tenant AQL. Enriching by asset ID avoids translating AQL into v3 filter syntax and keeps current source selection behavior intact.
- Decision: Keep v1 API credentials and v3 OAuth credentials side by side during migration.
  - Rationale: Existing deployments still need v1 AQL selection until the integration has a complete v3 search implementation. V3 enrichment requires `client_id`, `client_secret`, and `vendor_id`, which are not equivalent to the existing v1 API key and secret.
- Decision: Keep raw field preservation bounded to default attachment candidates plus configured `extra_metadata_fields`.
  - Rationale: Storing every raw Armis field would bloat CNPG metadata and increase the chance of secret or high-cardinality data leakage.

## Risks / Trade-offs
- Field names may differ between Armis tenants. Mitigation: allow operators to configure additional field names and preserve both camelCase and snake_case defaults.
- Metadata strings are not normalized topology edges. Mitigation: use stable `armis_*` keys now and leave topology promotion for a later spec once evidence semantics are validated.
- If configured Armis v3 credentials lack the required scopes, the sync will fail before emitting incomplete enriched data. Mitigation: error messages identify missing local credential names or upstream response bodies without logging secret values.

## Migration Plan
1. Deploy code with default attachment field preservation.
2. Add `asset_fields` settings to the Armis integration source for tenant-specific field names and configure Armis v3 credentials (`client_id`, `client_secret`, `vendor_id`).
3. Use `extra_metadata_fields` only for fields already present in raw v1 payloads.
4. Before deployment, run the local Armis API probe against a small AQL sample to verify field names such as `accessSwitch` and `vlans`.
5. Trigger an Armis sync and verify `ocsf_devices.metadata` includes keys such as `armis_access_switch`, `armis_vlans`, `armis_connection_type`, and `armis_dhcp_lease_type` when Armis returns them.
