## 1. Shared reset plumbing

- [x] 1.1 Add `SRQL.Page.handle_event("srql_reset", params, opts)` that stays on
      `srql.page_path`, drops `q`/`cursor`/`page`/`nf`, keeps scoped extra_params, and
      patches with `opts[:default_query]` when provided (otherwise the builder/catalog
      default for the current entity + limit)
- [x] 1.2 Do **not** change empty-`q` `srql_submit` fallback (keep current query)
- [x] 1.3 Point `srql_query_bar` X control at `phx-click="srql_reset"`; keep
      `data-srql-reset`; remove `phx-value-q=""`
- [x] 1.4 Align `ui_icon_button` global attrs with `ui_button` for `phx-value-*` used
      by the query bar so value attrs are not stripped

## 2. LiveView forwarders

- [x] 2.1 Forward `srql_reset` next to every existing `srql_submit` → `SRQL.Page`
      call, passing the same `fallback_path` / `extra_params` / `entity` opts
- [x] 2.2 LogLive netflows: pass the same default string
      `maybe_default_netflows_query/2` would insert (`in:flows time:last_1h sort:time:desc`)
- [x] 2.3 Device detail / interface detail / dashboard hub: reset to that view's
      first-visit default (device uid-scoped query, not the index query) and clear
      cursor/page

## 3. Client hook

- [x] 3.1 On `[data-srql-reset]` click, expire `srql_time` (do not no-op on empty)
- [x] 3.2 Stop blanking the input to `""`; let `data-query` sync be the source of truth
- [x] 3.3 Ensure `maybeRestore` cannot upsert a remembered range after the cookie is
      cleared, including when the URL has no `q`

## 4. Tests

- [x] 4.1 `page_test.exs`: reset from a filtered flows query returns the provided
      default (or builder default), omits cursor/page/`nf`, does not no-op
- [x] 4.2 `page_test.exs`: empty `srql_submit` still keeps the current query
- [x] 4.3 `SRQLTimeCookie.test.js`: reset click expires `srql_time` and does not
      restore a remembered window
- [x] 4.4 `log_live/netflows_test.exs`: click Reset on a `time:[start,end]` query;
      assert input, URL `q`, and subsequent SRQL calls use the first-visit netflows
      baseline
- [x] 4.5 `device_live_test.exs` (index and/or show): reset restores that route's
      baseline and reloads results; Run and builder toggle still work

## 5. Verification

- [x] 5.1 `mix test` for the touched ExUnit files (and `mix precommit` if format/credo
      noise appears)
- [x] 5.2 Vitest for `SRQLTimeCookie.test.js`
- [ ] 5.3 Manual check on Devices and `/observability/netflows` if a browser loop is
      available
