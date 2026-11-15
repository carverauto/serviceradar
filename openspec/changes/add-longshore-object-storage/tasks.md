## 1. Contract and build qualification

- [ ] 1.1 Review the pinned public API against existing archive authority; hand off missing attempt/deadline, metadata, identity-bound reads, encryption and request-evidence APIs to the Longshore owner.
- [ ] 1.2 Qualify actual Linux/container io_uring, memlock and TLS requirements with explicit unsupported results.
- [ ] 1.3 Add immutable Cargo dependencies and hermetic Bazel AWS-LC support; verify supported Linux release architectures remotely.
- [x] 1.4 Land the separate media-storage seccomp chart setting, node-installation runbook and rendering tests (PR #6607).
- [ ] 1.5 Verify the reviewed seccomp profile on every eligible node before pod qualification; reject unsupported configuration such as the withdrawn buffer-pinning option.
- [ ] 1.6 Qualify the node/runtime memlock configuration needed for pinned zero-copy sends; obtain separate authorization before changing node configuration and verify every eligible node.

## 2. Rustler integration

- [ ] 2.1 Add the reusable library with bounded operation/byte admission, correlated asynchronous completion, panic containment and off-scheduler teardown.
- [ ] 2.2 Verify synthetic store/fetch/range, multipart, saturation, caller loss, deadline and shutdown behavior through the shipped NIF.
- [x] 2.2.1 Run the compiled qualification release in a prepared pod and verify synthetic conditional PUT, exact full/range reads, client/operation admission, caller exit and drain behavior.
- [ ] 2.2.2 Qualify the CI executor's native runtime policy and run the same runtime tests there; a pod pass does not substitute for a CI pass.
- [ ] 2.3 After upstream contract closure, connect the isolated archive provider adapter while preserving grant, no-clobber, exact-identity verification and unknown-outcome handling.
- [ ] 2.4 Verify credential rotation, failed writes, lost replies and preservation/reconciliation without automatic transport fallback.

## 3. Dogfood milestone

- [ ] 3.1 Complete the required source assignment and publication dependencies from the recorder-plane tasks; record any remaining prerequisite explicitly.
- [ ] 3.2 Record a bounded interval from the operator-selected inventory camera into the selected Linode binding; independently verify bytes, decode and authorized catalog playback.
- [ ] 3.3 Verify service restart with retained spool/journal and available recordings. Keep node-loss qualification separate.
- [ ] 3.4 Verify cleanup of only disposable synthetic objects/multipart uploads and retain operational evidence privately.

## 4. Performance and bottleneck validation

- [ ] 4.1 Add remote runnable native, Rustler and recorder benchmark targets using synthetic data and the protocol in benchmarks.md.
- [ ] 4.2 Reproduce matched native/Rustler single-object, range and multipart workloads; preserve raw evidence, versions, topology and effective limits privately.
- [ ] 4.3 Compare with the pinned Longshore reports, explicitly recording incompatible settings and missing upstream measurements.
- [ ] 4.4 Measure end-to-end seal-to-verified/archive/playable latency, useful video goodput, resource use, scheduler responsiveness, queue pressure and request amplification under concurrent recording/playback.
- [ ] 4.5 Profile the limiting stage, fix demonstrated avoidable overhead, and rerun matched cases; classify failed, passed and inconclusive gates.
- [ ] 4.6 Run the steady-state and bounded backlog-recovery soak, prove no unreported gaps or unbounded growth, and record supported capacity without extrapolating from one camera.
- [ ] 4.7 Require green relevant remote tests and full CI, including Core Integration and Web-NG DB, before implementation handoff. Do not mark unexecuted measurements complete.

