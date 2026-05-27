# Dashboard Builder Redesign — Query-First Authoring

## The problem

The current builder asks users to commit to a visualization *before* they can see the data, then forces them to reverse-engineer what the query returns by trial-and-error. Specifically:

1. **You pick the visual first, the data second.** Inspector starts with "Visual: gauge / line / table / stat" and only *after* you've committed to a shape do you see whether the SRQL query actually produces fields compatible with it. If the query returns three numbers and a timestamp, gauge wants one, line wants two, table wants all four — you can't tell which fits until you've written the query and bound fields blind.

2. **One panel = one query = one visual.** A SRQL query like `in:devices` returns rows with `name, status, cpu, mem, last_seen, site`. A natural dashboard for that data has multiple panels — *device count by status* (stat), *top 10 by CPU* (bar), *device list* (table). Today each of those is a separate panel with its own duplicated query. The user has to write the same `in:devices` three times and tweak.

3. **JSON in the UI.** Variable definitions, field bindings, trend overrides, and a few panel-config blocks still surface as raw JSON. Users don't think in JSON. They think "show me CPU over time for this list of hosts." Every JSON textarea is a UX cliff.

4. **No sample data while authoring.** The preview only fires after the query parses *and* the visual is selected *and* fields are bound — meaning by the time you see whether your query was right, you've already configured three other things you may now need to throw away.

The net effect: even the senior engineers on the team treat the builder as a "write SRQL → click run → squint at the table preview → guess at bindings → repeat" loop. New users give up.

## The new model

Reverse the flow. **Data first, shape second, layout third.**

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  1. QUERY    │ →  │  2. OUTPUTS  │ →  │  3. LAYOUT   │
│              │    │              │    │              │
│  Write SRQL  │    │  Pick fields │    │  Drag onto   │
│  See rows    │    │  Pick visual │    │  the grid    │
│              │    │  (× N)       │    │              │
└──────────────┘    └──────────────┘    └──────────────┘
```

### Core concepts

- **Source query** — one SRQL string. Runs once per author session; returns *up to 5 sample rows* + the field schema (name, type, nullability, sample values). Source queries are first-class and reusable.
- **Output** — a (source query, field selection, visualization, optional aggregation/transform, optional title) tuple. One source query can have many outputs. Each output is what becomes a tile on the dashboard.
- **Panel** — an output placed on the grid with position and size. Panels reference outputs; outputs reference source queries.

This decoupling is the unlock: writing `in:devices` once gives you a data set; from that data set you build *several* panels without re-typing the query, and each panel chooses fields appropriate to its shape.

## The new flow, screen by screen

### Step 1 — Write the query, see the data

A single large pane. Monaco SRQL editor on top. Below it, a **Run** button and a **sample table** showing up to 5 rows with column types annotated.

```
┌──────────────────────────────────────────────────────────────────────┐
│ Source query                                       [+ New query]    │
│ ┌──────────────────────────────────────────────────────────────────┐│
│ │ in:devices time:last_1h limit:1000                               ││
│ │                                                                  ││
│ └──────────────────────────────────────────────────────────────────┘│
│                                                          [ ▶ Run ]  │
│                                                                      │
│ Sample (5 of 247 rows · 12ms)                                       │
│ ┌────────┬─────────┬───────────┬────────┬────────┬─────────────────┐│
│ │ name   │ status  │ cpu_pct   │ mem_mb │ site   │ last_seen       ││
│ │ string │ string  │ number    │ number │ string │ datetime        ││
│ ├────────┼─────────┼───────────┼────────┼────────┼─────────────────┤│
│ │ host-1 │ ok      │ 42        │ 8192   │ chi1   │ 2026-05-26 04:… ││
│ │ host-2 │ fail    │ 91        │ 4096   │ chi1   │ 2026-05-26 04:… ││
│ │ ...    │ ...     │ ...       │ ...    │ ...    │ ...             ││
│ └────────┴─────────┴───────────┴────────┴────────┴─────────────────┘│
│                                                                      │
│           [ Add output → ]    [ Save query for reuse ]              │
└──────────────────────────────────────────────────────────────────────┘
```

The user sees concrete data with concrete types. **No visualization picker yet.** No bindings. Just "did your query return what you expected."

Errors surface inline next to the run button (parse, permission, timeout). The query stays editable; iterate until rows look right.

### Step 2 — Pick fields, pick a visual (repeatable)

Once a query has rows, the user clicks **Add output**. A panel opens beside or below the sample table:

```
┌──────────────────────────────────────────────────────────────────────┐
│ Output 1                                                  [ × Remove]│
│                                                                      │
│ Title:        [ Devices by status                              ]    │
│                                                                      │
│ Show me:      ◉ A single number    (1 numeric field)               │
│               ○ A list             (any fields, multiple rows)     │
│               ○ A trend over time  (1 datetime + 1 numeric)        │
│               ○ A breakdown        (1 category + 1 numeric)        │
│               ○ A comparison       (2 categories + 1 numeric)      │
│               ○ A pivot / cross-tab (2 dimensions + 1 numeric)     │
│                                                                      │
│ Field:        [ status (count distinct)  ▾ ]                       │
│                                                                      │
│ Preview:                                                            │
│ ┌─────────────────┐                                                 │
│ │                 │                                                 │
│ │     247         │                                                 │
│ │   Devices       │                                                 │
│ │                 │                                                 │
│ └─────────────────┘                                                 │
│                                                                      │
│                                              [ + Add another output ]│
└──────────────────────────────────────────────────────────────────────┘
```

Key decisions baked in:

- **"Show me" is intent, not implementation.** The user picks an *intent* ("a single number", "a trend over time"), and the system maps that to a visualization. The visual type is still configurable in an "Advanced" toggle for power users, but it's no longer the entry point.
- **Field pickers only show compatible fields.** "Trend over time" requires a datetime axis → the time field dropdown only contains datetime columns from the sample. "A single number" only lets you pick numeric columns or apply `count distinct` to a categorical column. The field picker enforces what works.
- **Aggregations are inline with the field, not a separate config.** "status (count distinct)" is a single dropdown choice — the user doesn't have to know that's a group-by/count-aggregation under the hood.
- **Live preview** for the output renders right there, using the sample rows. The user sees the visual update as they pick fields. No round-trip to commit before they can see what they're building.

Adding more outputs repeats the form. Each output gets its own card. A typical "device overview" dashboard might end with 5 outputs from a single `in:devices` query: one stat (count), one bar (cpu by host), one table (full list), one trend (cpu over time), one breakdown (status by site).

### Step 3 — Place outputs on the dashboard

Once the user has the outputs they want, they go to the layout step. The dashboard grid appears with each output rendered as a draggable tile in a "tray" along the side.

```
┌──────────────────────────────────────────────────────────────────────┐
│ Tray                  Dashboard                                      │
│ ┌─────────────┐       ┌───────────────────────────────────────────┐ │
│ │ 247         │       │ ┌──────┐ ┌────────────────────────────┐  │ │
│ │ Devices     │ ⇒     │ │ 247  │ │  cpu over time             │  │ │
│ └─────────────┘       │ │      │ │                            │  │ │
│ ┌─────────────┐       │ └──────┘ └────────────────────────────┘  │ │
│ │ cpu over    │       │ ┌────────────────────────────────────┐    │ │
│ │ time        │       │ │  device list                       │    │ │
│ └─────────────┘       │ │                                    │    │ │
│ ┌─────────────┐       │ │                                    │    │ │
│ │ device list │       │ └────────────────────────────────────┘    │ │
│ └─────────────┘       └───────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

Drag a tile from the tray onto the grid. Resize and re-position with GridStack as today. Outputs not placed stay in the tray (drafts). Outputs already placed can still be removed back to the tray.

This step is the only place where layout decisions happen. Steps 1–2 produce *outputs*, step 3 produces a *dashboard*.

## Intent → visualization mapping

The "Show me" options resolve to concrete visuals based on the fields the user picks. Default mappings:

| Intent                | Required fields                       | Default visual | Notes                                |
|-----------------------|---------------------------------------|----------------|--------------------------------------|
| A single number       | 1 numeric (or count-distinct of any)  | `stat`         | Auto-detect threshold colors if `status`/`health` fields present |
| A gauge               | 1 numeric, optional denom             | `gauge`        | Hidden behind "Advanced" by default  |
| A trend over time     | 1 datetime + 1 numeric + opt. label   | `line`         | Becomes `area` if user toggles fill  |
| A breakdown           | 1 category + 1 numeric                | `bar`          | Becomes `pie` only behind "Advanced" |
| A comparison          | 2 categories + 1 numeric              | `pivot` or `stacked_bar` | Picked by cardinality      |
| A pivot / cross-tab   | 2 dimensions + 1 numeric aggregate    | `pivot`        | Analyst workflow for rows x columns slicing |
| A list                | any fields, ≥1 row                    | `table`        | Default if user hasn't decided       |
| A status grid         | 1 category + 1 status field           | `status_list`  | Auto-suggested when `status` present |

When the user picks fields, the system suggests the intent ("Looks like you want a trend over time — switch?"). Power users can override via the Advanced toggle and pick any visual that's compatible with the selected fields.

**Incompatible bindings are unreachable, not silently broken.** If the user picks a string field for "value" on a stat, the field doesn't appear in the dropdown — there's no "save broken config" path.

## What goes away

- **All visible JSON.** Variables get a key-value editor with typed inputs. Field bindings are dropdowns over the sample schema. Trend comparisons are picker UIs. The only place JSON survives is the underlying storage format.
- **The "Visual first" Inspector** is replaced by "Show me" intent + structured field pickers driven by the sample schema.
- **One-panel-equals-one-query** assumption goes. Panels reference outputs; outputs reference a shared source query. Saving a dashboard saves the source queries once and the outputs as derived nodes.
- **The "edit panel" modal** disappears in favor of always-visible inspector cards in step 2.

## Data model changes

Server side, the existing `AuthoredDashboard` + `AuthoredPanel` resources need to grow (or be supplemented by) a `SourceQuery` concept:

```
AuthoredDashboard ──┐
                    ├── AuthoredPanel (position, size, output_id)
                    │
                    └── SourceQuery (srql, sample cache)
                         └── Output (source_query_id, field_bindings, visual_type, title)
```

Migration path:
- Existing panels (one query each) keep working untouched.
- New panels created via the new builder write a `SourceQuery` row + an `Output` row + an `AuthoredPanel` row.
- A migration job can optionally "lift" existing panels by grouping panels that share an identical SRQL query into a single `SourceQuery` + N `Output`s, but this is opt-in and not required for v1.

Storage cost is small: sample rows for a `SourceQuery` are cached server-side (TTL 5 min) and only persisted as part of the *draft* state, not the saved dashboard. Saved dashboards re-run their source query at view time, same as today.

## Coexistence with the current builder

Two paths:

1. **New mode behind a flag.** Add `?mode=guided` to the existing builder route. Default for new dashboards switches to guided after a few weeks of dogfooding. Legacy mode stays for power users until parity.
2. **Replace, with a "drop to advanced" escape hatch.** Make the new flow the default; expose a single "Switch to legacy editor" link for users who hit a workflow the new builder can't yet express.

Recommend (1) initially. Cheaper to ship, easier to roll back if user testing surfaces issues.

## What this fixes, concretely

- **No more guessing field shapes.** Sample rows are step 1; binding pickers in step 2 only show compatible fields.
- **One query → many panels.** Output-as-a-concept eliminates the "duplicate the query and tweak" pattern.
- **No JSON anywhere user-facing.** Every JSON textarea has a structured replacement.
- **Errors surface where they originate.** Query errors in step 1; binding errors are unreachable by construction in step 2; layout has no errors.
- **Live preview throughout.** Sample rows in step 1, output preview in step 2, dashboard preview in step 3.

## Open questions

1. **Where do variables fit?** Currently variables substitute into the SRQL string. In the new model they could attach to a `SourceQuery` (one set of variables shared across outputs) or to individual outputs. Recommend attach to `SourceQuery` — the natural granularity.
2. **Can a single output span multiple source queries?** E.g., a stat that's "this week's count / last week's count" needs two queries. Suggest deferring multi-query outputs to v2 and using SRQL's own `time:` shifting for the simple "compare to previous window" case in v1.
3. **How does the user discover SRQL?** The query box needs strong inline help — "what entities can I query?" → entity list dropdown; "what fields does `in:devices` have?" → field reference panel. Today this is partially done via Monaco completion; the new flow should expose it more prominently.
4. **What about ad-hoc filters at view time?** Existing dashboards have variable substitution. Need to confirm whether the new builder's `SourceQuery` plays well with the existing variable token model (probably yes — it's the same string substitution under the hood).
5. **Naming.** "Output" vs "Tile" vs "Card" vs "View". The data model needs a name; "Output" is fine internally but UI copy should be tested.

## Next steps

1. **Validate the flow with two or three users** — sketch the three steps on paper or in Figma, walk through building a "device overview" dashboard. Confirm the mental model lands.
2. **Convert to an OpenSpec proposal** (`openspec/changes/dashboard-builder-query-first/`) once the flow is locked. Spec needs to cover: new resources (`SourceQuery`, `Output`), API changes, UI routes, deprecation timeline for the legacy builder.
3. **Prototype step 1 in isolation** — the query → sample data loop is the foundation. If it doesn't feel fast (<200ms for typical queries), the rest of the flow won't recover.
4. **Audit the JSON inputs we have today** — list every textarea/input that takes JSON in the current builder; each one needs a structured replacement before the new builder can ship.
