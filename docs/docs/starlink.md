---
title: Starlink Integration
---

# Starlink Integration

ServiceRadar monitors and manages Starlink user terminals and routers with two first-party WASM plugin packages built from one Go module (`go/cmd/wasm-plugins/starlink`):

| Package | Runs on | Talks to | Credential |
| --- | --- | --- | --- |
| `starlink-cloud` | one agent per Starlink account | Starlink Management API V2 and Telemetry API | a Starlink service account, brokered by the agent |
| `starlink-local` | agents on the same LAN as the devices | the device-local diagnostics API on terminals and routers | none (the local API is unauthenticated) |

`starlink-cloud` discovers every terminal and router visible to the service account and keeps ServiceRadar inventory current, trends link telemetry, turns vendor alerts into events, and runs confirmed management actions. `starlink-local` adds on-site diagnostics from the devices themselves.

## Service account setup

1. In the Starlink web dashboard, create an API V2 service account for the account ServiceRadar should monitor. Create a **dedicated** service account for ServiceRadar: the telemetry stream keeps one read position per service account, so a second reader of the same service account (another tool, or a second ServiceRadar rule) silently receives only part of the data.
2. Give it these permissions:

   | Feature | Permission | Needed for |
   | --- | --- | --- |
   | Account information | View | account identification |
   | Device management | View | inventory |
   | Service plan | View | service lines, products |
   | Device telemetry | View | telemetry and alerts |
   | Device command and configuration | Edit | reboot actions |
   | Device management | Edit | terminal swap (adding a terminal to the account) |
   | Service plan | Edit | terminal swap and service-line lifecycle actions |

   Omit the Edit permissions for a monitoring-only deployment; the corresponding actions then fail with a permission error and change nothing.
3. Copy the client ID and generate a client secret.

## Credential rule

1. Open **Settings -> Networks -> Credential Rules**.
2. **New Credential -> Starlink - Service account**, with the client ID and client secret.
3. Create a credential rule with provider `starlink`, purpose `inventory_telemetry`, and scope type `agent`: the agent that will run collection for this account. Starlink is a cloud API, so any agent with outbound HTTPS to `starlink.com` works; pick one.

The rule provisions two producer schedules on that agent:

| Schedule | Default cadence | Does |
| --- | --- | --- |
| `starlink.inventory.refresh` | 15 minutes | complete inventory snapshot of terminals, routers and service lines |
| `starlink.telemetry.collect` | 60 seconds | drains the telemetry stream into metrics and reads current alert state |

The agent exchanges the client ID and secret for a short-lived access token on the agent host and injects it into each allowed request. The plugin never receives the client secret, and its configuration is refused if it contains credential material.

## Inventory and identity

Devices are identified only by their vendor device ID, carried as the integration identifier `starlink:ut:<terminal id>` or `starlink:router:<router id>`. Addresses are never used as identity:

- public IPs are shared by many terminals behind carrier-grade NAT, and
- the default LAN address of a terminal or router is the same at every site.

Kit and dish serials, service line, product, nickname, and the router-to-terminal association are recorded as device metadata. A snapshot is marked complete only when every listing was read to its last page; a failed page never causes a device to be treated as gone. A device removed from the account follows the normal inventory availability lifecycle; the plugin never deletes devices.

## Telemetry

Terminal and router measurements (throughput, PoP latency and drop rate, obstruction, signal quality, uptime, router client counts and link quality) are emitted as `serviceradar.metric.v1` records under a `starlink_` prefix and flow through NATS JetStream like every other metric. Column names are read from every telemetry response, so a vendor reordering or adding columns does not mis-map values.

The vendor retains stream data for 8 hours and delivers it at most once. A collection outage shorter than that catches up automatically; a run that receives no rows reports a warning (every device offline, or another reader is sharing the service account).

## Alerts

Active vendor alerts become OCSF events with signal schema `com.carverauto.starlink.alert`, keyed per device and alert. Each run marks the account's alert set as complete for its condition scope, and the agent emits a clear when an alert stops being reported; healthy devices produce no events. If a run cannot read every device's alert state, it does not mark the scope complete, so nothing is cleared on partial data.

The vendor publishes no severities. ServiceRadar classifies `thermal_shutdown`, `actuator_motor_stuck` and every `disabled_*` alert as critical, informational alerts such as `pop_change` as informational, and everything else (including alerts the vendor adds later) as warning. The software-update-reboot-pending alert is informational only because the vendor currently reports it unreliably.

The package proposes one alert rule, `starlink_terminal_critical_alert`, which is created **disabled**; enable and tune it under alert rules.

## Management actions

> Management actions ship in a follow-up release of `starlink-cloud`; the first release collects inventory, telemetry and alerts only.

All actions are device actions on a terminal or router and require confirmation. From a dashboard, the confirmation is shown by ServiceRadar itself, outside the dashboard, and bound to the exact action, targets and inputs.

| Action | Classification | What it does |
| --- | --- | --- |
| Reboot Starlink terminal / router | standard | vendor reboot |
| Swap terminal on service line | destructive | removes this terminal from its service line, adds the replacement (terminal ID, kit serial or dish serial) to the account and the line, and re-applies the L2VPN circuits that removal clears |
| Change service line product | destructive | changes the line's product |
| Deactivate service line | destructive | ends service at the next bill day, or immediately |
| Reactivate service line | destructive | reactivates an inactive line on the chosen product |

Multi-step actions check preconditions before changing anything (for example, a swap is refused if the line's product already exceeds its terminal limit). They record progress after every step and re-read vendor state before each change, so a retry after a rate limit or outage resumes where it stopped and never repeats a completed change. Nothing is rolled back automatically; a failed action reports exactly which steps completed. Each action's credential is limited to the vendor endpoints and methods that action uses.

## Local diagnostics (`starlink-local`)

Assign `starlink-local` to an agent on the devices' LAN and list the device endpoints in its configuration. The vendor's device API documentation gives the default LAN addresses and ports of the dish and router; this package has no built-in defaults.

```json
{
  "targets": [
    {"kind": "dish", "host": "192.0.2.10", "port": 9200},
    {"kind": "router", "host": "192.0.2.1", "port": 9000}
  ],
  "router_diagnostics_url": "https://router.example.com/starlinkrouter/diagnostics"
}
```

- Targets are called with the vendor-documented `get_diagnostics` request over plaintext gRPC, which the agent permits only to private and link-local addresses. The agent must advertise the `grpc_request` host capability.
- `router_diagnostics_url` is optional and requires an enterprise router configuration with a domain and a publicly trusted certificate.
- Results attach to the device ID each device reports about itself, so local and cloud data land on the same device. Local alert names match the cloud names where the condition is the same.
- The package issues only read requests. It never sends stow, power-save, reboot or factory-reset requests to the local API.

## Troubleshooting

| Result code | Meaning |
| --- | --- |
| `starlink_auth_failed` | the token exchange or a request was rejected: check the client secret and that the service account is enabled |
| `starlink_permission_denied` | the service account lacks a permission from the table above |
| `starlink_rate_limited` | the account's request limit (shared with every other client of the account) was reached; collection resumes next run, actions retry automatically |
| `starlink_telemetry_no_rows` | no telemetry arrived: devices offline, or another reader shares the service account |
| `starlink_config_contains_credential` | credential material was placed in plugin configuration; remove it and use a credential rule |
| `*_diagnostics_unreachable` (local) | the agent could not reach a configured device endpoint |
