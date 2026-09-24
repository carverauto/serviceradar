# Change: Stop complete-set reads at a silent page

## Why

PR #4629 removed the Ash clamp that made `Device.read` return 251 rows and report the page complete. The default page is now 250, `more?` is truthful when the caller stays within `max_page_size`, and `Device` and `PrefixTag` accept a page up to one billion rows. Callers that still take one page and discard `more?` are unchanged. On an inventory larger than that default page they proceed as if the tail did not exist: SNMP targets are never polled, identity batches treat a missing row as "not tombstoned", flow exporters stay unnamed, and topology nodes never hydrate.

Issue #4632 is the census. Interactive screens hide it, because the device list pages at 20 to 100 and a count query is separate from the page. This change is the follow-up #4629 left open. It does not raise another finite ceiling.

## What Changes

- Internal callers that need every matching device stream or follow `more?` until the set is exhausted. A missing row is not treated as absence when the read stopped early.
- Sites still on one page of `Device.read`: the SNMP compiler, identity batch resolver, both netflow cache refresh workers, god-view device hydration, mapper promotion, sweep tombstone restore, and interface classification.
- SRQL grouped stats keep a default page when `limit:` is omitted, and they honor an explicit `limit:`. An explicit limit is never compiled down to a smaller `LIMIT` with a successful response. A partial group page says it is partial.
- Maintenance reads that claim to cover a window (netflow exporter and interface caches, threat-candidate refresh, GeoIP enrichment of observed flow IPs, capacity forecasts, seasonal baselines, hostile-flow exposure) page until the window is covered. A top-N widget may stay top-N only where the UI already says so.
- Jobs that must see every row do not stop at the interactive SRQL cursor ceiling of 100_000. Interactive queries keep that ceiling and surface the error they already return.
- The pending change `add-srql-jsonb-group-by` no longer restates a hard maximum of 100 on device group-by, so archiving it cannot put the silent cap back.

## Impact

- Affected specs: `device-inventory`, `device-identity-reconciliation`, `srql`, `observability-netflow`, `capacity-forecasting`, `topology-god-view`
- Affected code: the call sites named above, `rust/srql` limit planning, capacity and seasonal SRQL sources, netflow refresh workers, `docs/docs/srql-language-reference.md`
- Issue: https://github.com/carverauto/serviceradar/issues/4632
- Already merged and out of this change's code: https://github.com/carverauto/serviceradar/pull/4629
