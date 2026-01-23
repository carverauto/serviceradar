## 1. Implementation
- [x] 1.1 Remove `is_default` from the sysmon profile schema and add a migration to drop the column.
- [x] 1.2 Update Ash resources, API serializers, and config compiler logic to stop reading or writing `is_default`.
- [x] 1.3 Change sysmon config resolution to return a disabled config when no SRQL profile matches (local overrides still win).
- [x] 1.4 Update web-ng UI flows to remove default-profile protections and show "Unassigned" when no profile applies.
- [x] 1.5 Update tests/fixtures for sysmon profile creation, assignment, and config resolution.
