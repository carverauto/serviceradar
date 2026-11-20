import React, {useMemo, useState} from "react"
import {
  Button,
  Callout,
  Card,
  Drawer,
  HTMLTable,
  InputGroup,
  MenuItem,
  NonIdealState,
  SegmentedControl,
  Tag,
} from "@blueprintjs/core"
import {PulseIcon, SearchIcon, WarningSignIcon} from "@blueprintjs/icons"
import {Select} from "@blueprintjs/select"
import {
  mountBlueprintDashboard,
  useBlueprintPortalContainer,
} from "@carverauto/serviceradar-dashboard-sdk/blueprint"
import {
  useDashboardTheme,
  useFilterState,
  useFrameRows,
} from "@carverauto/serviceradar-dashboard-sdk/react"
import "./styles.css"

const ROW_SHAPE = Object.freeze({
  device_id: "device_id",
  name: "name",
  ip_address: "ip_address",
  site_code: "site_code",
  status: (row) => String(row.status || "unknown").toLowerCase(),
  last_seen: "last_seen",
})

function BlueprintStarterDashboard() {
  const theme = useDashboardTheme()
  const portalContainer = useBlueprintPortalContainer()
  const rows = useFrameRows("rows", {decode: "auto", shape: ROW_SHAPE})
  const filters = useFilterState({
    initialState: {search: "", status: "all", site: "all"},
    debounceMs: 200,
    debounceFields: ["search"],
  })
  const [selectedDevice, setSelectedDevice] = useState(null)

  const sites = useMemo(() => {
    const unique = new Set(rows.map((row) => row.site_code).filter(Boolean))
    return ["all", ...Array.from(unique).sort()]
  }, [rows])

  const visibleRows = useMemo(() => {
    const query = filters.debouncedState.search.trim().toLowerCase()
    const statusFilter = filters.state.status
    const siteFilter = filters.state.site
    return rows.filter((row) => {
      if (statusFilter !== "all" && row.status !== statusFilter) return false
      if (siteFilter !== "all" && row.site_code !== siteFilter) return false
      if (!query) return true
      return [row.device_id, row.name, row.ip_address, row.site_code]
        .some((value) => String(value ?? "").toLowerCase().includes(query))
    })
  }, [rows, filters.debouncedState.search, filters.state.status, filters.state.site])

  const downCount = useMemo(
    () => rows.filter((row) => row.status === "down").length,
    [rows],
  )

  return (
    <div className="sr-bp-template-shell" data-theme={theme}>
      <Card compact>
        <div className="sr-bp-template-header">
          <div className="sr-bp-template-title">
            <PulseIcon size={18} />
            <h1>__DASHBOARD_TITLE__</h1>
            <Tag minimal intent={downCount > 0 ? "warning" : "success"}>
              {rows.length} devices · {downCount} down
            </Tag>
          </div>
          <div className="sr-bp-template-controls">
            <InputGroup
              leftElement={<SearchIcon size={14} />}
              placeholder="Filter devices…"
              value={filters.state.search}
              onChange={(event) => filters.setFilter("search", event.target.value)}
            />
            <SegmentedControl
              small
              value={filters.state.status}
              onValueChange={(value) => filters.setFilter("status", value)}
              options={[
                {label: "All", value: "all"},
                {label: "Up", value: "up"},
                {label: "Down", value: "down"},
              ]}
            />
            <Select
              items={sites}
              filterable={false}
              onItemSelect={(site) => filters.setFilter("site", site)}
              popoverProps={{portalContainer: portalContainer ?? undefined}}
              itemRenderer={(site, {handleClick, modifiers}) => (
                <MenuItem
                  key={site}
                  active={modifiers.active}
                  selected={site === filters.state.site}
                  text={site === "all" ? "All sites" : site}
                  onClick={handleClick}
                />
              )}
            >
              <Button
                variant="outlined"
                endIcon="caret-down"
                text={filters.state.site === "all" ? "All sites" : `Site: ${filters.state.site}`}
              />
            </Select>
          </div>
        </div>
      </Card>

      {downCount > 0 ? (
        <Callout intent="warning" icon={<WarningSignIcon size={16} />}>
          {downCount} {downCount === 1 ? "device reports" : "devices report"} status down.
        </Callout>
      ) : null}

      <Card className="sr-bp-template-table-wrap">
        {visibleRows.length === 0 ? (
          <NonIdealState
            icon={<SearchIcon size={32} />}
            title="No matching devices"
            description="Adjust your search or filter selections to view rows."
          />
        ) : (
          <HTMLTable interactive striped compact className="sr-bp-template-table">
            <thead>
              <tr>
                <th>Device</th>
                <th>IP Address</th>
                <th>Site</th>
                <th>Status</th>
                <th>Last Seen</th>
              </tr>
            </thead>
            <tbody>
              {visibleRows.map((row) => (
                <tr key={row.device_id} onClick={() => setSelectedDevice(row)}>
                  <td>
                    <strong>{row.name || row.device_id}</strong>
                  </td>
                  <td>{row.ip_address}</td>
                  <td>{row.site_code}</td>
                  <td>
                    <Tag
                      minimal
                      intent={row.status === "down" ? "danger" : "success"}
                    >
                      {row.status}
                    </Tag>
                  </td>
                  <td>{row.last_seen}</td>
                </tr>
              ))}
            </tbody>
          </HTMLTable>
        )}
      </Card>

      <Drawer
        isOpen={Boolean(selectedDevice)}
        onClose={() => setSelectedDevice(null)}
        title={selectedDevice?.name || "Device Details"}
        size="360px"
        portalContainer={portalContainer ?? undefined}
      >
        {selectedDevice ? (
          <div className="sr-bp-template-drawer-body">
            <div><strong>ID:</strong> {selectedDevice.device_id}</div>
            <div><strong>IP Address:</strong> {selectedDevice.ip_address}</div>
            <div><strong>Site:</strong> {selectedDevice.site_code}</div>
            <div><strong>Status:</strong> {selectedDevice.status}</div>
            <div><strong>Last Seen:</strong> {selectedDevice.last_seen}</div>
          </div>
        ) : null}
      </Drawer>
    </div>
  )
}

export const mountDashboard = mountBlueprintDashboard(BlueprintStarterDashboard)
export default mountDashboard
