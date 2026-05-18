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

Production deployments should keep the CA private key outside web-ng, core, and
agent-gateway processes. The bundled `serviceradar-sshca-signer` supports a
file-backed key for bootstrap and lab use, but the preferred production custody
model is an isolated signer command/service backed by OpenBao Transit, Vault
Transit, cloud KMS, or an HSM. That signer should expose the same bounded command
interface, load the key inside the custody boundary, audit every signing request,
and deny operation if the custody backend is unavailable.

Configure the signer in the web-ng or core environment that approves remote access sessions:

```bash
SERVICERADAR_REMOTE_ACCESS_SSH_ENABLED=true
SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ENABLED=true
SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_COMMAND=serviceradar-sshca-signer
SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_ARGS_JSON='["--ca-key-file","/run/secrets/serviceradar_ssh_ca","--max-ttl","8h"]'
SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_ID=serviceradar-user-ca-2026q2
```

`SERVICERADAR_REMOTE_ACCESS_SSH_ENABLED` defaults to `false`. Keep it disabled until targets, RBAC, host-key policy, and the SSH CA signer are ready; the device-details SSH action and remote-access session API are hidden or blocked while it is disabled.

The signer can also read the private key from `SERVICERADAR_SSH_CA_KEY`; use `SERVICERADAR_SSH_CA_PASSPHRASE` when the key is encrypted. Environment-variable custody is suitable only for development because process dumps, debug output, and host introspection can expose the key. File-backed Kubernetes secrets are a better bootstrap option, and OpenBao/Vault/KMS/HSM custody is the production target.

Certificate issuance is rate limited per actor. The default bucket is
`remote_access_ssh_certificate_issue` with a limit of 10 certificates per minute.
Tune it in `ServiceRadar.Security.RateLimiter` config if your SSO/session pattern
requires a different issuance rate, and alert on throttling because repeated
denials can indicate credential stuffing or automation misuse.

Rotate the SSH user CA by adding a new CA public key to target hosts, switching
`SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_ID` and signer key material, then removing
the old public key after all certificates signed by the old CA have expired.

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

Example automation lives in `docs/ansible/remote-access-ssh-ca/`.

ServiceRadar already has an AWX/AAP-backed [Ansible Integration](./ansible). Use that integration as the normal enrollment path:

1. Copy `docs/ansible/remote-access-ssh-ca/playbook.yml` into a git repository that AWX uses as a Project.
2. Create an AWX Job Template for that playbook.
3. Attach the AWX inventory that contains the Linux hosts, Proxmox VE hosts, or VMs you want to enroll.
4. Register the AWX controller in ServiceRadar under **Settings -> Ansible**.
5. Let AWX inventory sync mark the matching inventory devices as `ansible_managed`.
6. Select one or more devices in ServiceRadar inventory and launch the enrollment job with **Run Task** or `/ansible/launch?devices=<device-uids>`.

ServiceRadar sends AWX a host `limit` derived from the selected devices, so the sample playbook uses `hosts: all` and relies on the launch limit to narrow the run. The playbook accepts the public CA key and SSH server options as `extra_vars`; define them in an AWX Survey for a polished operator flow or enter them as raw JSON from the ServiceRadar launch page. For ServiceRadar-launched AWX jobs, pass the public key inline as `serviceradar_ssh_ca_public_key`; `serviceradar_ssh_ca_public_key_file` only works when that file is available inside the AWX execution environment.

Example launch variables:

```json
{
  "serviceradar_ssh_ca_public_key": "ssh-ed25519 AAAA... serviceradar-remote-access-ca",
  "serviceradar_sshd_service": "sshd",
  "serviceradar_manage_authorized_principals": false
}
```

For Debian or Ubuntu targets, set `serviceradar_sshd_service` to `ssh` if that is the systemd service name.

The local `ansible-playbook` path is useful for testing the playbook outside ServiceRadar:

```bash
ansible-playbook \
  -i docs/ansible/remote-access-ssh-ca/inventory.example.ini \
  docs/ansible/remote-access-ssh-ca/playbook.yml \
  -e serviceradar_ssh_ca_public_key_file=/secure/path/serviceradar_user_ca.pub
```

The playbook installs only the public CA key and SSH server configuration. It never handles the CA private key.

For Debian or Ubuntu targets in local fallback mode, set the service name if needed:

```bash
ansible-playbook \
  -i docs/ansible/remote-access-ssh-ca/inventory.example.ini \
  docs/ansible/remote-access-ssh-ca/playbook.yml \
  -e serviceradar_sshd_service=ssh \
  -e serviceradar_ssh_ca_public_key_file=/secure/path/serviceradar_user_ca.pub
```

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

Smoke tests for lab environments are available in:

```bash
scripts/remote-access-authentik-oidc-ssh-smoke.sh
scripts/remote-access-demo-ssh-smoke.sh
```

## Rotation

Rotate the SSH user CA with an overlap window:

1. Generate the new CA keypair.
2. Add the new public key to every target while leaving the old public key trusted.
3. Update the ServiceRadar signer to use the new private key and `SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_ID`.
4. Wait longer than the maximum certificate TTL.
5. Remove the old public key from targets.

Never rotate by copying the private key to agents or target hosts. Only public trust anchors belong on SSH servers.
