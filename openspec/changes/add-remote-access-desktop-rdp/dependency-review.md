# RDP Dependency Review

## Scope
This review records dependency choices for the first desktop/RDP implementation slice before protocol adapter work starts.

## Decisions
- RDP protocol implementation: use upstream Devolutions IronRDP crates directly, pinned before import.
- Initial upstream candidate: `https://github.com/Devolutions/IronRDP` at commit `df0bf9c69d88febaf6b82c479fdc7dcafe226567`.
- First ServiceRadar import: link only `ironrdp-core = 0.1.5` and `ironrdp-pdu = 0.7.0` behind the helper's `ironrdp-backend` feature and a separate Bazel target. Do not link `ironrdp-connector`, CredSSP, SSPI, clipboard, drive, printer, audio, smart-card, or file redirection crates in this slice.
- Browser renderer: use ServiceRadar-owned Canvas/ImageData rendering that consumes the typed desktop frame contract in `go/pkg/agent/remoteaccess/desktop.go`.
- Do not import Teleport's Go/Rust RDP wrapper, decoder, web package, TDP protocol, or desktop service implementation.
- Do not enable clipboard, drive, printer, audio, smart-card, or file redirection dependencies in the first adapter slice.

## Rationale
Teleport's current desktop/RDP implementation is not suitable for direct import into ServiceRadar:

- `~/src/teleport/Cargo.toml` sets `license = "AGPL-3.0-only"` for the Teleport RDP workspace members.
- Current Teleport files under `lib/srv/desktop/rdp` and `web/packages/shared/libs/ironrdp` include AGPL headers.
- The local license scan for `github.com/gravitational/teleport/lib/srv/desktop`, `github.com/gravitational/teleport/lib/srv/desktop/rdp`, and `github.com/gravitational/teleport/lib/web/desktop` reports AGPL transitive dependency paths.

The upstream IronRDP repository is the cleaner dependency candidate. Its GitHub repository advertises `LICENSE-APACHE` and `LICENSE-MIT`, and the project is a focused Rust RDP implementation rather than Teleport-specific access-plane code.

The pinned local checkout at `~/src/IronRDP` is detached at `df0bf9c69d88febaf6b82c479fdc7dcafe226567`. The root workspace and reviewed crates declare `MIT OR Apache-2.0` and include `LICENSE-APACHE` and `LICENSE-MIT`. The first ServiceRadar import intentionally stops at `ironrdp-core` and `ironrdp-pdu` because enabling the connector feature pulls the CredSSP/SSPI crypto graph into the shared workspace lockfile. That graph must be reviewed in a dedicated connector import before any helper can dial real RDP targets.

## Connector Import Gate
Do not link `ironrdp-connector` into the production helper until this gate is satisfied.

Current exact crates.io connector surface, refreshed 2026-07-13:

- The isolated review workspace pins `ironrdp-connector = 0.10.0`, `ironrdp-blocking = 0.10.0`, `ironrdp-core = 0.2.1`, `ironrdp-graphics = 0.9.0`, `ironrdp-pdu = 0.9.0`, and `ironrdp-session = 0.11.0`. The IronRDP crates declare `MIT OR Apache-2.0`.
- `ironrdp-connector = 0.10.0` resolves `sspi = 0.21.1`, `picky = 7.0.0-rc.25`, `picky-asn1-der = 0.5.6`, `picky-asn1-x509 = 0.15.4`, `rand = 0.9.5`, `url = 2.5.8`, and `tracing = 0.1.44`.
- The published connector manifest unconditionally enables `sspi`'s `scard` feature. That forces `winscard 0.3.3 -> iso7816 0.1.4 -> heapless 0.7.17 -> spin 0.9.9` into the build graph. Cargo features are additive, so ServiceRadar's `default-features = false` cannot subtract this subtree.
- ServiceRadar rejects smart-card and all other redirection policy before connector construction. The subtree is unreachable build baggage, not an enabled ServiceRadar synchronization or smart-card capability. It must be removed through a maintained upstream IronRDP feature gate; ServiceRadar will not carry a connector fork, version override, archived `spin` vendor, or new audit ignore for it.
- `picky = 7.0.0-rc.25` remains security-sensitive pre-release PKI/crypto code and is covered by the isolated lockfile plus the RustSec release gate.
- `ironrdp-client` is not an import target for ServiceRadar. It pulls UI/windowing, audio, clipboard, RDPDR, RDPSND, dynamic virtual channel, MSTS Gateway, WebSocket, and Devolutions Gateway transport dependencies that do not belong in the agent helper.

Initial 2026-05-16 checkout/import evidence remains useful history: the pinned IronRDP checkout exposed connector 0.8.0 with `sspi 0.19` and `picky 7.0.0-rc.22`, while the then-published connector 0.8.0 resolved `sspi 0.18` and `picky 7.0.0-rc.20`. Importing it into the shared workspace locked 89 packages and downgraded shared crypto crates. That established the separate workspace/lockfile boundary; those versions are no longer the reviewed probe baseline.

Current crates.io import and audit check:

- A same-workspace import of the published connector forces the root `Cargo.lock` away from existing stable crypto crate versions. Do not land that import in the shared ServiceRadar Rust workspace.
- The 2026-07-13 exact-family upgrade removes yanked `spin 0.9.8` and removes `paste`; the locked graph contains non-yanked `spin 0.9.9` only through the forced smart-card subtree described above.
- `cargo audit --deny warnings` passes with the two pre-existing documented exceptions: RUSTSEC-2023-0071 for the unfixed `rsa` Marvin timing issue through `sspi/picky`, and RUSTSEC-2023-0089 for unmaintained `atomic-polyfill` through the forced smart-card subtree. The former RUSTSEC-2024-0436 `paste` exception is removed. Any additional vulnerability, unmaintained warning, or yanked package fails CI.
- `rust/rdp-connector-probe` is a review-only isolated Cargo workspace with its own `Cargo.lock`. It proves the connector graph, a ServiceRadar helper-open payload parser, a minimal ServiceRadar-to-IronRDP config mapping, registered endpoint/TLS identity derivation, and the first IronRDP connector state-machine steps can compile without perturbing the root ServiceRadar Rust lockfile. The negotiation smoke tests decode the emitted X.224 request, verify that NLA/CredSSP is advertised without plain TLS fallback, prove HYBRID and HYBRID_EX server confirms reach the TLS upgrade boundary before CredSSP, reject server-selected TLS-only and standard-RDP downgrades, and confirm the pre-TLS X.224 request carries the mstshash username cookie without the cleartext password.
- The isolated probe links `ironrdp-blocking = 0.10.0` and drives its upstream `connect_begin` wrapper with a scripted server confirm. This proves the production helper should reuse IronRDP's connector loop through the TLS upgrade boundary rather than hand-rolling the connection-initiation sequence.
- The isolated probe directly links `x509-cert = 0.2` and proves ServiceRadar can extract the TLS peer certificate public key bytes needed for IronRDP/CredSSP binding after a verified TLS upgrade. It also proves the `ironrdp-blocking::connect_finalize` boundary enters CredSSP after the TLS upgrade marker, writes the first CredSSP bytes, and does not expose the cleartext password in that first write. TLS verification, completing CredSSP against a controlled server, and the active graphics stage remain production-helper work and must stay behind the isolated dependency boundary.
- The isolated probe declares `rustls = 0.23.40` and locks 0.23.42 with `ring`, `std`, and `tls12` features for a lab-only TLS upgrade smoke test. The test requires `SERVICERADAR_RDP_LIVE_TLS_INSECURE_ACCEPT_INVALID_CERTS=1`, accepts invalid certificates only inside the review probe, disables TLS resumption for CredSSP compatibility, extracts the peer certificate public key after handshake, and verifies the recorded client bytes do not contain the test password. This is not production target trust and must not make the helper ready.
- The isolated probe declares `rustls-native-certs = 0.8.3` and locks 0.8.4 for the `system` trust path. The crate is `Apache-2.0 OR ISC OR MIT` and adds platform-specific root-store loading dependencies only inside the isolated RDP connector universe.
- The isolated probe and Bazel connector-link adapter target now prove registered PEM CA bundle material and native system roots can build normal Rustls client verifiers, reject DER, empty, or malformed bundles/root stores, and disable TLS resumption for CredSSP compatibility. This is the production trust shape for `verify` with a registered bundle, `pinned_ca`, and `system`; live verified TLS against a controlled target remains follow-up work.
- The isolated probe now derives an explicit TLS upgrade plan from ServiceRadar target policy. System-root verification is the default for `verify` without a registered CA bundle, `verify` with a bundle and `pinned_ca` use registered CA bundle IDs, and insecure modes or `pinned_ca` without a bundle fail closed before connector finalization.
- The RDP adapter now has a Bazel-only connector-link probe target that compiles adapter source against the isolated `@rdp_connector_crates` universe and directly links `ironrdp-connector`, `ironrdp-blocking`, `ironrdp-session`, `ironrdp-graphics`, `ironrdp-pdu`, `rustls`, `rustls-native-certs`, `x509-cert`, `base64`, and `zeroize` without adding connector/CredSSP/active-stage dependencies to the root ServiceRadar Rust lockfile. It also proves a validated ServiceRadar open payload can map target screen policy, NLA posture, explicit PEM TLS trust source, and domain-qualified memory-user credentials into IronRDP connector config inside that isolated boundary, emit an initial X.224 request that advertises CredSSP/NLA without plain TLS fallback, advance HYBRID/HYBRID_EX server confirms to the TLS upgrade then CredSSP boundary while rejecting TLS-only downgrade, reuse the upstream `ironrdp-blocking::connect_begin` loop without pre-TLS cleartext password exposure, derive typed CredSSP binding public-key material from verified TLS certificate DER while invalid certificate bytes fail closed, build verified Rustls client configs from registered PEM CA bundles and system roots, enter `ironrdp-blocking::connect_finalize` CredSSP writes using that typed certificate-derived public-key material without exposing the cleartext password before server input, construct the active stage far enough to encode keyboard input into an RDP response frame, and translate ServiceRadar keyboard/pointer/focus input frames into IronRDP active-stage input events with unsupported tokens failing closed. This is still a compile/link and mapping check only; the runtime helper remains connector-not-ready and fail-closed.
- The production IronRDP helper should use an isolated optional helper dependency graph, for example a separate helper workspace/lockfile or Bazel crate-universe repository, so CredSSP/PKI dependencies cannot perturb SRQL, collectors, or other Rust services.

ServiceRadar connector import requirements:

- Import connector dependencies in a dedicated commit with the exact crate list, versions, features, and license check output.
- Keep connector/CredSSP/PKI dependencies out of the root ServiceRadar Rust lockfile unless the resolver impact is explicitly reviewed across all Rust services.
- Prefer the smallest direct IronRDP crate set required for TCP + TLS + NLA + screen frames. Do not import `ironrdp-client`.
- Disable clipboard, drive, printer, audio, smart-card redirection, file transfer, dynamic virtual channel plugins, and MSTS Gateway/RDCleanPath support until each feature has its own policy and audit implementation.
- Do not enable TOFU or any target-trust mode that requires agent-local persistent state. Target trust must come from the registered target policy, system roots, or an explicit CA bundle/pin managed outside the helper.
- Treat `sspi`/CredSSP and `picky`/PKI as security-sensitive dependencies: run focused dependency review, record crypto provider features, and add an integration test against a controlled RDP server before advertising `remote_access.rdp`.
- Keep the Go agent as the credential, route, policy, audit, and flow-control owner. The Rust connector loop may receive only a session-scoped open payload over local IPC and must drop credential material on any open, auth, TLS, route, or process failure.

## Active Stage Import Gate
After `ironrdp-blocking::connect_finalize` returns an `ironrdp-connector::ConnectionResult`, the upstream path for the live desktop loop is `ironrdp-session::ActiveStage`, not `ironrdp-client`, `ironrdp-client-glutin`, `ironrdp-web`, or Teleport's desktop wrapper.

Current active-stage crate surface, refreshed 2026-07-13:

- `ironrdp-session = 0.11.0` is `MIT OR Apache-2.0`.
- `ironrdp-session` resolves `ironrdp-bulk 0.1.1`, `ironrdp-core 0.2.1`, `ironrdp-displaycontrol 0.8.0`, `ironrdp-dvc 0.8.0`, `ironrdp-error 0.2.0`, `ironrdp-graphics 0.9.0`, `ironrdp-pdu 0.9.0`, `ironrdp-svc 0.8.0`, and `tracing 0.1.44`. Session 0.11.0 no longer adds its own connector dependency.
- `ActiveStage::process` can emit response frames, graphics update rectangles, pointer updates, termination, deactivation, multitransport requests, and autodetect output. The ServiceRadar helper must map only approved graphics and input behavior into SRDP media/control frames.
- Do not import `ironrdp-client`, `ironrdp-client-glutin`, `ironrdp-web`, audio/clipboard/drive/printer stacks, or UI renderer crates for the helper active-stage slice.
- Treat multitransport, display-control resize, dynamic virtual channels, and pointer rendering as policy-gated follow-ups. They must not bypass the existing route, recording, redirection, and media backpressure contracts.

ServiceRadar active-stage import requirements:

- Add `ironrdp-session` only to the isolated optional helper dependency graph first, with the exact crate list and lockfile impact recorded before any production-ready artifact advertises `remote_access.rdp`.
- Map IronRDP active-stage graphics outputs to ServiceRadar-owned SRDP media frames; do not pass upstream frame payloads directly to the browser without the existing session guard, quota, and recording checks.
- Map browser keyboard, pointer, focus, and resize input through ServiceRadar's typed desktop control frames before encoding IronRDP input PDUs.
- Keep clipboard, drive, printer, audio, smart-card, file-copy, and arbitrary dynamic virtual channel handling disabled until each feature has explicit policy, audit, and tests.

Historical validation on 2026-05-16 added `ironrdp-session = 0.8.0` to the isolated connector probe and established the active-stage boundary without changing the root ServiceRadar lockfile.

Validation on 2026-07-13: the probe was upgraded coherently to session 0.11.0 and the new `ActiveStageBuilder` API. It links `ironrdp_session::ActiveStageOutput`, constructs active-stage state from ServiceRadar-mapped connector state, and encodes a ServiceRadar-shaped keyboard event through `ActiveStage::process_fastpath_input` into an upstream RDP response frame. `cargo fmt --check`, all 37 isolated tests, and `cargo clippy --locked --all-targets -- -D warnings` pass. After regenerating the isolated crate-universe entry, `bazel test --lockfile_mode=error` passes for `//rust/rdp-connector-probe:rdp_connector_probe_test`, `//rust/rdp-adapter:rdp_adapter_connector_link_probe_test`, and `//rust/rdp-adapter:rdp_adapter_ironrdp_connector_experimental_test`; those targets are part of the Rust CI gate. The adapter handoff probes prove an IronRDP `ConnectionResult` can enter the same active-stage and network-pump backend session path that future `connect_finalize` output will use. This does not prove completed live authentication, production target trust, active-stage media against a controlled server, cleanup ordering, or helper readiness.

## Implementation Boundary
The ServiceRadar adapter must own:

- target policy validation
- route/session lifecycle
- credential custody
- redirection policy
- recording metadata
- graphical frame quota and backpressure
- browser renderer UX

IronRDP may be used only for the RDP protocol mechanics after a dedicated import commit records the exact crates, features, transitive dependency review, Bazel/Rust integration plan, and platform support matrix.

The feature-linked helper target must still report `connector_ready: false` until verified live authentication, active-stage media, credential drop ordering, cleanup behavior, and the controlled RDP demo proof are complete.

Live target validation on 2026-05-16: `SERVICERADAR_RDP_LIVE_TARGET=192.168.1.45 cargo test --manifest-path rust/rdp-connector-probe/Cargo.toml --locked live_blocking_connect_begin_reaches_tls_upgrade_boundary_when_configured -- --nocapture` passed. This proves the lab target is reachable on RDP and accepts the NLA/CredSSP negotiation path through `ironrdp-blocking::connect_begin` without cleartext password exposure in the initial client bytes. It does not prove TLS certificate validation, CredSSP completion, target authentication, active-stage media, cleanup ordering, or helper readiness.

Lab TLS validation on 2026-05-16: `SERVICERADAR_RDP_LIVE_TARGET=192.168.1.45 SERVICERADAR_RDP_LIVE_TLS_INSECURE_ACCEPT_INVALID_CERTS=1 cargo test --manifest-path rust/rdp-connector-probe/Cargo.toml --locked live_tls_upgrade_reaches_credssp_boundary_when_lab_insecure_is_enabled -- --nocapture` passed. This proves the lab target can complete the RDP TLS upgrade, expose a peer certificate public key for CredSSP binding, and advance IronRDP to the CredSSP state without recorded cleartext password exposure. It intentionally bypasses certificate verification and therefore does not prove production trust, CredSSP completion, authentication, media, cleanup ordering, or helper readiness.

Live target validation was rerun on 2026-05-17 after removing the artificial finalized-session readiness gate. `SERVICERADAR_RDP_LIVE_TARGET=192.168.1.45 cargo test --manifest-path rust/rdp-connector-probe/Cargo.toml --locked live_blocking_connect_begin_reaches_tls_upgrade_boundary_when_configured -- --nocapture` and `SERVICERADAR_RDP_LIVE_TARGET=192.168.1.45 SERVICERADAR_RDP_LIVE_TLS_INSECURE_ACCEPT_INVALID_CERTS=1 cargo test --manifest-path rust/rdp-connector-probe/Cargo.toml --locked live_tls_upgrade_reaches_credssp_boundary_when_lab_insecure_is_enabled -- --nocapture` both passed. This reconfirms live reachability and lab TLS/CredSSP-state entry only; it still does not prove production trust, CredSSP completion, authentication, active-stage media, cleanup ordering, or helper readiness.

Verified live TLS probe path added on 2026-05-16: `SERVICERADAR_RDP_LIVE_TARGET=<target> SERVICERADAR_RDP_LIVE_SERVER_NAME=<certificate-name> SERVICERADAR_RDP_LIVE_CA_BUNDLE_FILE=<ca-bundle.pem> cargo test --manifest-path rust/rdp-connector-probe/Cargo.toml --locked live_verified_tls_upgrade_reaches_credssp_boundary_when_configured -- --nocapture`. This probe skips unless the target and CA bundle file are explicitly provided. It proves the RDP TLS upgrade can use configured target trust and server identity before entering IronRDP's CredSSP state, but it still does not prove CredSSP completion, authentication, active-stage media, cleanup ordering, or helper readiness.

Adapter-level live helper-open probe path added on 2026-05-17: source an ignored `.env` that contains `SERVICERADAR_RDP_ADAPTER_LIVE_TARGET`, `SERVICERADAR_RDP_ADAPTER_LIVE_SERVER_NAME`, `SERVICERADAR_RDP_ADAPTER_LIVE_CA_BUNDLE_FILE`, `SERVICERADAR_RDP_ADAPTER_LIVE_USERNAME`, and `SERVICERADAR_RDP_ADAPTER_LIVE_PASSWORD`, then run `bazel test --config=macos --features=-fully_static_link //rust/rdp-adapter:rdp_adapter_live_connector_probe_test --test_env=SERVICERADAR_RDP_ADAPTER_LIVE_TARGET --test_env=SERVICERADAR_RDP_ADAPTER_LIVE_SERVER_NAME --test_env=SERVICERADAR_RDP_ADAPTER_LIVE_CA_BUNDLE_FILE --test_env=SERVICERADAR_RDP_ADAPTER_LIVE_USERNAME --test_env=SERVICERADAR_RDP_ADAPTER_LIVE_PASSWORD --test_output=streamed`. This probe skips unless target, username, and password are set. It exercises the actual `serviceradar-rdp-adapter` open path and expects a finalized network-pump session. On 2026-05-17 the probe executed against the lab target with target/user/password present but no server-name or CA-bundle env values, and it failed closed at verified TLS with `peer certificate is not trusted by the configured CA roots`. That is the expected production-trust blocker; the helper must not use lab-insecure TLS to become ready.

## Follow-Up Before Import
- Verify the selected IronRDP commit's crate licenses from the upstream checkout, not from Teleport's AGPL workspace.
- Decide whether the production optional IronRDP connector helper uses the review probe's separate Rust workspace/lockfile pattern or a dedicated Bazel crate-universe repository to keep the connector crypto graph isolated from the root ServiceRadar workspace.
- Upgrade to an upstream IronRDP release that feature-gates `sspi/scard`, disable the feature, and prove `winscard`, `iso7816`, `heapless`, and `spin` leave the connector graph; do not solve this with a ServiceRadar-maintained fork or audit ignore.
- Update Bazel/Rust dependency manifests in the same commit that imports the crates.
- Add protocol integration tests against a controlled RDP test server before enabling runtime capability advertisement.
