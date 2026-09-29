## 1. Implementation

- [ ] 1.1 Authorized time-bounded timeline, seek and export APIs with explicit discontinuities, stale/index-pending states, unavailable intervals and gaps.
- [ ] 1.2 Short-lived media handles; no camera credentials or reusable bucket credentials in the browser or shared links.
- [ ] 1.3 Retention, holds and export leases with atomic conflict resolution, deletion verification and orphan/multipart cleanup.
- [ ] 1.4 Extend the existing host camera API/SDK player lifecycle. Coordinate resource/object links with `add-shared-spatial-resources`; a link locates a view/object/interval but grants no access.
- [ ] 1.5 Keep recording independent of viewer lifecycle; release viewer sessions when dashboards hide/unmount.

## 2. Acceptance

- [ ] Real browser playback seeks across verified synthetic segments and reports gaps/expired intervals accurately.
- [ ] Access denial, expired handles and guessed object identities fail without exposing storage credentials.
- [ ] Hold-vs-delete and export-vs-retention races resolve consistently; a hold is never confirmed on deleted or temporary-only footage.
- [ ] Object deletion is rechecked before the index reports completion; failed cleanup remains retryable.
- [ ] Shared map/object/recording links restore the intended authorized context and dashboard disposal releases resources.

## 3. Delivery

- [ ] 3.1 Validate this proposal with openspec validate --strict and run applicable remote checks.
- [ ] 3.2 Run make test and deliver code changes through no-mistakes with the srql-fixtures-only database restriction in the intent.
- [ ] 3.3 Record evidence and close only this issue after its own acceptance passes.
