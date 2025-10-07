# Product Requirements Document (PRD)

**Product**: ServiceRadar Stateful Rules & Correlation
**Doc owner**: Platform / Observability
**Status**: Draft v1
**Last updated**: 2025‑09‑09

---

## 1) Summary

Provide users a first‑class **Rules** feature in ServiceRadar that can:

* Evaluate **stateful** patterns over streaming events (syslog, traps, OTEL, internal events).
* **Enrich** events (via KV, Proton, or external lookups) and **correlate** across sources over time.
* Be **created, enabled, and tuned in the UI** without code, using a **rule library** + **visual builder**.
* Use a typed, maintainable **OCaml core** (ADTs) that compiles rules into an executable plan and integrates with **SRQL** for query‑backed windows/aggregations.
* Emit **CloudEvents** to a dedicated subject for downstream DBs/dashboards/alerts.

**Result**: Users can start with a catalog of rules (e.g., “failed‑login burst”, “missing heartbeat”, “interface flap”); later, users author their own rules via SRQL extensions or a visual builder.

---

## 2) Background & current architecture

* **Stateless stage**: Rust consumer uses **GoRules Zen** for decision tables/expressions; outputs to `events.*.processed`.
* **DB stage**: **Timeplus Proton** for streaming SQL (windows, aggregations, join) and ad‑hoc queries via SRQL translator.
* **Transport/state**: **NATS JetStream** (streams, KV); **KV** stores rule JSON; watchers hot‑reload rules.

Pain points motivating this PRD:

* Need **stateful correlation** (timers, absence of events, sequences) not expressible ergonomically as pure SQL or Zen tables.
* Need **user‑facing rule configuration** (enable/disable, thresholds, keys, windows) with safe typing.
* Want to leverage **SRQL** to avoid duplicating query semantics and to make rules approachable.

---

## 3) Goals & Non‑goals

### Goals

1. **Stateful rule engine** that supports correlation (A→B→C, “unless D”, missing heartbeat), per‑key timers, event‑time, and bounded out‑of‑order handling.
2. **Rule library & UI**: browse/enable built‑ins; parameterize thresholds/windows/keys; dry‑run & preview.
3. **SRQL integration**:

   * Reuse SRQL expressions in `WHERE` conditions and selections.
   * Allow rules to embed SRQL/Proton **subqueries** for heavy windows/joins.
4. **OCaml ADTs**: strong typing for rules, safe compilation to plans, and deterministic runtime behavior.
5. **Operational fit**: keep JetStream + KV + CloudEvents; preserve at‑least‑once semantics with idempotent sinks.

### Non‑goals (v1)

* Full Flink/Siddhi‑level CEP language.
* Arbitrary user‑provided code execution in the data plane.
* UI for authoring arbitrary external connector plugins (we’ll start with a fixed set of enrichers).

---

## 4) Personas & top use cases

* **SecOps / NOC engineer**: enable prebuilt rules, tweak thresholds, receive correlated incidents.
* **SRE / Platform**: author new rules from building blocks, test on historical slices, publish safely.
* **Analyst**: explore correlated outputs in SRQL dashboards.

**Examples**

* *Burst detection*: ≥5 failed root logins on same host in 5 minutes.
* *Missing heartbeat*: emit alert if no health event within 30s.
* *Sequence pattern*: A (login from new geo) → B (S3 access) → C (EC2 spawn) within 10m unless MFA.
* *Interface flap*: link transitions up/down ≥N times in T window.
* *DNS tunneling heuristic*: high unique subdomain cardinality (HLL sketch) per apex domain.

---

## 5) Scope

### MVP (v1)

* Library of \~6 prebuilt rules (parameterizable).
* Rule runtime (OCaml) with:

  * Event‑time, watermark, allowed lateness.
  * Per‑key state, TTL, timers.
  * KV‑backed rule configs; hot‑reload via watcher.
  * Emission to `events.*.correlated` as CloudEvents (idempotent).
* UI: Rule catalog, enable/disable, parameter editing, dry‑run (side‑by‑side preview).
* SRQL integration:

  * Use SRQL expressions in rule filters (`WHERE`), and `GROUP BY`/`BY key`.
  * Allow `USING PROTON ( … SRQL STREAM … )` to delegate heavy windows.

### v2+

* Visual rule builder (pattern canvas).
* External lookup blocks (Kubernetes, LDAP/IdP, Threat Intel).
* Sketches (HLL/Bloom) as built‑in operators.
* Rule versioning & staged rollout (canary).
* Multi‑tenant quotas and concurrency shaping.

---

## 6) User stories (selected)

* **As a NOC engineer**, I can enable “Missing heartbeat in 30s” for a device group and set the window to 45s.
* **As a SecOps analyst**, I can preview “Failed login burst” against the last 1h of data to estimate alert volume before enabling.
* **As a platform engineer**, I can create a new rule that uses SRQL to fetch “count of failed logins per host in 10m” and trigger at ≥20.

---

## 7) UX outline

1. **Rules Catalog**

   * Cards: name, description, defaults, last change, on/off toggle.
   * “Customize” → parameter panel (threshold, window, keys, lateness, subject filters).
   * “Preview” → run in **dry‑run mode** on live tail or historical slice (read‑only) and show hypothetical emissions.

2. **Rule Instance**

   * YAML/JSON view of parameters (with schema).
   * SRQL snippet embedded (read‑only or editable in v2).
   * Metrics: matches/sec, emits/sec, late events, timer backlog.
   * Version & change log.

3. **Builder (v2)**

   * Visual A→B→C with per‑edge time constraints; add “unless D”; add enrichers; add SRQL subquery node.

---

## 8) Functional requirements

* **FR1**: Subscribe to one or more NATS subjects (default: `events.*.processed`).
* **FR2**: Parse inputs as JSON (OTEL protobuf supported earlier in pipeline).
* **FR3**: Evaluate rules with **event‑time** semantics, **watermark**, **lateness allowance** (configurable per rule).
* **FR4**: Maintain **per‑key state** (tenant, subject, correlation key).
* **FR5**: Support **timers** and **absence** patterns.
* **FR6**: Call **Proton** via SRQL for heavy windows/joins; cache short‑lived results.
* **FR7**: Emit **CloudEvents** to `events.<source>.correlated` (configurable suffix).
* **FR8**: **Hot‑reload** rules from KV; **enable/disable** toggles in UI reflected in KV.
* **FR9**: **Dry‑run** mode (no side effects; labeled emissions to a preview subject).
* **FR10**: **Idempotency**: deterministic `id` to avoid duplicates on replays.
* **FR11**: Rule **validation**: schema + semantic checks (keys present, windows sane).
* **FR12**: **Metrics** & **health** endpoints; structured logs.

---

## 9) Non‑functional requirements

* **Throughput**: Target ≥ 15k events/sec per pod (baseline; horizontally scalable).
* **Latency**: p95 decision < 50ms for in‑memory state; < 250ms with Proton calls.
* **Footprint**: < 1 GiB RSS per 50k tracked keys (with in‑mem store), tunable TTLs.
* **Availability**: stateless workers with rebuildable state from replay; HA via JetStream.
* **Security**: mTLS to NATS; signed rule bundles (v2); RBAC on rule edits.
* **Auditability**: rule version, author, timestamp in emitted events.

---

## 10) System design & integration

### 10.1 Data flow

```
Producers → JetStream (events.*)
  → Zen consumer → events.*.processed (CloudEvents JSON)
    → OCaml correlator → events.*.correlated (CloudEvents JSON)
                       → (optional) notifications/webhooks
                       → Proton (ingest / materialized views)
```

### 10.2 NATS subjects & KV layout

* **Input**: `events.syslog.processed`, `events.snmp.processed`, `events.otel.logs.processed`, …
* **Output**: `events.<subject>.correlated` (configurable suffix).
* **Dead‑letter**: `events.deadletter`.
* **KV (rules & metadata)**:

  ```
  agents/<agent_id>/<stream>/correlator/<subject>/<rule_key>.json
  agents/<agent_id>/<stream>/correlator/_catalog/<rule_key>.meta.json
  agents/<agent_id>/<stream>/correlator/_instances/<instance_id>.json
  ```

  * `meta.json` holds schema, defaults, UI help.
  * `instance` stores user parameters, enabled flag, version, scope (subjects, tenant filters).

### 10.3 CloudEvents envelope (output)

* `id`: deterministic hash of (rule\_id, rule\_version, key, window\_end/time\_bucket).
* `source`: `nats://<stream>/<subject>`
* `type`: e.g., `sr.rule.brute_force.v1`
* `data`: rule‑specific payload + `rule_id`, `rule_version`, `correlation_key`, `window`, `inputs` (optional reference).

### 10.4 Reliability

* Use JetStream `Ack/Nak/Term`.
* Non‑retryable parsing → `Term` + dead‑letter.
* Retryable transient errors (e.g., Proton) → `Nak` with backoff; cap retries.

---

## 11) SRQL integration (syntax & semantics)

### 11.1 SRQL extensions (MVP, text form)

Add **RULE** statements alongside existing `SHOW/FIND/COUNT/STREAM`.

**Create rule**

```
CREATE RULE brute_force_login
ON events
MATCH WHERE event_type = 'ssh_login' AND outcome = 'failure'
BY host
USING PROTON (
  STREAM COUNT(*) AS failures
  FROM events
  WHERE event_type = 'ssh_login' AND outcome = 'failure' AND host = $.host
  GROUP BY TUMBLE(event_time, 5m), host
)
WHEN failures >= 5
EMIT TYPE 'sr.rule.brute_force.v1' SET severity = 'High';
```

**Purely stateful (no Proton)**

```
CREATE RULE heartbeat_missing_30s
ON events
MATCH WHERE event = 'heartbeat'
BY host
WINDOW 30s ALLOW_LATE 5s
ON ABSENCE EMIT TYPE 'sr.rule.heartbeat_missing.v1' SET expected_by = now() + 30s;
```

**Sequence**

```
CREATE RULE lateral_move
ON events
BY user
SEQUENCE
  A: logs WHERE action = 'login' AND geo_new = true
  THEN WITHIN 10m
  B: cloudtrail WHERE action = 's3:GetObject' AND first_access = true
  THEN WITHIN 2m
  C: cloudtrail WHERE action = 'ec2:RunInstances'
UNLESS
  D: idp WHERE action = 'mfa_challenge'
EMIT TYPE 'sr.rule.lateral_move.v1' SET risk = 'High';
```

**Notes**

* `MATCH WHERE` uses **SRQL expressions** (reusing your parser).
* `BY` defines correlation key(s) (e.g., `host`, `user`, `device_id`).
* `WINDOW` + `ALLOW_LATE` define timers/watermarks for absence patterns.
* `USING PROTON (…)` embeds a SRQL **STREAM** subquery suitable for offloading heavy windows (engine decides local vs Proton).
* `EMIT` declares CloudEvent type and optional field assignments.

### 11.2 Parser & translator

* Extend SRQL grammar (OCaml version) with `CREATE RULE`, `BY`, `WINDOW`, `SEQUENCE`, `UNLESS`, `USING PROTON (…)`, `EMIT`.
* Reuse existing SRQL **expression AST** for `WHERE` and for SRQL subqueries.

---

## 12) OCaml data model (ADTs) & runtime

### 12.1 Core ADTs (simplified)

```ocaml
type duration = Seconds of int | Minutes of int

type value =
  | str of string | i64 of int | f64 of float | b of bool
  | json of Yojson.Safe.t

type field = string  (* SRQL-resolved field, e.g. "host" or "service.name" *)

type predicate =
  | Expr of Srql_ast.expr   (* Reuse SRQL AST for WHERE *)

type key = string list      (* ["tenant"; "host"] *)

type window = {
  size : duration option;        (* for absence/time-bounded patterns *)
  allow_late : duration option;  (* watermark lateness *)
}

type source =
  | Subject of string           (* e.g., "events.syslog.processed" *)
  | Any_of of string list

type proton_stream =
  { srql : Srql_ast.query;      (* embedded SRQL STREAM query *)
    cache_ttl_s : int option }

type pattern_step =
  | Event of { name : string; src : source; where_ : predicate option }
  | Absence of { name : string; src : source; where_ : predicate option; within : duration }

type sequence =
  { steps : pattern_step list; bounds : (string * duration) list (* between steps *) ;
    unless : pattern_step list }

type condition =
  | Threshold of { left: [`LocalCount of field | `Proton of proton_stream]; op: [`Ge|`Gt|`Eq]; right: int }
  | Custom of predicate

type emit =
  { event_type : string; set : (string * value) list }

type rule =
  { id : string;
    by : key;
    match_ : predicate option;         (* simple non-sequence rule filter *)
    window : window;
    seq : sequence option;             (* for ordered patterns *)
    when_ : condition option;
    emit : emit }
```

### 12.2 Runtime interfaces

```ocaml
module type STATE = sig
  val get    : key:string -> string -> Yojson.Safe.t option
  val put    : key:string -> string -> Yojson.Safe.t -> ttl_s:int option -> unit
  val delete : key:string -> string -> unit
end

module type TIMERS = sig
  val set    : key:string -> name:string -> at:float -> unit
  val cancel : key:string -> name:string -> unit
end

module type SINK = sig
  val emit_cloudevent : typ:string -> data:Yojson.Safe.t -> id:string -> unit
end

module type PROTON = sig
  val run_stream : Srql_ast.query -> Yojson.Safe.t Lwt.t
end

module Engine : sig
  val eval_event : now:float -> rule:rule -> event:Yojson.Safe.t -> unit Lwt.t
  val on_timer   : now:float -> rule:rule -> key:string -> name:string -> unit Lwt.t
end
```

* **Deterministic CE `id`**: `sha1(rule_id, rule_version, key, window_bucket, payload_fingerprint)`.
* **Watermarks**: track `max_event_time` per subject; hold late buffer up to `allow_late`.

---

## 13) APIs (control plane)

* **gRPC/HTTP** (read‑only in MVP; write in v2):

  * `GET /rules` catalog & instances (merged view).
  * `POST /rules/{id}/preview` with filters/time‑slice → preview stream subject.
  * `POST /rules/{id}/enable|disable`.
* **NATS control subjects** (internal):

  * `rules.reload` (force reload), `rules.preview.start/stop`.

---

## 14) Telemetry & ops

* **Metrics**: events/sec in/out, eval latency p50/p95, timer queue depth, late event count, Proton call latency, cache hit rate, state size per keyspace.
* **Health**: `/healthz`, `/readyz`, gRPC health (already used in your agents).
* **Logs**: structured with rule\_id, key, subject, decision\_path.
* **DLQ**: `events.deadletter` for unparseable / permanently failing events.

---

## 15) Security & RBAC

* mTLS to NATS; TLS for control plane.
* UI permissions: View, Enable/Disable, Edit, Publish, Preview.
* Audit trail: who changed what & when (persist to Proton).

---

## 16) Performance targets (initial)

* **MVP** baseline single worker:

  * 10–20k EPS; p95 < 50ms for in‑mem rules; p95 < 250ms with Proton calls (low % of traffic).
* **Scale‑out** linearly with partitions (subject sharding by key hash).

---

## 17) Rollout plan & milestones

**M1 — Foundations**

* OCaml runtime skeleton (STATE/TIMERS/SINK adapters).
* JetStream consumer (via sidecar or direct) + KV watcher.
* CloudEvents emitter; metrics/health.
* Implement 2 rules: “missing heartbeat” + “failed login burst (Proton)”.
* UI: Catalog list, enable toggle, parameter form (static schema).

**M2 — Usability**

* Dry‑run & preview subject; rule validation; error surfaces.
* More rules: interface flap, sequence (A→B→C unless D).
* SRQL embedding (`USING PROTON`) in rules.

**M3 — Authoring**

* SRQL **CREATE RULE** syntax end‑to‑end (parse → ADT → runtime).
* Rule versioning + change log; canary flag.
* (Optional) External lookup block (1 provider).

---

## 18) Acceptance criteria (MVP)

* Enable/disable rules from UI persists to KV and takes effect within ≤ 5s.
* “Missing heartbeat 30s” emits an event within ≤ 35s of last heartbeat.
* “Failed login burst (5 in 5m)” emits within ≤ 2s of breach.
* Dry‑run shows preview emissions on test slice with no writes to main sinks.
* Runtime survives JetStream reconnects; resumes from last acked position.
* Unit/integration tests cover: timers, lateness, idempotent emissions, Proton delegation, KV reload.

---

## 19) Risks & mitigations

* **JetStream client maturity in OCaml**: start with a small **Rust sidecar** that re‑publishes to core subjects and/or exposes a simple gRPC to the OCaml runtime; swap out later.
* **State growth**: per‑key TTLs; eviction metrics & alerts; optional RocksDB/LMDB backend.
* **Rule complexity creep**: keep MVP DSL compact; delegate heavy windows to Proton.

---

## 20) Open questions

1. Which initial subjects should the correlator subscribe to by default (only `.processed` or also raw `events.*`)?
2. Tenant scoping: config per agent vs. global catalog—do we need per‑tenant overrides in MVP?
3. External enrichers priority: which single provider (K8s, IdP, TI) should be first in v2?
4. Do we require **exactly‑once sinks** for any downstreams, or is idempotent CE consumption sufficient?

---

## 21) Appendix: Example rule instance (KV)

```json
{
  "rule_id": "heartbeat_missing_30s@v1",
  "enabled": true,
  "subjects": ["events.heartbeat.processed"],
  "by": ["tenant", "host"],
  "window": { "size": "30s", "allow_late": "5s" },
  "match": { "where": "event = 'heartbeat'" },        // SRQL expression
  "emit": {
    "type": "sr.rule.heartbeat_missing.v1",
    "set": { "severity": "High" }
  }
}
```