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

Observed connector crate surface from the pinned IronRDP checkout:

- `ironrdp-connector = 0.8.0` is `MIT OR Apache-2.0`.
- `ironrdp-connector` depends on `sspi = 0.19` with the `scard` feature enabled, `picky = 7.0.0-rc.22`, `picky-asn1-der`, `picky-asn1-x509`, `rand`, `url`, and `tracing`.
- `sspi = 0.19.0` is `MIT OR Apache-2.0`, defaults to `aws-lc-rs`, and its `scard` feature pulls smart-card/PKCS#11 support via `winscard` and `cryptoki`.
- `picky = 7.0.0-rc.22` is `MIT OR Apache-2.0`; its default feature set includes X.509, JOSE, HTTP signature traits, and PKCS#12 support.
- `ironrdp-client` is not an import target for ServiceRadar. It pulls UI/windowing, audio, clipboard, RDPDR, RDPSND, dynamic virtual channel, MSTS Gateway, WebSocket, and Devolutions Gateway transport dependencies that do not belong in the agent helper.

Crates.io import check:

- The published `ironrdp-connector = 0.8.0` is not the same dependency surface as the pinned local IronRDP checkout. It depends on `sspi = 0.18` and `picky = 7.0.0-rc.20`.
- `picky = 7.0.0-rc.20` pins several pre-release crypto crates with exact requirements, including `digest = 0.11.0-rc.3`, `hmac = 0.13.0-rc.2`, and `sha2 = 0.11.0-rc.2`.
- A same-workspace import of the published connector forces the root `Cargo.lock` away from existing stable crypto crate versions. Do not land that import in the shared ServiceRadar Rust workspace.
- Validation on 2026-05-16: adding `ironrdp-connector = 0.8.0` to the real helper feature compiled the RDP adapter tests, but Cargo locked 89 additional packages and downgraded shared workspace crates including `block-buffer`, `crypto-common`, `digest`, `hmac`, `md-5`, `nix`, `postgres-protocol`, and `sha2`. That confirmed the connector import must remain isolated until we have a dedicated helper lockfile or separate Bazel crate-universe repository.
- `rust/rdp-connector-probe` is a review-only isolated Cargo workspace with its own `Cargo.lock`. It proves the connector graph, a ServiceRadar helper-open payload parser, a minimal ServiceRadar-to-IronRDP config mapping, registered endpoint/TLS identity derivation, and the first IronRDP connector state-machine steps can compile without perturbing the root ServiceRadar Rust lockfile. The negotiation smoke tests decode the emitted X.224 request, verify that NLA/CredSSP is advertised without plain TLS fallback, prove HYBRID and HYBRID_EX server confirms reach the TLS upgrade boundary before CredSSP, reject server-selected TLS-only and standard-RDP downgrades, and confirm the pre-TLS X.224 request carries the mstshash username cookie without the cleartext password.
- The isolated probe also links `ironrdp-blocking = 0.8.0` and drives its upstream `connect_begin` wrapper with a scripted server confirm. This proves the production helper should reuse IronRDP's connector loop through the TLS upgrade boundary rather than hand-rolling the connection-initiation sequence.
- The isolated probe directly links `x509-cert = 0.2` and proves ServiceRadar can extract the TLS peer certificate public key bytes needed for IronRDP/CredSSP binding after a verified TLS upgrade. It also proves the `ironrdp-blocking::connect_finalize` boundary enters CredSSP after the TLS upgrade marker, writes the first CredSSP bytes, and does not expose the cleartext password in that first write. TLS verification, completing CredSSP against a controlled server, and the active graphics stage remain production-helper work and must stay behind the isolated dependency boundary.
- The isolated probe now derives an explicit TLS upgrade plan from ServiceRadar target policy. System-root verification is the default for `verify` without a registered CA bundle, `verify` with a bundle and `pinned_ca` use registered CA bundle IDs, and insecure modes or `pinned_ca` without a bundle fail closed before connector finalization.
- The RDP adapter now has a Bazel-only connector-link probe target that compiles adapter source against the isolated `@rdp_connector_crates` universe and directly links `ironrdp-connector`, `ironrdp-blocking`, `ironrdp-pdu`, and `zeroize` without adding connector/CredSSP dependencies to the root ServiceRadar Rust lockfile. It also proves a validated ServiceRadar open payload can map target screen policy, NLA posture, explicit TLS trust source, and domain-qualified memory-user credentials into IronRDP connector config inside that isolated boundary. This is still a compile/link and mapping check only; the runtime helper remains connector-not-ready and fail-closed.
- The production IronRDP helper should use an isolated optional helper dependency graph, for example a separate helper workspace/lockfile or Bazel crate-universe repository, so CredSSP/PKI dependencies cannot perturb SRQL, collectors, or other Rust services.

ServiceRadar connector import requirements:

- Import connector dependencies in a dedicated commit with the exact crate list, versions, features, and license check output.
- Keep connector/CredSSP/PKI dependencies out of the root ServiceRadar Rust lockfile unless the resolver impact is explicitly reviewed across all Rust services.
- Prefer the smallest direct IronRDP crate set required for TCP + TLS + NLA + screen frames. Do not import `ironrdp-client`.
- Disable clipboard, drive, printer, audio, smart-card redirection, file transfer, dynamic virtual channel plugins, and MSTS Gateway/RDCleanPath support until each feature has its own policy and audit implementation.
- Do not enable TOFU or any target-trust mode that requires agent-local persistent state. Target trust must come from the registered target policy, system roots, or an explicit CA bundle/pin managed outside the helper.
- Treat `sspi`/CredSSP and `picky`/PKI as security-sensitive dependencies: run focused dependency review, record crypto provider features, and add an integration test against a controlled RDP server before advertising `remote_access.rdp`.
- Keep the Go agent as the credential, route, policy, audit, and flow-control owner. The Rust connector loop may receive only a session-scoped open payload over local IPC and must drop credential material on any open, auth, TLS, route, or process failure.

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

The feature-linked helper target must still fail closed until the connector loop, TLS verification, NLA/CredSSP handling, credential drop ordering, frame decoding, and controlled RDP test target are implemented.

## Follow-Up Before Import
- Verify the selected IronRDP commit's crate licenses from the upstream checkout, not from Teleport's AGPL workspace.
- Decide whether the production optional IronRDP connector helper uses the review probe's separate Rust workspace/lockfile pattern or a dedicated Bazel crate-universe repository to keep the connector crypto graph isolated from the root ServiceRadar workspace.
- Update Bazel/Rust dependency manifests in the same commit that imports the crates.
- Add protocol integration tests against a controlled RDP test server before enabling runtime capability advertisement.
