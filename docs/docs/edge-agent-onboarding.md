---
title: Edge Agent Onboarding
---

# Edge Agent Onboarding

Edge onboarding is intentionally simple:

1. Install `serviceradar-agent` on the host (RPM/DEB from GitHub Releases).
2. In the UI, create an agent package.
3. Copy/paste the enroll command on the host.

That is it. The agent enrolls, receives config, and starts streaming results.

## Prereqs

- You can reach the web UI for your deployment.
- The host can reach your `agent-gateway` endpoint (outbound).
- You have `sudo` on the host.

## 1. Install The Agent (RPM/DEB)

Download the latest `serviceradar-agent` package from the ServiceRadar GitHub Releases page and install it on the target host:

- Debian/Ubuntu: install the `.deb`
- RHEL/Alma/Rocky: install the `.rpm`

After install, confirm the CLI exists:

```bash
/usr/local/bin/serviceradar-cli --help
```

## 2. Create An Agent Package (UI)

In the web UI:

1. Go to **Settings -> Agents -> Deploy**
2. Click **Create Agent Package**
3. Fill in the required fields in the modal (gateway, agent ID/label, etc.)
4. Submit

<!-- TODO: screenshot: Settings -> Agents -> Deploy page -->
<!-- TODO: screenshot: Create Agent Package modal -->

The UI will show a one-liner enroll command that looks like:

```bash
sudo /usr/local/bin/serviceradar-cli enroll --core-url https://demo.serviceradar.cloud --token edgepkg-v2:<token>
```

## 3. Enroll The Host

On the host where you installed the agent, paste the enroll command from the UI:

```bash
sudo /usr/local/bin/serviceradar-cli enroll --core-url https://demo.serviceradar.cloud --token edgepkg-v2:<token>
```

Notes:

- Treat the token as a secret (it grants enrollment).
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

1. Go to **Settings -> Sysmon Profiles**
2. Create a baseline profile (example: “Default Host Metrics”)
3. Set **Target Query** to apply broadly, for example:
   - `in:devices` (apply to all devices)
   - `in:devices tags.role:server` (only servers)
4. Save

<!-- TODO: screenshot: Sysmon profile editor with Target Query set to in:devices -->

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

<!-- TODO: screenshot: Sweep Group editor -->

See: [Network Sweeps](./network-sweeps.md)

### SNMP Polling

SNMP profiles configure embedded agent SNMP polling.

1. Go to **Settings -> SNMP Profiles**
2. Create a profile and set a **Target Query** (SRQL) to select devices
3. Add targets/credentials and enable polling

<!-- TODO: screenshot: SNMP profile editor -->

See: [SNMP Ingest Guide](./snmp.md)

### Discovery / Mapper

Discovery runs inside `serviceradar-agent` and is configured from the UI.

1. Go to **Settings -> Networks -> Discovery**
2. Create/enable discovery jobs
3. Verify interfaces and topology are flowing into inventory and the graph

<!-- TODO: screenshot: Discovery job editor -->

See: [Discovery Guide](./discovery.md)
