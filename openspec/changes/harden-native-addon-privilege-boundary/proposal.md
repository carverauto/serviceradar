# Change: Harden native add-on privilege boundary

## Why
Systemd-supervised native add-ons currently execute binaries from the non-root
agent's writable staging tree, and the privileged updater installs unit files
from that same tree. A compromised `serviceradar` process can therefore replace
an executable or unit after download verification and gain the privileges of the
add-on service, including root.

## What Changes
- Require signed artifacts for systemd-supervised native add-ons.
- Make the root-owned updater verify the original artifact and publish an
  immutable, root-owned runtime tree before installing units or capabilities.
- Execute privileged add-ons only from that root-owned runtime tree.
- Keep assignment-derived configuration and mutable state in the existing
  non-root state tree, outside the executable tree.
- Preserve atomic activation, rollback, timer activation, and stale-unit cleanup.

## Impact
- Affected specs: `agent-configuration`
- Affected code: native add-on staging, the privileged agent updater, systemd
  unit assets, package ownership setup, and activation/rollback tests
- **BREAKING**: unsigned artifacts cannot use `systemd-service` or
  `systemd-timer` supervision.
