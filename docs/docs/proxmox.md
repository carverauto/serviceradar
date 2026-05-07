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
in:devices protocol:proxmox-api
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

## SSH Keys For Future Console Access

Inventory collection does not require SSH keys. Console access is a future, separately authorized workflow and should use its own credential rule, RBAC policy, and audit trail.

When SSH-backed console access is enabled, use a dedicated key and a dedicated operating-system account or narrowly scoped Proxmox access path. Do not reuse a personal administrator key, a shared break-glass key, or the root key used for host administration. Prefer per-site or per-cluster keys so rotation and incident response can be limited to the affected scope.

Store SSH private keys through encrypted credential rules when central management is acceptable. For high-sensitivity deployments, store the key only in agent-local configuration and restrict the rule to the local agent or gateway that brokers the console session. In both modes, display only the public fingerprint, track rotation metadata, and never render the private key or passphrase back in the UI.

Console credentials should be separate from Proxmox API tokens. API tokens remain read-only for inventory; SSH keys are only released to the console broker after RBAC approval, short-lived session ticket issuance, and agent-scope checks.

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
