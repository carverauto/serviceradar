## Context

napalm-logs splits each syslog line into a prefix (time, host, process, tag)
and a message body, then maps captured fields onto an OpenConfig or IETF
tree. The snapshot at `1f7b06f808156812bab07d1c622fa1d0ba91f2d5` has ten
platforms and 109 message stanzas:

| Platform | Profile files | Message stanzas |
| --- | ---: | ---: |
| eos | 16 | 17 |
| fortinet | 3 | 2 |
| huawei | 3 | 2 |
| ios | 6 | 6 |
| iosxr | 8 | 8 |
| junos | 40 | 52 |
| netiron | 6 | 8 |
| nxos | 5 | 6 |
| opengear | 6 | 5 |
| sonic | 4 | 3 |

Fifty-seven distinct event names are shared across platforms (`INTERFACE_DOWN`
appears eleven times). Models in use are `openconfig-interfaces`,
`openconfig-bgp`, `openconfig-ospf`, `openconfig-isis`, `ietf-alarm`,
`ietf-hardware`, `openconfig-system`, `openconfig-network-instance`,
`openconfig-lacp`, `openconfig-bfd`, and `NO_MODEL`. One NX-OS file,
`USER_LOGIN.py`, is Python; every other profile is YAML. Transforms used in
the YAML are `upper`, `int`, `str`, `bgp_state_convert`, `bfd_state_convert`,
and `color_to_severity`. Matching is case-insensitive, and a single space in
a `line` template matches a run of whitespace.

ServiceRadar already parses the syslog header in Flowgger (`auto`, RFC 3164,
RFC 5424, ClearPass) and publishes a GELF-shaped JSON record (`host`,
`short_message`, `application_name`, `process_id`, `level`, `full_message`).
Zen rules on subject `logs.syslog` then run in order: `passthrough` (100),
`coraza_waf` (105), `strip_full_message` (110), `syslog_severity` (115),
`cef_severity` (120). `rust/zen-normalize` is the only engine. The core NIF
calls `RuleSet`, and the log collector does too. `RuleSet::compile` still
builds that engine with `NoopCustomNode`.

Solution Packs (`pack_format_version: 1`) already install rules with a `kind`
of `stateful_alert_rule`, `event_rule`, or `zen_rule`. A `zen_rule` carries
`subject`, `template`, `builder_config`, and a compiled `jdm_definition`, and
the reconciler stamps pack provenance on the `ZenRule` row. No built-in pack
ships a `zen_rule` today. `ZenRuleTemplates.compile/2` loads a static JSON
file and ignores `builder_config`.

Collectors do not read the catalog database. They apply the rule bundle core
publishes at `zen/rulesets/events/logs.syslog.json`. A profile that exists
only as a catalog row would normalize in one process and not the other.

The active change `improve-syslog-ingestion-fidelity` keeps unrecognized
bodies and records `source_ip`. Vendor field extraction is the step after
that.

## Goals / Non-Goals

- Goals:
  - Turn every napalm-logs message profile in that snapshot into a profile
    ServiceRadar can execute.
  - Give each platform its own installable Solution Pack.
  - Run the matcher in the collector and in core from one implementation.
  - Keep the raw log, and add attributes operators can filter on.
  - Match the napalm-logs corpus for event name, OS, and mapped fields.
- Non-Goals:
  - A new pack resource kind, or a general plugin type system beyond the
    Zen template this change adds.
  - Hand-authored JDM graphs, one per message.
  - Replacing Flowgger's header parser, or re-parsing RFC 3164/5424 on the
    hot path when the collector already split the line.
  - napalm-logs listeners, publishers, buffers, Prometheus state gauges, or
    the Salt and StackStorm clients.
  - Promoting a matched syslog line to an OCSF event. Promotion stays on the
    existing log-to-event rules.
  - A visual editor for profiles. The catalog shows the pack; the Zen editor
    shows the compiled rule.
  - SNMP trap profiles. `logs.snmp` already has its own severity rule.

## Decisions

### Decision: Profiles are data. One Zen custom node executes them.

Each platform pack installs one `zen_rule`:

- `kind`: `zen_rule`
- `name`: `syslog_profile_<os>` (for example `syslog_profile_junos`)
- `subject`: `logs.syslog`
- `stream_name`: `events`
- `format`: `json`
- `template`: `syslog_profile`
- `order`: `112` (after `strip_full_message`, before `syslog_severity`)
- `builder_config`: the profile document below

`ZenRuleTemplates.compile/2` grows a branch for `syslog_profile`. That branch
reads `builder_config` and emits a JDM graph with a single custom node named
`syslog_profile` whose configuration is the profile document. The compiled
JDM is what the rule bundle carries, so a collector can apply it with no
catalog lookup.

`RuleSet::compile` registers a custom-node handler in `serviceradar-zen-normalize`.
The handler implements `syslog_profile` and leaves every other custom node
as a no-op, which is what `NoopCustomNode` does today. The Elixir NIF does
not grow a second engine.

Alternative considered: compile each message into Zen expression nodes.
`compile/2` ignores `builder_config` today, the expression language has no
capture-group replacement, and 109 templates would be unreviewable graphs.
Alternative considered: a new pack resource kind `syslog_profile` with its
own table. The `zen_rule` row, provenance columns, bundle publisher, and
collector fetch path already exist. A second kind would duplicate them and
still have to be stuffed into the bundle before a collector could run it.

### Decision: Where the files live

| Artifact | Path |
| --- | --- |
| Matcher | `rust/zen-normalize` custom node, used by `RuleSet::compile` |
| Template compiler | `ZenRuleTemplates.compile/2` when `template == "syslog_profile"` |
| Pack validation | `pack_manifest.ex` and `js/cli/src/pack/validate.ts`, only when the rule template is `syslog_profile` |
| Built-in packs | `elixir/serviceradar_core/priv/solution_packs/syslog-<os>/` |
| Generator | `tools/syslog_profiles/`, run when refreshing from napalm-logs. Output is committed. Runtime does not depend on napalm-logs. |
| Corpus fixtures | copied or generated beside the Rust tests from `tests/config/**/syslog.msg` and `yang.json` |

Pack ids follow the existing reverse-DNS form, for example
`io.serviceradar.syslog-junos`, slug `syslog-junos`, version `0.1.0`.
Each pack README names napalm-logs, the Apache-2.0 license, and commit
`1f7b06f808156812bab07d1c622fa1d0ba91f2d5`.

The packs are built-in catalog entries, same as `proxmox-monitoring`. They
are not seeded into every tenant. A tenant that has installed none of them
sees today's syslog behavior. Installing a pack creates the managed Zen rule,
which the existing reconciler publishes onto the bundle.

### Decision: Profile document

`builder_config` is a JSON object:

```json
{
  "schema": "serviceradar.syslog.profile.v1",
  "os": "junos",
  "prefixes": [],
  "messages": [
    {
      "event": "INTERFACE_DOWN",
      "tag": "SNMP_TRAP_LINK_DOWN",
      "match_on": "tag",
      "line": "ifIndex {snmpID}, ifAdminStatus {adminStatusString}({adminStatusValue}), ifOperStatus {operStatusString}({operStatusValue}), ifName {interface}",
      "values": {
        "snmpID": { "pattern": "(\\\\d+)" },
        "adminStatusString": { "pattern": "(\\\\w+)", "transform": "upper" },
        "interface": { "pattern": "([\\\\w\\\\-\\\\/\\\\:]+)" }
      },
      "attributes": {
        "network.interface.name": "{interface}",
        "network.interface.admin_status": "{adminStatusString}",
        "network.interface.oper_status": "{operStatusString}"
      },
      "yang_model": "openconfig-interfaces",
      "yang": {
        "variables": {
          "interfaces/interface/{interface}/state/admin_status": "adminStatusString",
          "interfaces/interface/{interface}/state/oper_status": "operStatusString"
        },
        "static": {}
      }
    }
  ]
}
```

`prefixes` keep the napalm-logs prefix list for raw lines. `match_on`
defaults to `tag`. `values` patterns are the napalm capture groups.
`transform` is optional and one of the closed set below. `attributes` is the
ServiceRadar projection. `yang` preserves the napalm mapping with `/`
separators so the corpus can be compared. Static yang values are constants,
including the literal `DOWN` / `UP` some IOS templates set without a capture.

The generator emits this JSON from the YAML. It does not execute Python.
`nxos/USER_LOGIN.py` becomes one message in the NX-OS profile: tag
`AUTHPRIV-6-SYSTEM_MSG`, event `USER_LOGIN`, captures `user`, `uid`,
`sshPid`, attributes `user.name` and `enduser.uid`, yang model omitted.

### Decision: What a match writes

On a match the node sets:

- `syslog.os`, `syslog.event` (the napalm `error` name), `syslog.tag`,
  `syslog.profile` (rule name), `syslog.matched` = true
- `syslog.yang_model` when the message has one
- `syslog.yang` when the mapping is non-empty
- the keys listed under `attributes`
- `syslog.fields` with every captured value after transforms

It does not change `short_message`, `full_message`, `host`,
`application_name`, `level`, `severity_text`, or `severity_number`. Severity
remains the job of the rules at orders 115 and 120.

Canonical attribute keys for the mapped models:

| Model | Attributes |
| --- | --- |
| openconfig-interfaces, openconfig-lacp | `network.interface.name`, `network.interface.admin_status`, `network.interface.oper_status` |
| openconfig-bgp | `network.bgp.peer.address`, `network.bgp.peer.remote_as`, `network.bgp.peer.state`, `network.bgp.prefix.limit`, `network.bgp.prefix.count` |
| openconfig-ospf, openconfig-isis | `network.routing.protocol`, `network.routing.neighbor.address`, `network.routing.neighbor.state` |
| openconfig-bfd | `network.bfd.session.state` |
| ietf-alarm, ietf-hardware | `alarm.id`, `alarm.severity`, `alarm.state` |
| openconfig-system, user messages | `user.name`, `user.action` |
| NO_MODEL, Fortinet traffic | identity fields plus `syslog.fields` only |

A yang path the table does not cover still lands in `syslog.yang` and
`syslog.fields`. The generator fails the build if a mapped model uses a path
the table does not name and the message has no `syslog.fields` destination
for that capture.

### Decision: Match procedure

For one profile rule:

1. If `syslog.matched` is already true, return the record unchanged. A second
   evaluation in core after the collector, or a later platform rule, does not
   overwrite the first match.
2. Build candidate tags from `application_name`, from `syslog.tag` when
   present, and from the first token of `short_message` when that token
   matches `^[A-Za-z0-9][A-Za-z0-9_-]*$` and is followed by `:` or end of
   token. When `short_message` still looks like a raw syslog line (leading
   `<pri>` or a month-name / ISO timestamp), run the profile's prefix list
   first and take `tag` and the message section from the first prefix that
   matches.
3. Look those tags up in a map built at rule compile time. Only the messages
   for the hit tags are tried, in file order.
4. Compile each `line` the way napalm-logs does: `{name}` becomes the value's
   pattern, a single space matches `\s+`, every other character is literal.
   Search is case-insensitive, as `re.search(..., re.I)` is in napalm-logs.
5. The first match wins. Apply transforms, then write the attributes.

Transforms, ported from `napalm_logs.utils`:

| Name | Result |
| --- | --- |
| `upper` | Unicode uppercase (`str.upper`) |
| `str` | string form of the capture |
| `int` | base-10 integer; a value that is not an integer fails the match |
| `bgp_state_convert` | `OpenSent`→`OPEN_SENT`, `OpenConfirm`→`OPEN_CONFIRM`, `Up`→`ESTABLISHED`, `Down`→`ACTIVE`, otherwise uppercase |
| `bfd_state_convert` | `AdminDown`→`ADMIN_DOWN`, otherwise uppercase |
| `color_to_severity` | `RED`→`3`, `YELLOW`→`4`, otherwise the capture unchanged |

Pack validation rejects any other transform, a `{name}` with no value entry,
a value pattern that does not compile, and a pattern the validator classifies
as nested unbounded repetition (a rejection list kept next to the validator,
covering the forms that blow up backtracking). The hot path is a tag-map
lookup plus the regexes for that tag.

### Decision: Failure leaves the log in place

A profile rule that fails to compile, a custom node that errors, or a
transform that cannot be applied on a live record does not drop the log and
does not fail the batch. The record continues without `syslog.matched`, and
the process increments a counter `zen_syslog_profile_errors` labeled by rule
name. This matches the event-writer behavior that already keeps the original
JSON when Zen normalization returns an error, and it requires the collector
path to do the same for this node.

An unmatched message is a normal miss, not an error.

### Decision: Corpus

The Rust tests load each `tests/config/<os>/<event>/**/syslog.msg` from the
snapshot and the sibling `yang.json`. The raw line is matched with that OS
profile's prefixes and messages. The test asserts `syslog.os`, `syslog.event`
(the napalm `error`), and the `syslog.yang` object against `yang_message`.
Fields the fixture leaves null stay absent. A second test feeds a parsed
record (`short_message` = the message section, `application_name` = the
process name) and asserts the same event and attributes, so the collector
shape is covered without re-parsing the header.

A fixture that the generator cannot represent fails the corpus test until the
generator or the profile is fixed. Platforms are not dropped to make the
suite green.

## Risks / Trade-offs

- Tag collisions across installed packs → first installed rule at order 112
  wins, and the corpus test installs the whole set and fails if two profiles
  both match one fixture. Authors disambiguate with a tighter `line`.
- Compiled JDM grows by the size of the installed profiles. Ten platforms are
  on the order of a few hundred kilobytes. Acceptable for the rule bundle.
  Tenants install the platforms they run, so the hot path does not carry
  unused regexes.
- Case-insensitive regex and `\s+` can over-match. The corpus is the guard.
- `int` and the BGP/BFD maps change captured text before it is stored. The
  raw capture remains available only inside the match; `syslog.fields` stores
  the transformed value, which is what napalm-logs puts in the output.
- Repeating evaluation (collector, then core) is safe because `syslog.matched`
  short-circuits. A bundle rollout that removes a profile does not strip
  attributes already written on a record that was stored.

## Migration Plan

1. Land the matcher, the template compiler, and pack validation behind no
   built-in install. With no `syslog_profile_*` rule enabled, behavior is
   unchanged.
2. Add the ten packs to the built-in catalog. Operators install them from
   the catalog. Upgrade uses the existing managed-pack reconciler.
3. Document the attribute keys in `docs/docs/syslog.md` and the pack list in
   `docs/docs/solution-packs.md`.
4. Rollback is uninstalling the pack, which disables the managed Zen rule and
   removes it from the published bundle. Stored logs keep the attributes they
   already have.

## Open Questions

- Whether a later change should offer one combined pack that vendors all ten
  profiles for a single install. Version 0.1.0 ships per-platform packs,
  because a pack has no pack-to-pack dependency and a Junos site should not
  have to carry the Fortinet regexes.
- Whether Fortinet `FORWARD_TRAFFIC` / `LOCAL_TRAFFIC` should eventually feed
  the flow pipeline. This change stores them as log attributes only.
