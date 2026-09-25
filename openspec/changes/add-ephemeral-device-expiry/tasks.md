# Tasks

## 1. Expiry

- [x] 1.1 `platform.device_holds_strong_identifier/1` and `platform.mac_is_locally_administered/1`
      (migration), plus the new `DeviceCleanupSettings` columns.
- [x] 1.2 `EphemeralDeviceExpiry.run/3`: candidate read, attribute/metadata re-check, SRQL
      exclusion (fail closed), mass-expiry guard, soft delete with the re-check in its `WHERE`,
      telemetry.
- [x] 1.3 Run it from `DeviceCleanupWorker` before the purge.
- [x] 1.4 Settings form fields in web-ng.
- [x] 1.5 Integration tests: eligible devices expire; every strong class, operator-created,
      recently seen and excluded devices do not; the guard refuses and its override lets the
      pass through; revival leaves an audit row and bumps the revision.

## 2. Formal model

- [x] 2.1 `Expire` action and `ExpiryKeepsStrongIdentity` in `DireLifecycle.tla`, checked in
      `lifecycle_goal.cfg` and `lifecycle_current.cfg`; `lifecycle_vacuity_expire` proves the
      action is reachable.
- [x] 2.2 `expire_ephemeral` lifecycle trace from the real code.
