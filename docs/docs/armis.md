---
title: Armis Integration
---

# Armis Integration

ServiceRadar ingests Armis device intelligence to enrich inventory, surface unmanaged assets, and drive risk-based alerting. The integration runs through the embedded sync runtime in the ServiceRadar agent and optionally uses the Faker generator for demos.

## Prerequisites

- Armis API client credentials with read access to your account.
- A ServiceRadar agent with outbound connectivity to the Armis API.
- Armis credentials stored in the integration config (managed through the UI or API).

## Enabling the Integration

1. Create an Armis integration source in **Integrations → New Source** and provide the API URL, client ID, and secret.
2. Ensure a sync-capable agent is connected. If running in Kubernetes, watch `kubectl logs deploy/serviceradar-agent -n <namespace>` for `armis_sync` messages confirming pagination progress.
3. Confirm imported devices in the registry via `srql`:
   `in:devices source:armis sort:risk_score:desc limit:20`.

## Alerting and Enrichment

- Sync attaches Armis risk scores and device tags; combine them with SNMP status to prioritize outages.
- Use the [Service Port Map](./service-port-map.md) to overlay Armis risk data on topology diagrams.

## Query Labels

Each configured Armis search query can have a label, such as `managed` or `unmanaged`. The agent stores that value on imported inventory devices as `metadata.query_label`, alongside `metadata.integration_type:armis`.

Use SRQL metadata filters to find devices imported by a specific Armis query:

```srql
in:devices metadata.integration_type:armis metadata.query_label:managed
```

```srql
in:devices metadata.integration_type:armis metadata.query_label:unmanaged
```

To list all Armis-imported devices:

```srql
in:devices metadata.integration_type:armis
```

If a label contains spaces, quote it:

```srql
in:devices metadata.integration_type:armis metadata.query_label:"managed devices"
```

If the same device matches multiple Armis queries, `metadata.query_label` reflects the latest sync update for that device. Keep query labels mutually exclusive when you need stable segmentation.

## Troubleshooting

- Authentication failures usually mean expired client secrets—rotate them in the integration config and confirm the agent is online.
- Large accounts may hit rate limits; tune `page_size` and enable incremental sync by storing the `last_seen` cursor.
- For ingestion gaps, consult the [Troubleshooting Guide](./troubleshooting-guide.md#armis) and cross-check Faker vs. production statistics.

## Large Ingestion Validation

Before releasing changes that touch Armis sync, sync result streaming, ResultsRouter, identity reconciliation, sweep ingestion, or mapper promotion, run the large-ingestion release gate against an isolated CNPG database:

```bash
scripts/validate-large-ingestion.sh
```

The gate exercises two paths:

- The agent fetches two configured Armis queries, refreshes the access token after an intentional `401`, pages 50k fake devices, and emits the same `StreamStatus` result chunks used in production.
- Core receives gateway-style sync chunks through `ResultsRouter`, ingests them into inventory, and asserts final device, identifier, and query-label counts.

Use `$srql-fixtures-db-tests` to create the scratch CNPG database first when `SERVICERADAR_TEST_DATABASE_URL` is not already set. The validation defaults to 50k devices and 1k-device chunks; override with `SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT` and `SERVICERADAR_LARGE_INGESTION_CHUNK_SIZE` for a smaller local smoke run.

During a live run, the agent logs one `Starting Armis sync` event and one `Armis page streamed` event per page. The page log includes `run_id`, `query_label`, `page_index`, `from`, `armis_result_count`, `filtered_count`, `streamed_count`, `run_streamed_total`, `armis_total`, `next`, and `token_refresh_count`.
