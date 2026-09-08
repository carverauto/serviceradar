# ServiceRadar SSH CA Enrollment

This example enrolls Linux SSH servers so they trust a ServiceRadar OpenSSH user CA for remote access sessions.

The playbook installs:

- `/etc/ssh/serviceradar_user_ca.pub`
- `/etc/ssh/sshd_config.d/60-serviceradar-user-ca.conf`
- optional `/etc/ssh/auth_principals/<user>` files

It does not handle the CA private key. Keep the private key in the ServiceRadar signer custody boundary only. For production, prefer an isolated signer backed by OpenBao Transit, Vault Transit, cloud KMS, or an HSM; the file/env-key signer is a bootstrap path, not the long-term custody model.

## CA Private-Key Custody

Treat the SSH user CA private key as a signing authority, not as an agent
credential. It must not be copied to ServiceRadar agents, target hosts, AWX
inventory variables, or playbook launch inputs.

The production pattern is:

1. Keep the CA private key inside a dedicated signer boundary backed by OpenBao
   Transit, Vault Transit, cloud KMS, or an HSM.
2. Configure ServiceRadar to call that signer through
   `SERVICERADAR_REMOTE_ACCESS_SSH_CA_SIGNER_COMMAND`.
3. Have the signer consume `SERVICERADAR_SSHCA_SIGN_REQUEST_FILE`, apply the
   same bounded JSON request/response contract as `serviceradar-sshca-signer`,
   and return only the signed OpenSSH user certificate on stdout.
4. Emit signer-side audit records for key load, key id, actor/session metadata,
   requested principals, TTL, and denial reasons.

The bundled `serviceradar-sshca-signer` is for bootstrap and lab use when the CA
key is supplied from a file or environment variable. If you use it during
bootstrap, pass `--audit-file /var/log/serviceradar/sshca-signer-audit.jsonl`
or set `SERVICERADAR_SSHCA_AUDIT_FILE` so key-load events are appended outside
stdout. The audit event records the source kind (`file` or `env`) and CA public
key fingerprint, never the private key material or file path.

Rotation procedure:

1. Generate or provision a new CA key in the signer custody backend.
2. Distribute the new CA public key to targets while keeping the old public key
   trusted.
3. Switch `SERVICERADAR_REMOTE_ACCESS_SSH_CA_KEY_ID` and the signer backend/key
   reference to the new CA.
4. Wait longer than the maximum certificate TTL.
5. Remove the old CA public key from targets and archive the old signer audit
   stream.

## ServiceRadar Launch Path

ServiceRadar's Ansible integration runs playbooks through a registered AWX/AAP controller. Operators normally do not run `ansible-playbook` by hand.

1. Put this directory, or a copy of `playbook.yml`, in a git repository that AWX can use as a Project.
2. Create an AWX Job Template for `playbook.yml`.
3. Attach the AWX inventory that contains the Linux hosts, Proxmox VE hosts, or VMs you want ServiceRadar to enroll.
4. Configure the exact ServiceRadar dispatch-marker survey and reviewed immutable binding described in the [remote-access guide](../../docs/remote-access.md#ansible-enrollment). Integrated callback mode supplies the CA and target policy through the reviewed callback; do not add them to browser inputs. Put only optional, non-secret operator values such as `serviceradar_sshd_service` in the binding's typed input schema.
5. Register the AWX controller in ServiceRadar under **Settings -> Ansible**.
6. Let AWX inventory sync mark the matching devices as `ansible_managed`.
7. In ServiceRadar, select the target devices from inventory and choose **Launch Playbook**, or open `/ansible/launch?devices=<device-uids>` directly. The separate provider-neutral **Run Action** workflow does not launch Ansible playbooks.

ServiceRadar passes an AWX `limit` built from the selected device inventory refs, so this playbook uses `hosts: all`. AWX narrows execution to the selected hosts at launch time.

The ServiceRadar launch page renders only reviewed typed, non-secret inputs. It does not accept free-form payloads, undeclared variables, password fields, or connection variables. Keep SSH private keys, become passwords, and vault secrets in AWX credentials rather than adding them to the binding or browser form.

For Debian or Ubuntu targets, use `"serviceradar_sshd_service": "ssh"` if that is the systemd service name.

Use `serviceradar_ssh_ca_public_key_file` or inline `serviceradar_ssh_ca_public_key` only for the manual/lab fallback outside the integrated callback path.

## Local Fallback

Generate or locate the public CA key:

```bash
ssh-keygen -t ed25519 -f serviceradar_user_ca -C serviceradar-remote-access-ca
```

Run the playbook directly only for local testing or break-glass automation outside ServiceRadar:

```bash
ansible-playbook \
  -i docs/ansible/remote-access-ssh-ca/inventory.example.ini \
  docs/ansible/remote-access-ssh-ca/playbook.yml \
  -e serviceradar_ssh_ca_public_key_file=/secure/path/serviceradar_user_ca.pub
```

For Debian or Ubuntu hosts, set the SSH service name if it is `ssh`:

```bash
ansible-playbook \
  -i docs/ansible/remote-access-ssh-ca/inventory.example.ini \
  docs/ansible/remote-access-ssh-ca/playbook.yml \
  -e serviceradar_sshd_service=ssh \
  -e serviceradar_ssh_ca_public_key_file=/secure/path/serviceradar_user_ca.pub
```

You can also pass the public key material directly:

```bash
ansible-playbook \
  -i docs/ansible/remote-access-ssh-ca/inventory.example.ini \
  docs/ansible/remote-access-ssh-ca/playbook.yml \
  -e 'serviceradar_ssh_ca_public_key=ssh-ed25519 AAAA... serviceradar-remote-access-ca'
```

## Authorized Principals

By default, OpenSSH accepts a user certificate when one certificate principal matches the login account name.

Enable `AuthorizedPrincipalsFile` only when you need a mapping layer, such as allowing a `linux-admins` principal to log in as `ubuntu`:

```bash
ansible-playbook \
  -i docs/ansible/remote-access-ssh-ca/inventory.example.ini \
  docs/ansible/remote-access-ssh-ca/playbook.yml \
  -e @docs/ansible/remote-access-ssh-ca/group_vars.example.yml
```

Edit `group_vars.example.yml` before using it in a real environment.

## Verification

On a target host:

```bash
sudo sshd -T | grep trustedusercakeys
sudo sshd -t
```

Check the system auth log if SSH certificate login fails. Common causes are a missing OS account, principal mismatch, expired certificate, wrong CA public key, or an `AuthorizedPrincipalsFile` that does not list the presented principal.
