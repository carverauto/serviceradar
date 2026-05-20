## Context
Manual device creation already resolves hostname-only submissions through `ServiceRadarWebNG.Devices.HostnameResolver` and derives deterministic manual UIDs from the resolved IP address. The current path still assumes a fresh insert after resolution. That leaves older hostname-only records and soft-deleted records as failure modes when an operator tries to add the hostname again.

## Goals
- Keep manual device creation idempotent for the same hostname/IP.
- Prefer updating or restoring an existing canonical record over creating duplicates.
- Preserve existing device associations by merging only when two active records clearly represent the same manually submitted target.

## Non-Goals
- Add a background DNS refresh job for all inventory.
- Change discovery/DIRE behavior for non-manual ingestion sources.
- Introduce a new database schema or unique hostname constraint.

## Design
Manual creation will normalize input, resolve hostname-only submissions, and build the same create attributes used today. Before calling `Ash.create/2`, it will look for include-deleted matches in this order:

1. deterministic manual UID from resolved IP
2. resolved primary IP
3. normalized hostname

If exactly one matching record exists, the creator will restore it when tombstoned, update IP/hostname/name/type/tags/discovery metadata, and return it as success.

If the resolved-IP match and hostname match are different active records, the creator will choose the resolved-IP record as canonical, update it with the hostname/manual metadata, and merge the hostname-only duplicate into it through `IdentityReconciler.merge_devices/3` using a `manual_hostname_readd` reason.

If no match exists, the creator will keep the current fresh create path.
