---
title: Edge Agent Onboarding
---

# Edge Agent Onboarding

Edge onboarding is intentionally simple:

1. Install `serviceradar-agent` on the host (RPM/DEB from the [releases page](https://code.carverauto.dev/carverauto/serviceradar/releases)).
2. In the UI, create an agent package.
3. Copy/paste the enroll command on the host.

That is it. The agent enrolls, receives config, and starts streaming results.

## Prereqs

- You can reach the web UI for your deployment.
- The host can reach your `agent-gateway` endpoint (outbound).
- You have `sudo` on the host.

## 1. Install The Agent (RPM/DEB)

Download the latest `serviceradar-agent` package from the ServiceRadar releases page and install it on the target host:

- Releases: [code.carverauto.dev/carverauto/serviceradar/releases](https://code.carverauto.dev/carverauto/serviceradar/releases)
- Debian/Ubuntu: install the `.deb`
- RHEL/Alma/Rocky: install the `.rpm`

For the full hosted onboarding path (SSO, collectors, RBAC, and day-2 ops), see the
[Cloud Quickstart](./cloud-quickstart.md).

After install, confirm the CLI exists:

```bash
/usr/local/bin/serviceradar-cli --help
```

## 2. Create An Agent Package (UI)

In the web UI:

1. Go to **Settings → Agent Deploy** (`/settings/agents/deploy`)
2. Click **Create Agent Package** (opens edge package creation)
3. Fill in the required fields (gateway, agent ID/label, etc.)
4. Submit and copy the edgepkg token from the success modal

The enroll command looks like:

```bash
sudo /usr/local/bin/serviceradar-cli enroll --core-url https://<SERVICERADAR_HOST> --token edgepkg-v2:<token>
```

## 3. Enroll The Host

On the host where you installed the agent, paste the enroll command from the UI:

```bash
sudo /usr/local/bin/serviceradar-cli enroll --core-url https://<SERVICERADAR_HOST> --token edgepkg-v2:<token>
```

Notes:

- Treat the token as a secret (it grants enrollment).
- Enrollment **automates agent identity and mTLS** — you do not generate or
  distribute certificates by hand for standard Cloud or chart-managed installs.
- Bundle/package download tokens are accepted only in explicit request headers or POST bodies, never in URL query strings.
- Enrollment requires verified HTTPS. `serviceradar-cli enroll` no longer supports an insecure TLS bypass.
- Only signed `edgepkg-v2` tokens are accepted for agent enrollment.
- If you need to re-enroll, generate a new agent package to get a fresh token.

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
