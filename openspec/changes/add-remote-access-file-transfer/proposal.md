# Change: Add remote access file transfer

## Why
ServiceRadar remote access currently covers interactive SSH terminals and SSH-backed Proxmox host shells, but operators also need controlled file movement for diagnostics, config collection, log retrieval, and small remediation workflows.

File transfer is high risk because it can become an exfiltration or overwrite path. It must inherit the remote-access route, credential custody, RBAC, approval, recording, and audit model instead of becoming an arbitrary agent-side SFTP/SCP tunnel.

## What Changes
- Add SFTP-first file transfer as a remote-access capability over the selected agent route.
- Add per-operation RBAC for list, download, upload, and manage actions.
- Add policy gates for path allow/deny rules, symlink behavior, realpath validation, quotas, approval requirements, and optional content-audit hooks.
- Add transfer lifecycle records and replay/audit events that store metadata by default and never store file contents unless an explicit sensitive-artifact policy enables it.
- Keep SCP compatibility deferred until it can map into the same policy, quota, recording, and audit manager.

## Impact
- Affected specs: edge-architecture
- Affected code: web-ng remote access UI/API, core remote-access policy/recording resources, agent-gateway remote-access routing, Go agent remoteaccess adapters, RBAC catalog, audit/replay event projections, future dependency review for an Apache-compatible SFTP library
