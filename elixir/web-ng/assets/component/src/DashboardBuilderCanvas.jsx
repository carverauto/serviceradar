import React, {useEffect, useMemo, useRef, useState} from "react"
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

function displayValue(value) {
  if (value === null || value === undefined || value === "") return "—"
  if (typeof value === "object") return JSON.stringify(value)
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
          <span className="text-base text-base-content/50">{unit}</span>
        </div>
        <div className="truncate text-xs text-base-content/55">{panel.display_config?.label || valueField || "Value"}</div>
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
                <td>{displayValue(valueAt(row, rowField))}</td>
                <td>{displayValue(valueAt(row, columnField))}</td>
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
              {fields.slice(0, 4).map(field => <td key={field.name}>{displayValue(valueAt(row, field.name))}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function Inspector({panel, visualOptions, defaultQuery, onApply, onRemove}) {
  const [draft, setDraft] = useState(() => draftFromPanel(panel, defaultQuery))

  useEffect(() => {
    setDraft(draftFromPanel(panel, defaultQuery))
  }, [panel, defaultQuery])

  if (!panel) {
    return (
      <div className="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60">
        Select a panel on the canvas, or add one from the palette.
      </div>
    )
  }

  const update = (key, value) => setDraft(current => ({...current, [key]: value}))

  return (
    <div className="space-y-3">
      <label className="form-control">
        <span className="label-text text-xs">Title</span>
        <input className="input input-sm w-full" value={draft.panel_title} onChange={event => update("panel_title", event.target.value)} />
      </label>
      <label className="form-control">
        <span className="label-text text-xs">Dataset key</span>
        <input className="input input-sm w-full" value={draft.dataset_key} onChange={event => update("dataset_key", event.target.value)} />
      </label>
      <label className="form-control">
        <span className="label-text text-xs">Visual</span>
        <select className="select select-sm w-full" value={draft.visual_type} onChange={event => update("visual_type", event.target.value)}>
          {visualOptions.map(option => (
            <option key={option.type} value={option.type}>{option.label || VISUAL_LABELS[option.type] || option.type}</option>
          ))}
        </select>
      </label>
      <label className="form-control">
        <span className="label-text text-xs">SRQL query</span>
        <textarea
          className="textarea textarea-sm min-h-28 w-full font-mono"
          value={draft.srql_query}
          onChange={event => update("srql_query", event.target.value)}
        />
      </label>
      <label className="form-control">
        <span className="label-text text-xs">Unit</span>
        <input className="input input-sm w-full" value={draft.unit} onChange={event => update("unit", event.target.value)} />
      </label>
      <label className="form-control">
        <span className="label-text text-xs">Trend SRQL</span>
        <textarea
          className="textarea textarea-sm min-h-20 w-full font-mono"
          value={draft.trend_query}
          onChange={event => update("trend_query", event.target.value)}
        />
      </label>
      <div className="flex gap-2">
        <button type="button" className="btn btn-sm btn-primary" onClick={() => onApply(panel.id, draft)}>
          Apply
        </button>
        <button type="button" className="btn btn-sm btn-error btn-outline" onClick={() => onRemove(panel.id)}>
          Remove
        </button>
      </div>
    </div>
  )
}

function draftFromPanel(panel, defaultQuery) {
  return {
    dataset_key: panel?.dataset_key || "primary",
    panel_title: panel?.title || "Panel",
    srql_query: panel?.srql_query || defaultQuery || "",
    visual_type: String(panel?.visual_type || "table"),
    unit: panel?.display_config?.unit || "",
    trend_query: panel?.trend_query || panel?.visual_config?.trend_query || "",
  }
}

export default function DashboardBuilderCanvas({
  panels = [],
  visualOptions = [],
  selectedId = "",
  canManage = false,
  defaultQuery = "",
  pushEvent = () => {},
}) {
  const gridRef = useRef(null)
  const gridInstance = useRef(null)
  const panelsById = useMemo(() => new Map(panels.map(panel => [panel.id, panel])), [panels])
  const selectedPanel = panelsById.get(selectedId) || panels[0] || null

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

      gridInstance.current.on("change", (_event, items) => {
        pushEvent("canvas_layout_change", {
          layouts: items
            .map(item => ({
              id: item.el?.dataset.panelId,
              x: item.x,
              y: item.y,
              w: item.w,
              h: item.h,
            }))
            .filter(item => item.id),
        })
      })
    }

    const grid = gridInstance.current
    const ids = new Set(panels.map(panel => panel.id))
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
    grid.commit()

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

  return (
    <div className="grid min-h-[520px] grid-cols-1 gap-4 xl:grid-cols-[220px_minmax(0,1fr)_320px]">
      <aside className="rounded-lg border border-base-300 bg-base-100 p-3">
        <div className="mb-3 text-sm font-semibold">Palette</div>
        <div className="grid grid-cols-2 gap-2 xl:grid-cols-1">
          {visualOptions.map(option => (
            <button
              key={option.type}
              type="button"
              className="btn btn-sm justify-start"
              disabled={!canManage}
              onClick={() => pushEvent("canvas_add_panel", {visualType: option.type})}
            >
              {option.label || VISUAL_LABELS[option.type] || option.type}
            </button>
          ))}
        </div>
      </aside>

      <main className="rounded-lg border border-base-300 bg-base-200/40 p-3">
        <div ref={gridRef} className="grid-stack min-h-[480px]">
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
                  className={`grid-stack-item-content rounded-lg border bg-base-100 shadow-sm ${selected ? "border-primary" : "border-base-300"}`}
                  onClick={() => pushEvent("canvas_select_panel", {id: panel.id})}
                >
                  <div className="sr-dashboard-canvas-drag-handle flex cursor-move items-center justify-between gap-2 border-b border-base-300 px-3 py-2">
                    <div className="min-w-0">
                      <div className="truncate text-sm font-semibold">{panel.title}</div>
                      {!compact ? (
                        <div className="truncate font-mono text-[11px] text-base-content/45">{panel.srql_query}</div>
                      ) : null}
                    </div>
                    <span className="badge badge-xs badge-outline">{VISUAL_LABELS[panel.visual_type] || panel.visual_type}</span>
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
          <div className="flex min-h-[480px] items-center justify-center rounded-lg border border-dashed border-base-300 text-sm text-base-content/60">
            Add a visualization from the palette to start building the dashboard.
          </div>
        ) : null}
      </main>

      <aside className="rounded-lg border border-base-300 bg-base-100 p-3">
        <div className="mb-3 text-sm font-semibold">Inspector</div>
        <Inspector
          panel={selectedPanel}
          visualOptions={visualOptions}
          defaultQuery={defaultQuery}
          onApply={(id, draft) => pushEvent("canvas_update_panel", {id, panel: draft})}
          onRemove={id => pushEvent("remove_panel", {id})}
        />
      </aside>
    </div>
  )
}
