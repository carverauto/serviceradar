## Context

The global query bar is `srql_query_bar/1` in
`elixir/web-ng/lib/serviceradar_web_ng_web/components/srql_components.ex`, mounted from
`layouts.ex` whenever `assigns.srql.enabled` is true. The X button is:

```elixir
phx-click="srql_submit"
phx-value-q=""
data-srql-reset
```

`SRQLTimeCookie.js` also listens for `[data-srql-reset]` and sets the input to `""`.

`SRQL.Page.handle_event("srql_submit", params, opts)` then does:

```elixir
query = if query == "", do: to_string(srql[:query] || ""), else: query
```

Empty `q` is therefore a no-op. LiveView re-renders `data-query` from the unchanged
assign, and the hook's `updated/1` writes the old query back into the input. Device
detail and interface detail copy the same empty-q fallback locally.

NetFlows first-visit default is **not** the catalog/builder default. `LogLive.Index`
fills a missing `q` with `in:flows time:last_1h sort:time:desc` via
`maybe_default_netflows_query/2`. Catalog `flows.default_time` is `last_24h`. Reset
must not invent a third string.

A second trap: if reset omits `q` from the URL, `SRQLTimeCookie.maybeRestore` sees no
`q` param, reads `srql_time`, and upserts the remembered range into the (temporal)
default query without submitting. Input and results would diverge.

## Goals / Non-Goals

- Goals:
  - One click restores the route's first-visit SRQL baseline.
  - Input, URL `q`, cursor/page, and results stay synchronized.
  - Shared plumbing; no NetFlows-only special case in the button.
  - Remembered `srql_time` cannot resurrect the filter after reset.
- Non-Goals:
  - Changing Run / builder / catalog autocomplete behavior.
  - Resetting NetFlows view chrome (`view`, `graph`, `stack`, `compare`, …) unless
    those params encode SRQL filters (`nf` does and MUST drop).
  - Clearing the input to blank. Blank is not a valid page baseline for entity routes.
  - Reworking how each LiveView computes its first-visit default.

## Decisions

- **Decision: dedicated `srql_reset` event, not empty `srql_submit`.**
  Empty submit staying "keep current" is load-bearing for accidental blank Run. Reset
  is a different intent. The button MUST fire `srql_reset` and MUST NOT send `q=""`.

- **Decision: stay on the current page; do not re-route via `route_target_for_query/2`.**
  Reset is "undo filters on this view", not "run an empty query and hope the catalog
  route is right". Device detail stays on `/devices/:uid`. NetFlows stays on
  `/observability/netflows`.

- **Decision: drop `q`, `cursor`, `page`, and `nf`; keep scoped extra_params.**
  `handle_params` already applies the canonical default when `q` is absent
  (`maybe_default_netflows_query/2`, `normalize_query_param/2`, device
  `default_device_query/2`, …). That is the single source of truth. After
  `handle_params` assigns the default query, patch the URL so `q` equals that
  assigned query (or omit `q` only when that is already how first visit looks **and**
  the cookie cannot rehydrate a filter — see cookie decision). Prefer writing the
  canonical `q` so input and URL match the acceptance criteria literally.

  Implementation shape: `srql_reset` `push_patch`es `page_path` with extras minus
  `q`/`cursor`/`page`/`nf`. `handle_params` loads the default. A follow-up patch is
  not required if `handle_params` (or `load_list`) already writes `q` when it filled
  a default; if it does not, have `srql_reset` supply the default by calling the
  same helper the LiveView uses, passed as `opts[:default_query]` / derived from
  current `srql.entity` **only when the LiveView has no custom default**. For
  LogLive, pass the same string `maybe_default_netflows_query/2` would insert.

  Practical split:
  1. Shared `SRQL.Page` reset navigates to `page_path` without `q`/`cursor`/`page`/`nf`.
  2. LiveViews with a custom first-visit default (LogLive netflows, device detail)
     pass `default_query:` so the patch includes that `q` in one hop.
  3. Generic `SRQL.Page` consumers can derive default from `Builder.default_state/2`
     for the current entity + limit.

- **Decision: attach reset handling where `srql_submit` is already forwarded.**
  Do not add `attach_hook` inside `Page.init/3` — `ensure_srql_entity/3` re-calls
  `init/3` on tab change and a second `attach_hook` with the same id raises. Add
  `handle_event("srql_reset", ...)` next to each existing `srql_submit` forwarder
  (mechanical) and explicit clauses on custom submit LiveViews.

- **Decision: clear or replace `srql_time` on reset.**
  `SRQLTimeCookie` MUST expire `srql_time` (or write the baseline window from the
  post-reset input) when `[data-srql-reset]` is clicked. `cookieSet` currently
  no-ops on empty values; add an explicit clear. Do not optimistically blank the
  input — that flash is overwritten by `data-query` and looks broken.

- **Decision: `ui_icon_button` must forward reset bindings.**
  Align its `:global` include list with `ui_button` at least for `phx-value-q` and
  `phx-value-reset` so future value attrs are not silently stripped. Today's reset
  should not need `phx-value-q`.

## Risks / Trade-offs

- **Custom defaults drift from catalog** → Mitigation: reset calls the LiveView's
  existing first-visit helper, never a second copy of the NetFlows string in the
  component.
- **Missing `srql_reset` clause** → Mitigation: Page catch-all currently no-ops
  unknown events; add a unit test that reset changes query, and LiveView tests on
  Devices + NetFlows so a missed forwarder fails CI.
- **Cookie rehydrate** → Mitigation: hook test that reset click expires `srql_time`
  and does not upsert a remembered range when `q` is absent.
- **Double patch** → Mitigation: prefer one `push_patch` that already contains the
  canonical `q`.

## Migration Plan

No schema or API migration. Deploy is a web-ng-only behavior fix.

Rollback: revert the change; the control returns to inert (current production).

## Open Questions

None. Baseline = first-visit `handle_params` default for that route. View chrome
stays. `nf` drops because it encodes a time window.
