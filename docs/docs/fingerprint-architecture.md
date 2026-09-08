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
- MuonFP TCP SYN canonical signatures as a parallel TCP-axis signal.
- JA4 base for TLS ClientHello fingerprints.
- HASSH and HASSH-Server for SSH KEXINIT fingerprints, using Corelight's
  maintained fork of the original Salesforce work.
- Recog banner fingerprints for HTTP, SSH, FTP, Telnet, SMB, SNMP, SIP, RDP,
  and DNS version strings observed by existing dissectors or banner probes.
- Satori XML fingerprints for TCP, DHCP/DHCPv6, DNS, ICMP, NTP, SIP, SMB,
  SSH, SSL/TLS, HTTP server, and HTTP user-agent observations.

The TCP-axis signals are primary because SYN metadata is available for most
managed hosts and can be extracted once per connection. JA4 base, HASSH, Recog,
and Satori are confidence boosters when the same device exposes matching TLS,
SSH, banner, DHCP, DNS, ICMP, NTP, SIP, SMB, or HTTP evidence.

## Data Flow

1. eBPF programs observe TCP connection setup and encode the canonical p0f
   signature string and the MuonFP/Satori TCP fields derived from the same SYN.
2. Netprobe userspace consumes the `p0f_signatures` ring buffer and matches TCP
   signatures with `rust/netprobe/src/p0f_matcher.rs`,
   `rust/netprobe/src/muonfp.rs`, and the Satori TCP matcher.
3. DPI dissectors produce JA4 base, HASSH, Recog, and Satori observations when
   protocol payloads are available under the active
   [visibility profile](./visibility-profiles.md).
4. `rust/netprobe/src/os_matcher.rs` fuses agreeing observations into a
   `LicenseCleanFingerprint` event. Disagreements are preserved as metadata so
   operators can curate new signatures instead of hiding uncertainty.
5. The agent reports all corpus and spec revisions in netprobe status:
   p0f, ServiceRadar p0f additions, JA4 base, MuonFP, Recog, Satori, and
   ServiceRadar Recog additions.

## Coverage Matrix

| Signal | Observation axis | Source | License boundary | Packaging |
| --- | --- | --- | --- | --- |
| p0f | TCP SYN | `p0f.fp` | LGPL-2.1 data file | Compiled matcher; source corpus remains replaceable |
| ServiceRadar p0f additions | TCP SYN | `serviceradar-additions.fp` | CC0-1.0 ServiceRadar data | Compiled matcher; separate from upstream p0f |
| MuonFP | TCP SYN | Format reference, no upstream label corpus | MIT reference encoder; CC BY 4.0 spec text | ServiceRadar-owned matcher rules |
| JA4 base | TLS ClientHello | FoxIO JA4 base spec | BSD-3-Clause JA4 base only | Code only; no JA4+ algorithms |
| HASSH | SSH KEXINIT | Corelight maintained fork | BSD-3-Clause | Code only |
| Recog | Service banners | Rapid7 XML corpus | BSD-2-Clause | Compile-time regex DFA generation |
| ServiceRadar Recog additions | Service banners | `serviceradar-recog-additions.xml` | CC0-1.0 ServiceRadar data | Compile-time regex DFA generation |
| Satori | TCP, DHCP, DNS, ICMP, NTP, SIP, SMB, SSH, SSL/TLS, HTTP | xnih Satori XML | GPLv2 data files only | Runtime-loaded replaceable XML corpus |

The ensemble weights agreement across independent axes more heavily than
multiple signatures from the same axis. A p0f-only match is useful but low
confidence. A device that produces agreeing TCP, HTTP banner, TLS, SSH, and
DHCP evidence reaches the highest confidence tier. Disagreement is emitted as
metadata so operators can curate additions or investigate middleboxes.

## Licensing Boundaries

The upstream `p0f.fp` corpus remains a separate LGPL-2.1 data file under
`third_party/netprobe_corpora/p0f/p0f.fp`. ServiceRadar does not relicense it. Operators
can replace or inspect it independently of the Apache-2.0 ServiceRadar code.

ServiceRadar-owned additions live in
`third_party/netprobe_corpora/p0f/serviceradar-additions.fp` and default to CC0-1.0.
The curation workflow is documented in
`third_party/netprobe_corpora/p0f/CONTRIBUTING.md`.

MuonFP is included as an audited format/reference input. The pinned upstream
tree does not contain a standalone signature corpus, so ServiceRadar does not
ship an upstream MuonFP label database. ServiceRadar-owned MuonFP rules can be
added separately when curated.

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

Recog is included from Rapid7's BSD-2-Clause XML corpus under
`third_party/netprobe_corpora/recog/xml/`. ServiceRadar additions live in
`third_party/netprobe_corpora/recog/serviceradar-recog-additions.xml`, default to
CC0-1.0, and are reviewed with `make lint-recog-additions`.

Satori is included only as GPLv2 XML data under
`third_party/netprobe_corpora/satori/xml/`. The Python runtime, pcap integration, and
SSL / JA4 implementation are not copied. Netprobe runtime-loads the XML files
from a replaceable corpus directory and must not embed them with
`include_str!`, `include_bytes!`, generated Rust constants, or translated code.

## Operational Guardrails

- Do not add `huginn-net`, `ja4t`, `ja4h`, `ja4s`, `ja4ssh`, `ja4x`, or a
  FoxIO-1.1-licensed crate to netprobe.
- Do not edit `third_party/netprobe_corpora/p0f/p0f.fp` for local signatures. Use
  `serviceradar-additions.fp`.
- Do not edit Rapid7 Recog XML files for local signatures. Use
  `serviceradar-recog-additions.xml`.
- Do not edit Satori XML files for ServiceRadar-owned additions. Keep any local
  additions in ServiceRadar-owned files with a separate license.
- Run `make lint-p0f-additions` before merging p0f addition changes.
- Run `make lint-recog-additions` before merging Recog addition changes.
- Run `bash scripts/check-netprobe-fingerprint-licenses.sh` after changing any
  fingerprint corpus or dependency.
- Keep `P0F_CORPUS_REVISION`, `SERVICERADAR_ADDITIONS_REVISION`,
  `JA4_BASE_SPEC_REVISION`, `MUONFP_CORPUS_REVISION`,
  `RECOG_CORPUS_REVISION`, `SATORI_CORPUS_REVISION`, and
  `SERVICERADAR_RECOG_ADDITIONS_REVISION` in
  `rust/netprobe/src/fingerprint.rs` synchronized with corpus and spec changes.
- Use AshPaperTrail-backed [visibility profile](./visibility-profiles.md)
  audit logs for operator changes that enable invasive capture surfaces.
