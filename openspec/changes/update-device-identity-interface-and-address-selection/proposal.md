# Change: Interface-MAC identity and routable-address preference

## Why

Two defects on farm01 share one root: the system collects the evidence that would
identify a device correctly, then declines to use it for identity.

### 1. A router's own interfaces become separate devices

`farm01` is one Ubiquiti chassis. Inventory holds it as two devices:

| device | ip | mac | identifiers |
| --- | --- | --- | --- |
| `sr:dd250d1a...` | 152.117.116.178 | `f4:92:bf:75:c7:21` | `F492BF75C721` strong, `F692BF75C721` medium |
| `sr:a6a7e25a...` | 192.168.1.1 | `f4:92:bf:75:c7:2b` | `F492BF75C72B` strong |

The SNMP walk ALREADY knows both interfaces belong to that chassis:

```
eth9  | f4:92:bf:75:c7:2a | idx 3 | {152.117.116.178, ...}
eth10 | f4:92:bf:75:c7:2b | idx 5 | {}          <- the second device's exact MAC
```

Two gaps follow:

- `eth10` is discovered with the right MAC but an EMPTY `ip_addresses`, so `192.168.1.1` is never
  bound to the interface that holds it.
- Interface MACs are never registered as device identifiers. The parent device carries only
  `...C721`; it never carries `...C72B`.

So the two rows share no identifier and `Identity.DuplicateSweep` refuses to merge them --
**correctly**. Two distinct strong MACs are not evidence of one device, and merging because MACs
look sequential would collapse genuinely separate hardware.

The alias is not the missing piece either, and the reason is sharper than "an alias is not an
identifier". An alias IS wired to merge: `AliasGuard.maybe_merge_ip_alias_device/3` (called from
`identity/resolver.ex:79` and `:85`) merges the alias holder with the resolved device under reason
`ip_alias_conflict`. It did not fire here because it was VETOED --
`distinct_strong_identity_conflict?/3` -> `distinct_mac_conflict?/3` (`alias_guard.ex:74`) finds the
two MAC sets entirely disjoint, and `Mac.any_hardware_mac_siblings?/2` recognises only the U/L-bit
flip (which is why `F692BF75C721` pairs with `F492BF75C721`, and why a third row legitimately
collapsed into the router on 2026-08-12). `...C72B` gets no such pass.

That veto is correct on the evidence available -- disjoint MACs are the network-agnostic tell that a
recycled IP has rebound to different hardware -- and it is also why there is no `merge_audit` row
for the pair: a refusal writes no audit. It matters for the remedy: once the chassis carries
`...C72B`, the MAC sets are no longer disjoint, the veto lifts, and this path merges the pair
directly rather than waiting on the sweep.

This is not a reconciler bug. The reconciler is starved of the one fact that would let it act.

### 2. Non-routable addresses become the primary IP (GitHub #3905)

Measured on farm01: **18** live devices have an `fe80:` link-local primary IP and **7** have a
ULA -- **25 of 126 live devices, 20%**. Of the 18 link-local ones, **10 already carry an IPv4
alias**, so the routable address is already known and simply is not promoted.

The same root shows up in gap 1: `eth10`'s only recorded address is
`fe80::f692:bfff:fe75:c72b`. Address selection prefers whatever arrived over whatever is useful.

A link-local address is not an identity: it is not routable, it is not unique beyond a link, and
it cannot be used to reach or correlate the device.

## What Changes

- **ADD interface-MAC corroboration.** MACs discovered on a device's own interfaces SHALL be
  recorded against that device under a DISTINCT identifier type, `:interface_mac`.

  **Corrected during implementation.** This originally said to register them as `:mac`
  identifiers, and that does not work. `DeviceIdentifier` uniqueness is
  `(identifier_type, identifier_value, partition)` and its upsert deliberately excludes
  `device_id` -- "silent last-writer-wins repoints collapsed distinct devices" -- so a MAC already
  owned by the other device stays with it. `MergePolicy` separately blocks MAC-only merges,
  noting they are "too noisy (especially interface MACs observed by mapper)". Both rules are
  right and neither is being weakened; a distinct TYPE coexists with the other device's `:mac`
  row instead of fighting them. `:interface_mac` is absent from `Ids.identifier_priority/0`, so
  it never resolves an update or identifies a device on its own.

  Existing exclusions stay: locally-administered/randomized MACs must not anchor, and the polling
  agent exclusion is unchanged.
- **ADD interface address binding.** An address learned for an interface SHALL be recorded on that
  interface, so `eth10` holds `192.168.1.1` rather than an empty set.
- **MODIFY primary-address selection.** A routable address SHALL outrank a link-local or ULA when
  choosing a device's primary IP. Where a device already holds a routable alias, that address
  SHALL be promoted. Resolves #3905.
- Not BREAKING for merge policy: no new merge rule is introduced. What changes is that
  `AliasGuard.distinct_mac_conflict?/3` no longer treats two devices as distinct hardware when one
  reports the other's MAC on its own interfaces. That NARROWS a veto; the merge it unblocks still
  requires its own evidence, a confirmed IP alias.

  **Also corrected during implementation:** the duplicate sweep does NOT merge the pair, because
  the two rows still hold different `:mac` values. The alias guard is what merges them, and only
  because the alias was already there.

  Blast radius measured before shipping on a 126-device deployment: the narrowing changes the
  outcome for exactly ONE device pair -- the chassis whose WAN and LAN addresses had split -- and
  that pair claims each other's MACs in BOTH directions, because SNMP polled both addresses and
  returned the same interface table.

## Impact

- **Affected specs:** `device-identity-reconciliation` (ADDED + MODIFIED). Touches the existing
  `Interface MAC Registration`, `Polling Agent Exclusion from Interface MAC Registration`,
  `IP Alias Resolution` and `IP Alias Sightings and Promotion` requirements.
- **Affected code:** `elixir/serviceradar_core/lib/serviceradar/network_discovery/` (SNMP interface
  and address walk, `mapper_results_ingestor.ex`), `inventory/identity/` (identifier registration,
  alias promotion), `inventory/sync/source_policy.ex` (MAC eligibility rules are reused, not
  redefined).
- **Related, NOT included:** `platform.discovered_interfaces` holds ~118 duplicate rows per
  interface for this device. Real, and it inflates every interface read, but it is a write-path
  defect rather than an identity rule; it is called out in `tasks.md` so it is not lost.
- **Risk:** registering more MACs as identifiers widens what can merge. The design sets the
  boundary so a MAC observed ON the wire (a neighbour's) is never confused with a MAC belonging TO
  the device's own interfaces -- otherwise every host a router sees becomes the router.
