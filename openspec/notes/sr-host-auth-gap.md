# ServiceRadar — Host / Fleet Authentication Ingest Gap

> **Status:** deferred / separate track. Split out of the causal-security-engine design
> ([`sr-causal-engine.md`](./sr-causal-engine.md)) so it can be scoped and scheduled on its own.
> **One-line:** ServiceRadar has authentication data only for its *own web console*, not for the
> *monitored fleet* — so identity-driven detections (lateral movement, credential attacks) are blind.

---

## 1. The gap

The causal-security-engine treats **Identity/auth** as one of its cross-domain signal sources
([`sr-causal-engine.md`](./sr-causal-engine.md) §2). Verification against the repo found the substrate
is **console-only**:

| Table | What it actually covers |
|---|---|
| `user_auth_events` | logins to the **ServiceRadar web console** (`ng_users`) |
| `security_events` | ServiceRadar app security events (console/API) |
| `auth_lockouts` | lockout state for **console** accounts |

All three are scoped to ServiceRadar's own operator accounts. **There is no ingest of authentication
from the monitored fleet** — no SSH, RDP, Windows logon, sudo/PAM, RADIUS/TACACS, or directory auth
from the hosts ServiceRadar watches. The `Auth` Observation domain therefore has **no fleet data
today**.

> This is distinct from — and narrower than — the identity↔asset↔flow bridge (the engine's Gap #1).
> That bridge is about *which identity can reach which asset*; this gap is the more basic *"we don't
> even see host logins."* Closing host-auth is a prerequisite for a useful identity bridge.

---

## 2. Impact on the causal engine

Two security causaloids depend on host auth and are blocked:

- **S3 — Lateral movement** (`auth(host) ∧ flow(new internal SMB/RDP) ∧ topology(segment-cross) ∧ vuln`).
  Without host logon events, S3 cannot see the "successful login on host B from host A" leg — the
  defining signal of lateral movement. Marked ⚠️ in §6.
- **S7 — Credential attack** (`auth(host brute/lockout) ∧ flow ∧ time(off-hours)`). With only console
  auth, S7 would fire on failed *ServiceRadar-console* logins, not SSH/RDP/Windows brute force against
  monitored hosts. **Demoted from ✅ to ⚠️** during review for exactly this reason.

More broadly, the "identity" leg of the cross-domain kill chain (§0) has no fleet substrate, so any
kill-chain reasoning that should escalate on *credential access → lateral* stalls at the network tier.

---

## 3. What it takes to close it

The good news: **no `ocsf_events` schema change is needed.** Host auth is a standard OCSF class, so
closing the gap is a **collector + OCSF-mapping** effort that lands in the same `ocsf_events` store as
the existing Falco (`falco_events.ex`) and PowerDNS (`power_dns.ex`) promotions — an addon-gated
domain, exactly like DNS and Host/runtime.

**Target model:** OCSF **Authentication** — `class_uid 3002` (category 3, IAM). Key fields to populate:
`activity_id` (Logon/Logoff/…), `auth_protocol` (ssh/kerberos/ntlm/radius/…), `user`, `src_endpoint` /
`dst_endpoint`, `status` (success/failure), `is_remote`, `logon_type`, `session`, timestamps.

**Sources → mapping (per platform):**

| Source | Where it comes from | Notes |
|---|---|---|
| Linux SSH / PAM / sudo | `/var/log/auth.log`, journald → syslog | route through the existing syslog path (`log-collector` / `flowgger`), then normalize to 3002 |
| Windows logon | Security event log (4624 success / 4625 failure / 4768 TGT / 4776 NTLM) | needs a Windows event forwarder → syslog/OTLP |
| RADIUS / TACACS | AAA server accounting/auth logs | for network-device and VPN auth |
| Directory (LDAP/AD, IdP) | directory/SSO logs | optional; richer identity context |

**Pipeline shape (mirrors DNS/Falco):**
1. A **collector/forwarder** ships raw host-auth logs onto a JetStream subject (e.g. under the existing
   `logs.syslog.>` path, or a dedicated `logs.auth.>`).
2. A **normalizer** (a new `event_writer` processor, sibling of `falco_events.ex` / `power_dns.ex`)
   maps them to OCSF `class_uid 3002` and writes `ocsf_events` — **ingestion only, no DDL**, per the
   repo's schema rule.
3. SRQL exposes an `auth_activity` (class 3002) entity, exactly as `dns_activity` (4003) /
   `scan_activity` (6007) are exposed as views over `ocsf_events`.

---

## 4. How it re-enters the engine

Once class-3002 rows flow:
- **L1** gains a real `Auth` Observation domain (needs the same central per-domain confidence
  construction as the other non-metric domains — see `sr-causal-engine.md` §7 #3: the edge does not
  produce this; L1 constructs the `Uncertain` from the auth signal).
- **S3 and S7 upgrade ⚠️ → ✅.**
- **Context** gains identity `Datoid`s (who authenticated where, privilege), which is the substrate the
  identity↔asset bridge (Gap #1) builds on — so this gap should land **before or with** Phase 2.

---

## 5. Sequencing

Deferred by decision (2026-07). When picked up:
- It is an **ingestion/collector** track (L1), independent of the reasoning-engine crates — can proceed
  in parallel with engine V1 (which ships S1/S2/S4/S5/S6 without host auth).
- Coordinate with `add-causal-engine` Phase 2 (Gap A, identity/service substrate) and with the
  per-domain confidence-construction work, since the `Auth` domain needs both to be useful.
- Likely its own OpenSpec change (new collector + OCSF-3002 normalizer + SRQL `auth_activity` entity).

---

## References
- [`sr-causal-engine.md`](./sr-causal-engine.md) §2 (Identity/auth row), §6 (S3, S7), §7 (gaps).
- Existing OCSF promotion pattern: `event_writer/processors/falco_events.ex`, `power_dns.ex`.
- OCSF Authentication class: `class_uid 3002` (category 3, IAM).
