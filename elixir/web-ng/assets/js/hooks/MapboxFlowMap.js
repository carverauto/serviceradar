import mapboxgl from "mapbox-gl"

export default {
  mounted() {
    this._initOrUpdate()
    this._themeObserver = new MutationObserver(() => this._applyThemeStyle())
    // daisyUI typically drives theme via `data-theme` on <html>, but be resilient:
    // some pages/toggles may update `class`, inline styles, or set theme on <body>.
    this._themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme", "class", "style"],
    })
    this._themeObserver.observe(document.body, {
      attributes: true,
      attributeFilter: ["data-theme", "class", "style"],
    })

    this._colorSchemeMql = window.matchMedia?.("(prefers-color-scheme: dark)") || null
    this._onColorSchemeChange = () => this._applyThemeStyle()
    if (this._colorSchemeMql?.addEventListener) {
      this._colorSchemeMql.addEventListener("change", this._onColorSchemeChange)
    } else if (this._colorSchemeMql?.addListener) {
      // Safari
      this._colorSchemeMql.addListener(this._onColorSchemeChange)
    }
  },
  updated() {
    this._initOrUpdate()
    try {
      this._map?.resize()
    } catch (_e) {}
  },
  destroyed() {
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
      this._map?.remove()
    } catch (_e) {}
    this._map = null
    this._markers = []
  },
  _initOrUpdate() {
    const token = this.el.dataset.accessToken || ""
    const enabled = (this.el.dataset.enabled || "false") === "true"
    const styleLight = this.el.dataset.styleLight || "mapbox://styles/mapbox/light-v11"
    const styleDark = this.el.dataset.styleDark || "mapbox://styles/mapbox/dark-v11"
    let markers = []
    try {
      markers = JSON.parse(this.el.dataset.markers || "[]")
    } catch (_e) {
      markers = []
    }

    if (!enabled || !token) {
      try {
        this._map?.remove()
      } catch (_e) {}
      this._map = null
      this._markers = []
      this._showFallback(!enabled ? "Maps are disabled" : "Mapbox access token not configured")
      return
    }

    this._clearFallback()
    this._token = token
    this._styleLight = styleLight
    this._styleDark = styleDark
    this._markerData = Array.isArray(markers) ? markers : []

    if (!this._map) {
      mapboxgl.accessToken = token
      const style = this._currentStyle()

      this._map = new mapboxgl.Map({
        container: this.el,
        style,
        center: [0, 0],
        zoom: 1.2,
        attributionControl: false,
      })

      this._map.addControl(new mapboxgl.NavigationControl({showCompass: true}), "top-right")

      this._map.on("load", () => {
        this._map.resize()
        this._syncMarkers()
        this._fitToMarkers()
        this._stampStyleUrl(style)
      })

      this._map.on("error", (e) => {
        const msg = e?.error?.message || e?.message || "Unknown map error"
        console.warn("[MapboxFlowMap] map error:", msg)
        if (msg.includes("access token") || msg.includes("401") || msg.includes("403")) {
          this._showFallback("Invalid Mapbox access token")
        }
      })
    } else {
      if (mapboxgl.accessToken !== token) {
        try {
          this._map?.remove()
        } catch (_e) {}
        this._map = null
        this._markers = []
        this._initOrUpdate()
        return
      }

      this._applyThemeStyle()
      this._syncMarkers()
      this._fitToMarkers()
    }
  },
  _currentStyle() {
    return this._isDarkMode() ? this._styleDark : this._styleLight
  },
  _isDarkMode() {
    // 1) Prefer computed `color-scheme` (best signal when themes set it)
    try {
      const cs = window.getComputedStyle(document.documentElement).colorScheme
      if (typeof cs === "string") {
        if (cs.includes("dark")) return true
        if (cs.includes("light")) return false
      }
    } catch (_e) {}

    // 2) Fall back to explicit theme names for the common case
    const themeAttr =
      document.documentElement.getAttribute("data-theme") || document.body?.getAttribute?.("data-theme") || ""
    const theme = String(themeAttr || "").toLowerCase().trim()
    if (theme === "dark") return true
    if (theme === "light") return false

    // 3) Infer from background luminance (works even for custom themes)
    const bg =
      (document.body && window.getComputedStyle(document.body).backgroundColor) ||
      window.getComputedStyle(document.documentElement).backgroundColor ||
      ""
    const m = String(bg).match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/i)
    if (m) {
      const r = Number(m[1]) / 255
      const g = Number(m[2]) / 255
      const b = Number(m[3]) / 255
      // Relative luminance (sRGB)
      const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
      return lum < 0.45
    }

    // 4) Last resort: OS preference
    return !!this._colorSchemeMql?.matches
  },
  _styleUrlFromMeta() {
    try {
      const meta = this._map?.getStyle()?.metadata || {}
      return meta.sr_style_url
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
    const current = this._styleUrlFromMeta()
    if (current === desired) return

    this._map.setStyle(desired, {diff: true})
    this._map.once("style.load", () => {
      this._stampStyleUrl(desired)
      this._syncMarkers()
    })
  },
  _syncMarkers() {
    if (!this._map) return
    const data = Array.isArray(this._markerData) ? this._markerData : []

    for (const m of this._markers || []) {
      try {
        m.remove()
      } catch (_e) {}
    }
    this._markers = []

    for (const d of data) {
      const lng = Number(d?.lng)
      const lat = Number(d?.lat)
      if (!Number.isFinite(lng) || !Number.isFinite(lat)) continue

      const label = String(d?.label || "")
      const popup = label ? new mapboxgl.Popup({offset: 20}).setText(label) : null

      const side =
        label.toLowerCase().startsWith("source") ? "source" : label.toLowerCase().startsWith("dest") ? "dest" : null

      const markerColor =
        side === "source" ? "#22c55e" : // green-500
        side === "dest" ? "#ef4444" : // red-500
        "#64748b" // slate-500

      const marker = new mapboxgl.Marker({color: markerColor}).setLngLat([lng, lat])
      if (popup) marker.setPopup(popup)
      marker.addTo(this._map)

      this._markers.push(marker)
    }

    this._syncLine()
  },
  _syncLine() {
    if (!this._map) return

    const coords = (Array.isArray(this._markerData) ? this._markerData : [])
      .map((d) => [Number(d?.lng), Number(d?.lat)])
      .filter(([lng, lat]) => Number.isFinite(lng) && Number.isFinite(lat))

    const sourceId = "sr-flow-line"
    const layerId = "sr-flow-line-layer"

    // Remove if we don't have a full src/dst pair.
    if (coords.length < 2) {
      try {
        if (this._map.getLayer(layerId)) this._map.removeLayer(layerId)
      } catch (_e) {}
      try {
        if (this._map.getSource(sourceId)) this._map.removeSource(sourceId)
      } catch (_e) {}
      return
    }

    const line = {
      type: "FeatureCollection",
      features: [
        {
          type: "Feature",
          geometry: {type: "LineString", coordinates: [coords[0], coords[1]]},
          properties: {},
        },
      ],
    }

    if (this._map.getSource(sourceId)) {
      try {
        this._map.getSource(sourceId).setData(line)
      } catch (_e) {}
    } else {
      try {
        this._map.addSource(sourceId, {type: "geojson", data: line})
        this._map.addLayer({
          id: layerId,
          type: "line",
          source: sourceId,
          paint: {
            "line-color": "#0ea5e9", // sky-500
            "line-width": 3,
            "line-opacity": 0.75,
          },
        })
      } catch (_e) {}
    }
  },
  _fitToMarkers() {
    if (!this._map || !Array.isArray(this._markerData) || this._markerData.length === 0) return

    const coords = this._markerData
      .map((d) => [Number(d?.lng), Number(d?.lat)])
      .filter(([lng, lat]) => Number.isFinite(lng) && Number.isFinite(lat))

    if (coords.length === 0) return

    if (coords.length === 1) {
      this._map.easeTo({center: coords[0], zoom: 3.2, duration: 250})
      return
    }

    const bounds = coords.reduce((b, c) => b.extend(c), new mapboxgl.LngLatBounds(coords[0], coords[0]))

    this._map.fitBounds(bounds, {padding: 28, duration: 250, maxZoom: 6})
  },
  _showFallback(message) {
    if (!this.el) return
    let fb = this.el.querySelector("[data-map-fallback]")
    if (!fb) {
      fb = document.createElement("div")
      fb.setAttribute("data-map-fallback", "")
      fb.className = "flex items-center justify-center h-full w-full text-xs text-base-content/50"
      this.el.appendChild(fb)
    }
    fb.textContent = message
    fb.style.display = ""
  },
  _clearFallback() {
    if (!this.el) return
    const fb = this.el.querySelector("[data-map-fallback]")
    if (fb) fb.style.display = "none"
  },
}
