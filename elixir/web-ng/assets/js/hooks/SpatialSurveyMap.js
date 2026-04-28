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
      const {LineLayer, PointCloudLayer, SolidPolygonLayer} = await import("@deck.gl/layers")

      this.resizeDeck()

      let artifacts = []
      let floorplanSegments = []
      let pointCloud = []

      try {
        const response = await fetch(apiUrl, {credentials: "same-origin"})
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        const payload = await response.json()
        const scene = payload?.data

        if (!Array.isArray(scene)) {
          artifacts = Array.isArray(scene?.artifacts) ? scene.artifacts : []
          floorplanSegments = Array.isArray(scene?.floorplan_segments)
            ? scene.floorplan_segments.map(normalizeFloorplanSegment).filter(Boolean)
            : []

          if (floorplanSegments.length === 0 && scene?.point_cloud_artifact?.download_url) {
            pointCloud = await loadPointCloud(scene.point_cloud_artifact.download_url, floorplanSegments)
          }
        }

        const hasRenderableRoom = pointCloud.length > 0 || floorplanSegments.length > 0
        const hasRoomPlanOnly = artifacts.some((artifact) => artifact?.artifact_type === "roomplan_usdz") && !hasRenderableRoom
        const emptyDetail = hasRoomPlanOnly
          ? "RoomPlan USDZ is stored, but no browser-renderable floorplan or point-cloud artifact was uploaded for this session yet."
          : "FieldSurvey room scan uploads will appear here once RoomPlan floorplan or point-cloud artifacts are ingested."
        this.setEmptyState(!hasRenderableRoom ? "empty" : null, emptyDetail)
      } catch (error) {
        this.setEmptyState("error", error?.message || "The spatial sample API did not return usable data.")
      }

      const roomSurfaces = roomSurfacesFromSegments(floorplanSegments)
      const structuralLines = roomStructuralLines(floorplanSegments)
      const sceneBounds = boundsForScene(floorplanSegments, pointCloud)

      const gridLayer = new LineLayer({
        id: "spatial-reference-grid",
        data: referenceGridLines(sceneBounds),
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getSourcePosition: (d) => d.source,
        getTargetPosition: (d) => d.target,
        getColor: (d) => d.axis ? [56, 189, 248, 130] : [45, 212, 191, 36],
        getWidth: (d) => d.axis ? 2 : 1,
        widthUnits: "pixels",
        pickable: false,
      })

      const wallSurfaceLayer = new SolidPolygonLayer({
        id: "roomplan-wall-surfaces",
        data: roomSurfaces,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getPolygon: (d) => d.polygon,
        getFillColor: (d) => d.color,
        material: {
          ambient: 0.52,
          diffuse: 0.82,
          shininess: 18,
          specularColor: [80, 110, 120],
        },
        _full3d: true,
        pickable: true,
      })

      const structureLineLayer = new LineLayer({
        id: "roomplan-structure-lines",
        data: structuralLines,
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getSourcePosition: (d) => d.source,
        getTargetPosition: (d) => d.target,
        getColor: (d) => d.color,
        getWidth: (d) => d.width,
        widthUnits: "pixels",
        pickable: true,
      })

      // Raw ARKit feature points are noisy, so only use them when no RoomPlan floorplan
      // is available. The review page owns RF/heatmap rendering.
      const pointCloudLayer = new PointCloudLayer({
        id: "lidar-point-cloud",
        data: floorplanSegments.length === 0 ? pointCloud : [],
        coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
        getPosition: (d) => d.position,
        getNormal: [0, 1, 0],
        getColor: (d) => d.color,
        pointSize: 1.4,
        sizeUnits: "pixels",
      })

      this.deck = new Deck({
        canvas: this.el,
        views: new OrbitView({
          id: "orbit-view",
          orbitAxis: "Z",
        }),
        initialViewState: viewStateForBounds(sceneBounds),
        controller: true,
        parameters: {
          clearColor: [0.02, 0.04, 0.08, 1],
        },
        layers: [gridLayer, wallSurfaceLayer, structureLineLayer, pointCloudLayer],
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

function normalizeFloorplanSegment(segment) {
  const startX = Number(segment?.start_x)
  const startZ = Number(segment?.start_z)
  const endX = Number(segment?.end_x)
  const endZ = Number(segment?.end_z)
  const height = Number(segment?.height)

  if (![startX, startZ, endX, endZ].every(Number.isFinite)) return null

  return {
    kind: segment?.kind || "wall",
    startX,
    startZ,
    endX,
    endZ,
    height: Number.isFinite(height) && height > 0.3 ? Math.min(height, 4) : 2.55,
  }
}

async function loadPointCloud(downloadUrl, floorplanSegments) {
  try {
    const response = await fetch(downloadUrl, {credentials: "same-origin"})
    if (!response.ok) return []
    const text = await response.text()
    return parseAsciiPly(text, floorplanSegments)
  } catch (_error) {
    return []
  }
}

function parseAsciiPly(text, floorplanSegments) {
  const lines = text.split(/\r?\n/)
  const endHeader = lines.findIndex((line) => line.trim() === "end_header")
  if (endHeader < 0 || !lines.some((line) => line.trim() === "format ascii 1.0")) return []

  const vertexLine = lines.find((line) => line.startsWith("element vertex "))
  const vertexCount = Number(vertexLine?.split(/\s+/)[2])
  if (!Number.isFinite(vertexCount) || vertexCount <= 0) return []

  const vertices = []
  for (let index = 0; index < vertexCount; index += 1) {
    const fields = lines[endHeader + 1 + index]?.trim().split(/\s+/).map(Number)
    if (!fields || fields.length < 3) continue

    const [x, y, z, red, green, blue] = fields
    if (![x, y, z].every(Number.isFinite)) continue

    vertices.push({
      x,
      y,
      z,
      position: [x, z, y],
      color: [red || 178, green || 205, blue || 220, 185],
    })
  }

  return downsamplePointCloud(trimPointCloud(vertices, floorplanSegments), 180000)
}

function trimPointCloud(vertices, floorplanSegments) {
  if (vertices.length === 0) return []

  const bounds = floorplanBounds(floorplanSegments) || robustPointBounds(vertices)
  if (!bounds) return vertices

  const margin = floorplanSegments.length > 0 ? 1.2 : 0
  const minY = floorplanSegments.length > 0 ? -0.75 : bounds.minY
  const maxY = floorplanSegments.length > 0 ? 3.6 : bounds.maxY

  return vertices.filter((vertex) =>
    vertex.x >= bounds.minX - margin &&
    vertex.x <= bounds.maxX + margin &&
    vertex.z >= bounds.minZ - margin &&
    vertex.z <= bounds.maxZ + margin &&
    vertex.y >= minY &&
    vertex.y <= maxY
  )
}

function downsamplePointCloud(vertices, maxPoints) {
  if (vertices.length <= maxPoints) return vertices

  const stride = Math.ceil(vertices.length / maxPoints)
  const sampled = []
  for (let index = 0; index < vertices.length && sampled.length < maxPoints; index += stride) {
    sampled.push(vertices[index])
  }
  return sampled
}

function robustPointBounds(vertices) {
  return {
    minX: percentile(vertices.map((point) => point.x), 0.01),
    maxX: percentile(vertices.map((point) => point.x), 0.99),
    minY: percentile(vertices.map((point) => point.y), 0.01),
    maxY: percentile(vertices.map((point) => point.y), 0.99),
    minZ: percentile(vertices.map((point) => point.z), 0.01),
    maxZ: percentile(vertices.map((point) => point.z), 0.99),
  }
}

function percentile(values, ratio) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b)
  if (sorted.length === 0) return 0
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.floor((sorted.length - 1) * ratio)))]
}

function roomSurfacesFromSegments(segments) {
  return segments.map((segment) => {
    const color = wallFillColor(segment.kind)
    const baseStart = [segment.startX, segment.startZ, 0]
    const baseEnd = [segment.endX, segment.endZ, 0]
    const topEnd = [segment.endX, segment.endZ, segment.height]
    const topStart = [segment.startX, segment.startZ, segment.height]

    return {
      kind: segment.kind,
      polygon: [baseStart, baseEnd, topEnd, topStart],
      color,
    }
  })
}

function roomStructuralLines(segments) {
  return segments.flatMap((segment) => {
    const color = floorplanColor(segment.kind)
    const width = segment.kind === "wall" ? 3 : 2
    const startBottom = [segment.startX, segment.startZ, 0.02]
    const endBottom = [segment.endX, segment.endZ, 0.02]
    const startTop = [segment.startX, segment.startZ, segment.height]
    const endTop = [segment.endX, segment.endZ, segment.height]

    return [
      {source: startBottom, target: endBottom, color, width},
      {source: startTop, target: endTop, color, width},
      {source: startBottom, target: startTop, color: [...color.slice(0, 3), 120], width: 1},
      {source: endBottom, target: endTop, color: [...color.slice(0, 3), 120], width: 1},
    ]
  })
}

function floorplanBounds(segments) {
  if (segments.length === 0) return null

  const xs = segments.flatMap((segment) => [segment.startX, segment.endX])
  const zs = segments.flatMap((segment) => [segment.startZ, segment.endZ])
  const heights = segments.map((segment) => segment.height)

  return {
    minX: Math.min(...xs),
    maxX: Math.max(...xs),
    minY: 0,
    maxY: Math.max(...heights, 2.55),
    minZ: Math.min(...zs),
    maxZ: Math.max(...zs),
  }
}

function boundsForScene(segments, pointCloud) {
  const roomBounds = floorplanBounds(segments)
  if (roomBounds) return roomBounds
  const pointBounds = robustPointBounds(pointCloud)
  if (pointCloud.length > 0) return pointBounds
  return {minX: -5, maxX: 5, minY: 0, maxY: 3, minZ: -5, maxZ: 5}
}

function viewStateForBounds(bounds) {
  const centerX = (bounds.minX + bounds.maxX) / 2
  const centerY = (bounds.minZ + bounds.maxZ) / 2
  const centerZ = Math.max(0.8, (bounds.minY + bounds.maxY) / 2)
  const span = Math.max(bounds.maxX - bounds.minX, bounds.maxZ - bounds.minZ, 3)

  return {
    target: [centerX, centerY, centerZ],
    zoom: Math.max(3.4, Math.min(7.0, 8.1 - Math.log2(span))),
    rotationX: 58,
    rotationOrbit: 38,
  }
}

function floorplanColor(kind) {
  if (kind === "door") return [255, 255, 255, 210]
  if (kind === "window") return [125, 211, 252, 220]
  return [103, 232, 249, 220]
}

function wallFillColor(kind) {
  if (kind === "door") return [226, 232, 240, 85]
  if (kind === "window") return [125, 211, 252, 95]
  return [103, 232, 249, 80]
}

function referenceGridLines(bounds) {
  const lines = []
  const minX = Math.floor((bounds.minX - 4) / 2) * 2
  const maxX = Math.ceil((bounds.maxX + 4) / 2) * 2
  const minZ = Math.floor((bounds.minZ - 4) / 2) * 2
  const maxZ = Math.ceil((bounds.maxZ + 4) / 2) * 2

  for (let value = minZ; value <= maxZ; value += 2) {
    lines.push({
      source: [minX, value, 0],
      target: [maxX, value, 0],
      axis: value === 0,
    })
  }

  for (let value = minX; value <= maxX; value += 2) {
    lines.push({
      source: [value, minZ, 0],
      target: [value, maxZ, 0],
      axis: value === 0,
    })
  }

  return lines
}
