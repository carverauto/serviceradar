## 1. Scanner skip union
- [x] 1.1 Add a built-in skip directory set in `go/pkg/scalibrinventory` and union it with `Config.DirsToSkip` before `scalibrfilesystem.Run`.
- [x] 1.2 Ignore operator skip paths that are empty, relative, or not under a configured scan root; record them on diagnostics without failing the scan.
- [x] 1.3 Emit the effective (unioned, de-duplicated) skip list on scanner activity metadata `dirs_to_skip`.
- [x] 1.4 Unit-test: built-in skips apply when `dirs_to_skip` is empty; operator extras are kept; a delivered list that omits `/proc` still skips `/proc`; a nested tree under a skipped parent is not visited.

## 2. Add-on config surface
- [x] 2.1 Expand `dirs_to_skip` schema title/description so the assignment and profile form explains that listed directories and their descendants are skipped, and that built-in runtime/cache trees are always skipped.
- [x] 2.2 Expand package-default `dirs_to_skip` in `scalibr-endpoint-inventory.json` to match the documented operator-visible examples without relying on it for safety.
- [x] 2.3 Bump `addons/scalibr-endpoint-inventory/addon.yaml` `version` (native add-on gate).
- [x] 2.4 Regenerate add-on config contract fixtures if the delivered default document changes (`mix serviceradar.gen.addon_contract_fixtures`).
  Assignment fixture does not set `dirs_to_skip`; delivered assignment JSON is unchanged, so no fixture regen.

## 3. Validation
- [x] 3.1 `openspec validate add-scalibr-scan-skip-directories --strict`
- [x] 3.2 Focused Go tests for `go/pkg/scalibrinventory`
- [x] 3.3 Native add-on version-bump gate for the touched add-on paths
  Manifest version 0.1.6 -> 0.1.7. The git gate compares commits; it will apply once this branch is committed.
