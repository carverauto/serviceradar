import React, {useCallback, useMemo} from "react"
import {
  mountReactDashboard,
  useDashboardTheme,
  useFilterState,
  useFrameRows,
  useIndexedRows,
} from "@carverauto/serviceradar-dashboard-sdk/react"
import {scatter, useDeckLayers, useDeckMap, useScreenLod} from "@carverauto/serviceradar-dashboard-sdk/map"
import {useMapPopup} from "@carverauto/serviceradar-dashboard-sdk/popup"

const SITE_SHAPE = Object.freeze({
  site_code: (row) => String(row.site_code || row.iata || "").toUpperCase(),
  name: (row) => String(row.name || ""),
  region: (row) => String(row.region || "Unknown"),
  longitude: (row) => Number(row.longitude ?? row.lon),
  latitude: (row) => Number(row.latitude ?? row.lat),
  ap_count: (row) => Number(row.ap_count || 0),
})

const INDEX_BY = {region: "region"}
const INITIAL_FILTERS = {regions: [], search: ""}

// Below exitZoom the map draws one marker per cell; at enterZoom it draws each
// site. Between the two it keeps whichever it was already drawing.
const LOD = Object.freeze({enterZoom: 5, exitZoom: 4, radiusPx: 48})
const sitePosition = (site) => [site.longitude, site.latitude]
const siteId = (site) => site.site_code
const sumAps = (members) => ({ap_count: members.reduce((sum, site) => sum + (site.ap_count || 0), 0)})

function MapDashboard() {
  const sites = useFrameRows("sites", {decode: "auto", shape: SITE_SHAPE})
  const dark = useDashboardTheme() === "dark"

  const filters = useFilterState({
    initialState: INITIAL_FILTERS,
    debounceMs: 300,
    debounceFields: ["search"],
  })

  const indexed = useIndexedRows(sites, {indexBy: INDEX_BY, searchText: ["site_code", "name"]})

  const visible = useMemo(() => indexed.applyFilters({
    region: filters.state.regions,
    search: filters.debouncedState.search,
  }), [indexed, filters.state.regions, filters.debouncedState.search])

  const handle = useDeckMap({
    initialViewState: {center: [-98.5, 39.8], zoom: 3.7, bearing: 0, pitch: 0},
    viewportThrottleMs: 120,
  })

  const lod = useScreenLod(visible, {
    ...LOD,
    viewState: handle.viewState,
    getPosition: sitePosition,
    getId: siteId,
    aggregate: sumAps,
  })

  const accessors = useMemo(() => ({
    getPosition: lod.positionOf,
    getRadius: (row) => (lod.isCluster(row)
      ? Math.min(40, 12 + Math.log2(row.__lod_count) * 4)
      : Math.min(36, Math.max(10, 8 + Math.sqrt(row.ap_count || 1) * 0.3))),
  }), [lod.positionOf, lod.isCluster])

  const visualProps = useMemo(() => ({
    pickable: true,
    radiusUnits: "pixels",
    stroked: true,
    filled: true,
    getFillColor: (row) => (row.__lod === "far"
      ? [37, 99, 235, 200]
      : dark ? [17, 24, 39, 232] : [255, 255, 255, 240]),
    getLineColor: [37, 99, 235, 255],
    lineWidthUnits: "pixels",
    getLineWidth: 2,
  }), [dark])

  const [focused, setFocused] = React.useState(null)
  const popup = useMapPopup(handle.map, {closeOnClick: false, offset: 12, onClose: () => setFocused(null)})

  const onSiteClick = useCallback((info) => {
    const row = info?.object
    if (lod.isCluster(row)) {
      setFocused(null)
      handle.flyTo({center: lod.positionOf(row), zoom: lod.enterZoom})
      return
    }
    setFocused(row || null)
  }, [lod, handle])

  useDeckLayers(handle, {
    sites: scatter("sites", {
      data: lod.data,
      accessors,
      visualProps,
      events: {onClick: onSiteClick},
    }),
  })

  React.useEffect(() => {
    if (!focused) { popup.close(); return }
    popup.open({
      coordinates: [focused.longitude, focused.latitude],
      content: (
        <div style={{minWidth: 200}}>
          <strong>{focused.site_code}</strong> · {focused.name}
          <div style={{color: "#6b7280", marginTop: 4}}>{focused.region} · {focused.ap_count.toLocaleString()} APs</div>
        </div>
      ),
    })
  }, [focused, popup])

  const regions = useMemo(() => Array.from(indexed.counts("region").entries())
    .sort((a, b) => Number(b[1]) - Number(a[1])), [indexed])

  const toggleRegion = useCallback((region) => {
    const set = new Set(filters.state.regions)
    if (set.has(region)) set.delete(region)
    else set.add(region)
    filters.setFilter("regions", Array.from(set))
  }, [filters])

  return (
    <div style={{display: "grid", gridTemplateColumns: "1fr 280px", height: "100%", fontFamily: "ui-sans-serif, system-ui, sans-serif"}}>
      <div ref={handle.containerRef} style={{position: "relative"}} />
      <aside style={{borderLeft: "1px solid #e5e7eb", padding: 16, overflow: "auto", background: "#f9fafb"}}>
        <h1 style={{margin: 0, fontSize: 16}}>__DASHBOARD_TITLE__</h1>
        <p style={{color: "#6b7280", marginTop: 4}}>{visible.length.toLocaleString()} of {sites.length.toLocaleString()} sites</p>
        {lod.band === "far" ? (
          <p style={{color: "#6b7280", marginTop: 0, fontSize: 12}}>
            {lod.hidden.toLocaleString()} sites in {lod.data.length.toLocaleString()} groups · zoom in or click a group
          </p>
        ) : null}
        <input
          type="search"
          placeholder="Filter sites…"
          value={filters.state.search}
          onChange={(event) => filters.setFilter("search", event.target.value)}
          style={{width: "100%", padding: "6px 10px", border: "1px solid #d1d5db", borderRadius: 6, marginTop: 8}}
        />
        <h2 style={{fontSize: 11, textTransform: "uppercase", letterSpacing: 0.06, color: "#6b7280", marginTop: 16}}>
          Regions
        </h2>
        <div style={{display: "flex", flexWrap: "wrap", gap: 6}}>
          {regions.map(([region, count]) => {
            const active = filters.state.regions.length === 0 || filters.state.regions.includes(region)
            return (
              <button
                key={region}
                type="button"
                onClick={() => toggleRegion(region)}
                style={{
                  padding: "4px 10px",
                  borderRadius: 999,
                  border: "1px solid #d1d5db",
                  background: active ? "#2563eb" : "white",
                  color: active ? "white" : "#1f2937",
                  cursor: "pointer",
                  fontSize: 12,
                }}
              >
                {region} {count.toLocaleString()}
              </button>
            )
          })}
        </div>
      </aside>
    </div>
  )
}

export const mountDashboard = mountReactDashboard(MapDashboard, {waitForReady: true})
export default mountDashboard
