# Change: Verify first-party plugin and add-on imports without the public Sigstore services

## Why

`ServiceRadarWebNG.Plugins.CosignVerifier` ran `cosign verify --key <release key>` and then
required the output to say the transparency log was checked. A first-party signature in the
registry holds the signature only, with no embedded log proof, so that check is an online
lookup at the public Sigstore services.

An installation that cannot reach those services imports nothing. The lookup does not fail, it
waits: one verification held the import job for minutes, the job then recorded every package of
the release as "import was rejected", and no newer plugin or native add-on version reached the
catalog. Installations without internet access are the common case, not the exception.

## What Changes

- First-party OCI artifacts (Wasm plugins and native add-on bundles) are verified against the
  configured release public key only. The transparency log is not consulted.
- Cosign runs with a bounded timeout, so an unreachable registry ends in an error.
- The publishing side is unchanged: release signing still uploads a transparency-log entry, and
  the repository verification workflow in `wasm-plugin-builds` still checks it.

The trust decision this leaves in place: a package is accepted when it is signed by the release
key, its upload signature verifies, and its digests match. A public record that the signature
was logged is no longer required at import time.

## Impact

- Affected specs: `wasm-plugin-system`
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng/plugins/cosign_verifier.ex`
- Affected docs: `docs/docs/wasm-plugins.md`, `docs/docs/native-addons.md`, `docs/docs/ansible.md`
