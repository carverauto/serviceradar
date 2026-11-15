## 1. Contract and build qualification

- [x] 1.1 Review the pinned public API against existing archive authority; hand off missing attempt/deadline, metadata, identity-bound reads, encryption and request-evidence APIs to the Longshore owner. Upstream implementation remains separate from this completed contract review.
- [ ] 1.2 Qualify actual Linux/container io_uring, memlock and TLS requirements with explicit unsupported results.
- [x] 1.3 Add immutable Cargo dependencies (`8759583fd1888f292f290a5adbe883c8c6eb6aee`) and hermetic Bazel AWS-LC support; verify supported Linux release architectures remotely.
- [x] 1.4 Land the separate media-storage seccomp chart setting, node-installation runbook and rendering tests (PR #6607).
- [ ] 1.5 Verify the reviewed seccomp profile on every eligible node before pod qualification; reject unsupported configuration such as the withdrawn buffer-pinning option.
- [ ] 1.6 Qualify the node/runtime memlock configuration needed for pinned zero-copy sends; obtain separate authorization before changing node configuration and verify every eligible node.

## 2. Rustler integration

- [x] 2.1 Add the reusable library with bounded operation/byte admission, correlated asynchronous completion (`ServiceRadarObjectStorage.Session`), strict option decoding, panic containment and off-scheduler teardown.
- [ ] 2.2 Verify synthetic store/fetch/range, multipart, saturation, caller loss, deadline and shutdown behavior through the shipped NIF (single-object `put`/`head`/`get`, saturation, caller loss, deadline and shutdown verified on RBE; multipart NIF surface remains deferred).
- [x] 2.2.1 Run the compiled qualification release in a prepared pod and verify synthetic conditional PUT, exact full/range reads, client/operation admission, caller exit and drain behavior.
- [x] 2.2.2 Qualify the CI executor's native runtime policy and run the same runtime tests there; a pod pass does not substitute for a CI pass. Both suites passed on the separately approved io_uring-capable executor pool.
- [x] 2.2.3 Run a bounded synthetic MP4 through the shipped NIF against the selected real provider over TLS; verify full SHA-256, ranged bytes and independently decoded frame equality. This does not qualify archive authority or live-camera playback.
- [x] 2.3 After upstream contract closure (`8759583fd1888f292f290a5adbe883c8c6eb6aee`), connect the isolated archive provider adapter (`CameraStorage` opt-in `:longshore` transport + `s3_compatible` CNPG credential binding) while preserving grant, no-clobber, `*-put-canonical-v1` evidence, independent `HEAD` + 4 MiB ranged `GET` SHA-256 verification, HTTP `200`/`206`-only body extraction, and unknown-outcome handling.
- [x] 2.4 Verify credential rotation, failed writes, lost replies and preservation/reconciliation without automatic transport fallback.

## 3. Dogfood milestone

- [ ] 3.1 Complete the required source assignment and publication dependencies from the recorder-plane tasks; record any remaining prerequisite explicitly.
- [ ] 3.2 Record a bounded interval from the operator-selected inventory camera into the selected Linode binding; independently verify bytes, decode and authorized catalog playback.
- [ ] 3.3 Verify service restart with retained spool/journal and available recordings. Keep node-loss qualification separate.
- [ ] 3.4 Verify cleanup of only disposable synthetic objects/multipart uploads and retain operational evidence privately.

## 4. Performance and bottleneck validation

- [x] 4.1 Add remote runnable native, Rustler and recorder benchmark targets (`//elixir/serviceradar_object_storage:object_storage_bench_test` and `//elixir/serviceradar_core_elx:camera_storage_bench_test`) using synthetic data and the protocol in benchmarks.md.
- [ ] 4.2 Reproduce matched native/Rustler single-object, range and multipart workloads; preserve raw evidence, versions, topology and effective limits privately (matched synthetic single-object and range workloads completed on RBE; multipart and live-provider HTTPS runs remain open).
- [x] 4.3 Compare with the pinned Longshore reports, explicitly recording incompatible settings and missing upstream measurements.
- [x] 4.4 Measure end-to-end seal-to-verified/archive/playable latency, useful video goodput, resource use, scheduler responsiveness, queue pressure and request amplification under concurrent recording/playback.
- [x] 4.5 Profile the limiting stage, fix demonstrated avoidable overhead (`ScratchBuf` write pool + single-allocation `OwnedBinary` read release), and rerun matched cases; classify failed, passed and inconclusive gates.
- [ ] 4.6 Run the steady-state and bounded backlog-recovery soak, prove no unreported gaps or unbounded growth, and record supported capacity without extrapolating from one camera.
- [ ] 4.7 Require green relevant remote tests and full CI, including Core Integration and Web-NG DB, before implementation handoff. Do not mark unexecuted measurements complete.
