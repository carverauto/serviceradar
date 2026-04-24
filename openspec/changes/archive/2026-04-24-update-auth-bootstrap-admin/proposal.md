# Change: Bootstrap admin credentials and remove magic-link login

## Why
Magic-link login is no longer supported. Operators need a predictable, secure admin login path for self-hosted installs.

## What Changes
- Remove magic-link login and registration flows in default deployments.
- Bootstrap an `admin` user with `root@localhost` and a randomly generated password on first install.
- Hash the generated password with bcrypt, persist it in the auth user store, and save the plaintext to an install-specific secret/volume.
- Surface the generated credentials once after successful install (Compose logs, Helm notes, manifest job output).
- Remove register links and disable the registration feature in the web UI.

## Impact
- Affected specs: `ash-authentication`
- Affected code: web-ng auth UI + auth endpoints, bootstrap job/logic (core-elx or web-ng), Helm chart, demo K8s manifests, Docker Compose init scripts
