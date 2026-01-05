# ServiceRadar Sync Runtime (embedded in agent)

## Overview

The ServiceRadar sync runtime runs inside `serviceradar-agent`. It polls external
data sources, transforms the data, and pushes device updates through the
agent/agent-gateway pipeline so DIRE can reconcile them into canonical devices.
There is no standalone sync binary or separate deployment.

The runtime operates on a configurable polling interval. On each poll, it
concurrently fetches data from all configured sources. For certain integrations,
like Armis, it can perform two-way synchronization (for example, pushing
availability data back into Armis).

## Configuration Delivery

Integration sources are configured per tenant in the UI (Integrations -> New
Source). Core stores the configuration in CNPG and delivers it to the agent via
`GetConfig`. The sync runtime keeps the config in memory and reloads it whenever
the gateway publishes updates.

### Example integration payload (JSON)

```json
{
  "poll_interval": "10m",
  "discovery_interval": "5m",
  "update_interval": "5m",
  "sources": {
    "armis_prod": {
      "type": "armis",
      "endpoint": "https://my-armis-instance.armis.com",
      "poll_interval": "15m",
      "batch_size": 500,
      "insecure_skip_verify": false,
      "credentials": {
        "secret_key": "your-armis-api-secret-key",
        "enable_status_updates": "true",
        "api_key": "your-serviceradar-api-key",
        "serviceradar_endpoint": "http://localhost:8080",
        "page_size": "500"
      },
      "queries": [
        {
          "label": "corporate_devices",
          "query": "in:devices boundaries:\"Corporate\""
        },
        {
          "label": "iot_devices",
          "query": "in:devices category:\"IoT\""
        }
      ]
    },
    "netbox_dc1": {
      "type": "netbox",
      "endpoint": "https://netbox.example.com",
      "credentials": {
        "api_token": "your-netbox-api-token",
        "expand_subnets": "false"
      }
    }
  }
}
```

### Top-Level Configuration

| Key                 | Type     | Description                                                                                     | Required |
| ------------------- | -------- | ----------------------------------------------------------------------------------------------- | -------- |
| `poll_interval`      | `string` | Interval at which to poll all sources (Go duration format, e.g., `"5m"`, `"1h"`).               | No       |
| `discovery_interval` | `string` | Interval at which to refresh device discovery results (Go duration format).                     | No       |
| `update_interval`    | `string` | Interval at which to push external updates (if enabled).                                        | No       |
| `logging`            | `object` | Logging configuration for the sync runtime.                                                     | No       |
| `sources`            | `object` | Map of one or more data sources. Keys are user-defined source names.                            | **Yes**  |

### Source Configuration

Each entry in the `sources` map defines a connection to an external system.

| Key                    | Type      | Description                                                                                                   | Required |
| ---------------------- | --------- | ------------------------------------------------------------------------------------------------------------- | -------- |
| `type`                 | `string`  | Integration type. Supported values are `armis` and `netbox`.                                                 | **Yes**  |
| `endpoint`             | `string`  | Base URL for the source API.                                                                                  | **Yes**  |
| `prefix`               | `string`  | Optional namespace prefix for device identifiers emitted by this source.                                      | No       |
| `insecure_skip_verify` | `boolean` | If `true`, the HTTP client will skip TLS verification. Use with caution.                                      | No       |
| `credentials`          | `object`  | Integration-specific credentials and settings.                                                                | **Yes**  |
| `queries`              | `array`   | (Armis only) AQL queries to run against the Armis API.                                                        | **Yes**  |
| `poll_interval`        | `string`  | Optional per-source override for `poll_interval`.                                                             | No       |
| `sweep_interval`       | `string`  | How often agents should sweep discovered networks (Go duration format).                                       | No       |
| `batch_size`           | `integer` | (Armis only) Devices per batch when syncing updates back to Armis (default: 500).                             | No       |

---

## Armis Integration (`type: "armis"`)

The Armis integration fetches device information based on one or more Armis
Query Language (AQL) queries and emits updates for the agent/agent-gateway
pipeline.

### Core Configuration

- `endpoint`: Base URL of your Armis instance (e.g., `https://my-instance.armis.com`).
- `credentials.secret_key`: API secret key generated in the Armis console.
- `queries`: Array of objects containing:
  - `label`: A descriptive name for the query.
  - `query`: The AQL string to execute.

### Armis Updater & Correlation (Optional)

This feature allows the sync runtime to "close the loop" by taking network
reachability data from ServiceRadar sweeps and pushing it back into Armis.

To enable it, configure the sync runtime to communicate with the ServiceRadar
API:

- `credentials.enable_status_updates`: Set to `"true"` to enable updates.
- `credentials.api_key`: API key for the ServiceRadar API.
- `credentials.serviceradar_endpoint`: Base URL for the ServiceRadar API.

> **Important:** The Armis integration uses two different keys:
> 1. `secret_key` for the Armis API (device data)
> 2. `api_key` for the ServiceRadar API (sweep results)

### Optional Parameters

- `credentials.page_size`: Number of devices per API request (default: `100`).

---

## NetBox Integration (`type: "netbox"`)

The NetBox integration fetches all devices with a primary IP address from a
NetBox instance.

- `endpoint`: Base URL of your NetBox instance (e.g., `https://netbox.example.com`).
- `credentials.api_token`: API token generated from your NetBox user profile.
- `credentials.expand_subnets`: (Optional) Use full CIDR notation for sweep config
  when set to `"true"`; otherwise treat each IP as `/32`.

---

## Security (mTLS)

Sync uses the agent's mTLS identity when connecting to the agent-gateway. There
is no sync-specific TLS configuration; ensure the agent itself is configured for
gateway mTLS as part of its bootstrap configuration.
