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
- Decide whether the agent links Rust through cgo/staticlib, a sidecar helper process, or another build boundary.
- Update Bazel/Rust dependency manifests in the same commit that imports the crates.
- Add protocol integration tests against a controlled RDP test server before enabling runtime capability advertisement.
