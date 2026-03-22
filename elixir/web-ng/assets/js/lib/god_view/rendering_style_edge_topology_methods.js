const TOPOLOGY_VISUAL_PROFILES = {
  backbone: {
    mantleAlphaScale: 1.0,
    mantleAlphaFloor: 24,
    mantleWidthScale: 1.0,
    crustAlphaScale: 1.0,
    crustAlphaFloor: 28,
    crustWidthScale: 1.0,
    particleDensityScale: 1.0,
    particleAlphaScale: 1.0,
    particleSizeScale: 1.0,
  },
  inferred: {
    mantleAlphaScale: 0.8,
    mantleAlphaFloor: 20,
    mantleWidthScale: 0.88,
    crustAlphaScale: 0.82,
    crustAlphaFloor: 24,
    crustWidthScale: 0.9,
    particleDensityScale: 0.72,
    particleAlphaScale: 0.8,
    particleSizeScale: 0.92,
  },
  endpoints: {
    mantleAlphaScale: 0.48,
    mantleAlphaFloor: 16,
    mantleWidthScale: 0.68,
    crustAlphaScale: 0.56,
    crustAlphaFloor: 20,
    crustWidthScale: 0.74,
    particleDensityScale: 0.28,
    particleAlphaScale: 0.42,
    particleSizeScale: 0.82,
  },
  unknown: {
    mantleAlphaScale: 0.9,
    mantleAlphaFloor: 22,
    mantleWidthScale: 0.94,
    crustAlphaScale: 0.9,
    crustAlphaFloor: 24,
    crustWidthScale: 0.94,
    particleDensityScale: 0.85,
    particleAlphaScale: 0.88,
    particleSizeScale: 0.96,
  },
}

function normalizeTopologyClass(value) {
  const normalized = String(value || "").trim().toLowerCase()
  if (normalized === "endpoint") return "endpoints"
  if (
    normalized === "inferred" ||
    normalized === "endpoints" ||
    normalized === "backbone" ||
    normalized === "unknown"
  ) {
    return normalized
  }

  return "unknown"
}

function dominantTopologyClassFromCounts(classCounts) {
  if (!classCounts || typeof classCounts !== "object") return null

  const orderedCounts = [
    ["backbone", Number(classCounts.backbone || 0)],
    ["inferred", Number(classCounts.inferred || 0)],
    ["endpoints", Number(classCounts.endpoints || 0)],
    ["unknown", Number(classCounts.unknown || 0)],
  ]

  let bestClass = null
  let bestCount = -1
  for (const [name, count] of orderedCounts) {
    if (count > bestCount) {
      bestClass = name
      bestCount = count
    }
  }

  return bestCount > 0 ? bestClass : null
}

export function edgeTopologyClassValue(edge) {
  const explicit = normalizeTopologyClass(edge?.topologyClass)
  if (explicit !== "unknown") return explicit

  return dominantTopologyClassFromCounts(edge?.topologyClassCounts) || explicit
}

export function edgeTopologyVisualStyleValue(edge) {
  const topologyClass = edgeTopologyClassValue(edge)
  return TOPOLOGY_VISUAL_PROFILES[topologyClass] || TOPOLOGY_VISUAL_PROFILES.unknown
}

export const godViewRenderingStyleEdgeTopologyMethods = {
  edgeTopologyClass(edge) {
    return edgeTopologyClassValue(edge)
  },
  edgeTopologyVisualStyle(edge) {
    return edgeTopologyVisualStyleValue(edge)
  },
  edgeEnabledByTopologyLayer(edge) {
    const classCounts = edge?.topologyClassCounts
    if (classCounts && typeof classCounts === "object") {
      const showBackbone =
        Number(classCounts.backbone || 0) > 0 && this.state.topologyLayers.backbone !== false
      const showInferred =
        Number(classCounts.inferred || 0) > 0 && this.state.topologyLayers.inferred === true
      const showEndpoints =
        Number(classCounts.endpoints || 0) > 0 && this.state.topologyLayers.endpoints === true
      const showUnknown =
        Number(classCounts.unknown || 0) > 0 && this.state.topologyLayers.backbone !== false
      return showBackbone || showInferred || showEndpoints || showUnknown
    }

    const topologyClass = edgeTopologyClassValue(edge)
    if (topologyClass === "inferred") return this.state.topologyLayers.inferred === true
    if (topologyClass === "endpoints") return this.state.topologyLayers.endpoints === true
    return this.state.topologyLayers.backbone !== false
  },
}
