## Context

The demo topology graph shows a healthy backbone on `192.168.1.0/24` and a set of
"islands": Proxmox hypervisors and endpoints on the routed `farm01`
(`192.168.2.0/24`) and `tonka01` (`192.168.10.0/24`) segments with no switch↔host
attachment edges. The hypervisor↔guest edges that appear inside each island are
**fabricated at read time** by the web-ng runtime graph from the virtualization
inventory (`virtualization_guests`/`virtualization_hosts`); the hypervisors and
endpoints themselves have zero evidence edges in Apache AGE.

The investigation (live `snmpwalk`, CNPG/AGE queries, Go + Elixir code trace,
adversarially verified) established that the attachment gap is produced entirely
inside the mapper-emission and core-resolution stages, and that the per-site
blockers differ. This change targets those stages only; presentation-tier and
identity-tier follow-ups are listed as related work in `proposal.md`.

### Per-site blocker analysis (verified against live SNMP)

- **tonka01 site (aruba `192.168.10.154`, HP 2920):** `dot1d` FDB walks fine (12
  entries; `dot1q` adds only VLAN-duplicate rows), so [B] is not the blocker here.
  Five endpoints on ports 13–17 have MACs that `tonka01`'s ARP resolves to
  `192.168.10.31/.33/.45/.56/.96` — all on the **same /24** as the aruba's own
  management IP, so [A] passes too. These edges are blocked purely by the
  recursive-pass veto **[D]** (the aruba is reached recursively, and its endpoint
  IPs are in the ARP-derived scan queue). Fixing [D] alone should surface these
  five edges. The pve **data** NICs (`.136/.235/.182`) attach directly to
  `tonka01` (no bridge FDB) and are not SNMP-recoverable — out of scope.
- **farm01 site (UniFi USW-Pro-24 `192.168.1.131`):** the pve hosts sit on VLAN 2,
  and the switch exposes its FDB only via `dot1q` **[B]**, on a different /24 than
  the switch's management IP **[A]**; the hosts are also learned as **wired**
  controller clients **[E]**. Recovering farm-site attachment needs [B]+[A], or
  the UniFi wired-client path [E] (which needs no SNMP change), plus [F2] to bind
  the resolved IP to the existing IP-only hypervisor device record.
- **Both sites:** [C] (router ARP as shared resolution evidence) is required
  wherever the switch that learns a MAC has no ARP for it and the router does;
  [F2] and [G] are binding-stage fixes needed so resolved/observed endpoints
  actually attach to the correct canonical device instead of being dropped or
  mis-minted.

## Goals / Non-Goals

- **Goals:** make the mapper *emit* switch↔host attachment evidence for endpoints
  on routed segments, and make core *bind* that evidence to the correct canonical
  device. Restore the concrete, live-verified edges (5 aruba endpoints via [D];
  farm pve hosts via [B]/[A]/[E]).
- **Non-Goals:** god-view rendering/layout (finding H), Proxmox identity
  over-merge and host NIC MAC capture (F1/I), enrichment-stall alerting (J),
  multipath/ECMP discovery, and any change to the
  `Mapper topology ingestion and graph projection` requirement.

## Decisions

- **Additive, not a rewrite of the join.** [A]/[C]/[D] relax existing gates and
  broaden the shared MAC→IP evidence map; they do not restructure the FDB join or
  the canonical rebuild. This keeps the change composable with
  `improve-mapper-topology-fidelity` (which assumes attachment rows are emitted)
  and `fix-topology-evidence-pipeline-resilience` (which promotes/binds them).
- **Confidence tiering preserved.** Cross-subnet and router-ARP-derived
  attachments SHOULD carry the same or lower confidence tier as today's
  same-subnet FDB attachments; switch-level (portless) UniFi wired attachments and
  LLDP/CDP-promoted endpoints SHOULD be emitted at reduced confidence so the
  read-model bounding in `refactor-topology-read-model-for-carrier-scale` can rank
  them correctly.
- **Binding consults DIRE, additively.** [F2] adds a `device_identifiers` lookup
  to the neighbor-resolution index; the existing `ocsf_devices` ip/mac/name lookup
  remains as fallback. This is the prerequisite that lets [E]/[G]'s resolved
  endpoints bind to existing IP-only device records (e.g. a hypervisor with an IP
  but no MAC identity) instead of minting provisional duplicates.
- **Per-VLAN community is credential-gated.** [B]'s `community@vlan` walk only
  runs when the discovery credential opts in, so single-context SNMPv3 or
  restricted communities are unaffected.

## Risks / Trade-offs

- **Attachment volume increase** → mitigated by confidence tiering + the read
  model's bounded attachment census (owned by
  `refactor-topology-read-model-for-carrier-scale`). This change must not assume
  every emitted attachment renders as a first-class node.
- **Cross-device ARP mis-join** (a MAC resolved to the wrong IP because two
  devices disagree) → keep provenance on each MAC→IP mapping and prefer the
  device that owns the L3 interface for the endpoint's subnet.
- **Removing the [D] veto could re-admit noise** the veto was added to suppress →
  scope the relaxation to cross-device ARP-observed endpoints (the case that is
  wrongly vetoed), not to all known-IP neighbors.
- **File-level overlap with `improve-mapper-topology-fidelity`** in
  `go/pkg/mapper` and `mapper_results_ingestor.ex` → sequence after or coordinate
  with that change; the requirements are additive but the diffs touch adjacent code.

## Migration Plan

Behavioral change only; no schema migration. Roll out behind the existing mapper
discovery path. Validate on demo by confirming the five aruba endpoints
(`192.168.10.31/.33/.45/.56/.96`) gain `ATTACHED_TO` edges to `aruba-24g-02`, and
that farm-site pve hosts gain attachment to the USW-Pro-24 once [E]/[B] land.
Rollback = revert; no persisted data shape changes.

## Open Questions

- Does the tonka01 job walk both `tonka01` (ARP owner) and the aruba (FDB owner)
  within one job run, so the shared MAC→IP map can join them? (Live data implies
  yes; confirm the recursive expansion includes both before relying on [C]+[D]
  alone for the tonka edges.)
- For [E], does the UniFi Integration v1 API expose wired-client switch/port at
  all on the deployed controller version, or must the mapper fall back to
  switch-level attachment universally? (Live check showed the v1 port-table empty;
  the legacy `/stat/sta` path may be required.)
- Should [G] LLDP/CDP endpoint promotion reuse the same promotable-source
  allowlist as `fix-topology-evidence-pipeline-resilience`'s
  `Endpoint attachment identity promotion`, or maintain a separate list? (Prefer
  extending the shared allowlist at implementation time to avoid drift.)
