# ServiceRadar SSH CA Enrollment

This example enrolls Linux SSH servers so they trust a ServiceRadar OpenSSH user CA for remote access sessions.

The playbook installs:

- `/etc/ssh/serviceradar_user_ca.pub`
- `/etc/ssh/sshd_config.d/60-serviceradar-user-ca.conf`
- optional `/etc/ssh/auth_principals/<user>` files

It does not handle the CA private key. Keep the private key in the ServiceRadar signer custody boundary only. For production, prefer an isolated signer backed by OpenBao Transit, Vault Transit, cloud KMS, or an HSM; the file/env-key signer is a bootstrap path, not the long-term custody model.

## ServiceRadar Launch Path

ServiceRadar's Ansible integration runs playbooks through a registered AWX/AAP controller. Operators normally do not run `ansible-playbook` by hand.

1. Put this directory, or a copy of `playbook.yml`, in a git repository that AWX can use as a Project.
2. Create an AWX Job Template for `playbook.yml`.
3. Attach the AWX inventory that contains the Linux hosts, Proxmox VE hosts, or VMs you want ServiceRadar to enroll.
4. Add a Survey or allow `extra_vars` for these variables:
   - `serviceradar_ssh_ca_public_key`
   - `serviceradar_sshd_service`
   - `serviceradar_manage_authorized_principals`
   - `serviceradar_authorized_principals`
5. Register the AWX controller in ServiceRadar under **Settings -> Ansible**.
6. Let AWX inventory sync mark the matching devices as `ansible_managed`.
7. In ServiceRadar, select the target devices from inventory and launch the AWX-sourced job template from **Run Task** or `/ansible/launch?devices=<device-uids>`.

ServiceRadar passes an AWX `limit` built from the selected device inventory refs, so this playbook uses `hosts: all`. AWX narrows execution to the selected hosts at launch time.

Example raw `extra_vars` from the ServiceRadar launch page:

```json
{
  "serviceradar_ssh_ca_public_key": "ssh-ed25519 AAAA... serviceradar-remote-access-ca",
  "serviceradar_sshd_service": "sshd",
  "serviceradar_manage_authorized_principals": false
}
```

For Debian or Ubuntu targets, use `"serviceradar_sshd_service": "ssh"` if that is the systemd service name.

Use `serviceradar_ssh_ca_public_key_file` only when the public key file is available inside the AWX execution environment or when running the playbook locally. For ServiceRadar-launched AWX jobs, passing the public key inline as `serviceradar_ssh_ca_public_key` is usually the correct path.

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
