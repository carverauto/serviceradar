export default {
  mounted() {
    const apiUrl = this.el.dataset.apiUrl
    this.deck = null
    this.emptyState = null
    this.resizeObserver = null

    this.resizeDeck = () => {
      const rect = this.el.getBoundingClientRect()
      const width = Math.max(1, Math.floor(rect.width))
      const height = Math.max(1, Math.floor(rect.height))
      const dpr = window.devicePixelRatio || 1

      this.el.width = Math.max(1, Math.floor(width * dpr))
      this.el.height = Math.max(1, Math.floor(height * dpr))
      this.deck?.setProps({width, height})
    }

    this.setEmptyState = (state, detail) => {
      const parent = this.el.parentElement
      if (!parent) return

      parent.classList.toggle("is-spatial-empty", state !== null)
      parent.classList.toggle("is-spatial-error", state === "error")

      if (state === null) {
        this.emptyState?.remove()
        this.emptyState = null
        return
      }

      if (!this.emptyState) {
        this.emptyState = document.createElement("div")
        this.emptyState.className = "sr-spatial-empty-state"
        parent.appendChild(this.emptyState)
      }

      const title =
        state === "error"
          ? "Spatial samples unavailable"
          : state === "loading"
            ? "Loading spatial samples"
            : "No spatial samples yet"
      this.emptyState.innerHTML = `
        <strong>${title}</strong>
        <span>${detail || "FieldSurvey uploads will appear here once pose and RF samples are ingested."}</span>
      `
    }

    this.initDeck = async () => {
      const {Deck, OrbitView, COORDINATE_SYSTEM} = await import("@deck.gl/core")
      const {LineLayer, PointCloudLayer} = await import("@deck.gl/layers")
      const {HexagonLayer} = await import("@deck.gl/aggregation-layers")

      this.resizeDeck()

      let data = []

      try {
        const response = await fetch(apiUrl, {credentials: "same-origin"})
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        const payload = await response.json()

        data = Array.isArray(payload?.data) ? payload.data.map(normalizeSample).filter(Boolean) : []
        this.setEmptyState(data.length === 0 ? "empty" : null)
      } catch (error) {
        this.setEmptyState("error", error?.message || "The spatial sample API did not return usable data.")
      }

      const gridLayer = new LineLayer({
        id: "spatial-reference-grid",
        data: referenceGridLines(),
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getSourcePosition: (d) => d.source,
        getTargetPosition: (d) => d.target,
        getColor: (d) => d.axis ? [56, 189, 248, 130] : [45, 212, 191, 36],
        getWidth: (d) => d.axis ? 2 : 1,
        widthUnits: "pixels",
        pickable: false,
      })

      // Hexagon layer representing dense RF coverage aggregation
      const hexLayer = new HexagonLayer({
        id: "rf-hexagon-layer",
        data,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        pickable: true,
        extruded: true,
        radius: 1.5, // 1.5 meters per hex cell
        elevationScale: 4,
        getPosition: (d) => [d.x, d.y],
        // Aggregate color by average RSSI. Closer to 0 = stronger = brighter green.
        getColorValue: (points) => {
          const avg = points.reduce((sum, p) => sum + p.rssi, 0) / points.length
          return avg
        },
        colorRange: [
          [255, 64, 64], // Red (Weak)
          [255, 162, 50], // Orange
          [255, 255, 0], // Yellow
          [0, 255, 0], // Green
          [0, 224, 255], // Cyan (Strong)
          [214, 97, 255], // Purple (Excellent)
        ],
        colorDomain: [-90, -40], // RSSI bounds
        getElevationValue: (points) => points.length, // Taller hex = more density
      })

      // Point cloud layer representing raw LiDAR/ARKit geometry or Wi-Fi vectors
      const pointCloudLayer = new PointCloudLayer({
        id: "lidar-point-cloud",
        data,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getPosition: (d) => [d.x, d.y, d.z],
        getNormal: [0, 1, 0],
        getColor: (d) => {
          // Map RSSI to a heatmap gradient for the point cloud
          const normalized = Math.max(0, Math.min(1, (d.rssi + 90) / 50))
          return [Math.floor(255 * (1 - normalized)), Math.floor(255 * normalized), 200, 200]
        },
        pointSize: 4,
        sizeUnits: "pixels",
      })

      this.deck = new Deck({
        canvas: this.el,
        views: new OrbitView({
          id: "orbit-view",
          orbitAxis: "Z",
        }),
        initialViewState: {
          target: [0, 0, 0],
          zoom: 4,
          rotationX: 60,
          rotationOrbit: 45,
        },
        controller: true,
        parameters: {
          clearColor: [0.02, 0.04, 0.08, 1],
        },
        layers: [gridLayer, hexLayer, pointCloudLayer],
      })

      this.resizeDeck()
    }

    this.resizeObserver = new ResizeObserver(this.resizeDeck)
    this.resizeObserver.observe(this.el.parentElement || this.el)
    this.setEmptyState("loading", "Preparing the FieldSurvey renderer and loading sample data.")
    this.initDeck()
  },
  destroyed() {
    this.resizeObserver?.disconnect()
    this.emptyState?.remove()
    if (this.deck) {
      this.deck.finalize()
      this.deck = null
    }
  },
}

function normalizeSample(sample) {
  const x = Number(sample?.x)
  const y = Number(sample?.y)
  const z = Number(sample?.z || 0)
  const rssi = Number(sample?.rssi)

  if (!Number.isFinite(x) || !Number.isFinite(y)) return null

  return {
    ...sample,
    x,
    y,
    z: Number.isFinite(z) ? z : 0,
    rssi: Number.isFinite(rssi) ? rssi : -90,
  }
}

function referenceGridLines() {
  const lines = []
  const extent = 20

  for (let value = -extent; value <= extent; value += 5) {
    lines.push({
      source: [-extent, value, 0],
      target: [extent, value, 0],
      axis: value === 0,
    })
    lines.push({
      source: [value, -extent, 0],
      target: [value, extent, 0],
      axis: value === 0,
    })
  }

  return lines
}
