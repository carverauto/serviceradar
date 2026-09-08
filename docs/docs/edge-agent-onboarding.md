---
title: Edge Agent Onboarding
---

# Edge Agent Onboarding

Edge onboarding is intentionally simple:

1. Install `serviceradar-agent` on the host (RPM/DEB from the [releases page](https://github.com/carverauto/serviceradar/releases)).
2. In the UI, create an agent package.
3. Copy/paste the enroll command on the host.

That is it. The agent enrolls, receives config, and starts streaming results.

## Prereqs

- You can reach the public web UI/API origin for your deployment over HTTPS.
- The host can reach the public `agent-gateway` gRPC endpoint on TCP `50052`
  (outbound). This may be a different hostname or IP from the web UI.
- You have `sudo` on the host.
- For Helm deployments, configure the public web and agent-gateway endpoints
  before creating an onboarding package. A common deployment uses separate DNS
  names and a dedicated agent-gateway `LoadBalancer`:

  ```yaml
  webNg:
    host: serviceradar.example.com
    publicUrl: https://serviceradar.example.com
    gatewayAddress: agent-gateway.example.com:50052

  agentGateway:
    publicHostname: agent-gateway.example.com
    service:
      type: LoadBalancer
      annotations:
        external-dns.alpha.kubernetes.io/hostname: agent-gateway.example.com.
  ```

  `webNg.host` is Phoenix's public host and `webNg.publicUrl` is the bare HTTPS
  origin used by generated install commands and signed tokens. The CLI uses it
  only to download the onboarding bundle. `webNg.gatewayAddress` is the
  externally reachable `host:port` written into that bundle as `gateway_addr`;
  the installed agent uses it for its long-lived mTLS gRPC connection.

  `agentGateway.publicHostname` should match the gateway DNS name and is used
  for the public artifact endpoint on TCP `50053`. The bundle verifies the
  gateway using the hostname from `webNg.gatewayAddress`, so the certificate
  presented by the gateway must cover that name. Changing the name can require
  certificate reissuance. Do not set any of these public values to a Kubernetes
  Service name.

  The agent-gateway can instead share a Gateway API data-plane address, but
  enabling the web `HTTPRoute` alone does not expose gRPC. The parent Gateway
  must have TCP listeners for `50052` and, when enabled, `50053`; then configure
  `gatewayApi.agentGateway.enabled` and the matching `parentRefs`. See
  [Helm Deployment and Configuration](./helm-configuration.md#public-web-and-edge-agent-endpoints).

## 1. Install The Agent (RPM/DEB)

Download the latest `serviceradar-agent` package from the ServiceRadar releases page and install it on the target host:

- Releases: [github.com/carverauto/serviceradar/releases](https://github.com/carverauto/serviceradar/releases)
- Debian/Ubuntu: install the `.deb`
- RHEL/Alma/Rocky: install the `.rpm`

For the full hosted onboarding path (SSO, collectors, RBAC, and day-2 ops), see the
[Cloud Quickstart](./cloud-quickstart.md).

After install, confirm the CLI exists:

```bash
/usr/local/bin/srctl --help
```

## 2. Create An Agent Package (UI)

In the web UI:

1. Go to **Settings → Agent Deploy** (`/settings/agents/deploy`)
2. Click **Create Agent Package** (opens edge package creation)
3. Fill in the required fields (gateway, agent ID/label, etc.)
4. Submit and copy the edgepkg token from the success modal

The enroll command looks like:

```bash
sudo /usr/local/bin/srctl enroll --core-url https://<SERVICERADAR_HOST> --token edgepkg-v3:<token>
```

## 3. Enroll The Host

On the host where you installed the agent, paste the enroll command from the UI:

```bash
sudo /usr/local/bin/srctl enroll --core-url https://<SERVICERADAR_HOST> --token edgepkg-v3:<token>
```

Notes:

- Treat the token as a secret (it grants enrollment).
- Enrollment **automates agent identity and mTLS** — you do not generate or
  distribute certificates by hand for standard Cloud or chart-managed installs.
- Bundle/package download tokens are accepted only in explicit request headers or POST bodies, never in URL query strings.
- Enrollment requires verified HTTPS. `srctl enroll` no longer supports an insecure TLS bypass.
- Newly issued agent enrollment tokens use the signed `edgepkg-v3` format.
  Signed `edgepkg-v2` tokens remain accepted for upgrade compatibility.
- The signed token embeds the deployment's public API origin. When
  `--core-url` is supplied, the explicit CLI value overrides the embedded
  origin after the same HTTPS validation. This lets an operator recover from a
  token minted with a stale hostname; create a new package after correcting the
  deployment value.
- `--core-url` does **not** override the agent's gRPC destination. The downloaded
  bundle supplies `gateway_addr`, which comes from `webNg.gatewayAddress` in a
  Helm deployment. Correct that deployment value and issue a new package if the
  agent is dialing the web hostname on `50052` or another unreachable endpoint.
- If you need to re-enroll, generate a new agent package to get a fresh token.

If enrollment tries to resolve `serviceradar-web-ng`, the token was minted with
an internal endpoint. Set `webNg.publicUrl` correctly and issue a new package,
or use `--core-url https://<PUBLIC_HOST>` as a temporary override.

If enrollment succeeds but the agent later times out connecting to
`<WEB_HOST>:50052`, the web URL is no longer the problem. Verify the
`gateway_addr` in `/etc/serviceradar/agent.json`, confirm it names the actual
agent-gateway L4 endpoint, and test TCP reachability to port `50052`. A web-only
Gateway normally exposes `80`/`443`, not the agent-gateway ports.

## 4. Verify

In the UI:

- Go to **Settings -> Agents**
- Confirm the agent shows **Online** and its last-seen timestamp is updating.

On the host:

- Check the agent service logs (systemd) and confirm it connects to `agent-gateway`.

## Next: Turn On Collection

Onboarding just gets the agent connected. The next step is enabling the collection features you want (all via the UI).

### Host Metrics (Sysmon)

Sysmon profiles control host metrics collection from enrolled agents.

1. Go to **Settings → Host Health** (`/settings/sysmon`)
2. Create a baseline profile (example: “Default Host Metrics”)
3. Set **Target Query** to apply broadly, for example:
   - `in:devices` (apply to all devices)
   - `in:devices tags.role:server` (only servers)
4. Save

Agents fetch updated profiles via `GetConfig` and start publishing host metrics.

See: [Sysmon Profiles](./sysmon-profiles.md)

### Visibility Profiles (passive fingerprint / capture)

Visibility profiles control what enrolled host agents capture and fingerprint.
They are not sweep profiles: sweeps scan CIDRs; visibility profiles watch
traffic already crossing an allowlisted NIC.

1. Assign the **netprobe** add-on to the host agent
   (**Settings -> Agents -> Add-ons**). See [Host Network Visibility](./netprobe.md).
2. Go to **Settings -> Network Services -> Visibility Profiles**
   (`/settings/networks/visibility-profiles`)
3. Create a profile: name, capture interface (exact kernel NIC name), SRQL
   target (blank means `in:devices`), and only the fingerprint / DPI
   capabilities you need. Attributed flows come from the netprobe assignment,
   not from this profile.
4. Enable the profile after targeting is narrow enough.

See: [Visibility Profiles](./visibility-profiles.md)

### Network Sweeps (Availability + Discovery Seeds)

Sweep groups schedule scans against device inventories and static targets.

1. Go to **Settings -> Networks**
2. Create a **Scanner Profile** (ports, timeouts, concurrency)
3. Create a **Sweep Group** and choose:
   - target criteria (inventory match)
   - static targets (CIDRs / IPs / ranges)
   - schedule
4. Enable the group

See: [Network Sweeps](./network-sweeps.md)

### SNMP Polling

SNMP profiles configure embedded agent SNMP polling.

1. Go to **Settings -> SNMP Profiles**
2. Create a profile and set a **Target Query** (SRQL) to select devices
3. Add targets/credentials and enable polling

See: [SNMP Ingest Guide](./snmp.md)

### Discovery / Mapper

Discovery runs inside `serviceradar-agent` and is configured from the UI.

1. Go to **Settings -> Networks -> Discovery**
2. Create/enable discovery jobs
3. Verify interfaces and topology are flowing into inventory and the graph

See: [Discovery Guide](./discovery.md)

### Notification Delivery From This Site (Edge Route)

An enrolled agent can also be the thing that **delivers** a notification, for a
destination that is only reachable from inside this network - an internal
ticketing system, an on-premises chat server, an SMS gateway on a private
segment. That is the `edge_agent` execution route on a notification channel.

1. Import and approve a Wasm plugin package whose manifest declares a
   `notifications:` block and requests the `notify:v1` capability.
2. Assign that package to this agent. The assignment's narrowed capability set
   must still include `notify:v1`; the agent checks it, so denying it on either
   the approval or the assignment stops delivery.
3. Create a notification provider bound to the package and one declared notifier
   key, then a channel on the `edge_agent` route naming this agent.

Three things to know before you route a page through an edge agent:

- **The edge route is for unreachable destinations only.** Everything reachable
  from the platform should stay on the control plane, which is the default.
- **The command path is at-most-once with no store-and-forward.** If the agent
  has no live control session when a notification is dispatched, the command is
  refused and nothing re-drains it on reconnect. An escalation policy whose only
  reachable channel is an edge agent therefore **cannot deliver the page that
  says this site went dark** - the platform detects the outage, and the agent it
  would have paged through went dark with it. Always give an edge-routed channel
  a control-plane fallback.
- **Slack and Discord incoming webhooks cannot run on the edge route**, because
  their webhook URL carries the secret in the path and no credential-injection
  mode rewrites a path. Use the bot-token mode for those destinations; it works
  on either route.

See: [Notification Plugins (Wasm)](./notification-plugin-authoring.md) and
[Notifications](./notifications.md#execution-route-control-plane-vs-edge-agent)
