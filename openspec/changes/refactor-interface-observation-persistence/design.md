# Design: interface observation persistence

## What counts as a change

The semantic state of an interface is what a consumer of interface inventory reads:

```
(device_id, if_index, if_name, if_descr, if_alias, if_phys_address,
 if_admin_status, if_oper_status, if_speed, speed_bps, mtu, duplex,
 if_type, interface_kind, sorted(ip_addresses))
```

Everything else on the row is either derived (`classifications`,
`classification_meta`, `available_metrics`) or provenance (`discovery_id`,
`mapper_job_id`, `discovery_time`, `agent_id`, `gateway_id`).

**Provenance must not participate in change detection.** That is the whole bug: a
fresh `discovery_id` per poll makes every row unique, which is why 36,816 rows
collapse to 374 states but no `DISTINCT` can see it. Provenance answers "who last
told us this and when", which is a property of the *observation*, not of the
interface -- so it belongs in `last_*` fields on the current row.

## Canonical ordering is not cosmetic

The same interface produced 12 textual values of `ip_addresses` for 3 real sets. An
unordered array compared by equality is a change detector that fires on nothing.

Sort on write. Sorting on read cannot work: the comparison that decides whether to
write happens first, and a reader cannot un-write rows that already exist.

## Current state vs history

These are different questions and the table currently answers neither well:

- **"What does this interface look like now?"** -- one row per `(device_id, if_index)`,
  upserted. This is what topology, identity and the UI need. 374 rows on the measured
  sample.
- **"When did this interface change, and to what?"** -- append-only, written ONLY on
  semantic change, with retention. On the measured sample that is 374 rows over 12
  days rather than 36,816.

Writing history as a side effect of polling frequency conflates them: it makes storage
a function of how often we ask rather than of how often the answer changes. At
1M devices that difference is ~1.2 TB/day versus a few hundred MB.

### The history has a named consumer

Interface history is wanted for **causal analysis of network outages** -- "what changed
on the network around the time this broke". That is a requirement on the SHAPE of the
history, not just its existence:

- It must record **what changed** -- previous value, new value, which fields -- because
  the query is "what changed in this window", not "what did every interface look like at
  time T". A snapshot-per-change forces the consumer to diff adjacent rows to recover the
  event, and to guess whether an absent row means unchanged or unobserved.
- It must be **queryable by time window and by device**, since that is how an outage
  investigation enters it.
- Retention must cover the forensic horizon the causal engine looks back over. A window
  shorter than that silently makes past outages unexplainable.

This is also the strongest argument AGAINST the current per-poll table: it already
contains every one of those transitions, and buries each in ~98 restatements, which is
precisely why nothing can consume it today.

## Why this is not solved by making it a hypertable

Compression and retention would shrink the symptom while leaving the cause: 99% of
what is written is a restatement, and every reader still has to defend itself against
duplicates (today by ordering by `timestamp` and taking the newest). A hypertable with
30-day retention at 1M devices still ingests ~767M rows/day and still returns 98
near-identical rows for one interface.

Retention and compression remain the right tools for the history store, once history
is only written when something happens.

## Migration

The existing 36,816 rows cannot be de-duplicated in place, because provenance made
each byte-distinct -- there is no "the true row" to keep. The safe path is to derive
the current-state rows from the LATEST observation per `(device_id, if_index)` and
leave the historical rows to the retention policy. That is stated as a task rather
than assumed, because it discards data and the maintainer should see it said out loud.

## Deliberately out of scope

- The identity work in `update-device-identity-interface-and-address-selection`. It
  reads interface MACs through a compact `:interface_mac` identifier specifically so it
  never scans this table, and so the two changes do not block each other.
- Interface metric counters. They already live in
  `platform.timeseries_metrics_interface_hourly`; this table holds no counters, which
  is why its row growth is not legitimate time-series data.
