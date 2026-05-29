# MuonFP TCP Fingerprint Format
**Draft Specification — Version 0.9 (September 24, 2025)**

---

## Status of This Memo
This document defines the **MuonFP TCP Fingerprint (MFP) Format** intended for adoption by firewall vendors, network middleware, and security tooling. It is published as a draft for community review. Implementation is encouraged to validate the format, provide feedback, and contribute additional examples and test vectors.

## Copyright and License
Copyright © 2025 by the MuonFP community.  
This draft is released under the **Creative Commons Attribution 4.0 International (CC BY 4.0)**. Implementations may use, adapt, and redistribute the format and examples with attribution.

## Abstract
The **MuonFP TCP Fingerprint (MFP) Format** encodes salient fields from a TCP handshake into a compact string that is stable for a given TCP/IP stack and scanning tool configuration. It enables early-stage detection and policy enforcement (allow/deny/defer) at L3/L4 by matching fingerprints with exact or wildcard rules. MuonFP focuses on passive observation of the SYN and SYN-ACK packets and expresses the result as **four colon-separated fields**: TCP Window Size, TCP Options (Kind codes in on-wire order), TCP Maximum Segment Size (MSS), and TCP Window Scale.

## Normative and Informative References
- **[R1]** MuonFP GitHub Repository (format overview, examples, implementation notes):  
  <https://github.com/sundruid/muonfp>
- **[R2]** Ken Webster, “There is No Such Thing as a ‘Benign’ Internet Scanner” (motivation, examples, wildcard practice):  
  <https://www.kenwebster.com/index.php/2025/01/29/there-is-no-such-thing-as-a-benign-internet-scanner/>
- **[R3]** ELLIO, “IP Blocking vs TCP Fingerprint Blocking: How to Use and Combine Them” (deployment guidance, L3/L4 positioning):  
  <https://blog.ellio.tech/ip-blocking-vs-tcp-fingerprint-blocking-how-to-use-and-combine-them/>

---

## 1. Terminology and Conventions
The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**, **SHOULD**, **SHOULD NOT**, **RECOMMENDED**, **MAY**, and **OPTIONAL** are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals, as shown here.

This specification uses the term **“fingerprint”** to denote a signature derived from TCP header features. It does **not** uniquely identify a person or device; rather, it characterizes TCP stack and tool behavior.

## 2. Scope
This document specifies the string format, parsing rules, normalization and matching semantics for MuonFP fingerprints. It also defines error handling, interoperability guidance, and conformance requirements for **producers** (sensors) and **consumers** (firewalls, SIEM, SOAR, proxies).

## 3. Data Model
An MFP fingerprint encodes values observed in the initial TCP handshake. Two observation profiles are defined:

- **Client-Initiated (SYN):** values derived from the first SYN packet received by the protected interface.  
- **Server-Initiated (SYN-ACK):** values derived from the first SYN-ACK packet sent by the responder.

Implementations **MAY** support either profile; supporting both is **RECOMMENDED** for bidirectional deployments.

## 4. String Format
The canonical MFP string consists of **four colon-separated fields** (no whitespace):

<win>:<opts>:<mss>:<wscale>


Where:
- `<win>` — TCP Window Size as a decimal integer.  
- `<opts>` — Hyphen-separated list of TCP Option **Kind** codes in the exact on-wire order as received; each element is a decimal integer (e.g., `2-4-8-1-3`).  
- `<mss>` — TCP Maximum Segment Size (MSS) value as a decimal integer.  
- `<wscale>` — TCP Window Scale factor as a decimal integer.

**Empty fields are permitted** and indicate that the corresponding value was **not present on the wire (NULL)**, not zero.

### 4.1. ABNF

The following Augmented Backus–Naur Form (ABNF) defines the syntax using the core rules of RFC 5234:

mfp = win ":" opts ":" mss ":" wscale
win = 1DIGIT / wildcard
opts = (optval "-") optval / empty
optval = 1DIGIT
mss = 1DIGIT / empty / wildcard
wscale = 1*DIGIT / empty / wildcard
empty = ""
wildcard = "%"


The percent sign (`%`) is the **wildcard operator** for a field and matches any value for that field.  
**Example:** `%:::` matches any window size with **no options**, **no MSS**, and **no window scale**.

### 4.2. Examples

- `65535:2-4-8-1-3:1412:8` — A common desktop OS/network stack configuration.  
- `65535:::` — High-speed scanner behavior with only window size present.  
- `62727:2:8961:` — Tool-specific pattern (e.g., Nmap) with absent window scale.  
- `%:::` — Wildcard rule matching any window size with empty options/MSS/scale.

**Notes:** Option Kind codes use their IANA/RFC numeric values (e.g., `2=MSS`, `3=Window Scale`, `4=SACK Permitted`, `1=NOP`, `8=Timestamp`). `NOP` and `EOL` **MAY** appear in the sequence when present on wire and **MUST** be preserved for order fidelity.

## 5. Normalization Rules
Producers **MUST** apply the following normalization before emitting an MFP string:

1) Observe only the **first** packet relevant to the profile (SYN or SYN-ACK) and ignore retransmissions.  
2) Record `<opts>` as the exact **on-wire order** of TCP Option Kind codes; do not sort or deduplicate.  
3) If an element is **absent on wire**, emit an **empty field** between colons.  
4) Do **not** left-pad integers; use base-10 decimal.  
5) Treat **zero values** as literal zeros, not empty fields. Empty means “**not present**.”  
6) If **no TCP options** are present, `<opts>` is empty (e.g., `65535:::`).

## 6. Matching Semantics
Consumers (e.g., firewalls) **MUST** support **exact matching** and **SHOULD** support **wildcard matching** using the field wildcard (`%`). Matching operates **field-by-field**; a wildcard in a field compares as true against any value of that field. Implementations **MAY** support prefix/suffix wildcards for `<opts>` subsequences (e.g., `2-*`); such extensions **MUST NOT** break exact matching behavior.

When `<opts>` matching requires subsequence checks, consumers **SHOULD** implement an **ordered-subsequence** comparison.  
**Example:** The rule `2-4-8` matches any options list that contains `2`, then later `4`, then later `8`, **in that order**, with zero or more elements in between.

## 7. Policy Actions and Use Cases
MFP rules can drive firewall policy at ingress to disrupt reconnaissance and mass-exploitation:

- **Drop/Reject:** Block connections that match scanners (e.g., ZMap, Masscan) or high-speed minimalist stacks (e.g., `%:::`).  
- **Allow/Defer:** Treat unknown or low-risk stacks differently (challenge, tarpitting, rate-limit).  
- **Classify/Tag:** Enrich logs/SIEM with the matched fingerprint for threat hunting and attribution.

Guidance for combining with IP-based controls is provided in §11.

## 8. Error Handling
If a producer cannot determine a field, it **MUST** emit an **empty field** for that position. If a consumer receives an **invalid string** (bad characters, wrong number of fields), it **MUST** treat it as **non-matching** and **SHOULD** log a parse error with context. Consumers **MUST** treat consecutive colons as indicating **empty fields**, not missing separators.

## 9. Versioning and Compatibility
This specification defines the **v1 canonical string**. Future versions **MUST** remain **backward-compatible** for existing four-field records. If extensions are needed (e.g., additional fields), they **MUST** be appended after the fourth field and identified by a **semicolon-prefixed** `key=value` list (e.g., `;dir=S` for SYN, `;dir=SA` for SYN-ACK). Consumers that do not recognize extensions **MUST** ignore them.

## 10. Interoperability Considerations
Reverse proxies and CDNs terminate client TCP connections, so protected origins will observe proxy/provider fingerprints rather than end-client fingerprints. Policy **SHOULD** be applied at the true network edge (before termination) when feasible. For middleboxes, vendors **SHOULD** expose observed MFP values via logs/telemetry so that upstream edge devices can enforce policy.

## 11. Deployment Guidance (Non-Normative)
A layered approach is **RECOMMENDED**:

- Maintain dynamic IP blocklists for known malicious infrastructure (simple and broad control).  
- Add MFP-based rules targeting scanner/tool fingerprints and high-speed minimal stacks to disrupt reconnaissance.  
- Start in **monitor-only** mode to collect baselines; promote high-confidence rules to enforcement.  
- Carefully evaluate shared-IP and NAT environments to avoid collateral blocking.

## 12. Security Considerations
Attackers **MAY** attempt to mimic benign fingerprints. Because option ordering and negotiated values are constrained by implementation, perfect mimicry is difficult but not impossible. Vendors **SHOULD** combine MFP with rate limits, behavioral signals, and reputation. Rules that block `%:::` or similar high-speed scanner signatures should be placed early for maximal effect.

## 13. Privacy Considerations
MFP values describe **protocol behavior**, not user identity. They **SHOULD** be treated as low-sensitivity telemetry. When exported, follow organizational logging policies and applicable regulations.

## 14. Conformance Requirements
Producers **MUST** implement §5 normalization and emit **four colon-separated fields**. Consumers **MUST** implement **exact matching** and **SHOULD** implement **wildcard matching** (§6). Telemetry **SHOULD** export both the matched rule ID and the observed MFP string.

---

## Appendix A — Test Vectors
1) **Desktop OS example:** `65535:2-4-8-1-3:1412:8` → MUST parse as `win=65535`, `opts=[2,4,8,1,3]`, `mss=1412`, `wscale=8`.  
2) **High-speed scanner:** `65535:::` → MUST parse as `win=65535`, `opts=[]`, `mss=NULL`, `wscale=NULL`.  
3) **Nmap-like:** `62727:2:8961:` → MUST parse as `win=62727`, `opts=[2]`, `mss=8961`, `wscale=NULL`.  
4) **Wildcard rule:** `%:::` → MUST match any record whose `opts=[]`, `mss=NULL`, `wscale=NULL`.

## Appendix B — Option Kind Reference (Informative)
Kind `0=EOL`, `1=NOP`, `2=MSS`, `3=Window Scale`, `4=SACK Permitted`, `5=SACK`, `8=Timestamp` (see TCP option RFCs). **Record values exactly as they appear on wire; do not expand sub-option payloads.**

---

## Change Log
- **v0.9 (2025-09-24):** Initial public draft.

## Acknowledgments
This draft reflects insights from the MuonFP project and community research on TCP fingerprinting.
