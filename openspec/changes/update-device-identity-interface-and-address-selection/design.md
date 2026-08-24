# Design: interface identity and address preference

## The boundary that makes interface-MAC identity safe

A router sees two very different kinds of MAC:

1. MACs **belonging to** its own interfaces (`eth9 = ...c7:2a`, `eth10 = ...c7:2b`), read from its
   own interface table.
2. MACs **observed on** the wire -- every neighbour's ARP/NDP.

Only the first kind may become an identifier of the device. Registering the second kind would make
every host a router can see collapse onto the router: the exact collector over-merge that
`SourcePolicy.observer_agent_source?/1` exists to prevent, and which has already been reproduced
for `passive-netprobe`.

The distinction is structural, not heuristic: kind 1 comes from the device's OWN interface table,
kind 2 comes from a neighbour table. They arrive on different code paths and must not be unified
into a single "MACs we saw near this device" set.

## Why this needs no new merge rule

The pair in the motivating case fails to merge because they share no identifier -- not because the
merge policy is too strict. TWO existing paths would merge them the moment that changes:

- `AliasGuard.maybe_merge_ip_alias_device/3`, which already sees the `192.168.1.1` alias and is
  vetoed only by `distinct_mac_conflict?/3` finding the MAC sets disjoint. Registering the
  interface MAC removes the disjointness and the veto lifts.
- `DuplicateSweep`, which merges on a shared strong identifier and runs every five minutes.

Neither needs a new rule; both need the same missing fact.

That is deliberate: this change adds EVIDENCE, and leaves the decision to the existing policy.
Adding a merge rule ("merge if MACs differ only in the last octet", "merge if one's IP is another's
alias") would be a heuristic that trades a visible duplicate for an invisible over-merge. Sequential
MACs across a chassis are a convention, not a guarantee, and an alias means "this address routes
here", not "this address IS here".

## Existing MAC exclusions are reused, not restated

`SourcePolicy.census_anchorable_mac?/1` already refuses locally-administered and randomized MACs as
anchors, because iOS/Android per-SSID rotation would otherwise mint a device per rotation. That rule
applies unchanged to interface MACs.

It matters here concretely: the motivating device's identifiers include `F692BF75C721` at `medium`
confidence -- the U/L-flipped form of `F492BF75C721`, almost certainly derived from an EUI-64 IPv6
address. A locally-administered form of a universal MAC must not anchor, and must not be treated as
a second distinct NIC.

## Address preference

Ranking, strongest first: routable global > RFC1918 / private > ULA (`fc00::/7`) > link-local
(`fe80::/10`). Loopback is never a primary address.

Two properties this must have:

- **Promotion is not creation.** Where a device already holds a routable alias -- true for 10 of the
  18 affected devices -- the fix is to promote what is already recorded. No new discovery is needed
  and no new device may be created by promotion.
- **A device with only a link-local keeps it.** Eight of the 18 have no routable address recorded.
  Blanking their primary IP would trade a poor address for none; they keep what they have until a
  better one is observed.

Link-local addresses remain useful as *evidence* (they are how NDP census sightings arrive) and stay
recorded as aliases. The change is only about which address is chosen as primary.

## Out of scope

- Any new merge rule, as above.
- Deduplicating `platform.discovered_interfaces`. Real (~118 rows per interface on this device) and
  worth fixing, but it is a write-path defect, not an identity rule. Recorded in `tasks.md`.
- Retroactive repair of the 25 devices already holding a non-routable primary. The promotion path
  fixes them as they are next observed; a bulk rewrite is a separate, auditable operation.
