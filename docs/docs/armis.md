---
title: Armis Integration
---

# Armis Integration

ServiceRadar ingests Armis device intelligence to enrich inventory, surface unmanaged assets, and drive risk-based alerting. The integration runs through the Sync service and optionally uses the Faker generator for demos.

## Prerequisites

- Armis API client credentials with read access to your tenant.
- A dedicated Sync worker or Kubernetes deployment with outbound connectivity to the Armis API.
- KV entries for API keys and pagination cursors; see the [KV configuration guide](./kv-configuration.md) for secure storage tips.

## Enabling the Integration

1. Populate the Sync config with the Armis connector block:

   ```json
   {
     "integrations": {
       "armis": {
         "api_url": "https://<tenant>.armis.com/api/v1",
         "client_id": "${kv:secrets/armis/client_id}",
         "client_secret": "${kv:secrets/armis/client_secret}",
         "page_size": 500
       }
     }
   }
   ```

2. Deploy or restart the `serviceradar-sync` workload. Watch `kubectl logs` for `armis_sync` messages confirming pagination progress.
3. Confirm imported devices in the registry via `srql`:  
   `SELECT uid, hostname, risk_score FROM registry.devices WHERE source = 'armis' LIMIT 20;`.

## Demo and Testing

- The [Armis Faker](./agents.md#armis-faker-service) synthesizes data sets for local or CI demos. Mount the `serviceradar-faker-data` PVC to persist generated inventories.
- Resetting Faker? Follow the Agents runbook to truncate Proton tables and replay canonical devices.

## Alerting and Enrichment

- Sync attaches Armis risk scores and device tags; combine them with SNMP status to prioritize outages.
- Use the [Service Port Map](./service-port-map.md) to overlay Armis risk data on topology diagrams.
- Export curated Armis datasets to third-party tools through the [MCP integration](./mcp-integration.md).

## Troubleshooting

- Authentication failures usually mean expired client secrets—rotate them in KV and redeploy Sync.
- Large tenants may hit rate limits; tune `page_size` and enable incremental sync by storing the `last_seen` cursor.
- For ingestion gaps, consult the [Troubleshooting Guide](./troubleshooting-guide.md#armis) and cross-check Faker vs. production statistics.
