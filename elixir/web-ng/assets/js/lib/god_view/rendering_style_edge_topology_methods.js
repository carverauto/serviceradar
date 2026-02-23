export const godViewRenderingStyleEdgeTopologyMethods = {
  edgeTopologyClassFromLabel(label) {
    const text = String(label == null ? "" : label).trim().toUpperCase()
    if (text.includes(" ENDPOINT ")) return "endpoints"
    if (text.includes(" INFERRED ")) return "inferred"
    return "backbone"
  },
  edgeTopologyClass(edge) {
    const explicit = String(edge?.topologyClass || "").trim().toLowerCase()
    if (explicit === "inferred" || explicit === "endpoints" || explicit === "backbone") {
      return explicit
    }
    return this.edgeTopologyClassFromLabel(edge?.label || "")
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
      return showBackbone || showInferred || showEndpoints
    }

    const topologyClass = this.edgeTopologyClass(edge)
    if (topologyClass === "inferred") return this.state.topologyLayers.inferred === true
    if (topologyClass === "endpoints") return this.state.topologyLayers.endpoints === true
    return this.state.topologyLayers.backbone !== false
  },
}
