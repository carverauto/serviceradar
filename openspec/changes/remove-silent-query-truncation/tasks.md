## 1. Device reads that still take one page

- [x] 1.1 Stream or loop `Device.read` in `snmp_compiler.ex` `execute_parsed_query/3` so a profile scope larger than one default page becomes targets. `Ash.read_one` for a single management device stays.
- [x] 1.2 Stream the device preloads in `batch_resolver.ex`: `tombstoned_ids/2`, `preload_agent_trust/3`, and the primary-MAC half of `preload_canonical_macs/3`. A uid that was not loaded is a failed read, not "absent".
- [x] 1.3 Stream `load_devices_by_ip/2` in `netflow_exporter_cache_refresh_worker.ex` and `netflow_interface_cache_refresh_worker.ex`, including the exporter alias tier. Chunking addresses by 2_000 is fine; one Ash page per chunk is not.
- [x] 1.4 Stream `fetch_devices/2` in `god_view_stream.ex` so every topology node id is hydrated. Leave the unplaced viewport (query 96, show 16) as a viewport bound.
- [x] 1.5 Stream `load_devices/2` in `mapper_promotion.ex` and `load_deleted_devices/2` in `sweep_results_ingestor.ex`.
- [x] 1.6 Stream `load_device_contexts/2` in `interface_classifier.ex`.
- [x] 1.7 For each site, extend an existing test with a batch larger than `Device.read`'s `default_limit` (250) and assert every row is applied. A new test file under `elixir/serviceradar_core/test/` gets a row in `INTEGRATION_SOURCE_DISPOSITIONS.tsv` when it is selected. Do not `Enum.to_list` an unbounded stream in production code. The shared stream is `ServiceRadar.Ash.Page.stream!/2`. The identity fence already has the 260-row regression. `streamed_device_reads_test.exs` covers the core callers with 260 devices, and `god_view_device_page_test.exs` covers topology hydration. The alias-owner list is materialized only after a 2_000-address chunk.

## 2. SRQL limits

- [x] 2.1 Stop `determine_grouped_device_limit` from clamping an explicit limit to 100. Keep the default of 20 when `limit:` is omitted. When the page is not the full grouping, set a truncation indicator on the response.
- [x] 2.2 Apply the same rule to `MAX_GROUP_LIMIT` in `composite_results/stats.rs`: an explicit limit is honored, a partial page is marked, an omitted limit may stay at its default.
- [x] 2.3 Update `devices_grouped_stats_apply_the_documented_limits` and the composite stats tests. Update `docs/docs/srql-language-reference.md` so it no longer says grouped device stats max at 100 or composite stats hard-cap at 500.
- [x] 2.4 Give window-coverage jobs a continuation that is allowed past `srql_max_cursor_offset`, using the exhaustive-profile exemption or an equivalent server-side page loop. Ordinary interactive queries keep the ceiling and still return the existing error. Do not set `SRQL_MAX_LIMIT`.

## 3. Window-coverage jobs

- [x] 3.1 Page `NetflowExporterCacheRefreshWorker` sampler discovery and `NetflowInterfaceCacheRefreshWorker` pair discovery until the scan window is exhausted. Remove the one-shot `LIMIT` of 5_000 and 10_000 as the end of the set.
- [x] 3.2 Page `NetflowSecurityRefreshWorker` threat candidates the same way.
- [x] 3.3 Page `IpEnrichmentRefreshWorker` across uncached observed flow IPs. The top-200-by-bytes query is not the cache population the spec describes.
- [x] 3.4 Change `CapacityForecasting.Source` and `SeasonalDisposition.Source` so history is complete per series over the horizon. `sort:timestamp:desc limit:50000` across every series is not that read.
- [x] 3.5 Page `DeviceRiskIocExposure.query_flows/1` across the configured window. The newest 5_000 rows are not the window.
- [x] 3.6 Tests for 3.1-3.5 use a fixture larger than the old constant and fail if the job stops there. Sampler discovery, `PagedQuery.collect/3`, interface pairs, threat candidates, IP enrichment, capacity history, seasonal history, and the hostile-IOC offset loop each fail if they stop on the first full page.

## 4. Spec alignment already started

- [x] 4.1 Keep `openspec/changes/add-srql-jsonb-group-by/specs/srql/spec.md` free of a hard maximum of 100. Do not edit files under `openspec/changes/archive/`.
- [x] 4.2 `openspec validate remove-silent-query-truncation --strict` passes.
