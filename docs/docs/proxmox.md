---
title: Proxmox VE Integration
---

# Proxmox VE Integration

ServiceRadar enriches Proxmox VE hosts, virtual machines, and LXC containers from the edge agent that can reach the PVE API on port `8006`. Discovery remains inventory-driven: mapper, imports, or other discovery sources identify candidate PVE devices, then credential rules decide which agent may try which Proxmox credentials.

## Credential Modes

Use one of these credential modes per deployment.

### Network Credential Rules

This is the default mode for centrally managed deployments.

1. Create a Proxmox API token in PVE for a read-only service account.
2. In ServiceRadar, open **Settings -> Networks -> Credential Rules**.
3. Create a **New Proxmox Token** secret with the token user, realm, token ID, token secret, and TLS policy.
4. Create a credential rule with:
   - Provider: `proxmox`
   - Auth method: `proxmox_api_token`
   - Purpose: `inventory_enrichment`
   - Target query: an SRQL query that only matches intended PVE devices
   - Scope type/value: the agent, gateway, or partition allowed to reach those devices
   - Auto-discovery credential trials: disabled unless the deployment explicitly accepts that risk

Credential-rule assignments deliver a broker grant to the edge path. The central plugin assignment does not store or display a raw Proxmox token, and the Wasm plugin should not receive decrypted credential material as a normal plugin parameter.

### Agent-Local Credentials

Use this mode for self-hosted or high-sensitivity customers that do not want Proxmox credentials stored in the ServiceRadar control plane.

In this mode, the token is configured only on the edge agent host or in agent-local plugin configuration. Keep the token out of central plugin assignments, issue tracking, logs, and screenshots. This mode trades central rotation and audit controls for reduced SaaS/control-plane credential exposure.

Agent-local mode should still use a narrow target set. Do not pair a broad scan range with a powerful local token.

For SSH-backed PVE host consoles, the agent can load a local credential file configured with `proxmox_console_credentials_file` in `agent.json`, the `SERVICERADAR_PROXMOX_CONSOLE_CREDENTIALS_FILE` environment variable, or the default `proxmox-console-credentials.json` next to the agent config when that file exists. The file must be readable only by the agent user, for example mode `0600`.

Example:

```json
{
  "version": 1,
  "credentials": [
    {
      "auth_method": "ssh_private_key",
      "username": "serviceradar-console",
      "private_key": "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----",
      "passphrase": "optional-passphrase"
    }
  ]
}
```

The central console assignment still carries only the credential broker grant and target metadata. The Wasm console plugin delegates SSH to the agent host connector, and only the agent host process reads this local file.

## Proxmox API Token Format

ServiceRadar expects the PVE API token identity and secret in the standard header form:

```text
PVEAPIToken=<user>@<realm>!<token_id>=<token_secret>
```

Example identity fields:

```text
user: root
realm: pam
token_id: serviceradar
```

The stored public identity is `root@pam!serviceradar`; the token secret is encrypted and never rendered back in the UI.

## Least-Privilege Role

Create a dedicated PVE user and API token for ServiceRadar. Prefer a role that only permits read-only inventory and status collection.

A practical starting point is:

```bash
pveum role add ServiceRadarInventory -privs "Sys.Audit VM.Audit Datastore.Audit"
```

Apply the role to the narrowest practical path. For one cluster-wide inventory token:

```bash
pveum aclmod / -user serviceradar@pve -role ServiceRadarInventory
pveum user token add serviceradar@pve serviceradar -privsep 1
pveum aclmod / -token serviceradar@pve!serviceradar -role ServiceRadarInventory
```

If the environment uses API token privilege separation, permissions on the token are constrained by the backing user's permissions. Grant both the user and token only the access needed for inventory.

Verify the effective permissions before using the token in ServiceRadar:

```bash
curl -sk \
  -H "Authorization: PVEAPIToken=serviceradar@pve!serviceradar=<token-secret>" \
  https://pve.example.com:8006/api2/json/access/permissions
```

If Ceph, disk, storage, or network detail endpoints return `403`, add the smallest additional audit privilege required by the endpoint on the relevant path. Avoid write privileges such as `VM.Allocate`, `VM.Config.*`, `Sys.Modify`, `Datastore.Allocate`, or `Permissions.Modify` for inventory-only collection.

## SRQL Scoping Examples

Scope credential rules as tightly as the inventory data allows.

### Single-Site Deployment

For a single site, bind the credential rule to one edge agent or gateway that can reach only that site's PVE management network.

Imported NetBox tag:

```text
in:devices tags.provider:proxmox
```

Protocol fingerprint from discovery:

```text
in:devices metadata.proxmox_candidate:true
```

### Multi-Datacenter Deployment

For multiple datacenters, create one credential rule per site. Each rule should use the site-specific token, SRQL query, and agent/gateway scope for that datacenter.

Datacenter-specific PVE hosts:

```text
in:devices tags.provider:proxmox tags.datacenter:iad
```

Another site can use a different rule and token:

```text
in:devices tags.provider:proxmox tags.datacenter:dfw
```

Imported Armis device class:

```text
in:devices source:armis tags.type:hypervisor tags.vendor:proxmox
```

Use the target preview in Credential Rules before enabling or testing a rule. The preview shows matched devices, in-scope devices, and per-agent distribution so operators can see which edge agent would receive the broker grant.

## Auto-Discovery Credential Trials

Auto-discovery credential trials are disabled by default. Keep them disabled for most deployments.

Enable them only when all of these are true:

- The rule is scoped to an agent, gateway, or partition that can only reach the intended PVE network.
- The token is read-only and least-privilege.
- Operators accept that a fake service on the reachable network could receive an authentication attempt.
- The deployment has audit expectations for who enabled the rule and when it was tested.

Unauthenticated fingerprinting can still identify likely PVE candidates without sending credentials. Credentialed collection should stay SRQL-scoped unless the operator explicitly opts in to broader trials.

## Console Access

Proxmox console access is intentionally configured separately from Proxmox inventory. Inventory uses a read-only PVE API token. Console access currently supports SSH-backed PVE host shells through the edge agent; native Proxmox VM and LXC console modes such as `termproxy` and `vncwebsocket` are reserved for a later connector and return an unsupported-console response today.

### What The Console Plugin Fields Mean

If you import or assign the `Proxmox Console` plugin, do not hand-enter these runtime fields:

- `credential_broker`: generated by ServiceRadar when a console session is approved. It tells the edge path which scoped credential grant may be resolved for that one session.
- `credential_rule_id`: generated from the matching credential rule. It identifies the `console_access` rule that authorized the session.
- `console`: generated per browser session. It contains non-secret session context such as session ID, target device, requested terminal size, and console mode.

Those fields are not Proxmox values and are not values from the PVE UI. The normal operator workflow is to configure a credential secret and a credential rule, then open the console from the device details page. ServiceRadar injects the broker, rule ID, and session context at launch time.

The assignment fields an operator may configure are:

- `timeout_ms`: connector timeout for opening the SSH path from the edge agent to the PVE host. The default is usually sufficient.
- `ssh_host_key_policy`: how the agent verifies the PVE host key. Use `known_hosts` when the agent has a managed known-hosts file, `trust_on_first_use` for first-connection pinning, and `skip_verify` only for temporary testing.
- `insecure_skip_verify`: only applies to future Proxmox API console transports. Leave it disabled for SSH-backed host consoles.

### Proxmox Host Preparation

For the current SSH-backed host console mode:

1. Create a dedicated operating-system account or a dedicated SSH key on each PVE node.
2. Add the public key to the intended account's `authorized_keys`.
3. Grant only the shell permissions the operations team actually needs. Avoid reusing personal admin keys or shared break-glass keys.
4. Make sure the selected edge agent can reach the PVE host on TCP `22`.

Example key test from the edge network:

```bash
ssh -i ./serviceradar-pve-console-key serviceradar-console@pve01
```

If you use root login for an initial lab test, keep it temporary and rotate the key before wider use.

### Central Credential Rule Setup

Use this mode when storing the console key in the ServiceRadar control plane is acceptable.

1. Create an encrypted credential secret for the console key:
   - Provider: `proxmox`
   - Credential kind: `ssh_private_key`
   - Username: the PVE shell account, for example `serviceradar-console`
   - Secret payload: the private key and optional passphrase
2. Create a credential rule in **Settings -> Networks -> Credential Rules**:
   - Provider: `proxmox`
   - Auth method: `ssh_private_key`
   - Purpose: `console_access`
   - Secret: the SSH private-key secret
   - Target query: an SRQL query matching only the PVE host devices that may receive shell access, for example `in:devices type:"Hypervisor" vendor:"Proxmox"`
   - Scope type/value: the agent, gateway, or partition allowed to broker those shells
   - Allowed ports: `22`
   - SSH host key policy: preferably `known_hosts` or `trust_on_first_use`
   - Auto-discovery credential trials: disabled
3. Preview the rule before saving or testing. The preview should show only the intended PVE host devices and the expected edge agent.
4. Confirm the user has the `devices.console.open` permission through RBAC.

Console rules and inventory rules should not be reused. A read-only PVE API token should stay attached to an `inventory_enrichment` rule. SSH shell access should use a separate `console_access` rule and separate secret.

### Agent-Local Console Credentials

Use this mode when the SSH private key must remain on the edge host and must not be stored in the ServiceRadar database.

Create an agent-local credential file and point the agent at it with `proxmox_console_credentials_file` in `agent.json`, `SERVICERADAR_PROXMOX_CONSOLE_CREDENTIALS_FILE`, or the default `proxmox-console-credentials.json` next to the agent config.

Example:

```json
{
  "version": 1,
  "credentials": [
    {
      "auth_method": "ssh_private_key",
      "username": "serviceradar-console",
      "private_key": "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----",
      "passphrase": "optional-passphrase"
    }
  ]
}
```

Each credential entry must also include the matching console rule identifier and credential secret reference from the ServiceRadar credential rule. Keep those IDs out of tickets, logs, and screenshots.

Set file ownership and permissions so only the agent service account can read it:

```bash
sudo chown serviceradar:serviceradar /etc/serviceradar/proxmox-console-credentials.json
sudo chmod 0600 /etc/serviceradar/proxmox-console-credentials.json
sudo systemctl restart serviceradar-agent
```

The matching central credential rule still needs provider `proxmox`, auth method `ssh_private_key`, purpose `console_access`, a narrow target query, and an edge scope. In agent-local mode, the central rule authorizes and scopes the session, while the private key is resolved only on the agent host.

### Opening A Console

From a PVE host device details page, click **Open Console**. ServiceRadar will:

1. Verify RBAC permission.
2. Resolve the device as a Proxmox PVE host.
3. Find a matching `console_access` credential rule.
4. Check that the rule target query includes the device.
5. Check that the rule scope includes the device's assigned agent or gateway.
6. Issue a short-lived single-use browser ticket.
7. Stream terminal frames through web-ng, agent-gateway, the selected edge agent, and the console plugin.

If the UI says `No scoped console credential rule matched this device`, verify that the rule purpose is `console_access`, the target query includes the exact device, the device has an assigned agent, and the scope value matches that agent or gateway.

## SSH Key Guidance

Inventory collection does not require SSH keys. Console access is a separately authorized workflow and should use its own credential rule, RBAC policy, and audit trail.

When SSH-backed console access is enabled, use a dedicated key and a dedicated operating-system account or narrowly scoped Proxmox access path. Do not reuse a personal administrator key, a shared break-glass key, or the root key used for host administration. Prefer per-site or per-cluster keys so rotation and incident response can be limited to the affected scope.

Store SSH private keys through encrypted credential rules when central management is acceptable. For high-sensitivity deployments, store the key only in agent-local configuration and restrict the rule to the local agent or gateway that brokers the console session. In both modes, display only the public fingerprint, track rotation metadata, and never render the private key or passphrase back in the UI.

Console credentials should be separate from Proxmox API tokens. API tokens remain read-only for inventory; SSH keys are only released to the console broker after RBAC approval, short-lived session ticket issuance, and agent-scope checks.

## Console Session Security Model

Console access is separate from inventory enrichment. A user who can view a Proxmox device, or who can manage read-only Proxmox API tokens, does not automatically receive shell access. Console launch must require a dedicated RBAC permission for Proxmox console use, a matching console credential rule, and an eligible edge agent or gateway that is inside the rule scope for the target device.

The control plane should treat console launch as a short-lived, audited session:

1. The operator opens a PVE host shell from device details. VM and LXC console requests remain unavailable until a native Proxmox guest console connector is enabled.
2. Web-ng authorizes the user, resolves the canonical target, checks the credential rule scope, and selects the eligible edge path.
3. Web-ng creates a short-lived, single-use console ticket bound to the user, target device or guest, console mode, selected agent/gateway, credential reference, issue time, and expiration time.
4. The browser attaches to the web terminal websocket with the ticket. The ticket is consumed on first successful attach and cannot be reused.
5. Web-ng proxies terminal frames to the edge console broker over the authenticated edge channel.
6. The edge broker resolves only the scoped credential needed for that session and opens the requested SSH path. Proxmox `termproxy` and `vncwebsocket` modes must return an unsupported-console response until a native guest connector is enabled.

The browser, URL, websocket metadata, audit payload, and UI errors must never contain SSH private keys, SSH passphrases, Proxmox API tokens, Proxmox tickets, cookies, or CSRF tokens. The WASM Proxmox inventory plugin is not part of the interactive console path and must not receive SSH private key material for console sessions.

### Console Audit Events

Emit audit events for every material console lifecycle transition:

- ticket requested, granted, denied, expired, and reused
- session opened, broker connected, broker denied, disconnected, closed, idle timeout, absolute timeout, and agent disconnect
- credential rule mismatch, missing credential, credential resolution failure, target reachability failure, and unsupported console mode

Audit payloads should identify the actor, target device or guest, target kind, session ID, credential rule ID, credential public fingerprint or token identity, selected agent/gateway, source IP or user session ID, start time, end time, duration, close reason, and sanitized failure phase. Do not record terminal input, terminal output, full command transcripts, private keys, passphrases, tickets, cookies, or token secrets by default. If transcript recording is ever added, it should be a separate policy-controlled feature with explicit retention and access rules.

Ash PaperTrail should be used for credential rule and console-policy changes where practical, so operators can answer who changed a credential, scope, RBAC rule, timeout, or console setting. Runtime console lifecycle events can use the operational audit stream, but they should still share stable IDs with the PaperTrail records for related policy and credential changes.

### Console Timeouts And Limits

Use bounded defaults for console sessions:

- Ticket TTL: short, preferably about 60 seconds.
- Ticket use: single-use; a second attach attempt is rejected without resolving credentials.
- Idle timeout: close after a configured quiet period, for example 10 minutes without terminal input or output.
- Absolute timeout: close after a configured maximum duration, for example 1 hour.
- Disconnect handling: close the session when the browser disconnects, the selected edge agent disconnects, RBAC is revoked, or the credential grant expires.
- Concurrency: cap concurrent sessions per user, per device, and per edge agent to protect the broker and PVE hosts.

Close events must include a sanitized reason in the terminal UI and an audit event. Timeout and disconnect paths should revoke any outstanding broker grant and release the PTY or Proxmox console process on the edge agent.

### Console Credential Guidance

Use separate credential rules for console access and inventory enrichment. Inventory API tokens should remain read-only. Console credentials should use dedicated operating-system users, dedicated SSH keys, and the narrowest SRQL target query and agent/gateway scope that matches the environment.

For centrally managed deployments, store console private keys through encrypted credential rules and display only the public fingerprint and rotation metadata. For deployments that do not want console keys in the control plane, keep console keys in agent-local configuration and scope the rule to that local edge path. In either mode, a hacked or rogue agent should only be able to request credentials for targets explicitly assigned to that agent, and broker grants should expire with the session.

TPM-backed or enclave-backed credential brokers would provide stronger protection for high-assurance deployments, but they are not required for the first implementation.

## Collected Data

The Proxmox plugin collects read-only inventory and health data where the token allows it:

- PVE version and cluster status
- Nodes and runtime status
- QEMU and LXC guest status/config
- Storage pools and capacity
- Node network interfaces
- Node disks and health
- Ceph status, OSDs, pools, and filesystems

ServiceRadar maps this into canonical devices plus provider-neutral virtualization tables instead of storing all hypervisor-specific data in device metadata.

## Logs

Proxmox inventory collection does not scrape syslog. Forward Proxmox host logs to the ServiceRadar syslog collector using the deployment's normal syslog path. Future ServiceRadar flows may automate syslog forwarding through an audited edge action, but inventory collection should remain read-only.

## References

- Proxmox VE API: https://pve.proxmox.com/mediawiki/index.php?title=Proxmox_VE_API
- Proxmox VE API Viewer: https://pve.proxmox.com/pve-docs/api-viewer/
- Proxmox VE Administration Guide: https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf
