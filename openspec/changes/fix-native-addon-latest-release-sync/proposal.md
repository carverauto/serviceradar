# Change: Make native add-on catalog sync converge on the latest trusted release

## Why

The unattended native add-on synchronizer scans many historical release indexes
and retries every `(add-on, version)` pair on every run. In demo this produces 17
failures every 30 minutes after a successful v1.4.23 deployment: occupied legacy
versions are repeatedly compared with different historical OCI envelopes, while
the packages operators actually need are buried in the noise. A sync explicitly
scoped to v1.4.23 converges seven of eight packages; anomaly remains correctly
blocked because two different signed bundle digests were published as version
0.3.0.

## What Changes

- Make unattended native add-on and Wasm plugin sync use the exact deployed
  `SERVICERADAR_RELEASE_VERSION` tag as the authoritative release set. The
  recent-release feed remains a compatibility fallback only when no deployed
  release tag is available; delayed feed indexing can no longer make a v1.4.24
  deployment repeatedly import v1.4.23.
- Keep immutable source conflicts fail-closed. Signed first-party provenance is
  necessary but does not authorize replacing different bytes under the same
  semantic version.
- Publish the changed anomaly payload as 0.3.1 so it can coexist with the
  already-audited 0.3.0 package and converge normally.
- Reapply the configured first-party auto-approval policy after a verified
  package repair or when sync finds an allowlisted package left staged by an
  earlier interrupted repair. Explicit denial and revocation remain fail-closed.
- Cover every signed first-party native add-on shipped in demo with the demo
  deployment's explicit auto-approval allowlist.
- Add regression coverage for newest-release selection, explicit historical
  imports, and immutable version collisions.

## Impact

- Affected specs: `agent-feature-sets`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng/plugins/native_addon_sync.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/plugins/native_addon_sync_worker.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/plugins/first_party_sync_worker.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/plugins/packages.ex`
  - `elixir/web-ng/test/app_domain/plugins/native_addon_sync_test.exs`
  - `addons/anomaly-addon/addon.yaml`
  - `rust/anomaly-addon/Cargo.toml`
  - Rust vendor metadata required by the native add-on release gate
- Tracking issue: Forgejo #4558
