import mapboxgl from "mapbox-gl"
import {Deck, MapView} from "@deck.gl/core"
import {ScatterplotLayer, TextLayer} from "@deck.gl/layers"

const DEFAULT_LIGHT_STYLE = "mapbox://styles/mapbox/light-v11"
const DEFAULT_DARK_STYLE = "mapbox://styles/mapbox/dark-v11"

function isFiniteCoordinate(lng, lat) {
  return Number.isFinite(lng) && Number.isFinite(lat) && lng >= -180 && lng <= 180 && lat >= -90 && lat <= 90
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value))
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
    this._sites = this._parseSites()

    if (!this._enabled || !this._token) {
      this._teardownMap()
      this._showFallback(!this._enabled ? "Mapbox maps are disabled" : "Mapbox access token not configured")
      return
    }

    if (this._sites.length === 0) {
      this._teardownMap()
      this._showFallback("No mappable WiFi rows in the current SRQL result set")
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
    mapboxgl.accessToken = this._token
    const style = this._currentStyle()

    this._map = new mapboxgl.Map({
      container: this._mapContainer,
      style,
      center: [-98, 39],
      zoom: 2.6,
      attributionControl: false,
      interactive: false,
    })

    this._map.on("load", () => {
      this._stampStyleUrl(style)
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
        opacity: 0.92,
        radiusUnits: "pixels",
        getPosition: (d) => [d.longitude, d.latitude],
        getRadius: (d) => clamp(7 + Math.sqrt(Number(d.ap_count || 0)) * 2.2, 8, 28),
        getFillColor: (d) => {
          if (Number(d.down_count || 0) > 0) return [239, 68, 68, 210]
          if (Number(d.ap_count || 0) === 0) return [148, 163, 184, 190]
          return [20, 184, 166, 220]
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
        pickable: false,
        getPosition: (d) => [d.longitude, d.latitude],
        getText: (d) => String(d.site_code || d.name || ""),
        getSize: 11,
        getPixelOffset: [0, -18],
        getColor: [241, 245, 249, 235],
        getTextAnchor: "middle",
        getAlignmentBaseline: "bottom",
        background: true,
        getBackgroundColor: [15, 23, 42, 190],
        backgroundPadding: [4, 2],
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
    const subtitle = [site.site_code, site.region].filter(Boolean).join(" / ")
    const metric = (label, value) =>
      `<div><span>${this._escapeHtml(label)}</span><strong>${Number(value || 0).toLocaleString()}</strong></div>`

    return `
      <div class="sr-wifi-map-popup">
        <h3>${this._escapeHtml(title)}</h3>
        <p>${this._escapeHtml(subtitle)}</p>
        <div class="sr-wifi-map-popup-grid">
          ${metric("APs", site.ap_count)}
          ${metric("Up", site.up_count)}
          ${metric("Down", site.down_count)}
          ${metric("WLCs", site.wlc_count)}
        </div>
        ${
          site.server_group || site.cluster
            ? `<p>${this._escapeHtml([site.server_group, site.cluster].filter(Boolean).join(" / "))}</p>`
            : ""
        }
      </div>
    `
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

    const desired = this._currentStyle()
    if (this._styleUrlFromMeta() === desired) return

    this._map.setStyle(desired, {diff: true})
    this._map.once("style.load", () => {
      this._stampStyleUrl(desired)
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
