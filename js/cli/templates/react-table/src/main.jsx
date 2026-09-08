import React, {useMemo, useState} from "react"
import {mountReactDashboard, useFilterState, useFrameRows} from "@carverauto/serviceradar-dashboard-sdk/react"

const PAGE_SIZE = 25

const ROW_SHAPE = Object.freeze({
  device_id: "device_id",
  name: "name",
  site_code: "site_code",
  status: (row) => String(row.status || "").toLowerCase(),
  model: "model",
  last_seen: "last_seen",
})

function Dashboard() {
  const rows = useFrameRows("rows", {decode: "auto", shape: ROW_SHAPE})
  const filters = useFilterState({
    initialState: {search: "", statusOnly: ""},
    debounceMs: 250,
    debounceFields: ["search"],
  })
  const [page, setPage] = useState(0)

  const visible = useMemo(() => {
    const search = filters.debouncedState.search.trim().toLowerCase()
    const status = filters.state.statusOnly
    return rows.filter((row) => {
      if (status && row.status !== status) return false
      if (!search) return true
      return Object.values(row).some((value) => String(value ?? "").toLowerCase().includes(search))
    })
  }, [rows, filters.debouncedState.search, filters.state.statusOnly])

  const pageStart = page * PAGE_SIZE
  const pageRows = visible.slice(pageStart, pageStart + PAGE_SIZE)
  const totalPages = Math.max(1, Math.ceil(visible.length / PAGE_SIZE))

  return (
    <main style={{padding: 24, fontFamily: "ui-sans-serif, system-ui, sans-serif", maxWidth: 1100}}>
      <header style={{display: "flex", gap: 12, alignItems: "center", marginBottom: 16}}>
        <h1 style={{margin: 0, fontSize: 22}}>__DASHBOARD_TITLE__</h1>
        <input
          type="search"
          placeholder="Search rows…"
          value={filters.state.search}
          onChange={(event) => filters.setFilter("search", event.target.value)}
          style={{flex: 1, padding: "6px 10px", border: "1px solid #d1d5db", borderRadius: 6}}
        />
        <select
          value={filters.state.statusOnly}
          onChange={(event) => filters.setFilter("statusOnly", event.target.value)}
          style={{padding: "6px 10px", border: "1px solid #d1d5db", borderRadius: 6}}
        >
          <option value="">All statuses</option>
          <option value="up">Up</option>
          <option value="down">Down</option>
        </select>
      </header>
      <p style={{color: "#6b7280", marginTop: 0}}>
        {visible.length.toLocaleString()} rows ({rows.length.toLocaleString()} total)
      </p>
      <table style={{width: "100%", borderCollapse: "collapse"}}>
        <thead>
          <tr style={{textAlign: "left", borderBottom: "1px solid #d1d5db"}}>
            <th style={{padding: 8}}>Device</th>
            <th style={{padding: 8}}>Site</th>
            <th style={{padding: 8}}>Status</th>
            <th style={{padding: 8}}>Model</th>
            <th style={{padding: 8}}>Last seen</th>
          </tr>
        </thead>
        <tbody>
          {pageRows.map((row) => (
            <tr key={row.device_id} style={{borderBottom: "1px solid #f3f4f6"}}>
              <td style={{padding: 8}}>
                <strong>{row.name || row.device_id}</strong>
                <div style={{fontSize: 11, color: "#9ca3af"}}>{row.device_id}</div>
              </td>
              <td style={{padding: 8}}>{row.site_code}</td>
              <td style={{padding: 8, color: row.status === "down" ? "#dc2626" : "#16a34a"}}>{row.status}</td>
              <td style={{padding: 8}}>{row.model}</td>
              <td style={{padding: 8, color: "#6b7280"}}>{row.last_seen}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <footer style={{display: "flex", gap: 8, justifyContent: "flex-end", marginTop: 12}}>
        <button type="button" onClick={() => setPage((value) => Math.max(0, value - 1))} disabled={page === 0}>
          Prev
        </button>
        <span style={{padding: "0 8px"}}>{page + 1} / {totalPages}</span>
        <button type="button" onClick={() => setPage((value) => Math.min(totalPages - 1, value + 1))} disabled={page + 1 >= totalPages}>
          Next
        </button>
      </footer>
    </main>
  )
}

export const mountDashboard = mountReactDashboard(Dashboard)
export default mountDashboard
