---
sidebar_position: 18
title: Fingerprint Architecture
---

# Fingerprint Architecture

ServiceRadar netprobe uses a license-clean passive fingerprint stack. The goal
is to identify likely OS, device, and protocol families from traffic already
crossing the agent host without active probes and without shipping
commercially-restricted fingerprint algorithms.

## Signal Stack

The current stack is:

- p0f canonical TCP SYN signatures, encoded in the eBPF path and matched in
  userspace against the bundled p0f corpus.
- ServiceRadar p0f additions for signatures we curate from legacy gear and
  field observations.
- JA4 base for TLS ClientHello fingerprints.
- HASSH and HASSH-Server for SSH KEXINIT fingerprints, using Corelight's
  maintained fork of the original Salesforce work.

The p0f signal is primary because TCP SYN metadata is available for most
managed hosts and can be extracted once per connection. JA4 base and HASSH are
confidence boosters when the same flow exposes TLS or SSH evidence.

## Data Flow

1. eBPF programs observe TCP connection setup and encode the canonical p0f
   signature string.
2. Netprobe userspace consumes the `p0f_signatures` ring buffer and matches the
   signature with `rust/netprobe/src/p0f_matcher.rs`.
3. DPI dissectors produce JA4 base and HASSH observations when protocol payloads
   are available under the active visibility profile.
4. `rust/netprobe/src/os_matcher.rs` fuses agreeing observations into a
   `LicenseCleanFingerprint` event. Disagreements are preserved as metadata so
   operators can curate new signatures instead of hiding uncertainty.
5. The agent reports the p0f corpus revision, ServiceRadar additions revision,
   and JA4 base revision in netprobe status.

## Licensing Boundaries

The upstream `p0f.fp` corpus remains a separate LGPL-2.1 data file under
`rust/netprobe/p0f-corpus/p0f.fp`. ServiceRadar does not relicense it. Operators
can replace or inspect it independently of the Apache-2.0 ServiceRadar code.

ServiceRadar-owned additions live in
`rust/netprobe/p0f-corpus/serviceradar-additions.fp` and default to CC0-1.0.
The curation workflow is documented in
`rust/netprobe/p0f-corpus/CONTRIBUTING.md`.

JA4 base is included because FoxIO publishes a separate BSD-3-Clause license
for the TLS ClientHello algorithm at
`https://github.com/FoxIO-LLC/ja4/blob/main/LICENSE-JA4`. The broader JA4+
license at `https://github.com/FoxIO-LLC/ja4/blob/main/LICENSE` covers
JA4T, JA4H, JA4S, JA4SSH, JA4X, and related algorithms under terms that do not
fit ServiceRadar's commercial redistribution model. Netprobe therefore does
not implement those algorithms.

HASSH is included from Corelight's maintained BSD-3-Clause fork:
`https://github.com/corelight/hassh`. The original Salesforce notice is
preserved in `rust/netprobe/LICENSE-HASSH`.

## Operational Guardrails

- Do not add `huginn-net`, `ja4t`, `ja4h`, `ja4s`, `ja4ssh`, `ja4x`, or a
  FoxIO-1.1-licensed crate to netprobe.
- Do not edit `rust/netprobe/p0f-corpus/p0f.fp` for local signatures. Use
  `serviceradar-additions.fp`.
- Run `make lint-p0f-additions` before merging p0f addition changes.
- Keep `P0F_CORPUS_REVISION`, `SERVICERADAR_ADDITIONS_REVISION`, and
  `JA4_BASE_SPEC_REVISION` in `rust/netprobe/src/fingerprint.rs` synchronized
  with corpus and spec changes.
- Use AshPaperTrail-backed visibility profile audit logs for operator changes
  that enable invasive capture surfaces.
