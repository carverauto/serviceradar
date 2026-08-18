import mapboxgl from "mapbox-gl"

function parseCoord(value) {
  const n = Number.parseFloat(value)
  return Number.isFinite(n) ? n : null
}

export default {
  mounted() {
    this._init()
  },

  updated() {
    if (this._map) {
      this._syncMarkerFromDataset()
      try {
        this._map.resize()
      } catch (_e) {}
      return
    }

    this._init()
  },

  destroyed() {
    try {
      this._marker?.remove()
    } catch (_e) {}
    try {
      this._map?.remove()
    } catch (_e) {}
    this._marker = null
    this._map = null
  },

  _init() {
    const token = this.el.dataset.accessToken || ""
    const enabled = (this.el.dataset.enabled || "false") === "true"

    if (!enabled || !token) {
      return
    }

    const lat = parseCoord(this.el.dataset.lat)
    const lng = parseCoord(this.el.dataset.lng)
    const hasPoint = lat != null && lng != null
    const style = this.el.dataset.style || "mapbox://styles/mapbox/light-v11"

    mapboxgl.accessToken = token
    this._map = new mapboxgl.Map({
      container: this.el,
      style,
      center: hasPoint ? [lng, lat] : [-93.6258, 44.7633],
      zoom: hasPoint ? 10 : 3,
      attributionControl: false,
    })

    this._map.addControl(new mapboxgl.NavigationControl({showCompass: false}), "top-right")
    this._map.on("load", () => {
      try {
        this._map.resize()
      } catch (_e) {}
      this._syncMarkerFromDataset()
    })
    this._map.on("click", (event) => {
      const nextLng = event.lngLat.lng
      const nextLat = event.lngLat.lat
      this._setMarker(nextLng, nextLat)
      this.pushEvent("map_pick", {
        latitude: nextLat.toFixed(6),
        longitude: nextLng.toFixed(6),
      })
    })
  },

  _syncMarkerFromDataset() {
    const lat = parseCoord(this.el.dataset.lat)
    const lng = parseCoord(this.el.dataset.lng)
    if (lat == null || lng == null) {
      return
    }

    this._setMarker(lng, lat)
  },

  _setMarker(lng, lat) {
    if (!this._map) {
      return
    }

    if (!this._marker) {
      this._marker = new mapboxgl.Marker({color: "#2563eb"}).setLngLat([lng, lat]).addTo(this._map)
      return
    }

    this._marker.setLngLat([lng, lat])
  },
}
