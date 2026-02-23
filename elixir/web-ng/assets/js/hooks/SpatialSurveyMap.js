export default {
  mounted() {
    const apiUrl = this.el.dataset.apiUrl
    this.deck = null

    this.initDeck = async () => {
      const {Deck, OrbitView, COORDINATE_SYSTEM} = await import("@deck.gl/core")
      const {PointCloudLayer} = await import("@deck.gl/layers")
      const {HexagonLayer} = await import("@deck.gl/aggregation-layers")

      const response = await fetch(apiUrl)
      const {data} = await response.json()

      // Hexagon layer representing dense RF coverage aggregation
      const hexLayer = new HexagonLayer({
        id: "rf-hexagon-layer",
        data,
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
          clearColor: [10, 10, 10, 255], // Match dark theme
        },
        layers: [hexLayer, pointCloudLayer],
      })
    }

    this.initDeck()
  },
  destroyed() {
    if (this.deck) {
      this.deck.finalize()
      this.deck = null
    }
  },
}
