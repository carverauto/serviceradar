export const godViewRenderingTooltipMethods = {
  getNodeTooltip({object, layer}) {
    if (!object) return null
    if (layer?.id === "god-view-edges-mantle" || layer?.id === "god-view-edges-crust") {
      const connection = object.connectionLabel || "LINK"
      return {text: `${connection}\n${this.formatPps(object.flowPps || 0)}\n${this.formatCapacity(object.capacityBps || 0)}`}
    }
    if (layer?.id !== "god-view-nodes") return null
    const d = object?.details || {}
    const nodeMap = this.nodeIndexLookup((this.state.lastGraph?.nodes || []))
    const reason = this.escapeHtml(object.stateReason || this.defaultStateReason(object.state))
    const rootRef = this.nodeReferenceAction(
      d?.causal_root_index,
      "Root",
      nodeMap,
    )
    const parentRef = this.nodeReferenceAction(
      d?.causal_parent_index,
      "Parent",
      nodeMap,
    )
    const geo = [d.geo_city, d.geo_country].filter(Boolean).join(", ")
    return {
      html: [
        `<div class="font-semibold">${this.escapeHtml(object.label || "node")}</div>`,
        `<div>IP: ${this.escapeHtml(d.ip || "unknown")}</div>`,
        `<div>Type: ${this.escapeHtml(d.type || "unknown")}</div>`,
        `<div>State: ${this.escapeHtml(this.stateDisplayName(object.state))}</div>`,
        `<div>Why: ${reason}</div>`,
        rootRef,
        parentRef,
        geo ? `<div>Geo: ${this.escapeHtml(geo)}</div>` : "",
        d.asn ? `<div>ASN: ${this.escapeHtml(d.asn)}</div>` : "",
      ].filter(Boolean).join(""),
      style: {
        backgroundColor: "rgba(15, 23, 42, 0.8)",
        backdropFilter: "blur(12px)",
        WebkitBackdropFilter: "blur(12px)",
        border: "1px solid rgba(148, 163, 184, 0.15)",
        borderRadius: "10px",
        boxShadow: "0 8px 32px rgba(0, 0, 0, 0.4)",
        color: "#e2e8f0",
        fontFamily: "ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Inter', sans-serif",
        fontSize: "12px",
        letterSpacing: "0.2px",
        lineHeight: "1.35",
        maxWidth: "360px",
        padding: "8px 10px",
        pointerEvents: "auto",
        whiteSpace: "normal",
      },
    }
  },
  edgeLayerId(layerId) {
    return layerId === "god-view-edges-mantle" || layerId === "god-view-edges-crust"
  },
  handleHover(info) {
    const layerId = info?.layer?.id || ""
    const nextKey =
      this.edgeLayerId(layerId) && typeof info?.object?.interactionKey === "string"
        ? info.object.interactionKey
        : null
    if (this.state.hoveredEdgeKey === nextKey) return
    this.state.hoveredEdgeKey = nextKey
    if (this.state.lastGraph) this.renderGraph(this.state.lastGraph)
  },
  edgeIsFocused(edge) {
    if (!edge) return false
    const key = edge.interactionKey
    return key != null && (key === this.state.hoveredEdgeKey || key === this.state.selectedEdgeKey)
  },
}
