import React, {useEffect, useRef} from "../../node_modules/react/index.js"
import {GridStack} from "gridstack"

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

function numericValue(value) {
  const next = Number(value)
  return Number.isFinite(next) ? next : null
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

function MiniVisual({panel}) {
  const rows = panelRows(panel)
  const fields = panelFields(panel)
  const binding = panel.data_binding || {}
  const visual = String(panel.visual_type || "table")

  if (["stat", "count", "gauge", "availability"].includes(visual)) {
    const valueField = binding.value_field || binding.numerator_field || firstField(fields, "number")
    const raw = numericValue(valueAt(rows[0], valueField)) || 0
    const unit = panel.display_config?.unit || (["gauge", "availability"].includes(visual) ? "%" : "")

    return (
      <div className="flex h-full flex-col justify-center gap-2">
        <div className="text-3xl font-semibold tracking-normal">
          {raw}
          <span className="text-base text-base-content/65">{unit}</span>
        </div>
        <div className="truncate text-xs text-base-content/70">{panel.display_config?.label || valueField || "Value"}</div>
        {["gauge", "availability"].includes(visual) ? (
          <div className="h-2 overflow-hidden rounded-full bg-base-300">
            <div className="h-full rounded-full bg-primary" style={{width: `${Math.max(0, Math.min(raw, 100))}%`}} />
          </div>
        ) : null}
      </div>
    )
  }

  if (visual === "pivot") {
    const rowField = binding.row_field || firstField(fields, "string")
    const columnField = binding.column_field || fields.find(field => ["status", "state", "health"].includes(field.name))?.name

    return (
      <div className="overflow-hidden rounded border border-base-300">
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
                <td title={displayTitle(valueAt(row, rowField))}>{displayValue(valueAt(row, rowField))}</td>
                <td title={displayTitle(valueAt(row, columnField))}>{displayValue(valueAt(row, columnField))}</td>
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
      <div className="flex h-24 items-end gap-1">
        {values.slice(0, 16).map((value, index) => (
          <div
            key={index}
            className="min-w-2 flex-1 rounded-t bg-primary/70"
            style={{height: `${Math.max(8, (value / max) * 100)}%`}}
          />
        ))}
      </div>
    )
  }

  return (
    <div className="overflow-hidden rounded border border-base-300">
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
                  <td key={field.name} className="max-w-44 truncate" title={displayTitle(value)}>
                    {displayValue(value)}
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

export default function DashboardBuilderCanvas({
  panels = [],
  visualOptions = [],
  selectedId = "",
  canManage = false,
  pushEvent = () => {},
}) {
  const gridRef = useRef(null)
  const gridInstance = useRef(null)
  const syncingRef = useRef(false)

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
    const ids = new Set(panels.map(panel => panel.id))
    syncingRef.current = true
    grid.getGridItems().forEach(item => {
      if (!ids.has(item.dataset.panelId)) {
        grid.removeWidget(item, false)
      }
    })

    grid.batchUpdate()
    panels.forEach((panel, index) => {
      const item = gridRef.current.querySelector(`[data-panel-id="${escapeSelector(panel.id)}"]`)
      if (!item) return
      const layout = normalizeLayout(panel, index)
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
  }, [panels, canManage, pushEvent])

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
    <div className="grid min-h-[560px] grid-cols-1 gap-4 xl:grid-cols-[240px_minmax(0,1fr)]">
      <aside className="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
        <div className="mb-3">
          <div className="text-xs font-semibold uppercase tracking-normal text-primary">Workbench</div>
          <div className="mt-1 text-lg font-semibold tracking-normal">Visualization Palette</div>
          <p className="mt-2 text-xs leading-5 text-base-content/60">
            Start with a visual type. The SRQL preview will narrow choices and field mappings before the panel can be saved.
          </p>
        </div>
        <div className="grid grid-cols-2 gap-2 xl:grid-cols-1">
          {visualOptions.map(option => (
            <button
              key={option.type}
              type="button"
              className="btn btn-sm justify-start rounded-md"
              disabled={!canManage}
              onClick={() => pushEvent("canvas_add_panel", {visualType: option.type})}
            >
              {option.label || VISUAL_LABELS[option.type] || option.type}
            </button>
          ))}
        </div>
        <div className="mt-4 rounded-md border border-base-300 bg-base-200/45 p-3">
          <div className="flex items-center justify-between gap-2 text-xs">
            <span className="text-base-content/70">Panels</span>
            <span className="font-mono font-semibold">{panels.length}</span>
          </div>
          <div className="mt-2 flex items-center justify-between gap-2 text-xs">
            <span className="text-base-content/70">Selected</span>
            <span className="truncate font-mono font-semibold">
              {selectedPanel?.title || "None"}
            </span>
          </div>
          <div className="mt-2 flex items-center justify-between gap-2 text-xs">
            <span className="text-base-content/70">Layout</span>
            <span className="font-mono font-semibold">{canManage ? "Editable" : "Read only"}</span>
          </div>
        </div>
      </aside>

      <main className="rounded-lg border border-base-300 bg-base-200/40 p-4 shadow-sm">
        <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
          <div>
            <div className="text-lg font-semibold tracking-normal">Dashboard Canvas</div>
            <p className="text-xs text-base-content/70">
              Drag panels by their header, resize from the edges, and click a panel to open its composer.
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            {selectedPanel ? (
              <span className="badge badge-primary badge-outline max-w-72 truncate">
                Editing {selectedPanel.title}
              </span>
            ) : null}
            <span className="badge badge-outline">{panels.length} panels</span>
          </div>
        </div>
        <div className="relative min-h-[500px] rounded-lg border border-base-300 bg-base-100 p-2">
          <div ref={gridRef} className="grid-stack min-h-[500px]">
            {panels.map((panel, index) => {
              const layout = normalizeLayout(panel, index)
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
                    className={`grid-stack-item-content group overflow-hidden rounded-lg border bg-base-100 shadow-sm transition-shadow hover:shadow-md ${selected ? "border-primary ring-1 ring-primary/30" : "border-base-300"}`}
                    onClick={() => pushEvent("canvas_select_panel", {id: panel.id})}
                  >
                    <div className="sr-dashboard-canvas-drag-handle flex cursor-move select-none items-center justify-between gap-2 border-b border-base-300 px-3 py-2">
                      <div className="min-w-0">
                        <div className="flex min-w-0 items-center gap-2">
                          <div className="truncate text-sm font-semibold">{panel.title}</div>
                          {panel.refresh_interval_seconds > 0 ? (
                            <span className="badge badge-xs badge-outline shrink-0">
                              {panel.refresh_interval_seconds}s
                            </span>
                          ) : null}
                        </div>
                        {!compact ? (
                          <button
                            type="button"
                            className="mt-1 max-w-full truncate rounded border border-base-300 bg-base-200 px-1.5 py-0.5 text-left font-mono text-[11px] text-primary"
                            title="Open panel composer"
                            onClick={event => stopAndRun(event, () => pushEvent("canvas_select_panel", {id: panel.id}))}
                          >
                            {panel.srql_query || "No SRQL query yet"}
                          </button>
                        ) : null}
                      </div>
                      <div className="flex shrink-0 items-center gap-1">
                        <span className="badge badge-xs badge-outline">{VISUAL_LABELS[panel.visual_type] || panel.visual_type}</span>
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
                      <MiniVisual panel={panel} />
                    </div>
                  </div>
                </div>
              )
            })}
          </div>
          {panels.length === 0 ? (
            <div className="pointer-events-none absolute inset-3 flex items-center justify-center rounded-lg border border-dashed border-base-300 text-center text-sm text-base-content/60">
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
