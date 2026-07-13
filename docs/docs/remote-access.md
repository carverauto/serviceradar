---
sidebar_position: 8
title: Remote Access
---

# Remote Access

ServiceRadar remote access routes interactive sessions through the same edge topology used for monitoring. The current implementation is focused on agent-routed SSH sessions and SSH-backed Proxmox VE host shells. Native Proxmox VM/LXC `termproxy` or `vncwebsocket` consoles, SFTP/SCP, database access, Kubernetes access, and application access are follow-up capabilities. For the experimental graphical desktop/RDP path, see [Remote Access: RDP](./remote-access-rdp).

The intended enterprise model is short-lived SSH user certificates backed by your identity provider, ServiceRadar RBAC, and an edge agent that can reach the target. Operators should avoid reusable agent-local SSH secrets.

## Connection Path

Remote access traffic follows this path:

```text
browser -> web-ng -> agent-gateway -> edge agent -> target SSH server
```

For Proxmox host shells, the final target is the PVE host SSH service. For ordinary Linux hosts and VMs, the final target is the host or guest SSH service. A Proxmox VM does not need to use the Proxmox API console path if it has normal network reachability, `sshd`, a local or LDAP-backed account, and the ServiceRadar SSH CA installed.

## Operator Checklist

Before enabling remote access, make sure these pieces are in place:

- The target devices are in ServiceRadar inventory and assigned to an agent, gateway, or partition that can reach TCP `22`.
- Users authenticate through the normal ServiceRadar login path. For enterprise testing, Authentik OIDC works well as the identity provider.
- RBAC grants only the intended users the remote access actions. Use `devices.remote_access.ssh.open` for generic SSH and `devices.console.open` for Proxmox console entry points.
- The ServiceRadar SSH user CA public key is installed on each Linux or PVE target that should accept certificate login.
- The SSH CA private key is stored only in the control-plane signer environment or a dedicated secret store. Do not copy it to agents, browsers, target hosts, Ansible inventories, issue trackers, or logs.
- Target SSH host keys are managed through known-hosts or trust-on-first-use. Use host-key verification skip modes only for disposable lab tests.

## Credential Model

ServiceRadar supports several credential paths, but they are not equal.

Preferred path:

1. The user signs in through ServiceRadar, usually via Authentik, another OIDC provider, SAML, LDAP-backed SSO, or local auth plus MFA.
2. ServiceRadar evaluates RBAC and the remote access target policy.
3. ServiceRadar signs a short-lived OpenSSH user certificate with allowed principals, target restrictions, key ID, and TTL.
4. The browser session and edge path use the short-lived certificate for this one remote access session.
5. The target host trusts the ServiceRadar user CA and maps the certificate principal to a local or LDAP-backed Linux account.

Transitional paths:

- User-present password or key material can be used for a session when the operator allows it. The material should remain memory-only for that session.
- Centrally brokered reusable credentials can be used for tightly scoped break-glass or legacy Proxmox host shell workflows. They must be encrypted centrally, released only for one approved session, and bound to the target, agent, gateway, protocol, and TTL.

Avoid:

- Agent-local reusable SSH private keys.
- Shared master accounts that can log in to every target.
- Long-lived private keys stored in plugin parameters or local agent config.

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
```

```yaml
remoteAccess:
  ssh:
    enabled: true
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
mounts exactly the selected Secret key at
`/run/secrets/serviceradar_ssh_ca` with read-only `0400` projection and fails
rendering when an enabled signer lacks a Secret, key ID, or workload. Enable
only the workload that owns certificate issuance. Replace this file-backed
bootstrap with an OpenBao/Vault/KMS/HSM-backed command before production use.

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
SERVICERADAR_REMOTE_ACCESS_SSH_CERTIFICATE_POLICY_FILE=/etc/serviceradar/remote-access-ssh-policy.json
```

Example policy:

```json
{
  "allowed_principals": ["ubuntu", "admin"],
  "principal_mappings": [
    {
      "source": "groups",
      "value": "linux-admins",
      "principals": ["ubuntu", "admin"]
    },
    {
      "source": "email_domain",
      "value": "example.com",
      "principals": ["ubuntu"]
    }
  ],
  "ttl_seconds": 3600,
  "targets": {
    "vm-linux-01": {
      "allowed_principals": ["ubuntu"],
      "ttl_seconds": 1800
    }
  }
}
```

Use `SERVICERADAR_REMOTE_ACCESS_SSH_CERTIFICATE_POLICY_JSON` for small lab policies. Use the file path in production so policy can be managed as a mounted secret or config artifact.

## Linux Target Enrollment

Each Linux target must trust the ServiceRadar user CA. The account still has to exist on the host through local users, LDAP, Active Directory, or another NSS/PAM source. SSH certificates replace static SSH keys or SSH passwords for authentication; they do not create operating-system accounts.

Install the public key:

```bash
sudo install -o root -g root -m 0644 serviceradar_user_ca.pub /etc/ssh/serviceradar_user_ca.pub
```

Create `/etc/ssh/sshd_config.d/60-serviceradar-user-ca.conf`:

```text
PubkeyAuthentication yes
TrustedUserCAKeys /etc/ssh/serviceradar_user_ca.pub
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

By default, OpenSSH accepts a user certificate when the certificate principal list contains the login account name. For example, a certificate with principal `ubuntu` can log in as `ubuntu`.

If you need to map group-like principals to accounts, enable an authorized principals file:

```text
PubkeyAuthentication yes
TrustedUserCAKeys /etc/ssh/serviceradar_user_ca.pub
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
```

Then create one file per account:

```bash
sudo mkdir -p /etc/ssh/auth_principals
printf "linux-admins\nubuntu\n" | sudo tee /etc/ssh/auth_principals/ubuntu
sudo chmod 0644 /etc/ssh/auth_principals/ubuntu
```

Use authorized principals only when you need this extra mapping layer. It is simpler to issue certificates whose principals directly match allowed Linux login names.

## Ansible Enrollment

You can automate SSH CA enrollment with a small Ansible playbook that installs the public CA key and SSH server configuration on each target.

ServiceRadar already has an AWX/AAP-backed [Ansible Integration](./ansible). Use that integration as the normal enrollment path:

1. Copy the example playbook from the ServiceRadar repository ([`docs/ansible/remote-access-ssh-ca/`](https://github.com/carverauto/serviceradar/tree/main/docs/ansible/remote-access-ssh-ca)) into a git repository that AWX uses as a Project.
2. Create an AWX Job Template for that playbook.
3. Attach the AWX inventory that contains the Linux hosts, Proxmox VE hosts, or VMs you want to enroll.
4. Register the AWX controller in ServiceRadar under **Settings -> Ansible**.
5. Let AWX inventory sync mark the matching inventory devices as `ansible_managed`.
6. Select one or more devices in ServiceRadar inventory and launch the enrollment job with **Run Task** or `/ansible/launch?devices=<device-uids>`.

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
- `trust_on_first_use`: acceptable for initial enrollment when an operator can review the first key.
- `skip_verify`: only for temporary local testing.

Set `SERVICERADAR_REMOTE_ACCESS_KNOWN_HOSTS` on the agent if it should use a specific known-hosts file.

The web UI can expose host-key review and override controls only when the deployment enables them:

```bash
SERVICERADAR_REMOTE_ACCESS_SSH_HOST_KEY_SKIP_VERIFY_ENABLED=false
SERVICERADAR_REMOTE_ACCESS_TARGET_HOST_OVERRIDE_ENABLED=false
SERVICERADAR_REMOTE_ACCESS_TARGET_PORT_OVERRIDE_ENABLED=false
```

Keep overrides disabled unless an operator workflow explicitly needs them.

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

## User Workflows

### SSH Into A Linux Host Or VM

1. The user signs in to ServiceRadar.
2. The user opens a Linux node or VM in inventory.
3. The user starts an SSH remote access session.
4. ServiceRadar evaluates RBAC, device assignment, route eligibility, target policy, and principal policy.
5. ServiceRadar issues a short-lived SSH certificate.
6. The edge agent connects to the target SSH server and presents the user certificate.
7. The user lands in the shell as the mapped local or LDAP-backed Linux account.

### Open A Proxmox Host Shell

Use the Proxmox console entry point for PVE host shell access. Today this is SSH-backed through the edge agent. The preferred enterprise setup is still the SSH CA path: enroll the PVE host SSH server with the ServiceRadar user CA, allow only the intended principals, and route the console through the assigned edge agent.

Legacy encrypted credential rules remain available for PVE host shells when a deployment cannot use SSH certificates yet. Keep that path separate from Proxmox inventory API tokens.

### Access A Proxmox VM Or LXC

For now, use generic SSH remote access when the guest is reachable from an edge agent:

1. Install and enable `sshd` in the guest.
2. Make sure the user account exists through local accounts or LDAP/AD.
3. Enroll the guest with the ServiceRadar SSH CA.
4. Open the guest device in ServiceRadar and start an SSH session.

Native Proxmox VM/LXC console transports are planned separately. Until then, a guest without SSH reachability is not covered by the generic SSH workflow.

## Validation And Troubleshooting

Check the target SSH server configuration:

```bash
sudo sshd -T | grep trustedusercakeys
sudo sshd -t
```

Common failures:

- `Permission denied (publickey)`: the CA public key is missing, the certificate is expired, the certificate principal does not match the login user, or `AuthorizedPrincipalsFile` does not list the presented principal.
- User exists in ServiceRadar but not on the host: create the account locally or fix LDAP/AD/NSS/PAM integration on the target.
- Route denied: the device is not assigned to an eligible agent or gateway, or the remote access policy does not allow that target.
- Connection timeout: the selected edge agent cannot reach the target on TCP `22`.
- Host key rejected: the target host key is absent from known-hosts or changed since the last trusted connection.
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
