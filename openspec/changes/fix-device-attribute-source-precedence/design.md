## Context

`ocsf_devices` holds one value per attribute. Sources differ in what they know:
SNMP (mapper) reports `sysName` and `sysDescr`; the passive census sees an IP
and a MAC; an OUI lookup names the NIC registrant. Today the last write wins,
except for `ip` (never-downgrade address rank, #3905) and `type` (manual
ownership).

## Decisions

1. Evidence strength is recorded on the write, not inferred from the source
   name. `name` strength is "observed" when the update carries a hostname and
   "placeholder" when it is the address. `vendor_name` strength is "inferred
   from NIC registrant" when `mac_vendor_source = "ieee_oui"`, else "reported".
2. The upsert compares strength with the stored row inside the `ON CONFLICT`
   update, the same place the `ip` rank guard lives, so concurrent writers
   cannot race a read-then-write in Elixir.
3. A placeholder name equal to the stored address is itself replaceable, so a
   hostname-less device that changes address still gets its new placeholder.
4. In-batch merging uses the same rule so that two updates for one device in
   one batch resolve the same way as in two batches.

## Open questions

- Should a burned-in-MAC OUI vendor outrank a generic SNMP software vendor
  (`Net-SNMP`, `net-snmp`) that names the agent software rather than the
  hardware? Proposal: treat a known agent-software vendor as weaker than OUI.
- Integration-scoped ids: store per integration in metadata
  (`integration_ids.<provider>`) or in the identifier registry. The plugin
  assignment compiler should read the id for its own provider.

## Rejected alternatives

- Ignore `name` / `vendor_name` in the config version hash: the compiled config
  really does change (target name, credential), so the version must change.
- Drop the census's name and vendor entirely: loses enrichment for devices no
  other source describes, which the passive-census spec intends to keep.
