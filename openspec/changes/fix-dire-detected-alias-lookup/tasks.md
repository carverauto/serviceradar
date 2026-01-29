## 1. Investigation (Complete)

- [x] 1.1 Reproduce the issue on live system (demo namespace)
- [x] 1.2 Identify root cause in alias lookup filtering
- [x] 1.3 Document the race condition in alias confirmation

## 2. Alias Lookup Enhancement

- [x] 2.1 Add `lookup_detected_aliases_by_ip/2` function to `DeviceLookup` that returns detected aliases as fallback candidates
- [x] 2.2 Modify `batch_lookup_by_ip/2` to accept `include_detected: true` option
- [ ] 2.3 Add unit tests for detected alias fallback behavior

## 3. Sweep Ingestor Integration

- [x] 3.1 Update `process_batch/3` to check detected aliases before creating new devices
- [x] 3.2 When using a detected alias, call `confirm_from_sweep` action to promote state
- [x] 3.3 When creating a new sweep device, create an IP alias record (state: detected)
- [ ] 3.4 Add integration tests for sweep-detected alias resolution

## 4. DeviceAliasState Enhancement

- [x] 4.1 Add `confirm_from_sweep` action that promotes detected → confirmed immediately
- [x] 4.2 Record metadata about the sweep that triggered confirmation
- [ ] 4.3 Add tests for the new confirmation action

## 5. IdentityReconciler Enhancement

- [x] 5.1 Update `lookup_alias_device_id/3` to check detected aliases when no confirmed alias found (via `include_detected: true` option)
- [ ] 5.2 Ensure reconciliation merges devices sharing detected IP aliases
- [ ] 5.3 Add tests for detected alias resolution in reconciler

## 6. Scheduled Reconciliation

- [ ] 6.1 Add query to find devices with overlapping detected IP aliases
- [ ] 6.2 Merge duplicate devices discovered via detected alias overlap
- [ ] 6.3 Log statistics on alias-based merges

## 7. Validation

- [ ] 7.1 Test on demo namespace with live mapper + sweep data
- [ ] 7.2 Verify tonka01/216.17.46.98 scenario resolves correctly
- [ ] 7.3 Verify no regressions in normal sweep ingestion path
