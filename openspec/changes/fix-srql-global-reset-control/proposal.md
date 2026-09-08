# Change: Make the global SRQL reset control restore route-canonical query state

## Why

The X / reset control beside the shared SRQL query bar is inert. Clicking it leaves the
visible query, URL-backed `q`, pagination, and rendered results unchanged. This is
reproducible on `/observability/netflows` after applying a chart range (`time:[start,end]`)
and is likely to affect every page that mounts `srql_query_bar`. GitHub issue #4114.

The control already exists and is labeled "Reset SRQL filters". The bug is in the shared
event and navigation plumbing: reset is implemented as `srql_submit` with an empty `q`,
and `SRQL.Page` treats empty `q` as "keep the current query".

## What Changes

- Give the query-bar X control a dedicated `srql_reset` intent that restores the **same
  canonical query `handle_params` uses on first visit with no `q`**, not an empty string
  and not a NetFlows-only hard-coded query.
- Keep the visible input, URL-backed `q`, cursor/page state, and rendered results in
  lockstep after one click.
- Stop the `srql_time` cookie / `SRQLTimeCookie` hook from re-injecting a remembered
  `time:` token after an explicit reset.
- Leave Run, builder toggle, and builder apply/run behavior unchanged. Empty Run
  continues to mean "keep current query" unless the user also clicked reset.
- Cover the click in shared Page/hook tests and prove Devices plus Observability/NetFlows
  (and other representative `srql_query_bar` consumers) stay synchronized.

## Impact

- Affected specs: `srql`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/srql_components.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/srql/page.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/ui_components.ex`
  - `elixir/web-ng/assets/js/hooks/SRQLTimeCookie.js`
  - LiveViews that custom-handle `srql_submit` instead of delegating to `SRQL.Page`
    (device detail, interface detail, dashboard hub)
  - Tests: `test/phoenix/srql/page_test.exs`, hook vitest, `log_live/netflows_test.exs`,
    `device_live_test.exs`
- Related: GitHub issue
  [carverauto/serviceradar#4114](https://github.com/carverauto/serviceradar/issues/4114)
