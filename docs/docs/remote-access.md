---
sidebar_position: 8
title: Remote Access
---

# Remote Access

ServiceRadar remote access routes interactive sessions through the same edge topology used for monitoring. The current implementation is focused on agent-routed SSH sessions and SSH-backed Proxmox VE host shells. For file transfers, see [Copy Files Through SSH](#copy-files-through-ssh). For native Proxmox host and guest consoles, see [Proxmox Console Access](./proxmox#console-access). SCP, database access, Kubernetes access, and application access are follow-up capabilities. For the experimental graphical desktop/RDP path, see [Remote Access: RDP](./remote-access-rdp).

The intended enterprise model is short-lived SSH user certificates backed by your identity provider, ServiceRadar RBAC, and an edge agent that can reach the target. Operators should avoid reusable agent-local SSH secrets.

To disconnect an SSH session, click **Disconnect** next to the terminal status.
The console closes its connection immediately and returns to the connection
form, where you can start a new session. Disconnect also clears the session's
file listing and transfer state.

## Connection Path

Remote access traffic follows this path:

```text
browser -> web-ng -> agent-gateway -> edge agent -> target SSH server
```

For Proxmox host shells, the final target is the PVE host SSH service. For ordinary Linux hosts and VMs, the final target is the host or guest SSH service. A Proxmox VM does not need to use the Proxmox API console path if it has normal network reachability, `sshd`, a local or LDAP-backed account, and the ServiceRadar SSH CA installed.

### Connection Address

For inventory-device SSH sessions, ServiceRadar prefers the inventory IP address over the hostname. Hostnames reported by devices, such as SNMP `sysName` values or Proxmox node names, may not resolve from the selected edge agent. If no IP is recorded, selection falls back to the hostname or name, then the device UID; those fallback values must be resolvable to connect. An inventory IP avoids that DNS dependency but does not guarantee that the selected agent can reach the SSH service.

Proxmox host shells also prefer the target IP, then the hostname, then the host from the controller base URL. The SSH address preference matches the console's controller-origin authorization.

An operator-supplied target host takes precedence for an inventory-device SSH session. Through the web API, this requires `remote_access_target_host_override_enabled`, the `devices.remote_access.ssh.target.override` permission, and a match in `remote_access_target_host_override_allowlist`.

## Operator Checklist

Before enabling remote access, make sure these pieces are in place:

- The target devices are in ServiceRadar inventory and assigned to an agent, gateway, or partition that can reach TCP `22`. When the device has no owning agent column, SSH routing can use its discovery metadata (`sync_service_id`, then agent/source-agent metadata). This routing fallback does not bypass certificate policy or authorization.
- Users authenticate through the normal ServiceRadar login path. For enterprise testing, Authentik OIDC works well as the identity provider.
- RBAC grants only the intended users the remote access actions. Use `devices.remote_access.ssh.open` for generic SSH and `devices.console.open` for Proxmox console entry points.
- The ServiceRadar SSH user CA public key is installed on each Linux or PVE target that should accept certificate login.
- The SSH CA private key is stored only in the control-plane signer environment or a dedicated secret store. Do not copy it to agents, browsers, target hosts, Ansible inventories, issue trackers, or logs.
- Target SSH host keys are managed through known-hosts or trust-on-first-use. Use host-key verification skip modes only for disposable lab tests.

## Credential Model

ServiceRadar supports several credential paths, but they are not equal.

### Preferred path: Teleport-style SSO certificates (default in the UI)

This is the enterprise default. The browser SSH console no longer asks operators to
paste private keys for certificate sessions.

1. The user signs in through ServiceRadar with OIDC or SAML SSO (Authentik in the
   demo/lab environment). A local password login is deliberately ineligible for
   SSH certificate issuance, even if the account previously used SSO.
2. The operator opens **Devices → Remote Access → SSH**. The form defaults to
   **SSO certificate** mode. Unix account names come from certificate policy via
   `GET /api/remote-access/devices/:device_uid/ssh-options` (account names only;
   opaque principals are never sent to the browser). The preferred account is
   remembered per browser profile (Teleport-like default account pick). Connect
   is disabled while accounts load. If the loaded list is empty, the console
   replaces the account field with a missing-policy warning. Clicking Connect
   displays that reason without generating a key or requesting a session;
   see [SSH CA Setup](#ssh-ca-setup). If loading fails,
   the account field remains editable, but the server still enforces policy.
   **User-present key (legacy)** under **Advanced** remains available when you
   hold a key for the target.
3. On Connect, the browser generates a one-session Ed25519 keypair with WebCrypto
   (`crypto.subtle`). The private key stays in tab memory only. The public key is
   sent with the session attach credential after RBAC and target policy succeed.
4. ServiceRadar signs a short-lived OpenSSH user certificate with allowed
   principals, target restrictions, key ID, and TTL.
5. Traffic still follows the edge path (never direct from the operator laptop to
   the host):

   ```text
   browser → web-ng → agent-gateway → edge agent → target sshd
   ```

6. The target host trusts the ServiceRadar user CA and maps the certificate
   principal to a local Unix account, FreeIPA/LDAP account, or other NSS-backed
   identity. See [Unix identity (FreeIPA)](#unix-identity-freeipa).

### Why browser-mediated keys (not pasted keys)

Teleport and similar products generate short-lived keys client-side so operators
never handle long-lived SSH private keys. ServiceRadar follows the same pattern
for certificate mode: the private key is ephemeral, never written to disk by the
product UI, and never returned from the control plane. Policy principals remain
server-side only.

### Transitional paths

- User-present password or key material can be used for a session when the
  operator expands **Show advanced / legacy**. The material should remain
  memory-only for that session.
- Centrally brokered reusable credentials can be used for tightly scoped
  break-glass or legacy Proxmox host shell workflows. They must be encrypted
  centrally, released only for one approved session, and bound to the target,
  agent, gateway, protocol, and TTL.

### Avoid

- Agent-local reusable SSH private keys.
- Shared master accounts that can log in to every target.
- Long-lived private keys stored in plugin parameters or local agent config.
- Asking operators to paste CA private keys or session private keys for normal SSO
  certificate login.

### Remembered browser keys (opt-in, off by default)

The SSH console offers a **remember key** checkbox only in **user-present key
(legacy)** mode, and only when the deployment opts in with
`SERVICERADAR_REMOTE_ACCESS_BROWSER_KEY_REMEMBER_ENABLED=true` (Helm:
`remoteAccess.ssh.browserKeyRemember.enabled=true`). This feature is disabled
by default. Without an explicit opt-in, pasted keys remain in memory for the
current console only.

When enabled, remembered private keys stay in page memory only, never in
`localStorage` or `sessionStorage`. Keys can be reused while the page remains
loaded, but are lost on page reload, close, or browser restart. Opening a
console also removes that device's key left in `localStorage` by older builds.
Passphrases are never stored.

Tradeoff to accept before enabling: remembering a key extends its availability
in page memory beyond the current console. Scripts or extensions with access
to the page can still read it, and an open page offers no protection on a shared
workstation. Prefer SSO certificate mode (ephemeral in-memory keys) for routine
access, reserve remembered keys for break-glass workflows, and reload or close
the page when done. If persistence across restarts is needed later, it should
come from a WebAuthn or OS-keychain backed store, not from web storage.

## SSH CA Setup

Generate a ServiceRadar user CA once per environment:

```bash
ssh-keygen -t ed25519 -f serviceradar_user_ca -C serviceradar-remote-access-ca
```

Store `serviceradar_user_ca` as a private secret for the signer. Distribute only `serviceradar_user_ca.pub` to target hosts.

### CA Key Custody

Production deployments must keep the CA private key outside the web-ng, core,
and agent-gateway processes. The bundled `serviceradar-sshca-signer` supports a
file-backed or environment-variable key for bootstrap and lab use, but the
production custody model is an isolated signer command/service backed by OpenBao
Transit, Vault Transit, cloud KMS, or an HSM. Such a signer keeps a
non-exportable key inside the custody boundary, implements the same
stdin/request-file JSON contract as `serviceradar-sshca-signer`, returns only
the signed certificate response, audits every signing request, and fails closed
when the custody backend is unavailable. In practice, run the signer beside an
agent/template process that writes the current encrypted CA key into an
in-memory volume such as `/run/secrets/serviceradar_ssh_ca` (readable only by
the signer user) and point `--ca-key-file` at that path. The signer records the
key source class (`file` or `env`) in each certificate issue result so audit
events show how the key was loaded without exposing the key path or material.
Environment-variable custody is suitable only for development; file-backed
Kubernetes secrets are an acceptable bootstrap, and OpenBao/Vault/KMS/HSM is the
production target.

### Configuring The Signer

Configure the signer in the web-ng or core environment that approves remote access sessions:

```bash
SERVICERADAR_REMOTE_ACCESS_SSH_ENABLED=true
SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ENABLED=true
SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_COMMAND=serviceradar-sshca-signer
SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ARGS_JSON='["--ca-key-file","/run/secrets/serviceradar_ssh_ca","--max-ttl","8h","--audit-file","/var/log/serviceradar/sshca-signer-audit.jsonl"]'
SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_ID=serviceradar-user-ca-2026q2
```

For a Kubernetes bootstrap or lab deployment, create the private-key Secret
out of band and reference it from Helm. Do not put the private key in a values
file, rendered manifest, or Git repository:

```bash
kubectl create secret generic serviceradar-ssh-ca \
  --from-file=ca-key=/secure/path/serviceradar_user_ca \
  --namespace serviceradar

kubectl create secret generic serviceradar-ssh-certificate-policy \
  --from-file=certificate-policy.json=/secure/path/remote-access-ssh-policy.json \
  --namespace serviceradar
```

```yaml
remoteAccess:
  ssh:
    enabled: true
  sshCertificatePolicy:
    enabled: true
    existingSecretName: serviceradar-ssh-certificate-policy
    secretKey: certificate-policy.json
    workloads:
      web: true
      core: false
  sshCaSigner:
    enabled: true
    keyId: serviceradar-user-ca-2026q2
    existingSecretName: serviceradar-ssh-ca
    secretKey: ca-key
    workloads:
      web: true
      core: false
```

The web-ng and core-elx images include the bootstrap signer binary. The chart
mounts exactly the selected CA Secret key at
`/run/secrets/serviceradar_ssh_ca` with read-only `0400` projection and fails
rendering when an enabled signer lacks a Secret, key ID, or workload. Enable
only the workload that owns certificate issuance. Replace this file-backed
bootstrap with an OpenBao/Vault/KMS/HSM-backed command before production use.
The certificate policy is mounted independently from an operator-owned Secret
at `/etc/serviceradar/remote-access-ssh-policy/certificate-policy.json`. The
chart does not accept inline policy content because the target account and
opaque-principal mapping is internal authorization data.

Signer environment variables:

| Variable | Purpose |
|----------|---------|
| `SERVICERADAR_REMOTE_ACCESS_SSH_ENABLED` | Master switch for SSH remote access. Defaults to `false`; while disabled the device-details SSH action and remote-access session API are hidden or blocked. |
| `SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ENABLED` | Enables the CA signer integration. |
| `SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_COMMAND` | Path/name of the signer binary or wrapper. |
| `SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ARGS_JSON` | JSON array of signer arguments (for example `--ca-key-file`, `--max-ttl`, `--audit-file`). |
| `SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_ID` | Key ID stamped into issued certificates; advance this when rotating the CA. |
| `SERVICERADAR_SSH_CA_KEY` | Alternative to `--ca-key-file`: the CA private key read from the environment (development only). |
| `SERVICERADAR_SSH_CA_PASSPHRASE` | Passphrase when the CA key is encrypted. |
| `SERVICERADAR_SSHCA_AUDIT_FILE` | Audit log path for the bootstrap signer (equivalent to `--audit-file`); records CA key-load events without writing audit data to stdout. |
| `SERVICERADAR_REMOTE_ACCESS_SSH_CERTIFICATE_POLICY_FILE` | Path to a mounted certificate policy file (preferred for production). |
| `SERVICERADAR_REMOTE_ACCESS_SSH_CERTIFICATE_POLICY_JSON` | Inline certificate policy JSON (for small lab policies). |

Certificate issuance is rate limited per actor. The default bucket is
`remote_access_ssh_certificate_issue` with a limit of 10 certificates per minute.
Tune it in `ServiceRadar.Security.RateLimiter` config if your SSO/session pattern
requires a different issuance rate, and alert on throttling because repeated
denials can indicate credential stuffing or automation misuse.

For the CA key-rotation procedure, see [Rotation](#rotation).

The signer intentionally limits certificate power. By default it issues only the `permit-pty` OpenSSH extension and rejects caller-supplied critical options such as `force-command` and `source-address` unless the signer policy explicitly allows them. Use Ed25519 or ECDSA P-256+ CA keys; RSA CA keys must be at least 4096 bits and are signed with SHA-2 algorithms.

Configure certificate policy with either a JSON environment variable or a mounted file:

```bash
SERVICERADAR_REMOTE_ACCESS_SSH_CERTIFICATE_POLICY_FILE=/etc/serviceradar/remote-access-ssh-policy/certificate-policy.json
```

Example account-bound policy:

```json
{
  "accounts": [
    {
      "name": "mfreeman",
      "principals": ["srp_v1_6d8b1e49fbe24ad487ce2c5c"]
    }
  ],
  "principal_mappings": [
    {
      "source": "groups",
      "value": "linux-admins",
      "principals": ["srp_v1_6d8b1e49fbe24ad487ce2c5c"]
    },
    {
      "source": "email_domain",
      "value": "example.com",
      "principals": ["srp_v1_6d8b1e49fbe24ad487ce2c5c"]
    }
  ],
  "ttl_seconds": 3600,
  "targets": {
    "vm-linux-01": {
      "accounts": [
        {
          "name": "mfreeman",
          "principals": ["srp_v1_91c5f16df8aa4d90a6db2ed7"]
        }
      ],
      "ttl_seconds": 1800
    }
  }
}
```

Each account name is the existing non-root Unix account requested by the user.
Each principal is an opaque, target-specific token matching
`^srp_v1_[A-Za-z0-9_-]{20,96}$`. ServiceRadar chooses principals only from the
exact selected account. When `principal_mappings` is configured, the IdP-derived
principal set is intersected with that account's set; an empty intersection is
denied. A principal may appear under only one account within a target policy,
preventing one certificate from authenticating as a second Unix account. The
browser never supplies or receives these principals.

The public Ansible enrollment role must install the exact same account/principal
mapping in the target's `AuthorizedPrincipalsFile`. ServiceRadar fails closed
when an SSH-certificate target has no `accounts` mapping. The inline JSON
environment variable remains available for isolated development, but the Helm
chart intentionally supports only the Secret-backed file path.

A `targets` entry is matched by the device UID first, then its inventory
hostname (or name), then its inventory address; the first matching policy wins.
That entry overrides matching top-level fields, including `accounts`; omitted
fields inherit the top-level values. Policies from other targets are not merged. A
deployment that grants accounts per target and sets no top-level `accounts` is
therefore an allow-list: every new host needs its own entry before SSO
certificate access works, and adding one host does not cover its siblings.
For the console's handling of missing accounts, see
[Credential Model](#credential-model).

## Linux Target Enrollment

Each Linux target must trust the ServiceRadar user CA. The account still has to exist on the host through local users, LDAP, Active Directory, or another NSS/PAM source. SSH certificates replace static SSH keys or SSH passwords for authentication; they do not create operating-system accounts.

Install the public key:

```bash
sudo install -d -o root -g root -m 0755 /etc/ssh/serviceradar/current
sudo install -o root -g root -m 0644 serviceradar_user_ca.pub \
  /etc/ssh/serviceradar/current/trusted-user-ca-keys.pub
```

Create `/etc/ssh/sshd_config.d/60-serviceradar-user-ca.conf`:

```text
PubkeyAuthentication yes
TrustedUserCAKeys /etc/ssh/serviceradar/current/trusted-user-ca-keys.pub
```

Validate and reload SSH:

```bash
sudo sshd -t
sudo systemctl reload sshd
```

On Debian or Ubuntu, the service can be named `ssh` instead of `sshd`:

```bash
sudo systemctl reload ssh
```

ServiceRadar's remote-access model deliberately keeps the requested Unix login
account separate from the opaque certificate principal. Enable an authorized
principals file:

```text
PubkeyAuthentication yes
TrustedUserCAKeys /etc/ssh/serviceradar/current/trusted-user-ca-keys.pub
AuthorizedPrincipalsFile /etc/ssh/serviceradar/current/authorized-principals/%u
```

Then create one file per account containing only the opaque principals assigned
to that target and account:

```bash
sudo mkdir -p /etc/ssh/serviceradar/current/authorized-principals
printf "srp_v1_6d8b1e49fbe24ad487ce2c5c\n" | \
  sudo tee /etc/ssh/serviceradar/current/authorized-principals/mfreeman
sudo chmod 0644 /etc/ssh/serviceradar/current/authorized-principals/mfreeman
```

## Unix identity (FreeIPA)

SSH certificates authenticate the *session*. They do not create Unix accounts.
The account named in the browser form (for example `mfreeman`) must already
exist on the target through FreeIPA (preferred), a local user, or another
NSS/PAM source.

**Decision:** FreeIPA is the fleet Unix IdM. It owns POSIX users/groups,
**centralized sudo rules**, HBAC, host enrollment, and Kerberos. Prefer
**2 VMs outside Kubernetes** for production FreeIPA (not Synology LDAP, not
Authentik LDAP outpost as the sudo plane). Platform runbook:
platform gitops `k8s/freeipa/README.md` (VM-primary; k8s StatefulSet is lab-only).

### Division of labor

| System | Role |
|--------|------|
| **Authentik** | Human SSO into ServiceRadar (OIDC/SAML). RBAC groups for who may open remote access. Already deployed at `https://auth.carverauto.dev`. Optional LDAP Source from FreeIPA for user/group sync. |
| **ServiceRadar SSH CA** | Issues short-lived OpenSSH user certificates bound to opaque principals and certificate policy accounts. |
| **FreeIPA** | Enterprise Unix identity: POSIX accounts, **sudo rules**, HBAC, host enrollment. Hosts join FreeIPA and resolve `mfreeman` via SSSD. |
| **Edge agent path** | All interactive traffic still tunnels browser → web-ng → agent-gateway → edge agent → target. FreeIPA does not open a second path around the agent. |

Authentik is not a FreeIPA replacement for sudo/HBAC/host join. Certificate
policy still maps ServiceRadar opaque principals → the same POSIX account names
FreeIPA provides.

Until FreeIPA is online, lab hosts may use local accounts (as on `dusk01` /
`192.168.2.22`) with the same CA + `AuthorizedPrincipalsFile` layout.


### Authentik groups (Model A)

Authentik is the source of truth for people. FreeIPA only receives users who are
explicitly gated:

| Authentik group | Meaning |
|-----------------|---------|
| `unix-users` | May have a FreeIPA POSIX account and host login (HBAC). |
| `unix-sudo` | Subset of Unix users who receive FreeIPA sudo rules. |

Operator flow: create/invite user in Authentik → add to `unix-users` (and
`unix-sudo` if needed) → run the provisioner in platform gitops
`k8s/freeipa/PROVISIONING.md`. Username must match FreeIPA `uid` and the
ServiceRadar certificate policy account name.

### FreeIPA + sudo (summary)

Manage privilege in IPA after clients enroll (`ipa sudorule-*`, `ipa hbacrule-*`,
host groups / user groups). Do not scatter permanent sudoers on each host for
fleet operators. See the platform FreeIPA README for install topology, client
enrollment, Authentik LDAP Source, and example sudo/HBAC commands.

### FreeIPA platform docs

```text
# platform gitops repo
k8s/freeipa/README.md          # VM topology, sudo/HBAC, Authentik, checklist
k8s/freeipa/argocd-application.yaml
k8s/freeipa/base/              # optional lab StatefulSet only
```

## Lab target: dusk01 (192.168.2.22)

Use a disposable lab host for end-to-end SSH certificate tests. Prefer
**dusk01** (`192.168.2.22`) over Kubernetes worker nodes so enrollment mistakes
cannot break the control plane.

Demo certificate policy already includes target keys `192.168.2.22`, `dusk01`,
and the inventory device UID when present, with Unix account `mfreeman` and an
opaque principal of the form `srp_v1_...`.

Enrollment (once per host, with the **public** CA key only):

```bash
# On an operator workstation with SSH to dusk01 as a sudo user:
CA_PUB='ssh-ed25519 AAAA... serviceradar-demo-remote-access-ca-...'
PRINCIPAL='srp_v1_...'   # from certificate-policy for this target/account

ssh mfreeman@192.168.2.22 bash -s <<EOF
set -euo pipefail
sudo install -d -o root -g root -m 0755 /etc/ssh/serviceradar/current/authorized-principals
printf '%s\n' "\$CA_PUB" | sudo tee /etc/ssh/serviceradar/current/trusted-user-ca-keys.pub >/dev/null
printf '%s\n' "\$PRINCIPAL" | sudo tee /etc/ssh/serviceradar/current/authorized-principals/mfreeman >/dev/null
sudo tee /etc/ssh/sshd_config.d/60-serviceradar-user-ca.conf >/dev/null <<'CONF'
PubkeyAuthentication yes
TrustedUserCAKeys /etc/ssh/serviceradar/current/trusted-user-ca-keys.pub
AuthorizedPrincipalsFile /etc/ssh/serviceradar/current/authorized-principals/%u
CONF
sudo sshd -t && sudo systemctl reload ssh
EOF
```

Derive the public key from the demo CA secret only in a secure temporary
workspace (never commit the private key):

```bash
kubectl get secret -n demo serviceradar-ssh-ca -o jsonpath='{.data.ca-key}' \
  | base64 -d > /tmp/sr-ca && chmod 600 /tmp/sr-ca
ssh-keygen -y -f /tmp/sr-ca
shred -u /tmp/sr-ca
```

UI test path after enrollment:

1. Sign in to demo web-ng with Authentik SSO.
2. Open the dusk01 inventory device → Remote Access → SSH.
3. Confirm default mode is SSO certificate, account `mfreeman` (or policy
   dropdown), no private-key paste fields.
4. Connect. Expect a short-lived certificate session through the agent path.

## Ansible Enrollment

You can automate SSH CA enrollment with a small Ansible playbook that installs the public CA key and SSH server configuration on each target.

ServiceRadar already has an AWX/AAP-backed [Ansible Integration](./ansible). Use that integration as the normal enrollment path:

1. Copy the example playbook from the ServiceRadar repository ([`docs/ansible/remote-access-ssh-ca/`](https://github.com/carverauto/serviceradar/tree/main/docs/ansible/remote-access-ssh-ca)) into a git repository that AWX uses as a Project.
2. Create an AWX Job Template for that playbook. Keep **Prompt on launch -> Variables** disabled. Enable a survey containing the two exact ServiceRadar-owned declarations below and give them no defaults. ServiceRadar reserves these names and omits them from its own binding and run forms.
3. Attach the AWX inventory that contains the Linux hosts, Proxmox VE hosts, or VMs you want to enroll.
4. Register the AWX controller in ServiceRadar under **Settings -> Ansible**.
5. Let AWX inventory sync mark the matching inventory devices as `ansible_managed`.
6. Select one or more devices in ServiceRadar inventory and choose **Launch Playbook**, or open `/ansible/launch?devices=<device-uids>` directly. Do not use the separate provider-neutral **Run Action** workflow for Ansible enrollment.

The required AWX 24.6.1 survey fragment is:

```json
{
  "name": "ServiceRadar dispatch markers",
  "description": "Dispatcher-owned reconciliation fields",
  "spec": [
    {
      "question_name": "ServiceRadar dispatch ID",
      "question_description": "Injected by ServiceRadar; do not set manually",
      "required": true,
      "type": "text",
      "variable": "serviceradar_dispatch_id",
      "min": 36,
      "max": 36,
      "default": "",
      "choices": ""
    },
    {
      "question_name": "ServiceRadar snapshot digest",
      "question_description": "Injected by ServiceRadar; do not set manually",
      "required": true,
      "type": "text",
      "variable": "serviceradar_snapshot_digest",
      "min": 64,
      "max": 64,
      "default": "",
      "choices": ""
    }
  ]
}
```

This survey is a narrow AWX allow-list, not a credential channel. The reviewed binding contract requires the broad variable prompt to remain disabled and both marker declarations to be present, exact, and default-free. Additional public/internal survey fields must match the binding's separately reviewed non-secret input schema.

Keep mutating templates unavailable until the hardened planner's live AWX re-fetch and drift enforcement are enabled. Marker projection validates every declaration AWX returns, but the marker contract alone is not a substitute for re-fetching the complete template, survey, project, credentials, inventory, and target memberships immediately before persistence and dispatch.

AWX does not provide hidden or internal-only survey questions. AWX template administrators can see and edit these declarations, and AWX displays required survey questions during a direct AWX launch. Grant **Execute** on a hardened ServiceRadar template only to the dedicated ServiceRadar runner identity; do not grant operators a direct AWX launch path around ServiceRadar authorization. Restrict template edits to administrators, and re-review/rebind the template after any survey or template change.

ServiceRadar sends AWX a host `limit` derived from the selected devices, so the sample playbook uses `hosts: all` and relies on the launch limit to narrow the run. There are two distinct execution modes:

- An integrated, callback-enabled ServiceRadar launch obtains the public CA and exact target/account/principal policy from ServiceRadar's reviewed callback response. Do not put that response, the callback bearer, or the CA mapping in a survey, ordinary `extra_vars`, inventory variables, facts, artifacts, or target files.
- A direct `ansible-playbook` run outside ServiceRadar can accept a public CA key file as an explicit operator-controlled fallback. This path has no ServiceRadar callback authority and must not receive a ServiceRadar API key or callback bearer.

The inline `serviceradar_ssh_ca_public_key` variable remains a manual/lab fallback only. It is not the integrated ServiceRadar/AWX enrollment path.

Example manual/lab variables:

```json
{
  "serviceradar_ssh_ca_public_key": "ssh-ed25519 AAAA... serviceradar-remote-access-ca",
  "serviceradar_sshd_service": "sshd",
  "serviceradar_manage_authorized_principals": false
}
```

For Debian or Ubuntu targets, set `serviceradar_sshd_service` to `ssh` if that is the systemd service name.

Running the playbook directly with `ansible-playbook` is useful for testing it outside ServiceRadar:

```bash
ansible-playbook \
  -i <inventory-file> \
  <playbook.yml> \
  -e serviceradar_ssh_ca_public_key_file=/secure/path/serviceradar_user_ca.pub
```

The playbook installs only the public CA key and SSH server configuration. It never handles the CA private key.

For Debian or Ubuntu targets in local fallback mode, set the service name if needed:

```bash
ansible-playbook \
  -i <inventory-file> \
  <playbook.yml> \
  -e serviceradar_sshd_service=ssh \
  -e serviceradar_ssh_ca_public_key_file=/secure/path/serviceradar_user_ca.pub
```

### Callback response policy

Callback-enabled enrollment is disabled by default. Enabling it requires the exact reviewed AWX custom-credential contract and an operator-owned Kubernetes Secret containing the target-scoped response policy:

```yaml
automationCallbacks:
  enabled: true
  awxCredentialTypeId: 91
  awxOrganizationId: 2
  awxInjectorDigest: "<lowercase-sha256-of-the-reviewed-injector>"
  responsePolicy:
    existingSecretName: serviceradar-automation-callback-policy
    secretKey: response-policy.json
```

`awxOrganizationId` must name a dedicated empty AWX organization used only for
ServiceRadar's ephemeral callback credentials. The controller's callback
principal (normally the same least-privilege principal selected for execution)
may hold that organization's Credential Admin role. It must not hold Credential
Admin in the organization containing production machine credentials. Sync uses
a separate read-only controller credential, and no AWX controller token is ever
passed to the enrollment playbook.

The chart rejects enabled deployments with zero AWX IDs, a malformed injector digest, or no policy Secret. Both core and web-ng mount the Secret read-only. Keep it in a Secret rather than a ConfigMap: SSH CA public keys are public, but the per-device account and opaque-principal mapping is internal authorization data.

The policy file has this exact shape. Replace every example identifier and key with values from the reviewed ServiceRadar binding, AWX inventory, and CA custody boundary:

```json
{
  "schema": "serviceradar.automation.callback_response_policy/v1",
  "policies": [
    {
      "enabled": true,
      "action": "remote_access.ssh_ca.bundle.read",
      "action_version": "1.0.0",
      "policy_version": "ssh-policy-v3",
      "scope": {
        "tenant_id": "platform",
        "controller_id": "<serviceradar-controller-uuid>",
        "inventory_id": 34,
        "job_template_id": 42,
        "binding_id": "<serviceradar-binding-uuid>",
        "binding_version": 7,
        "approval_id": "<serviceradar-approval-uuid>",
        "scm_revision": "<reviewed-40-to-64-character-lowercase-hex-revision>",
        "content_sha256": "<reviewed-64-character-lowercase-sha256>"
      },
      "review": {
        "state": "approved",
        "reviewed_by_principal_type": "human",
        "reviewed_by_principal_id": "<reviewer-principal-id>",
        "reviewed_at": "2026-07-13T01:00:00.000000Z",
        "expires_at": "2026-07-20T01:00:00.000000Z"
      },
      "signer_key_id": "serviceradar-user-ca-2026q2",
      "ca_keys": [
        {
          "id": "serviceradar-user-ca-2026q2",
          "public_key": "ssh-ed25519 <base64-public-key-blob>",
          "fingerprint": "SHA256:<openssh-sha256-fingerprint>"
        }
      ],
      "targets": [
        {
          "state": "ready",
          "target_identity": {
            "controller_id": "<serviceradar-controller-uuid>",
            "inventory_id": 34,
            "awx_host_id": 100,
            "canonical_device_uid": "device:linux-01"
          },
          "ca_key_ids": ["serviceradar-user-ca-2026q2"],
          "accounts": [
            {
              "name": "mfreeman",
              "principals": ["srp_v1_0123456789abcdefghijklmnop"]
            }
          ],
          "transaction": {
            "generation": "generation-7",
            "machine_credential_ref": "awx-credential-ref:5"
          }
        }
      ]
    }
  ]
}
```

The provider accepts only public OpenSSH CA keys whose declared fingerprint matches the key blob. It rejects private-key fields, passwords, bearer/API tokens, reusable credentials, `root` target accounts, non-opaque principals, unknown fields, duplicate selectors, disabled targets, and partial target sets. Every ready target must trust the declared `signer_key_id`. Policy selection uses only tenant, controller, inventory, template, binding/approval, reviewed revision/content, AWX host ID, and canonical device UID. Hostnames and IP addresses are copied from the current authorized inventory membership and never select a policy.

The current external-command signer returns certificates but does not expose a trusted public-key discovery API. Before enabling callbacks, export and attest its public key and fingerprint inside the signer custody process, put only that public material in this policy, and verify that `signer_key_id` exactly matches `SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_ID`. Never mount the signer private key in the response-policy Secret. During rotation, include both public keys only for the reviewed overlap window and make the active signer key the declared `signer_key_id`.

Create or update the policy Secret through your normal secret-management/GitOps process. A one-off bootstrap command is:

```bash
kubectl -n <namespace> create secret generic serviceradar-automation-callback-policy \
  --from-file=response-policy.json=/secure/path/response-policy.json \
  --dry-run=client -o yaml | kubectl apply -f -
```

ServiceRadar validates the complete file at startup, re-reads the matching policy during every callback authority check, and compares its canonical digest with the immutable issuance snapshot. Disabling, expiring, removing, or changing a CA/account/principal mapping denies the whole callback; the operator must launch a newly authorized job. A policy update never broadens an already-issued grant.

## Host Key Trust

The edge agent verifies the target server host key before opening an SSH session. Prefer one of these modes:

- `known_hosts`: the agent uses a managed known-hosts file.
- `trust_on_first_use`: pins the first offered key without fingerprint review; use only when the operator accepts that initial-enrollment risk.
- `skip_verify`: only for temporary local testing.

Set `SERVICERADAR_REMOTE_ACCESS_KNOWN_HOSTS` on the agent if it should use a specific known-hosts file.

This file is agent-local. Records under **Settings -> Remote access host keys**
are a separate review store: SSH verification does not consult them or populate
them automatically. Enroll the key for the address and port the agent dials;
trusting a hostname alone does not cover a connection by IP address. A changed
key is still rejected.

A fresh agent has no known-hosts file, so under the default `known_hosts` policy
the first session to any target fails verification. The console does not leave
that as a dead end: it ends the session and presents the trust decision instead.
When the agent reports the offered key, the decision supports fingerprint review:

- **This host key is not trusted yet.** The target has no entry in the agent's
  known-hosts file. The console shows the dialed address, the key algorithm, and
  the offered key's SHA256 fingerprint. Compare that fingerprint against the
  target's own host key (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on
  the target for an Ed25519 key; use the matching public-key file for other
  algorithms) before choosing **Trust this host key and reconnect**, which
  reopens the session with approval for that exact address, port, and SHA256
  fingerprint. The agent checks the approval before pinning the key or
  authenticating; a different target or key is rejected as a mismatch. Approval
  applies only to this retry and does not change the form policy.
  `trust_on_first_use` remains selectable under **Advanced** for an enrollment
  you want to make up front.
- **This host key does not match the trusted key.** The target offered a
  different key than the one already pinned, or the retry does not match the
  approved target and fingerprint. The console shows the offered fingerprint
  and offers no accept action. This can indicate interception or a legitimate
  host rebuild or key rotation. Verify the target and key out of band; remove
  a pinned entry only after confirming it is stale, then connect again.

Persist the agent's known-hosts file across container replacement to preserve
pinned keys. By default it lives under `/var/lib/serviceradar/checkers`; when
`SERVICERADAR_REMOTE_ACCESS_KNOWN_HOSTS` overrides the path, persist that location
instead. Losing the file makes the next session first contact again.

Agents older than 1.4.52 report `knownhosts: key is unknown` for an unenrolled
target and `knownhosts: key mismatch` for a changed key, naming neither the
target nor the offered key. The console still presents a trust decision for
those, but an unreviewable one: with no fingerprint to compare it shows none.
For an unknown key, the accept action reads **Trust on first use and reconnect**.
That retry asks for the `trust_on_first_use` policy, so the agent
pins whatever key the target offers -- the same trust you would extend by
running `ssh-keyscan` against the target and pinning the result, and not the
reviewed acceptance a newer agent allows. A changed key is still a hard close
with no accept action. Upgrade the agent to 1.4.52 or newer to review the
fingerprint before pinning it.

The web UI can expose host-key review and override controls only when the deployment enables them:

```bash
SERVICERADAR_REMOTE_ACCESS_SSH_HOST_KEY_SKIP_VERIFY_ENABLED=false
SERVICERADAR_REMOTE_ACCESS_TARGET_HOST_OVERRIDE_ENABLED=false
SERVICERADAR_REMOTE_ACCESS_TARGET_PORT_OVERRIDE_ENABLED=false
```

Keep overrides disabled unless an operator workflow explicitly needs them.
See [Remembered browser keys](#remembered-browser-keys-opt-in-off-by-default)
for the tradeoff behind the remember-keys flag.

## Application And TCP Targets

Application and TCP access are disabled by default and use registered targets only. Browser requests can select a target ID and, when required, an approval ID. They cannot supply upstream host, port, route, Host header, SNI, TLS policy, quotas, credentials, or recording policy.

Enable the browser/API surfaces in `web-ng`:

```bash
SERVICERADAR_REMOTE_ACCESS_APP_ENABLED=true
SERVICERADAR_REMOTE_ACCESS_TCP_ENABLED=true
```

Grant users the relevant RBAC permissions:

- `devices.remote_access.app.open` to open registered HTTP/HTTPS application targets.
- `devices.remote_access.tcp.open` to open registered TCP targets.
- `settings.remote_access_targets.manage` to manage registered targets.

Application targets are launched from **Remote access targets** at `/remote-access/targets`. The application browser opens a session through `/api/remote-access/app-sessions`, attaches to `/v1/remote-access/sessions/:id/stream`, and sends only bounded `GET` or `HEAD` requests through the selected edge agent. The agent enforces the registered upstream, allowed path prefixes, methods, header policy, Host/SNI, TLS policy, byte quotas, and redirect policy.

TCP targets are separate resources. The UI exposes a TCP launcher only when the target metadata explicitly declares a browser workflow:

```json
{
  "browser_renderer": "text",
  "client_workflow": "Send one text line and read the response."
}
```

Without that metadata, TCP targets remain registered and policy-enforced but are not exposed as generic browser tunnels. This prevents turning ServiceRadar into an arbitrary forwarding proxy by accident.

To register an application or TCP target, use **Remote access targets** at `/remote-access/targets` (or the `/api/remote-access/targets` API) and provide the target name, device UID, the agent ID that can reach the service, the upstream scheme/host/port, and the allowed methods, path prefixes, and TLS policy. Targets are validated and stored centrally; the browser only ever selects an existing target ID.

## RDP WebRTC ICE And TURN

RDP screen and input traffic uses WebRTC after the route-bound remote-access
control channel reports the session ready. Configure ICE endpoints as
deployment policy; do not put them in desktop target records or browser input.

STUN-only example for a deployment whose public server-reflexive candidates
are reachable:

```yaml
remoteAccess:
  desktop:
    rdp:
      enabled: true
      webRTC:
        iceServers:
          - urls:
              - "stun:stun.example.net:3478"
```

When the chart-wide NetworkPolicy is enabled, add a narrowly scoped egress
exception for the core-elx pods that originate ICE traffic. Kubernetes
NetworkPolicy cannot match the ICE server's DNS name, so resolve and review the
current addresses before deployment and configure only the required ports:

```yaml
networkPolicy:
  enabled: true

remoteAccess:
  desktop:
    rdp:
      enabled: true
      webRTC:
        networkPolicy:
          enabled: true
          allowedCIDRs:
            - "192.0.2.40/32"
            - "2001:db8:40::1/128"
          allowedUDPPorts:
            - 3478
          allowedTCPPorts: []
```

This renders an additive `Egress` policy selecting only
`app: serviceradar-core`; it does not grant ICE egress to web-ng or other
ServiceRadar pods. When the chart's ordered Calico log-and-deny policy is also
enabled, the same template renders a matching core-only Calico `Allow`
immediately before that final deny; the existing deny policy remains unchanged.
Rendering fails when the chart-wide policy or RDP is disabled, the CIDR list is
empty or contains a DNS name/catch-all destination, or the UDP/TCP port lists
contain values outside `1..65535`. Re-resolve and review address changes instead
of widening the destination to `0.0.0.0/0` or `::/0`.

Use TURN for restrictive NAT or firewall environments. ServiceRadar supports
the TURN REST shared-secret convention and mints a different HMAC credential
for every viewer. Create the shared secret through your secret-management
system, store at least 32 printable non-whitespace bytes in one Kubernetes
Secret key, and reference only that Secret from values:

```yaml
remoteAccess:
  desktop:
    rdp:
      enabled: true
      webRTC:
        iceServers:
          - urls:
              - "turn:turn.example.net:3478?transport=udp"
              - "turns:turn.example.net:5349?transport=tcp"
        turn:
          existingSecretName: serviceradar-turn-rest
          secretKey: shared-secret
          credentialTtlSeconds: 600
        networkPolicy:
          enabled: true
          allowedCIDRs:
            - "192.0.2.41/32"
          allowedUDPPorts:
            - 3478
          allowedTCPPorts:
            - 5349
```

The chart mounts only the selected key at
`/etc/serviceradar/remote-access-rdp-turn/shared-secret`. It fails rendering
when TURN endpoints lack an existing Secret or use a credential TTL outside
`1..3600` seconds. Runtime validation also rejects inline usernames,
credentials, shared secrets, URI userinfo, unsupported schemes, malformed
hosts or ports, and oversized endpoint lists. The browser receives only the
public endpoint plus its expiring derived username and credential; it never
receives the shared secret.

Equivalent non-Helm runtime variables are:

| Variable | Purpose |
|----------|---------|
| `SERVICERADAR_REMOTE_ACCESS_DESKTOP_RDP_ENABLED` | Enables the registered RDP target and device-launch surfaces in web-ng/core. |
| `SERVICERADAR_REMOTE_ACCESS_DESKTOP_WEBRTC_ICE_SERVERS_JSON` | Bounded JSON list of public STUN/TURN URL objects; credentials are forbidden. |
| `SERVICERADAR_REMOTE_ACCESS_DESKTOP_WEBRTC_TURN_SHARED_SECRET_FILE` | Path to the mounted TURN REST shared-secret file. Required when a `turn:` or `turns:` endpoint is configured. |
| `SERVICERADAR_REMOTE_ACCESS_DESKTOP_WEBRTC_TURN_CREDENTIAL_TTL_SECONDS` | Per-viewer credential lifetime; defaults to 600 and cannot exceed 3600 seconds. |

The launcher posts only the registered desktop target ID, fixed RDP
protocol/adapter identifiers, and an optional approval ID. The user's target
username/password is sent once over the authenticated control WebSocket,
cleared from browser state immediately after the send is queued, and never
included in the WebRTC configuration. A single bounded deadline covers target
session creation, control attach, and the exact ready frame; timeout closes the
control and server sessions.

## User Workflows

### SSH Into A Linux Host Or VM

1. The user signs in to ServiceRadar.
2. The user opens a Linux node or VM in inventory.
3. The user starts an SSH remote access session.
4. ServiceRadar evaluates RBAC, device assignment, route eligibility, target policy, and principal policy.
5. ServiceRadar issues a short-lived SSH certificate.
6. The edge agent connects to the target SSH server and presents the user certificate.
7. The user lands in the shell as the mapped local or LDAP-backed Linux account.

### Copy Files Through SSH

The SSH console's **Files** sidebar transfers individual files over SFTP through
the selected agent route, subject to file-transfer permissions and policy.

- The remote path field selects the directory to browse. Press Enter or use
  refresh to list it. The `..` button browses the parent directory and is disabled
  at `/`. These controls only list directories; they never start a copy.
- Set **Upload path** before using **Choose File**: selecting a local file starts
  its upload. Leave the path blank to use the browsed directory, end it with `/`
  to append the selected filename, or enter a complete destination filename.
  A path equal to the browsed directory also appends the selected filename.
- Uploads require a selected, non-empty local file. A refused selection displays
  an error below the picker and a `refused` entry under **Transfers**. The server
  also rejects missing input, an empty stream, or an initial read failure before
  creating or truncating the destination.
- Use a file row's download button to download that file. Transfers require a
  file path; bare `/` cannot be a transfer target. An upload directory of `/`
  resolves to `/<selected filename>`, subject to policy.

The sidebar does not copy directories recursively or copy a local filesystem
root to a remote root. Check the displayed errors and **Transfers** status for
the result of each attempted transfer.

### Open A Proxmox Host Shell

For PVE host console modes and setup, see [Proxmox Console Access](./proxmox#console-access). For SSH access, the preferred enterprise setup is the SSH CA path: enroll the PVE host SSH server with the ServiceRadar user CA, allow only the intended principals, and route the session through the assigned edge agent.

Legacy encrypted credential rules remain available for PVE host shells when a deployment cannot use SSH certificates yet. Keep that path separate from Proxmox inventory API tokens.

### Access A Proxmox VM Or LXC

To use generic SSH remote access when the guest is reachable from an edge agent:

1. Install and enable `sshd` in the guest.
2. Make sure the user account exists through local accounts or LDAP/AD.
3. Enroll the guest with the ServiceRadar SSH CA.
4. Open the guest device in ServiceRadar and start an SSH session.

For guests without SSH reachability, see [Proxmox Console Access](./proxmox#console-access).

## Validation And Troubleshooting

Check the target SSH server configuration:

```bash
sudo sshd -T | grep trustedusercakeys
sudo sshd -t
```

When the edge agent supplies a close reason, the console banner displays it as
`SSH session closed: <reason>`, including when browser input or a resize races
with the broker's normal shutdown. Use that reason to diagnose failures below.
A broker that stops normally without a close reason produces
`SSH session closed: closed`; a broker crash produces
`Remote access stream failed.` These generic messages do not identify an SSH
authentication or host-key failure.

Common failures:

- `Permission denied (publickey)`: the CA public key is missing, the certificate is expired, the selected Unix account is not authorized, or its `AuthorizedPrincipalsFile` does not list the opaque principal in the presented certificate.
- User exists in ServiceRadar but not on the host: create the account locally or fix LDAP/AD/NSS/PAM integration on the target.
- Route denied: the device is not assigned to an eligible agent or gateway, or the remote access policy does not allow that target.
- Connection timeout: the selected edge agent cannot reach the target on TCP `22`.
- `dial tcp: lookup <name>: server misbehaving` or `no such host`: the session is connecting by name rather than by address. The device row has no address, or the target-host field was set to a name the edge agent's resolver cannot answer. Give the device an address in inventory, or supply a name that agent can resolve.
- Host key rejected: the session reached the target but host-key verification failed. See [Host Key Trust](#host-key-trust) for the console trust decision, enrollment, address matching, and older-agent errors. This is independent of certificate account policy and DNS resolution.
- `SSH certificate access requires trusted account and principal policy for the target`: the resolved account/principal policy is missing or invalid. The session is refused before it is created, so no row appears in `remote_access_sessions`. Check the mapping and target selection in [SSH CA Setup](#ssh-ca-setup); console alternatives are described in [Credential Model](#credential-model).
- Signer failure: check the signer binary path, CA key secret mount, `SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ARGS_JSON`, policy file syntax, and signer logs.

## Rotation

Rotate the SSH user CA with an overlap window so no in-flight certificate is
invalidated:

1. Generate the new CA keypair.
2. Add the new public key to every target while leaving the old public key
   trusted.
3. Update the ServiceRadar signer to use the new private key. With a
   secret-store backed signer, publish a new secret version and restart or
   reload the signer workload rather than copying key material by hand.
4. Advance `SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_ID` to the new key ID.
5. Wait longer than the maximum certificate TTL so all certificates signed by
   the old CA have expired.
6. Remove the old public key from targets.

Never rotate by copying the private key to agents or target hosts. Only public
trust anchors belong on SSH servers.
