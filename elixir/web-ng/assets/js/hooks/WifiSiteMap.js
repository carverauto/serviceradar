import mapboxgl from "mapbox-gl"
import {Deck, MapView} from "@deck.gl/core"
import {ScatterplotLayer, TextLayer} from "@deck.gl/layers"

const DEFAULT_LIGHT_STYLE = "mapbox://styles/mapbox/light-v11"
const DEFAULT_DARK_STYLE = "mapbox://styles/mapbox/dark-v11"
const OSM_STYLE_ID = "serviceradar-osm-raster"
const REGION_COLORS = ["#00c98b", "#ffac32", "#47a7ff", "#b46cff", "#ff6f83", "#1f6cff"]

function osmRasterStyle() {
  return {
    version: 8,
    metadata: {sr_style_url: OSM_STYLE_ID},
    sources: {
      osm: {
        type: "raster",
        tiles: [
          "https://a.tile.openstreetmap.org/{z}/{x}/{y}.png",
          "https://b.tile.openstreetmap.org/{z}/{x}/{y}.png",
          "https://c.tile.openstreetmap.org/{z}/{x}/{y}.png",
        ],
        tileSize: 256,
        attribution: "© OpenStreetMap contributors",
      },
    },
    layers: [{id: "osm", type: "raster", source: "osm"}],
  }
}

function isFiniteCoordinate(lng, lat) {
  return Number.isFinite(lng) && Number.isFinite(lat) && lng >= -180 && lng <= 180 && lat >= -90 && lat <= 90
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value))
}

function regionColor(region) {
  const value = String(region || "")
  let hash = 0
  for (let i = 0; i < value.length; i += 1) hash = (hash * 31 + value.charCodeAt(i)) >>> 0
  return REGION_COLORS[hash % REGION_COLORS.length]
}

function hexToRgb(hex) {
  const normalized = String(hex || "").replace("#", "")
  const value = Number.parseInt(normalized.length === 3 ? normalized.split("").map((c) => c + c).join("") : normalized, 16)
  if (!Number.isFinite(value)) return [0, 201, 139]
  return [(value >> 16) & 255, (value >> 8) & 255, value & 255]
}

export default {
  mounted() {
    this._onResize = () => this._resize()
    this._onThemeChange = () => this._applyThemeStyle()
    this._onColorSchemeChange = () => this._applyThemeStyle()

    this._themeObserver = new MutationObserver(this._onThemeChange)
    this._themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme", "class", "style"],
    })
    this._themeObserver.observe(document.body, {
      attributes: true,
      attributeFilter: ["data-theme", "class", "style"],
    })

    this._colorSchemeMql = window.matchMedia?.("(prefers-color-scheme: dark)") || null
    if (this._colorSchemeMql?.addEventListener) {
      this._colorSchemeMql.addEventListener("change", this._onColorSchemeChange)
    } else if (this._colorSchemeMql?.addListener) {
      this._colorSchemeMql.addListener(this._onColorSchemeChange)
    }

    window.addEventListener("resize", this._onResize)
    this._initOrUpdate()
  },

  updated() {
    this._initOrUpdate()
  },

  destroyed() {
    window.removeEventListener("resize", this._onResize)
    try {
      this._themeObserver?.disconnect()
    } catch (_e) {}
    try {
      if (this._colorSchemeMql?.removeEventListener && this._onColorSchemeChange) {
        this._colorSchemeMql.removeEventListener("change", this._onColorSchemeChange)
      } else if (this._colorSchemeMql?.removeListener && this._onColorSchemeChange) {
        this._colorSchemeMql.removeListener(this._onColorSchemeChange)
      }
    } catch (_e) {}
    try {
      this._popup?.remove()
    } catch (_e) {}
    try {
      this._deck?.finalize()
    } catch (_e) {}
    try {
      this._map?.remove()
    } catch (_e) {}
    this._popup = null
    this._deck = null
    this._map = null
  },

  _initOrUpdate() {
    this._enabled = (this.el.dataset.enabled || "false") === "true"
    this._token = this.el.dataset.accessToken || ""
    this._styleLight = this.el.dataset.styleLight || DEFAULT_LIGHT_STYLE
    this._styleDark = this.el.dataset.styleDark || DEFAULT_DARK_STYLE
    this._compact = (this.el.dataset.compact || "false") === "true"
    this._useMapbox = this._enabled && this._token
    this._sites = this._parseSites()

    if (this._sites.length === 0) {
      this._teardownMap()
      this._showFallback("No mappable WiFi sites")
      return
    }

    this._clearFallback()
    this._ensureContainers()

    if (!this._map) {
      this._createMap()
    } else {
      this._applyThemeStyle()
      this._updateDeckLayers()
      this._fitToSites()
    }
  },

  _parseSites() {
    let parsed = []
    try {
      parsed = JSON.parse(this.el.dataset.sites || "[]")
    } catch (_e) {
      parsed = []
    }

    if (!Array.isArray(parsed)) return []

    return parsed
      .map((site) => {
        const longitude = Number(site?.longitude)
        const latitude = Number(site?.latitude)
        if (!isFiniteCoordinate(longitude, latitude)) return null
        return {...site, longitude, latitude}
      })
      .filter(Boolean)
  },

  _ensureContainers() {
    if (this._mapContainer && this._deckContainer) return

    this.el.innerHTML = ""
    this.el.classList.add("sr-wifi-map-hook")

    this._mapContainer = document.createElement("div")
    this._mapContainer.className = "sr-wifi-map-basemap"

    this._deckContainer = document.createElement("div")
    this._deckContainer.className = "sr-wifi-map-deck"

    this.el.appendChild(this._mapContainer)
    this.el.appendChild(this._deckContainer)
  },

  _createMap() {
    if (this._useMapbox) {
      mapboxgl.accessToken = this._token
    }

    const style = this._currentStyle()
    const styleId = this._currentStyleId()

    this._map = new mapboxgl.Map({
      container: this._mapContainer,
      style,
      center: [-98, 39],
      zoom: 2.6,
      attributionControl: false,
      interactive: !this._compact,
    })

    this._map.on("load", () => {
      this._stampStyleUrl(styleId)
      this._createDeck()
      this._fitToSites()
      this._resize()
    })

    this._map.on("error", (event) => {
      const msg = event?.error?.message || event?.message || "Unknown map error"
      console.warn("[WifiSiteMap] map error:", msg)
      if (msg.includes("access token") || msg.includes("401") || msg.includes("403")) {
        this._showFallback("Invalid Mapbox access token")
      }
    })
  },

  _createDeck() {
    if (this._deck) return

    this._viewState = this._mapViewState()

    this._deck = new Deck({
      parent: this._deckContainer,
      views: new MapView({repeat: true}),
      controller: true,
      initialViewState: this._viewState,
      getTooltip: null,
      onViewStateChange: ({viewState}) => {
        this._setViewState(viewState, true)
      },
      onClick: (info) => this._handleClick(info),
      onHover: (info) => {
        this.el.style.cursor = info?.object ? "pointer" : ""
      },
      layers: this._layers(),
    })
  },

  _mapViewState() {
    const center = this._map?.getCenter?.()
    return {
      longitude: center?.lng ?? -98,
      latitude: center?.lat ?? 39,
      zoom: this._map?.getZoom?.() ?? 2.6,
      bearing: this._map?.getBearing?.() ?? 0,
      pitch: this._map?.getPitch?.() ?? 0,
    }
  },

  _setViewState(viewState, syncMap) {
    this._viewState = {
      longitude: Number(viewState.longitude),
      latitude: Number(viewState.latitude),
      zoom: Number(viewState.zoom),
      bearing: Number(viewState.bearing || 0),
      pitch: Number(viewState.pitch || 0),
    }

    this._deck?.setProps({viewState: this._viewState})

    if (syncMap && this._map) {
      this._map.jumpTo({
        center: [this._viewState.longitude, this._viewState.latitude],
        zoom: this._viewState.zoom,
        bearing: this._viewState.bearing,
        pitch: this._viewState.pitch,
      })
    }
  },

  _updateDeckLayers() {
    if (!this._deck) return
    this._deck.setProps({layers: this._layers()})
  },

  _layers() {
    const sites = this._sites || []

    return [
      new ScatterplotLayer({
        id: "wifi-sites",
        data: sites,
        pickable: true,
        opacity: this._compact ? 0.82 : 0.46,
        radiusUnits: "pixels",
        getPosition: (d) => [d.longitude, d.latitude],
        getRadius: (d) =>
          this._compact
            ? clamp(4 + Math.sqrt(Number(d.ap_count || 0)) * 1.2, 5, 16)
            : clamp(5 + Math.sqrt(Number(d.ap_count || 0)) * 1.15, 8, 19),
        getFillColor: (d) => {
          if (Number(d.down_count || 0) > 0) return [239, 68, 68, 210]
          if (Number(d.ap_count || 0) === 0) return [148, 163, 184, 190]
          return [...hexToRgb(regionColor(d.region)), 210]
        },
        getLineColor: [255, 255, 255, 230],
        lineWidthUnits: "pixels",
        getLineWidth: 1.25,
        updateTriggers: {
          getRadius: sites.length,
          getFillColor: sites.length,
        },
      }),
      new TextLayer({
        id: "wifi-site-labels",
        data: sites,
        pickable: true,
        getPosition: (d) => [d.longitude, d.latitude],
        getText: (d) =>
          this._compact
            ? String(d.site_code || d.name || "")
            : `${String(d.site_code || d.name || "")}  ${Number(d.ap_count || 0).toLocaleString()} APs`,
        getSize: this._compact ? 9 : 12,
        getPixelOffset: [0, this._compact ? -13 : -18],
        getColor: (d) => [...hexToRgb(regionColor(d.region)), 255],
        getTextAnchor: "middle",
        getAlignmentBaseline: "bottom",
        background: true,
        getBackgroundColor: [255, 255, 255, 242],
        backgroundPadding: this._compact ? [3, 2] : [7, 4],
      }),
    ]
  },

  _handleClick(info) {
    const site = info?.object
    if (!site || !this._map) return

    try {
      this._popup?.remove()
    } catch (_e) {}

    this._popup = new mapboxgl.Popup({offset: 18, closeButton: true})
      .setLngLat([site.longitude, site.latitude])
      .setHTML(this._popupHtml(site))
      .addTo(this._map)
  },

  _popupHtml(site) {
    const title = site.name || site.site_code || "WiFi site"
    const code = site.site_code || ""
    const row = (label, value, className = "") =>
      value ? `<div class="sr-wifi-map-popup-row ${className}"><span>${this._escapeHtml(label)}</span><strong>${this._escapeHtml(value)}</strong></div>` : ""
    const up = Number(site.up_count || 0)
    const down = Number(site.down_count || 0)
    const total = Number(site.ap_count || 0)
    const pct = total > 0 ? Math.round((up / total) * 100) : 0
    const apModels = this._entries(site.model_breakdown)
    const apFamilies = this._families(apModels)
    const wlcModels = this._entries(site.wlc_model_breakdown)
    const aosVersions = this._entries(site.aos_version_breakdown)
    const controllers = Array.isArray(site.controller_names) ? site.controller_names : []
    const modelTotal = apModels.reduce((sum, [, count]) => sum + count, 0)
    const donut = this._donut(apFamilies)

    return `
      <div class="sr-wifi-map-popup">
        <h3>${this._escapeHtml(code ? `${code} — ${title}` : title)}</h3>
        <div class="sr-wifi-map-popup-summary">
          ${row("Type", site.site_type || "Airport")}
          ${row("Region", site.region)}
          ${row("APs", total.toLocaleString())}
          <div class="sr-wifi-map-popup-row"><span>Up / Down</span><strong><em class="good">${up.toLocaleString()}</em> / <em class="bad">${down.toLocaleString()}</em> · ${pct}%</strong></div>
        </div>
        ${apFamilies.length ? `
          <div class="sr-wifi-map-popup-section">
            <h4>AP Models</h4>
            <div class="sr-wifi-map-popup-models">
              <div class="sr-wifi-map-popup-donut" style="background:${donut};"><span>${modelTotal.toLocaleString()}</span></div>
              <div>${apFamilies.map(([family, count, color]) => this._legendRow(family, count, modelTotal, color)).join("")}</div>
            </div>
            <div class="sr-wifi-map-popup-model-list">
              ${apModels.slice(0, 5).map(([model, count]) => row(model, count.toLocaleString())).join("")}
            </div>
          </div>
        ` : ""}
        <div class="sr-wifi-map-popup-section">
          <h4>WLCs</h4>
          ${row("Total", Number(site.wlc_count || 0).toLocaleString())}
          ${wlcModels.slice(0, 4).map(([model, count]) => row(model, count.toLocaleString())).join("")}
          ${aosVersions.slice(0, 3).map(([version, count]) => row(`AOS ${version}`, count.toLocaleString(), "accent")).join("")}
        </div>
        <div class="sr-wifi-map-popup-detail">
          ${row("MM", controllers[0] || "")}
          ${row("CPPM Cluster", site.cluster, "accent")}
          ${row("Auth", site.server_group)}
          ${row("Profile", site.aaa_profile)}
          ${row("Lat / Lon", `${Number(site.latitude).toFixed(3)}, ${Number(site.longitude).toFixed(3)}`)}
        </div>
      </div>
    `
  },

  _entries(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return []
    return Object.entries(value)
      .map(([key, raw]) => [String(key), Number(raw || 0)])
      .filter(([, count]) => Number.isFinite(count) && count > 0)
      .sort((a, b) => b[1] - a[1])
  },

  _families(entries) {
    const grouped = new Map()
    for (const [model, count] of entries) {
      const first = model.match(/\d/)?.[0]
      const family = first ? `${first}XX` : model
      grouped.set(family, (grouped.get(family) || 0) + count)
    }

    const colors = ["#f59e0b", "#3b82f6", "#10b981", "#a855f7", "#ef4444"]
    return Array.from(grouped.entries())
      .sort((a, b) => b[1] - a[1])
      .map(([family, count], index) => [family, count, colors[index % colors.length]])
  },

  _donut(entries) {
    const total = entries.reduce((sum, [, count]) => sum + count, 0)
    if (total <= 0) return "#e2e8f0"

    let cursor = 0
    const stops = entries.map(([, count, color]) => {
      const start = cursor
      cursor += (count / total) * 100
      return `${color} ${start}% ${cursor}%`
    })

    return `conic-gradient(${stops.join(", ")})`
  },

  _legendRow(label, count, total, color) {
    const pct = total > 0 ? Math.round((count / total) * 100) : 0
    return `<div class="sr-wifi-map-popup-legend"><i style="background:${this._escapeHtml(color)};"></i><strong>${this._escapeHtml(label)}</strong><span>${count.toLocaleString()} · ${pct}%</span></div>`
  },

  _fitToSites() {
    if (!this._map || !this._sites?.length) return

    const coords = this._sites.map((site) => [site.longitude, site.latitude])
    if (coords.length === 1) {
      const [longitude, latitude] = coords[0]
      this._setViewState({longitude, latitude, zoom: 6, bearing: 0, pitch: 0}, true)
      return
    }

    const bounds = coords.reduce((acc, coord) => acc.extend(coord), new mapboxgl.LngLatBounds(coords[0], coords[0]))
    this._map.fitBounds(bounds, {padding: 72, duration: 0, maxZoom: 8})
    this._setViewState(this._mapViewState(), false)
  },

  _currentStyle() {
    if (!this._useMapbox) return osmRasterStyle()
    return this._isDarkMode() ? this._styleDark : this._styleLight
  },

  _currentStyleId() {
    if (!this._useMapbox) return OSM_STYLE_ID
    return this._isDarkMode() ? this._styleDark : this._styleLight
  },

  _isDarkMode() {
    const theme =
      document.documentElement.getAttribute("data-theme") || document.body?.getAttribute?.("data-theme") || ""
    if (String(theme).toLowerCase() === "dark") return true
    if (String(theme).toLowerCase() === "light") return false

    try {
      const colorScheme = window.getComputedStyle(document.documentElement).colorScheme
      if (colorScheme.includes("dark")) return true
      if (colorScheme.includes("light")) return false
    } catch (_e) {}

    return Boolean(this._colorSchemeMql?.matches)
  },

  _styleUrlFromMeta() {
    try {
      return this._map?.getStyle?.()?.metadata?.sr_style_url
    } catch (_e) {
      return null
    }
  },

  _stampStyleUrl(url) {
    try {
      const style = this._map.getStyle()
      style.metadata = {...(style.metadata || {}), sr_style_url: url}
    } catch (_e) {}
  },

  _applyThemeStyle() {
    if (!this._map) return

    const desiredId = this._currentStyleId()
    const desired = this._currentStyle()
    if (this._styleUrlFromMeta() === desiredId) return

    this._map.setStyle(desired, {diff: true})
    this._map.once("style.load", () => {
      this._stampStyleUrl(desiredId)
      this._updateDeckLayers()
    })
  },

  _resize() {
    try {
      this._map?.resize()
    } catch (_e) {}
    try {
      const rect = this.el.getBoundingClientRect()
      this._deck?.setProps({width: rect.width, height: rect.height})
      this._deck?.redraw(true)
    } catch (_e) {}
  },

  _teardownMap() {
    try {
      this._popup?.remove()
    } catch (_e) {}
    try {
      this._deck?.finalize()
    } catch (_e) {}
    try {
      this._map?.remove()
    } catch (_e) {}
    this._popup = null
    this._deck = null
    this._map = null
    this._mapContainer = null
    this._deckContainer = null
  },

  _showFallback(message) {
    this.el.innerHTML = `<div class="sr-wifi-map-fallback">${this._escapeHtml(message)}</div>`
  },

  _clearFallback() {
    const fallback = this.el.querySelector(".sr-wifi-map-fallback")
    if (fallback) fallback.remove()
  },

  _escapeHtml(value) {
    return String(value || "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
  },
}
