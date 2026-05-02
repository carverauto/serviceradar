const MAP_VIEWS = new Set(["topology_traffic", "netflow"])
const SELECT_ID = "traffic-map-view-select"
const CANVAS_ID = "ops-traffic-map"

function normalizeMapView(value) {
  return MAP_VIEWS.has(value) ? value : "netflow"
}

function dashboardRoute(value) {
  const raw = String(value || "")
  if (!raw.startsWith("dashboard:")) return null

  const slug = raw.slice("dashboard:".length).trim()
  return slug ? `/dashboards/${encodeURIComponent(slug)}` : null
}

function applyMapView(value) {
  const route = dashboardRoute(value)

  if (route) {
    window.location.assign(route)
    return true
  }

  const mapView = normalizeMapView(value)
  const canvas = document.getElementById(CANVAS_ID)

  if (canvas) {
    canvas.dataset.mapView = mapView
  }

  window.dispatchEvent(new window.CustomEvent("serviceradar:dashboard-map-view", {detail: {mapView}}))
  return false
}

if (typeof window !== "undefined" && !window.__serviceRadarDashboardMapViewSelectBound) {
  window.__serviceRadarDashboardMapViewSelectBound = true

  document.addEventListener("change", (event) => {
    if (event.target?.id === SELECT_ID) {
      applyMapView(event.target.value)
    }
  })
}

const DashboardMapViewSelect = {
  mounted() {
    this.onChange = () => {
      if (!applyMapView(this.el.value)) {
        this.pushEvent("select_map_view", { map_view: this.el.value })
      }
    }

    this.el.addEventListener("change", this.onChange)
  },

  destroyed() {
    this.el.removeEventListener("change", this.onChange)
  },
}

export default DashboardMapViewSelect
