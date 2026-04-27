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
        parent.querySelector(".is-static-spatial-empty")?.remove()
        return
      }

      if (!this.emptyState) {
        this.emptyState = parent.querySelector(".is-static-spatial-empty")
        if (!this.emptyState) {
          this.emptyState = document.createElement("div")
          this.emptyState.className = "sr-spatial-empty-state"
          parent.appendChild(this.emptyState)
        }
      }

      this.emptyState.classList.remove("is-static-spatial-empty")
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
      const {LineLayer, PointCloudLayer, ScatterplotLayer} = await import("@deck.gl/layers")
      const {HexagonLayer} = await import("@deck.gl/aggregation-layers")

      this.resizeDeck()

      let data = []
      let artifacts = []
      let floorplanSegments = []
      let pointCloud = []

      try {
        const response = await fetch(apiUrl, {credentials: "same-origin"})
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        const payload = await response.json()
        const scene = payload?.data

        if (Array.isArray(scene)) {
          data = scene.map(normalizeSample).filter(Boolean)
        } else {
          data = Array.isArray(scene?.samples) ? scene.samples.map(normalizeSample).filter(Boolean) : []
          artifacts = Array.isArray(scene?.artifacts) ? scene.artifacts : []
          floorplanSegments = Array.isArray(scene?.floorplan_segments)
            ? scene.floorplan_segments.map(normalizeFloorplanSegment).filter(Boolean)
            : []

          if (scene?.point_cloud_artifact?.download_url) {
            pointCloud = await loadPointCloud(scene.point_cloud_artifact.download_url)
          }
        }

        const hasRenderableRoom = pointCloud.length > 0 || floorplanSegments.length > 0
        const hasRoomPlanOnly = artifacts.some((artifact) => artifact?.artifact_type === "roomplan_usdz") && !hasRenderableRoom
        const emptyDetail = hasRoomPlanOnly
          ? "RoomPlan USDZ is stored, but no browser-renderable floorplan or point-cloud artifact was uploaded for this session yet."
          : "FieldSurvey uploads will appear here once pose, RF, and room scan artifacts are ingested."
        this.setEmptyState(data.length === 0 && !hasRenderableRoom ? "empty" : null, emptyDetail)
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

      const floorplanLayer = new LineLayer({
        id: "roomplan-floorplan",
        data: floorplanSegments,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getSourcePosition: (d) => [d.startX, d.startZ, 0.05],
        getTargetPosition: (d) => [d.endX, d.endZ, 0.05],
        getColor: (d) => floorplanColor(d.kind),
        getWidth: (d) => d.kind === "wall" ? 4 : 2,
        widthUnits: "pixels",
        pickable: true,
      })

      // Flat RF coverage aggregation. This is RF survey data, not LiDAR geometry.
      const hexLayer = new HexagonLayer({
        id: "rf-hexagon-layer",
        data,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        pickable: true,
        extruded: false,
        radius: 1.5, // 1.5 meters per hex cell
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
      })

      const rfPointLayer = new ScatterplotLayer({
        id: "rf-sample-points",
        data,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getPosition: (d) => [d.x, d.y, 0.08],
        getFillColor: (d) => rssiColor(d.rssi, 170),
        getLineColor: [255, 255, 255, 90],
        getRadius: 0.12,
        radiusUnits: "meters",
        lineWidthUnits: "pixels",
        lineWidthMinPixels: 1,
        stroked: true,
        filled: true,
        pickable: true,
      })

      // Point cloud layer for browser-renderable LiDAR artifacts, when uploaded.
      const pointCloudLayer = new PointCloudLayer({
        id: "lidar-point-cloud",
        data: pointCloud,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getPosition: (d) => d.position,
        getNormal: [0, 1, 0],
        getColor: (d) => d.color,
        pointSize: 2,
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
        layers: [gridLayer, floorplanLayer, hexLayer, rfPointLayer, pointCloudLayer],
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
  const floorY = Number(sample?.z)
  const height = Number(sample?.y || 0)
  const rssi = Number(sample?.rssi)

  if (!Number.isFinite(x) || !Number.isFinite(floorY)) return null

  return {
    ...sample,
    x,
    y: floorY,
    z: Number.isFinite(height) ? height : 0,
    rssi: Number.isFinite(rssi) ? rssi : -90,
  }
}

function normalizeFloorplanSegment(segment) {
  const startX = Number(segment?.start_x)
  const startZ = Number(segment?.start_z)
  const endX = Number(segment?.end_x)
  const endZ = Number(segment?.end_z)

  if (![startX, startZ, endX, endZ].every(Number.isFinite)) return null

  return {
    kind: segment?.kind || "wall",
    startX,
    startZ,
    endX,
    endZ,
  }
}

async function loadPointCloud(downloadUrl) {
  try {
    const response = await fetch(downloadUrl, {credentials: "same-origin"})
    if (!response.ok) return []
    const text = await response.text()
    return parseAsciiPly(text)
  } catch (_error) {
    return []
  }
}

function parseAsciiPly(text) {
  const lines = text.split(/\r?\n/)
  const endHeader = lines.findIndex((line) => line.trim() === "end_header")
  if (endHeader < 0 || !lines.some((line) => line.trim() === "format ascii 1.0")) return []

  const vertexLine = lines.find((line) => line.startsWith("element vertex "))
  const vertexCount = Number(vertexLine?.split(/\s+/)[2])
  if (!Number.isFinite(vertexCount) || vertexCount <= 0) return []

  const vertices = []
  const limit = Math.min(vertexCount, 500000)
  for (let index = 0; index < limit; index += 1) {
    const fields = lines[endHeader + 1 + index]?.trim().split(/\s+/).map(Number)
    if (!fields || fields.length < 3) continue

    const [x, y, z, red, green, blue] = fields
    if (![x, y, z].every(Number.isFinite)) continue

    vertices.push({
      position: [x, z, y],
      color: [red || 180, green || 210, blue || 220, 220],
    })
  }
  return vertices
}

function rssiColor(rssi, alpha = 210) {
  if (rssi >= -50) return [34, 197, 94, alpha]
  if (rssi >= -60) return [132, 204, 22, alpha]
  if (rssi >= -70) return [250, 204, 21, alpha]
  if (rssi >= -80) return [249, 115, 22, alpha]
  return [239, 68, 68, alpha]
}

function floorplanColor(kind) {
  if (kind === "door") return [255, 255, 255, 210]
  if (kind === "window") return [125, 211, 252, 220]
  return [103, 232, 249, 220]
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
