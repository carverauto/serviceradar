## Context

`ocsf_devices` holds one value per attribute. Sources differ in what they know:
SNMP (mapper) reports `sysName`, `sysDescr` and `sysObjectID`; the passive
census sees an IP and a MAC; an OUI lookup names the NIC registrant. Today the
last write wins, except for `ip` (never-downgrade address rank, #3905) and
`type` (manual ownership).

## Decisions

1. Each single-valued attribute (`name`, `vendor_name`) stores its source and
   evidence strength alongside the value. Strength is assigned by the writer
   from the evidence it holds, not inferred later from the value.
2. Strength order for `name`, weakest first:
   1. address fallback: the update has no hostname, so the name is an address;
   2. passive census sighting (a hostname seen passively);
   3. SNMP `sysName` from the mapper, or a name reported by an integration.
3. Strength order for `vendor_name`, weakest first. The tier follows the
   vendor derived for the update, never the evidence channel or the
   `sysObjectID` enterprise alone:
   1. a derived vendor that names SNMP agent software (Net-SNMP and similar),
      whether from a `sysObjectID` under an agent-software enterprise (such as
      8072), `sysDescr` inference or a classification rule;
   2. the IEEE OUI registrant of the MAC (`mac_vendor_source = "ieee_oui"`),
      or an explicit metadata vendor on an update that is not from an
      integration (equal to the OUI);
   3. a derived vendor that names a hardware vendor, whether from a
      `sysObjectID` enterprise, `sysDescr` inference or a classification rule,
      or a vendor reported by an integration.
   The agent-software enterprises are a fixed, named list kept next to the
   enterprise-to-vendor table; an enterprise not on it is a hardware vendor.
   A `sysObjectID` under enterprise 8072 with a hardware vendor from
   `sysDescr` or a classification rule is tier 3; a `sysDescr` or
   classification result that names agent software is tier 1.
4. A write replaces the stored value when its strength is equal to or greater
   than the stored strength. A weaker write fills the attribute only when no
   value is stored. Nothing else decides: there is no test comparing the stored
   name with the stored address. A populated value without a recorded
   strength (rows written before this change) is kept against a weakest-tier
   write (address fallback name, or a derived vendor that names agent
   software from any channel); the next write of a middle or strongest tier
   (passive census sighting, IEEE OUI, non-integration metadata vendor, SNMP
   `sysName`, a derived hardware vendor from `sysObjectID`, `sysDescr` or a
   classification rule, or integration-reported) replaces it and records its
   strength. A missing strength is never treated
   as a recorded weak strength. So the first census pass after rollout may
   change an unrecorded spelling once (for example a legacy `Net-SNMP` or
   hardware vendor spelling becomes the OUI spelling), and the first mapper
   pass may change it once more to a stronger value.
5. An address fallback name is derived from the address the device keeps after
   the address rank guard, never from an update address the guard rejected, so
   a link-local sighting cannot rename a device that keeps a better address.
6. The upsert compares strength with the stored row inside the `ON CONFLICT`
   update, the same place the `ip` rank guard lives, so concurrent writers
   cannot race a read-then-write in Elixir.
7. In-batch merging (`merge_records_by_uid`) applies the same order and the
   same equal-or-stronger rule to the updates it combines, so two updates for
   one device in one batch resolve the same way as in two batches.

## Open questions

- Integration-scoped ids: store per integration in metadata
  (`integration_ids.<provider>`) or in the identifier registry. The plugin
  assignment compiler should read the id for its own provider.

## Rejected alternatives

- Ignore `name` / `vendor_name` in the config version hash: the compiled config
  really does change (target name, credential), so the version must change.
- Drop the census's name and vendor entirely: loses enrichment for devices no
  other source describes, which the passive-census spec intends to keep.
- Treat a stored name equal to the stored address as replaceable: a second
  definition of "placeholder" that disagrees with the recorded strength. It
  lets a guard-rejected address rename a device, and classifies an observed
  `sysName` that happens to be an address as a placeholder, which restarts the
  loop this change exists to stop.
