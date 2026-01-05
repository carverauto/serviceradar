---
title: Armis Integration
---

# Armis Integration

ServiceRadar ingests Armis device intelligence to enrich inventory, surface unmanaged assets, and drive risk-based alerting. The integration runs through the embedded sync runtime in the ServiceRadar agent and optionally uses the Faker generator for demos.

## Prerequisites

- Armis API client credentials with read access to your tenant.
- A ServiceRadar agent with outbound connectivity to the Armis API.
- Armis credentials stored in the integration config (managed through the UI or API).

## Enabling the Integration

1. Create an Armis integration source in **Integrations → New Source** and provide the API URL, client ID, and secret.
2. Ensure a sync-capable agent is connected. Watch `kubectl logs deploy/serviceradar-agent -n demo` for `armis_sync` messages confirming pagination progress.
3. Confirm imported devices in the registry via `srql`:
   `in:devices source:armis sort:risk_score:desc limit:20`.

## Demo and Testing

- The [Armis Faker](./agents.md#armis-faker-service) synthesizes data sets for local or CI demos. Mount the `serviceradar-faker-data` PVC to persist generated inventories.
- Resetting Faker? Follow the Agents runbook to truncate CNPG tables and replay canonical devices.

## Alerting and Enrichment

- Sync attaches Armis risk scores and device tags; combine them with SNMP status to prioritize outages.
- Use the [Service Port Map](./service-port-map.md) to overlay Armis risk data on topology diagrams.
- Export curated Armis datasets to third-party tools through the [MCP integration](./mcp-integration.md).

## Troubleshooting

- Authentication failures usually mean expired client secrets—rotate them in the integration config and confirm the agent is online.
- Large tenants may hit rate limits; tune `page_size` and enable incremental sync by storing the `last_seen` cursor.
- For ingestion gaps, consult the [Troubleshooting Guide](./troubleshooting-guide.md#armis) and cross-check Faker vs. production statistics.
