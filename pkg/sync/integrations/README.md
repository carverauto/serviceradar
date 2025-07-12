# ServiceRadar Sync Package (`serviceradar-sync`)

## Overview

The ServiceRadar Sync package (`serviceradar-sync`) is a standalone service responsible for polling external data sources, transforming the data, and synchronizing it with the ServiceRadar Key-Value (KV) store. It acts as the primary mechanism for populating ServiceRadar with device and asset information from third-party systems like Armis and Netbox.

The service operates on a configurable polling interval. On each poll, it concurrently fetches data from all configured sources. For certain integrations, like Armis, it can also perform advanced two-way synchronization, such as enriching the source system with data collected by ServiceRadar.

## Configuration

The service is configured using a single JSON file, typically named `config.json`. The path to this file is specified using the `-config` command-line flag.

```bash
./serviceradar-sync -config /path/to/your/config.json
```

### Example `config.json`

Here is a complete example demonstrating the configuration for both Armis (with the updater enabled) and Netbox sources.

```json
{
  "kv_address": "localhost:8443",
  "poll_interval": "10m",
  "security": {
    "cert_dir": "/etc/serviceradar/tls",
    "cert_file": "sync.crt",
    "key_file": "sync.key",
    "ca_file": "ca.crt"
  },
  "sources": {
    "armis_prod": {
      "type": "armis",
      "endpoint": "https://my-armis-instance.armis.com",
      "prefix": "devices/armis/",
      "poll_interval": "15m",
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
      "prefix": "devices/netbox/",
      "credentials": {
        "api_token": "your-netbox-api-token",
        "expand_subnets": "false"
      }
    }
  }
}
```

### Top-Level Configuration

| Key              | Type     | Description                                                                                             | Required |
| ---------------- | -------- | ------------------------------------------------------------------------------------------------------- | -------- |
| `kv_address`     | `string` | The gRPC address (e.g., `host:port`) of the ServiceRadar KV store.                                      | **Yes**  |
| `poll_interval`  | `string` | The interval at which to poll all sources. Uses Go's `time.ParseDuration` format (e.g., "5m", "1h").    | No       |
| `security`       | `object` | Configuration for mTLS when communicating with the KV store. See the [Security](#security-mtls) section. | No       |
| `sources`        | `object` | A map of one or more data sources to synchronize. The key is a user-defined name for the source.        | **Yes**  |

### Source Configuration

Each entry in the `sources` map defines a connection to an external system.

| Key                    | Type      | Description                                                                                                                                                                                                       | Required |
| ---------------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `type`                 | `string`  | The type of integration to use. Supported values are `armis` and `netbox`.                                                                                                                                      | **Yes**  |
| `endpoint`             | `string`  | The base URL for the source's API.                                                                                                                                                                                | **Yes**  |
| `prefix`               | `string`  | A string to prepend to every key written to the KV store from this source. **Must end with a `/`**.                                                                                                           | **Yes**  |
| `insecure_skip_verify` | `boolean` | If `true`, the HTTP client will skip TLS certificate verification. Use with caution.                                                                                                                              | No       |
| `credentials`          | `object`  | A map of strings containing authentication tokens, keys, and other integration-specific settings.                                                                                                                | **Yes**  |
| `queries`              | `array`   | (Armis only) An array of AQL queries to run against the Armis API to fetch devices.                                                                                                                               | **Yes**  |
| `poll_interval`        | `string`  | (Optional) Overrides the global `poll_interval` for this specific source. Uses Go's `time.ParseDuration` format.                                                                                                | No       |
| `sweep_interval`       | `string`  | How often agents should sweep discovered networks. Uses Go duration format (e.g., "5m").                                                                                                                        | No       |

---

## Armis Integration (`type: "armis"`)

The Armis integration fetches device information based on one or more Armis Query Language (AQL) queries. It then creates a network sweep configuration for ServiceRadar agents to scan these devices.

### Core Configuration

-   `endpoint`: The base URL of your Armis instance (e.g., `https://my-instance.armis.com`).
-   `credentials.secret_key`: The API secret key generated from your Armis console for authentication.
-   `queries`: An array of objects, each containing:
    -   `label`: A descriptive name for the query.
    -   `query`: The AQL string to execute.

### Armis Updater & Correlation (Optional)

This powerful feature allows `serviceradar-sync` to "close the loop" by taking network reachability data from ServiceRadar's sweep agents and pushing it back into Armis. This can enrich your Armis device data with near real-time availability status.

To enable this, you must configure `serviceradar-sync` to communicate with the **ServiceRadar API**.

-   `credentials.enable_status_updates`: Set to `"true"` to enable this feature.
-   `credentials.api_key`: An API key for the **ServiceRadar API**. This is required to query sweep results.
-   `credentials.serviceradar_endpoint`: The base URL for the **ServiceRadar API**. If not specified, it defaults to `http://localhost:8080`.

> **Important:** The Armis integration uses two different keys for its full functionality:
> 1.  `secret_key`: The key for the **Armis API** (to get devices).
> 2.  `api_key`: The key for the **ServiceRadar API** (to get sweep results).

### Optional Parameters

-   `credentials.page_size`: The number of devices to fetch per API request from Armis. Defaults to `100`.

---

## Netbox Integration (`type: "netbox"`)

The Netbox integration fetches all devices with a primary IP address from a Netbox instance.

-   `endpoint`: The base URL of your Netbox instance (e.g., `https://netbox.example.com`).
-   `credentials.api_token`: The API token generated from your Netbox user profile.
-   `credentials.expand_subnets`: (Optional) If set to `"true"`, it will use the full CIDR notation from Netbox (e.g., `192.168.1.1/24`) in the sweep config. If `false` or omitted, it will treat each IP as a `/32` host.

---

## Security (mTLS)

If your ServiceRadar KV store is protected by mTLS, you must provide the `security` block in your configuration.

| Key         | Type     | Description                                                                     |
| ----------- | -------- | ------------------------------------------------------------------------------- |
| `cert_dir`  | `string` | A base directory for your TLS assets. Relative paths below will be joined to this. |
| `cert_file` | `string` | The client certificate file (`.crt` or `.pem`).                                 |
| `key_file`  | `string` | The client private key file.                                                    |
| `ca_file`   | `string` | The certificate authority (CA) file used to validate the server's certificate.  |