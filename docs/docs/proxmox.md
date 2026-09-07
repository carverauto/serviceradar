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
2. In ServiceRadar, open **Settings -> Networks -> Credential Rules** (`/settings/networks/credentials`).
3. **New Credential -> Proxmox VE - API token**, with the token user, realm, token ID, and token secret.
4. Create a credential rule with:
   - Provider: `proxmox`
   - Auth method: `proxmox_api_token`
   - Purpose: `inventory_enrichment`
   - Target query: an SRQL query that only matches intended PVE devices
   - Scope type/value: the agent, gateway, or partition allowed to reach those devices
   - TLS policy: `verify` (see [TLS Verification and Node Certificates](#tls-verification-and-node-certificates), which the rule alone does not satisfy)
   - Allowed ports: `8006`
   - Auto-discovery credential trials: disabled unless the deployment explicitly accepts that risk

Credential-rule assignments deliver a broker grant to the edge path. The central plugin assignment does not store or display a raw Proxmox token, and the Wasm plugin should not receive decrypted credential material as a normal plugin parameter.

The general credential model -- credentials, rules, purposes, scopes, priority, and how a rule reaches a plugin -- is in [Credential Management](./credentials.md).

### TLS Verification and Node Certificates

This is the step that most often blocks a first Proxmox rollout, and the reason is
narrower than "self-signed certificate". Two constraints combine.

**Constraint 1: the controller origin is always `https://<ip>:8006`.** Core builds the
host-authority binding for a Proxmox assignment by canonicalising whatever address the
target carries, and `canonical_origin/3` in
`elixir/serviceradar_core/lib/serviceradar/plugins/proxmox_host_authority.ex` rejects any
origin whose host is not a bare IP literal:

```elixir
not valid_ip_literal?(uri.host) ->
  {:error, :invalid_origin_host}
```

`valid_ip_literal?/1` is `:inet.parse_address/1`, so a hostname never passes -- not
`pve04`, not `pve04.lan`, not a CNAME. The scheme must be `https` and the port defaults
to `8006`. A target that fails canonicalisation is dropped from the binding list, and if
no binding survives, the assignment is skipped with `:proxmox_host_authority_unavailable`.

**Constraint 2: `inventory_enrichment` requires `verify`.** The purpose accepts exactly
`proxmox_api_token` with TLS policy `verify`. A `skip_verify` rule is rejected at
resolution with `proxmox_tls_verification_required`, no broker grant is minted, and no
enrichment runs. Weakening the rule is not an escape hatch in the transport either: the
agent refuses to inject a credential-broker grant into a request that skips TLS
verification unless the grant explicitly permits it, and the Proxmox grant does not. The
check is fail-closed on purpose -- Proxmox enrichment writes into device identity, so a
machine-in-the-middle there is an identity-forgery primitive rather than bad metrics.

**What the two together require.** The agent performs ordinary TLS verification against
`https://<ip>:8006`. So it is not enough for the node certificate to be signed by a CA the
agent trusts. It must also be **valid for that IP address**: the certificate's Subject
Alternative Name list has to contain `IP Address:<the address ServiceRadar dials>`. A
`DNS` SAN never matches an IP literal, so a certificate issued for `pve04.lan` will fail
against `https://192.168.1.20` no matter who signed it.

Work the following steps in order.

#### Step 1: Retrieve the cluster CA

Proxmox signs each node certificate with a cluster CA that lives in the replicated
`/etc/pve` filesystem, so any node in the cluster serves the same copy:

```bash
ssh root@<pve-node> cat /etc/pve/pve-root-ca.pem
```

That is the public CA certificate. It is safe to copy and distribute. Do not copy
`/etc/pve/pve-root-ca.key`, which is the CA private key.

#### Step 2: Inspect the node certificate SANs

Before deciding anything, read the SAN list of the certificate the node actually serves:

```bash
ssh root@<pve-node> openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -text \
  | grep -A1 'Subject Alternative Name'
```

On OpenSSL 1.1.1 and later this is equivalent and easier to read:

```bash
ssh root@<pve-node> openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -ext subjectAltName
```

**How to read the result.** You are looking for one thing: the address the ServiceRadar
agent will dial, listed as an `IP Address` entry.

- Output containing `IP Address:192.168.1.20` (and you intend to reach the node at
  `192.168.1.20`): the stock certificate works. Go to step 3 and stop.
- Output containing only `DNS:pve04, DNS:pve04.lan` and no `IP Address` entry: the stock
  certificate does **not** work, because ServiceRadar cannot be pointed at `pve04.lan`.
  Go to step 4.
- Output containing an `IP Address` entry that is not the address you will use -- a node
  that was re-addressed after its certificate was generated, or a certificate covering a
  cluster network while the agent reaches a management network: treat this as the second
  case. Go to step 4.

If `pveproxy` is serving a custom certificate, it is at `/etc/pve/local/pveproxy-ssl.pem`
and that file, not `pve-ssl.pem`, is what a client sees. Inspect whichever exists. To read
what is actually presented on the wire rather than what is on disk:

```bash
openssl s_client -connect 192.168.1.20:8006 </dev/null 2>/dev/null \
  | openssl x509 -noout -text \
  | grep -A1 'Subject Alternative Name'
```

#### Step 3: Trust the CA on the agent

On 1.4.49 trust for plugin HTTP is agent configuration, not rule configuration. (Merged
work lets a Proxmox rule carry the anchor itself, where it replaces the system pool for
that request instead of extending it --
[Credential Management: CA trust material](./credentials.md#ca-trust-material).) Copy the
CA from step 1 onto the edge agent that will reach the node, and add its absolute path to
`plugin_http_trusted_ca_files` in `agent.json`:

```json
{
  "plugin_http_trusted_ca_files": [
    "/etc/serviceradar/certs/root.pem",
    "/etc/serviceradar/certs/pve-root-ca.pem"
  ]
}
```

Helm deployments set the same list through `agent.pluginHTTPTrustedCAFiles`, which already
includes the ServiceRadar runtime CA; add to that list rather than replacing it. These
roots extend the operating-system trust pool -- they widen what the agent accepts, they do
not restrict it. The Wasm module never sees the bundle and cannot select or replace the
roots. If a configured path is unreadable, oversized, or holds no certificate, the agent
disables outbound plugin HTTP entirely rather than silently continuing, so a typo here
takes out every plugin's HTTP, not just Proxmox. Restart the agent after changing the
list.

#### Step 4: When the SAN has no IP address

The certificate has to be replaced. `pvenode cert set` installs a custom certificate for
the API and web UI, and because you supply the certificate, you control its SAN list:

```bash
# on the PVE node, after issuing a certificate whose SAN includes the IP
pvenode cert set /path/to/node.pem /path/to/node.key --force --restart
pvenode cert info
```

**This is the recommended path**, for a specific reason: it is the only one where the SAN
list is something you decide rather than something you inspect and hope for. Issue the
certificate from a CA you operate -- your internal PKI, or a small offline CA created for
the PVE fleet -- with `subjectAltName = IP:192.168.1.20, DNS:pve04.lan`, then trust that
CA on the agent per step 3. A re-IP means reissuing one certificate; the agent
configuration does not change.

**ACME is not the answer here, and it is worth being explicit about why.** Proxmox has
first-class ACME support (`pvenode acme` and the ACME tab in the web UI), and it is the
right tool for making the web UI trusted in a browser. It does not help ServiceRadar,
because ACME certificates from public CAs are issued for DNS names, and ServiceRadar dials
an IP literal. A publicly trusted certificate for `pve04.example.com` will still fail
against `https://192.168.1.20`. A PVE node on RFC1918 address space cannot obtain a
public certificate for its address at all. Use ACME if you also want a browser-trusted web
UI; do not expect it to satisfy this constraint.

:::caution What is verified here, and what you have to check yourself
The ServiceRadar-side constraints above -- the IP-literal origin, the `verify`
requirement, the grant-injection refusal, and the agent trust-file behaviour -- were read
out of this repository and are exact.

One Proxmox-side claim has since been measured. On the ServiceRadar demo cluster the
stock `pve-ssl.pem` does carry an `IP Address` SAN -- `pve02` reports
`IP Address:10.0.0.3, DNS:pve02, DNS:pve02.localdomain` -- and with
`/etc/pve/pve-root-ca.pem` pinned as the sole anchor, verifying by IP returns
`Verify return code: 0 (ok)` on both `pve02` (`10.0.0.3`) and `pve03` (`10.0.0.4`);
without the CA the same handshake fails `unable to get local issuer certificate`. So the
normal case needs no re-issuance: step 3 is enough, and step 4 is for the exceptions.

The remaining Proxmox-side claims were not exercised against a live PVE node, and the
file layout and SAN contents vary across PVE versions. Treat these as
"run the command and read the output", not as fact:

- **Whether a re-addressed or custom-certificate node carries the right `IP Address`
  SAN.** Proxmox generates node certificates with SANs derived from the node's
  configuration at generation time, so a node re-addressed after certificate generation
  will not carry the new address, and a node serving
  `/etc/pve/local/pveproxy-ssl.pem` presents whatever that file contains. This is
  precisely why step 2 says to inspect rather than assume, and it is the single most
  important thing to check before choosing between step 3 and step 4.
- **Whether regenerating certificates picks up a new address.** `pvecm updatecerts
  --force` regenerates node certificates from the cluster CA and is the obvious thing to
  try after a re-IP, but we have not confirmed the SAN list it produces. If you try it,
  re-run step 2 afterwards and believe the output, not the intent.
- **Exact `pvenode cert set` flags.** `--force` (overwrite an existing custom certificate)
  and `--restart` (restart `pveproxy`) are shown above; confirm against
  `pvenode cert set --help` on your version, and use `pvenode cert info` to check what is
  installed.

Consult the Proxmox VE documentation for the authoritative behaviour of `pvenode`,
`pvecm updatecerts`, and the certificate paths on your release.
:::

#### Verifying the result

From the agent host, with the CA you configured in step 3:

```bash
curl --cacert /etc/serviceradar/certs/pve-root-ca.pem https://192.168.1.20:8006/api2/json/version
```

A clean TLS handshake and a `401` are success -- the `401` is the API declining an
unauthenticated request, which means verification passed. A message naming a certificate
authority means step 3 is incomplete; a message naming a hostname or IP SAN mismatch means
step 4 is required. Do not add `-k`, and do not put a Proxmox token on a shell command
line; the point of the check is the handshake.

Then confirm through ServiceRadar rather than through curl alone: use the target preview
and rule test on the credential rule, and check the `proxmox-inventory` plugin result for
a run timestamped after the agent restart. A stale successful result from before the
change proves nothing.

### Credential Custody

ServiceRadar does not support reusable agent-local Proxmox console credential files. SSH console credentials must come from one of the approved session-scoped custody paths: centrally brokered encrypted credential rules for legacy PVE host SSH, user-present credentials for generic SSH, or ServiceRadar-issued short-lived SSH certificates for the enterprise remote-access path.

Avoid placing Proxmox API tokens, SSH private keys, passwords, or passphrases in agent JSON, local plugin assignments, issue tracking, logs, or screenshots. Central assignments carry broker grants and target metadata; decrypted reusable secrets are resolved only inside the approved broker flow and only for the active session.

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

Ticking **Allow auto-discovery credential trials** sets `metadata.auto_discovery_enabled` on the rule, and the rules table then shows `Auto` instead of `SRQL` in its Runtime column. The effect is concrete: an enabled Proxmox `inventory_enrichment` rule with the flag on makes the mapper compile `proxmox_candidate_probe_enabled` into its job options. The mapper runs an unauthenticated HTTPS fingerprint against port `8006` on reachable hosts and stamps anything answering like a PVE web UI with `metadata.proxmox_candidate=true` plus `proxmox_candidate_source`, `_evidence`, `_observed_at`, `_port`, `_service`, and `_title`. Because the manifest's default target query is `in:devices metadata.proxmox_candidate:true`, those devices become rule targets and receive credentialed collection.

The fingerprint itself sends no credential. The credentialed collection that follows it does. That is the whole risk: the target set widens from devices you named to devices that answered a probe.

Enable them only when all of these are true:

- The rule is scoped to an agent, gateway, or partition that can only reach the intended PVE network.
- The token is read-only and least-privilege.
- Operators accept that a fake service on the reachable network could receive an authentication attempt.
- The deployment has audit expectations for who enabled the rule and when it was tested.

Unauthenticated fingerprinting can still identify likely PVE candidates without sending credentials. Credentialed collection should stay SRQL-scoped unless the operator explicitly opts in to broader trials.

## Console Access

Proxmox console access is intentionally configured separately from Proxmox inventory. Inventory uses a read-only PVE API token. Native consoles use `termproxy` for PVE hosts and LXC containers and `vncwebsocket` for QEMU guests through the edge agent. SSH-backed PVE host shells remain available with a separate SSH credential rule.

For the broader SSH CA setup, Linux target enrollment, and user workflow for Proxmox VMs that are reachable over normal SSH, see [Remote Access](./remote-access).

### Native Console Setup

Create a dedicated Proxmox API-token credential with the PVE permissions needed for the intended console targets. Bind it to a `proxmox` / `proxmox_api_token` rule with purpose `console_access`, TLS policy `verify`, and a narrow target query and agent, gateway, or partition scope. Inventory's read-only token does not grant console access. The user also needs `devices.console.open`.

Guest consoles resolve through their owning virtualization host and canonical PVE device, not the guest IP. Missing or ambiguous ownership prevents launch. Legacy inventory rows with native Proxmox identity fields can have their identity completed for the session when enabled scoped rules provide one unambiguous integration/controller scope; this does not rewrite stored inventory.

### Legacy SSH Console Plugin Fields

If you import or assign the `Proxmox Console` plugin, do not hand-enter these runtime fields:

- `credential_broker`: generated by ServiceRadar when a console session is approved. It tells the edge path which scoped credential grant may be resolved for that one session.
- `credential_rule_id`: generated from the matching credential rule. It identifies the `console_access` rule that authorized the session.
- `console`: generated per browser session. It contains non-secret session context such as session ID, target device, requested terminal size, and console mode.

Those fields are not Proxmox values and are not values from the PVE UI. The normal operator workflow is to configure a credential secret and a credential rule, then open the console from the device details page. ServiceRadar injects the broker, rule ID, and session context at launch time.

The assignment fields an operator may configure are:

- `timeout_ms`: connector timeout for opening the SSH path from the edge agent to the PVE host. The default is usually sufficient.
- `ssh_host_key_policy`: how the agent verifies the PVE host key. Use `known_hosts` when the agent has a managed known-hosts file or `trust_on_first_use` for first-connection pinning. Console rules reject `skip_verify`.
- `insecure_skip_verify`: leave disabled; native console API-token rules require TLS verification as described in [Native Console Setup](#native-console-setup).

### Proxmox Host Preparation

For the legacy SSH-backed host console mode:

1. Prefer enrolling the PVE node with the ServiceRadar SSH user CA so users can open short-lived certificate-backed sessions as their approved Linux account.
2. If the deployment cannot use SSH certificates yet, create a dedicated operating-system account or dedicated SSH key on each PVE node.
3. Add the public key to the intended account's `authorized_keys` only for the legacy key-based path.
4. Grant only the shell permissions the operations team actually needs. Avoid reusing personal admin keys or shared break-glass keys.
5. Make sure the selected edge agent can reach the PVE host on TCP `22`.

Example key test from the edge network:

```bash
ssh -i ./serviceradar-pve-console-key serviceradar-console@pve01
```

If you use root login for an initial lab test, keep it temporary and rotate the key before wider use.

### Legacy SSH Credential Rule Setup

Use this mode when storing the console key in the ServiceRadar control plane is acceptable.

1. Create an encrypted credential for the console key with **New Credential -> Proxmox VE - SSH private key**:
   - Username: the PVE shell account, for example `serviceradar-console`
   - Private key and optional passphrase
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

### Opening A Console

From a Proxmox host or guest device details page, use the console action. ServiceRadar will:

1. Verify RBAC permission.
2. Resolve the target and its owning PVE controller from virtualization inventory.
3. Find a matching `console_access` credential rule.
4. Check that the rule target query includes the device.
5. Check that the rule scope includes the device's assigned agent or gateway.
6. Resolve and validate the active console plugin assignment for the matching rule and selected agent. A missing or ambiguous assignment prevents launch.
7. Issue a short-lived single-use browser ticket.
8. Stream terminal frames through web-ng, agent-gateway, the selected edge agent, and the console plugin.

If the UI says `No scoped console credential rule matched this device`, verify that the rule purpose is `console_access`, the target query includes the exact device, the owning controller has a reachable edge route, and the scope value matches that route.

## SSH Key Guidance

Inventory collection does not require SSH keys. Console access is a separately authorized workflow and should use its own credential rule, RBAC policy, and audit trail.

When SSH-backed console access is enabled, use a dedicated key and a dedicated operating-system account or narrowly scoped Proxmox access path. Do not reuse a personal administrator key, a shared break-glass key, or the root key used for host administration. Prefer per-site or per-cluster keys so rotation and incident response can be limited to the affected scope.

Store reusable SSH private keys only through encrypted credential rules when this legacy custody mode is acceptable. High-sensitivity deployments should prefer ServiceRadar-issued short-lived SSH certificates backed by SSO/LDAP identity and RBAC rather than agent-local reusable private keys. Display only the public fingerprint, track rotation metadata, and never render the private key or passphrase back in the UI.

For native console credentials, see [Native Console Setup](#native-console-setup). Legacy SSH keys are only released to the console broker after RBAC approval, short-lived session ticket issuance, and agent-scope checks.

## Console Session Security Model

Console access is separate from inventory enrichment. A user who can view a Proxmox device, or who can manage read-only Proxmox API tokens, does not automatically receive shell access. Console launch must require a dedicated RBAC permission for Proxmox console use, a matching console credential rule, and an eligible edge agent or gateway that is inside the rule scope for the target device.

The control plane should treat console launch as a short-lived, audited session:

1. The operator opens the host or guest console from device details using the modes described in [Console Access](#console-access).
2. Web-ng authorizes the user, resolves the canonical target, checks the credential rule scope, and selects the eligible edge path.
3. Web-ng creates a short-lived, single-use console ticket bound to the user, target device or guest, console mode, selected agent/gateway, credential reference, issue time, and expiration time.
4. The browser attaches to the web terminal websocket with the ticket. The ticket is consumed on first successful attach and cannot be reused.
5. Web-ng proxies terminal frames to the edge console broker over the authenticated edge channel.
6. The edge broker resolves only the scoped credential needed for that session and opens the server-selected native console transport or legacy host SSH path.

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

For centrally managed deployments, store legacy console private keys through encrypted credential rules and display only the public fingerprint and rotation metadata. Deployments that do not want reusable console keys in the control plane should use ServiceRadar-issued short-lived SSH certificates or native Proxmox console tickets instead of agent-local key files. A hacked or rogue agent should only be able to request credentials for targets explicitly assigned to that agent, and broker grants should expire with the session.

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
