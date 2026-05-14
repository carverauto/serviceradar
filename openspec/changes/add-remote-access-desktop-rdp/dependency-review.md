# RDP Dependency Review

## Scope
This review records dependency choices for the first desktop/RDP implementation slice before protocol adapter work starts.

## Decisions
- RDP protocol implementation: use upstream Devolutions IronRDP crates directly, pinned before import.
- Initial upstream candidate: `https://github.com/Devolutions/IronRDP` at commit `df0bf9c69d88febaf6b82c479fdc7dcafe226567`.
- Browser renderer: use ServiceRadar-owned Canvas/ImageData rendering that consumes the typed desktop frame contract in `go/pkg/agent/remoteaccess/desktop.go`.
- Do not import Teleport's Go/Rust RDP wrapper, decoder, web package, TDP protocol, or desktop service implementation.
- Do not enable clipboard, drive, printer, audio, smart-card, or file redirection dependencies in the first adapter slice.

## Rationale
Teleport's current desktop/RDP implementation is not suitable for direct import into ServiceRadar:

- `~/src/teleport/Cargo.toml` sets `license = "AGPL-3.0-only"` for the Teleport RDP workspace members.
- Current Teleport files under `lib/srv/desktop/rdp` and `web/packages/shared/libs/ironrdp` include AGPL headers.
- The local license scan for `github.com/gravitational/teleport/lib/srv/desktop`, `github.com/gravitational/teleport/lib/srv/desktop/rdp`, and `github.com/gravitational/teleport/lib/web/desktop` reports AGPL transitive dependency paths.

The upstream IronRDP repository is the cleaner dependency candidate. Its GitHub repository advertises `LICENSE-APACHE` and `LICENSE-MIT`, and the project is a focused Rust RDP implementation rather than Teleport-specific access-plane code.

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

## Follow-Up Before Import
- Verify the selected IronRDP commit's crate licenses from the upstream checkout, not from Teleport's AGPL workspace.
- Decide whether the agent links Rust through cgo/staticlib, a sidecar helper process, or another build boundary.
- Update Bazel/Rust dependency manifests in the same commit that imports the crates.
- Add protocol integration tests against a controlled RDP test server before enabling runtime capability advertisement.
