import React, {useEffect, useMemo, useRef} from "react"
import {GridStack} from "gridstack"

import {canonicalUtcInstant, formatUserTime} from "../../js/utils/user_time"

const DEFAULT_TIME_ZONE = "Etc/UTC"

const VISUAL_LABELS = {
  table: "Table",
  stat: "Stat",
  count: "Count",
  gauge: "Gauge",
  availability: "Availability",
  line: "Line",
  area: "Area",
  bar: "Bar",
  category: "Category",
  status_list: "Status List",
  pivot: "Pivot Table",
}

function escapeSelector(value) {
  if (window.CSS?.escape) return window.CSS.escape(value)
  return String(value).replace(/["\\]/g, "\\$&")
}

function normalizeLayout(panel, index) {
  const layout = panel.layout || {}

  return {
    x: Number.isFinite(Number(layout.x)) ? Number(layout.x) : defaultX(panel, index),
    y: Number.isFinite(Number(layout.y)) ? Number(layout.y) : Math.floor(index / 3) * 4,
    w: Number.isFinite(Number(layout.w)) ? Number(layout.w) : defaultWidth(panel.visual_type),
    h: Number.isFinite(Number(layout.h)) ? Number(layout.h) : defaultHeight(panel.visual_type),
  }
}

function normalizedPanelEntries(panels) {
  const entries = panels.map((panel, index) => ({panel, layout: normalizeLayout(panel, index)}))
  const lastRow = Math.max(...entries.map(entry => entry.layout.y), 0)
  const lastRowEntries = entries.filter(entry => entry.layout.y === lastRow)

  if (lastRowEntries.length !== 1) return entries

  const orphan = lastRowEntries[0]
  if (orphan.layout.w >= 12) return entries

  return entries.map(entry =>
    entry.panel.id === orphan.panel.id
      ? {...entry, layout: {...entry.layout, x: 0, w: 12, autoFilled: true}}
      : entry,
  )
}

function defaultWidth(visualType) {
  if (["table", "pivot", "line", "area"].includes(String(visualType))) return 12
  if (String(visualType) === "status_list") return 8
  return 4
}

function defaultHeight(visualType) {
  if (["table", "pivot"].includes(String(visualType))) return 8
  if (["line", "area", "bar", "category"].includes(String(visualType))) return 6
  return 4
}

function defaultX(panel, index) {
  const width = defaultWidth(panel.visual_type)
  if (width >= 12) return 0
  return (index * width) % 12
}

function valueAt(row, field) {
  if (!row || !field) return null
  return row[field]
}

function parseJsonValue(value) {
  if (typeof value !== "string") return null
  const trimmed = value.trim()
  if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) return null

  try {
    const parsed = JSON.parse(trimmed)
    return parsed && typeof parsed === "object" ? parsed : null
  } catch (_error) {
    return null
  }
}

function structuredSummary(value) {
  const parsed = parseJsonValue(value)
  const next = parsed || value

  if (Array.isArray(next)) {
    return `${next.length} ${next.length === 1 ? "item" : "items"}`
  }

  if (next && typeof next === "object") {
    const keys = Object.keys(next)
    if (keys.length === 0) return "0 fields"
    const visible = keys.slice(0, 3).join(", ")
    const extra = keys.length > 3 ? ` +${keys.length - 3}` : ""
    return `${keys.length} ${keys.length === 1 ? "field" : "fields"}: ${visible}${extra}`
  }

  return null
}

function displayValue(value) {
  if (value === null || value === undefined || value === "") return "—"
  const summary = structuredSummary(value)
  if (summary) return summary
  return String(value)
}

function displayTitle(value) {
  if (value === null || value === undefined || value === "") return "No value"
  const parsed = parseJsonValue(value)
  const next = parsed || value
  if (next && typeof next === "object") return JSON.stringify(next)
  return String(value)
}

function displayTimeZone(timezone) {
  return typeof timezone === "string" && timezone.trim() !== ""
    ? timezone
    : DEFAULT_TIME_ZONE
}

function fieldMetadata(fields, name) {
  return fields.find(field => field.name === name) || null
}

function datetimeField(field) {
  return String(field?.type || "").toLowerCase() === "datetime"
}

function cellTitle(value, field) {
  return datetimeField(field) && canonicalUtcInstant(value) ? undefined : displayTitle(value)
}

function MiniValue({value, field, timezone}) {
  const canonical = datetimeField(field) ? canonicalUtcInstant(value) : null
  if (!canonical) return displayValue(value)

  const displayZone = displayTimeZone(timezone)
  const text = formatUserTime(canonical, {timeZone: displayZone, style: "full"})?.text || canonical
  const title = `${canonical} UTC; display zone ${displayZone}`
  const ariaLabel = `${text}; display zone ${displayZone}; canonical UTC ${canonical}`

  return (
    <time
      dateTime={canonical}
      data-user-time-zone={displayZone}
      data-user-time-style="full"
      title={title}
      aria-label={ariaLabel}
    >
      {text}
    </time>
  )
}

function numericValue(value) {
  const next = Number(value)
  return Number.isFinite(next) ? next : null
}

function booleanish(value) {
  if (value === true || value === "true") return true
  if (value === false || value === "false") return false
  return null
}

function countLabel(count, singular, plural = `${singular}s`) {
  return Number(count) === 1 ? singular : plural
}

function entityLabel(panel, fallback = "item") {
  const source = panel.display_config?.entity_label || panel.display_config?.noun || panel.srql_query || ""
  const match = String(source).match(/\bin:([a-zA-Z_][\w-]*)/u)
  const entity = match?.[1]

  if (!entity) return fallback
  if (entity.endsWith("ies")) return entity.slice(0, -3) + "y"
  if (entity.endsWith("s")) return entity.slice(0, -1)
  return entity
}

function panelFields(panel) {
  return panel.preview?.fields || panel.field_metadata?.fields || []
}

function panelRows(panel) {
  return panel.preview?.rows || []
}

function firstField(fields, type) {
  return fields.find(field => field.type === type)?.name || fields[0]?.name || null
}

function groupedAvailability(rows, valueField, labelField) {
  if (!valueField || !labelField) return null

  const normalizedLabel = String(labelField).toLowerCase()
  if (!["is_available", "available", "availability"].includes(normalizedLabel)) return null

  let numerator = 0
  let denominator = 0
  let matched = false

  rows.forEach(row => {
    const value = numericValue(valueAt(row, valueField))
    const available = booleanish(valueAt(row, labelField))

    if (value === null || available === null) return

    matched = true
    denominator += value
    if (available) numerator += value
  })

  return matched ? {numerator, denominator} : null
}

function MiniVisual({panel, timezone = DEFAULT_TIME_ZONE}) {
  const rows = panelRows(panel)
  const fields = panelFields(panel)
  const binding = panel.data_binding || {}
  const visual = String(panel.visual_type || "table")

  if (["stat", "count", "gauge", "availability"].includes(visual)) {
    const valueField = binding.value_field || binding.numerator_field || firstField(fields, "number")
    const labelField = binding.label_field || binding.row_field || firstField(fields, "string")
    const denominatorField = binding.denominator_field || fields.find(field => ["total", "count"].includes(field.name))?.name
    const availability = groupedAvailability(rows, valueField, labelField)
    const raw = availability?.numerator ?? numericValue(valueAt(rows[0], valueField)) ?? 0
    const denominator = availability?.denominator ?? numericValue(valueAt(rows[0], denominatorField))
    const displayValue =
      ["gauge", "availability"].includes(visual) && denominator > 0
        ? Math.max(0, Math.min(100, (raw / denominator) * 100)).toFixed(1)
        : raw
    const unit = panel.display_config?.unit || (["gauge", "availability"].includes(visual) ? "%" : "")
    const label = panel.display_config?.label || (visual === "availability" ? "Availability" : valueField || "Value")

    return (
      <div className="flex h-full min-h-0 flex-col justify-center gap-1.5 overflow-hidden">
        <div className="flex min-w-0 items-baseline gap-2">
          <div className="shrink-0 text-2xl font-semibold tracking-normal text-slate-100">
            {displayValue}
            <span className="text-sm text-slate-400">{unit}</span>
          </div>
          <div className="min-w-0 truncate text-xs text-slate-400">{label}</div>
        </div>
        {denominator > 0 && ["gauge", "availability"].includes(visual) ? (
          <div className="truncate text-[11px] text-slate-500">
            {visual === "availability" ? `${raw} of ${denominator} ${countLabel(denominator, entityLabel(panel))} available` : `${raw} of ${denominator}`}
          </div>
        ) : null}
        {["gauge", "availability"].includes(visual) ? (
          <div className="h-2 overflow-hidden rounded-full bg-slate-800">
            <div className="h-full rounded-full bg-cyan-400" style={{width: `${Math.max(0, Math.min(Number(displayValue), 100))}%`}} />
          </div>
        ) : null}
      </div>
    )
  }

  if (visual === "pivot") {
    const rowField = binding.row_field || firstField(fields, "string")
    const columnField = binding.column_field || fields.find(field => ["status", "state", "health"].includes(field.name))?.name
    const rowMetadata = fieldMetadata(fields, rowField)
    const columnMetadata = fieldMetadata(fields, columnField)

    return (
      <div className="overflow-hidden rounded border border-slate-800">
        <table className="table table-xs">
          <thead>
            <tr>
              <th>{rowField || "row"}</th>
              <th>{columnField || "column"}</th>
            </tr>
          </thead>
          <tbody>
            {rows.slice(0, 3).map((row, index) => (
              <tr key={index}>
                <td title={cellTitle(valueAt(row, rowField), rowMetadata)}>
                  <MiniValue value={valueAt(row, rowField)} field={rowMetadata} timezone={timezone} />
                </td>
                <td title={cellTitle(valueAt(row, columnField), columnMetadata)}>
                  <MiniValue value={valueAt(row, columnField)} field={columnMetadata} timezone={timezone} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    )
  }

  if (["line", "area", "bar", "category"].includes(visual)) {
    const valueField = binding.value_field || firstField(fields, "number")
    const values = rows.map(row => numericValue(valueAt(row, valueField)) || 0)
    const max = Math.max(...values, 1)

    return (
      <div className="flex h-full min-h-0 items-end gap-1 overflow-hidden">
        {values.slice(0, 16).map((value, index) => (
          <div
            key={index}
            className="min-w-2 flex-1 rounded-t bg-cyan-400/80"
            style={{height: `${Math.max(8, (value / max) * 100)}%`}}
          />
        ))}
      </div>
    )
  }

  return (
    <div className="overflow-hidden rounded border border-slate-800">
      <table className="table table-xs">
        <thead>
          <tr>{fields.slice(0, 4).map(field => <th key={field.name}>{field.name}</th>)}</tr>
        </thead>
        <tbody>
          {rows.slice(0, 4).map((row, index) => (
            <tr key={index}>
              {fields.slice(0, 4).map(field => {
                const value = valueAt(row, field.name)

                return (
                  <td key={field.name} className="max-w-44 truncate" title={cellTitle(value, field)}>
                    <MiniValue value={value} field={field} timezone={timezone} />
                  </td>
                )
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function stopAndRun(event, callback) {
  event.stopPropagation()
  callback()
}

export function Component({
  panels = [],
  visualOptions = [],
  selectedId = "",
  canManage = false,
  timezone = DEFAULT_TIME_ZONE,
  pushEvent = () => {},
}) {
  const gridRef = useRef(null)
  const gridInstance = useRef(null)
  const syncingRef = useRef(false)
  const panelEntries = useMemo(() => normalizedPanelEntries(panels), [panels])

  useEffect(() => {
    if (!gridRef.current) return

    if (!gridInstance.current) {
      gridInstance.current = GridStack.init(
        {
          column: 12,
          cellHeight: 38,
          margin: 8,
          float: true,
          animate: true,
          disableDrag: !canManage,
          disableResize: !canManage,
          draggable: {handle: ".sr-dashboard-canvas-drag-handle"},
          resizable: {handles: "e,se,s,sw,w"},
        },
        gridRef.current,
      )

      gridInstance.current.on("change", (_event, _items) => {
        if (syncingRef.current) return

        pushEvent("canvas_layout_change", {
          layouts: gridInstance.current
            .getGridItems()
            .map(item => ({
              id: item.dataset.panelId,
              x: item.gridstackNode?.x,
              y: item.gridstackNode?.y,
              w: item.gridstackNode?.w,
              h: item.gridstackNode?.h,
            }))
            .filter(item => item.id),
        })
      })
    }

    const grid = gridInstance.current
    const ids = new Set(panelEntries.map(entry => entry.panel.id))
    syncingRef.current = true
    grid.getGridItems().forEach(item => {
      if (!ids.has(item.dataset.panelId)) {
        grid.removeWidget(item, false)
      }
    })

    grid.batchUpdate()
    panelEntries.forEach(({panel, layout}) => {
      const item = gridRef.current.querySelector(`[data-panel-id="${escapeSelector(panel.id)}"]`)
      if (!item) return
      if (!item.gridstackNode) {
        grid.makeWidget(item)
      }
      grid.update(item, layout)
    })
    grid.batchUpdate(false)
    window.requestAnimationFrame(() => {
      syncingRef.current = false
    })

    return undefined
  }, [panelEntries, canManage, pushEvent])

  useEffect(() => {
    if (!gridInstance.current) return
    gridInstance.current.enableMove(canManage)
    gridInstance.current.enableResize(canManage)
  }, [canManage])

  useEffect(() => {
    return () => {
      if (gridInstance.current) {
        gridInstance.current.destroy(false)
        gridInstance.current = null
      }
    }
  }, [])

  const selectedPanel = panels.find(panel => panel.id === selectedId)

  return (
    <div className="grid min-h-[560px] grid-cols-1 gap-4 text-slate-100 xl:grid-cols-[240px_minmax(0,1fr)]">
      <aside className="rounded-lg border border-slate-800/80 bg-[#0b1220]/95 p-4 shadow-xl shadow-cyan-950/10 backdrop-blur-md">
        <div className="mb-3">
          <div className="text-xs font-semibold uppercase tracking-normal text-cyan-400">Workbench</div>
          <div className="mt-1 text-lg font-semibold tracking-normal">Layout Canvas</div>
          <p className="mt-2 text-xs leading-5 text-slate-400">
            Run a source query above, add compatible outputs, then place or resize them here.
          </p>
        </div>
        <div className="rounded-md border border-slate-800 bg-slate-950/60 p-3">
          <div className="text-xs font-semibold uppercase tracking-normal text-slate-400">Advanced</div>
          <p className="mt-1 text-xs leading-5 text-slate-500">
            Custom panels are still available for existing workflows, but new dashboards should start from a source query.
          </p>
          <button
            type="button"
            className="btn btn-sm mt-3 w-full justify-start rounded-md border-slate-800 bg-slate-950/70 text-slate-200 hover:border-cyan-500/40 hover:bg-cyan-950/30"
            disabled={!canManage}
            onClick={() => pushEvent("canvas_add_panel", {visualType: "table"})}
          >
            Add custom panel
          </button>
        </div>
        <div className="mt-4 rounded-md border border-slate-800 bg-slate-950/60 p-3">
          <div className="flex items-center justify-between gap-2 text-xs">
            <span className="text-slate-400">Panels</span>
            <span className="font-mono font-semibold">{panels.length}</span>
          </div>
          <div className="mt-2 flex items-center justify-between gap-2 text-xs">
            <span className="text-slate-400">Selected</span>
            <span className="truncate font-mono font-semibold">
              {selectedPanel?.title || "None"}
            </span>
          </div>
          <div className="mt-2 flex items-center justify-between gap-2 text-xs">
            <span className="text-slate-400">Layout</span>
            <span className="font-mono font-semibold">{canManage ? "Editable" : "Read only"}</span>
          </div>
        </div>
      </aside>

      <main className="rounded-lg border border-slate-800/80 bg-[#0b1220]/80 p-4 shadow-xl shadow-cyan-950/10 backdrop-blur-md">
        <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
          <div>
            <div className="text-lg font-semibold tracking-normal text-slate-100">Dashboard Canvas</div>
            <p className="text-xs text-slate-400">
              Drag panels by their header, resize from the edges, and click a panel to open its composer.
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            {selectedPanel ? (
              <span className="badge badge-outline max-w-72 truncate border-cyan-500/30 text-cyan-300">
                Editing {selectedPanel.title}
              </span>
            ) : null}
            <span className="badge badge-outline border-slate-700 text-slate-300">{panels.length} panels</span>
          </div>
        </div>
        <div className="relative min-h-[500px] rounded-lg border border-slate-800 bg-slate-950/60 p-2">
          <div ref={gridRef} className="grid-stack min-h-[500px]">
            {panelEntries.map(({panel, layout}) => {
              const selected = panel.id === selectedId
              const compact = layout.h <= 4 || layout.w <= 4

              return (
                <div
                  key={panel.id}
                  className="grid-stack-item"
                  data-panel-id={panel.id}
                  gs-x={layout.x}
                  gs-y={layout.y}
                  gs-w={layout.w}
                  gs-h={layout.h}
                >
                  <div
                    className={`grid-stack-item-content group overflow-hidden rounded-lg border bg-[#0f172a]/95 shadow-lg transition-shadow hover:shadow-cyan-950/20 ${selected ? "border-cyan-400 ring-1 ring-cyan-400/30" : "border-slate-800"}`}
                    onClick={() => pushEvent("canvas_select_panel", {id: panel.id})}
                  >
                    <div className="sr-dashboard-canvas-drag-handle flex cursor-move select-none items-center justify-between gap-2 border-b border-slate-800 px-3 py-2">
                      <div className="min-w-0">
                        <div className="flex min-w-0 items-center gap-2">
                          <div className="truncate text-sm font-semibold text-slate-100">{panel.title}</div>
                          {panel.refresh_interval_seconds > 0 ? (
                            <span className="badge badge-xs badge-outline shrink-0">
                              {panel.refresh_interval_seconds}s
                            </span>
                          ) : null}
                          {layout.autoFilled ? (
                            <span className="badge badge-xs border-emerald-500/30 text-emerald-300">
                              full row
                            </span>
                          ) : null}
                        </div>
                        {!compact ? (
                          <button
                            type="button"
                            className="mt-1 max-w-full truncate rounded border border-slate-800 bg-slate-950/70 px-1.5 py-0.5 text-left font-mono text-[11px] text-cyan-300"
                            title="Open panel composer"
                            onClick={event => stopAndRun(event, () => pushEvent("canvas_select_panel", {id: panel.id}))}
                          >
                            {panel.srql_query || "No SRQL query yet"}
                          </button>
                        ) : null}
                      </div>
                      <div className="flex shrink-0 items-center gap-1">
                        <span className="badge badge-xs badge-outline border-cyan-500/30 text-cyan-300">{VISUAL_LABELS[panel.visual_type] || panel.visual_type}</span>
                        {canManage ? (
                          <div className="hidden items-center gap-1 group-hover:flex">
                            <button
                              type="button"
                              className="btn btn-ghost btn-xs"
                              title="Duplicate panel"
                              onClick={event => stopAndRun(event, () => pushEvent("duplicate_panel", {id: panel.id}))}
                            >
                              Copy
                            </button>
                            <button
                              type="button"
                              className="btn btn-ghost btn-xs text-error"
                              title="Delete panel"
                              onClick={event => stopAndRun(event, () => {
                                if (window.confirm(`Delete panel "${panel.title}"?`)) {
                                  pushEvent("delete_panel", {id: panel.id})
                                }
                              })}
                            >
                              Delete
                            </button>
                          </div>
                        ) : null}
                      </div>
                    </div>
                    <div className="h-[calc(100%-48px)] overflow-hidden p-3">
                      <MiniVisual panel={panel} timezone={timezone} />
                    </div>
                  </div>
                </div>
              )
            })}
          </div>
          {panels.length === 0 ? (
            <div className="pointer-events-none absolute inset-3 flex items-center justify-center rounded-lg border border-dashed border-slate-800 text-center text-sm text-slate-500">
              <div>
                <div className="font-semibold">No panels yet</div>
                <div className="mt-1 text-xs">Add a visualization from the palette to start building the dashboard.</div>
              </div>
            </div>
          ) : null}
        </div>
      </main>
    </div>
  )
}

export default Component
