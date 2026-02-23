export const godViewRenderingStyleNodeVisualMethods = {
  nodeMetricText(node, shape) {
    const clusterCount = Number(node?.clusterCount || 1)
    if (shape === "global" || shape === "regional") {
      return `${clusterCount} node${clusterCount === 1 ? "" : "s"}`
    }
    return this.formatPps(node?.pps || 0)
  },
  nodeColor(state) {
    if (state === 0) return this.state.visual.nodeRoot
    if (state === 1) return this.state.visual.nodeAffected
    if (state === 2) return this.state.visual.nodeHealthy
    return this.state.visual.nodeUnknown
  },
  nodeNeutralColor(operUp) {
    if (Number(operUp) === 1) return [56, 189, 248, 230]
    if (Number(operUp) === 2) return [120, 113, 108, 220]
    return [100, 116, 139, 220]
  },
  nodeStatusIcon(operUp) {
    if (Number(operUp) === 1) return "UP"
    if (Number(operUp) === 2) return "DN"
    return "UNK"
  },
  nodeStatusColor(operUp) {
    if (Number(operUp) === 1) return [34, 197, 94, 230]
    if (Number(operUp) === 2) return [239, 68, 68, 230]
    return [148, 163, 184, 220]
  },
  normalizeDisplayLabel(value, fallback = "node") {
    const label = String(value == null ? "" : value).trim()
    if (label === "") return fallback
    const lowered = label.toLowerCase()
    if (lowered === "nil" || lowered === "null" || lowered === "undefined") return fallback
    return label
  },
}
