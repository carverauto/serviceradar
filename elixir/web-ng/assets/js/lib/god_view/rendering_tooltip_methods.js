export const godViewRenderingTooltipMethods = {
  getNodeTooltip({object, layer}) {
    if (!object) return null
    if (layer?.id === "god-view-edges-mantle" || layer?.id === "god-view-edges-crust") {
      const connection = object.connectionLabel || "LINK"
      return {text: `${connection}\n${this.formatPps(object.flowPps || 0)}\n${this.formatCapacity(object.capacityBps || 0)}`}
    }
    if (layer?.id === "god-view-mtr-paths") {
      return this.getMtrPathTooltip(object)
    }
    if (layer?.id !== "god-view-nodes") return null
    const d = object?.details || {}
    const rawIp = typeof d.ip === "string" ? d.ip.trim() : ""
    const hasRealIp =
      rawIp !== "" && !["unknown", "n/a", "na", "null", "undefined", "-"].includes(rawIp.toLowerCase())
    const ipText = this.escapeHtml(hasRealIp ? rawIp : "unknown")
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
        `<div>IP: ${ipText}</div>`,
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
        pointerEvents: "none",
        whiteSpace: "normal",
      },
    }
  },
  getMtrPathTooltip(object) {
    if (!object) return null
    const latency = this.formatMtrLatency(object.avgUs || 0)
    const jitter = this.formatMtrLatency(object.jitterUs || 0)
    const lossValue = Number(object.lossPct)
    const loss = `${(Number.isFinite(lossValue) ? lossValue : 0).toFixed(1)}%`
    const hasHops = Number.isFinite(object.fromHop) && Number.isFinite(object.toHop)
    const hops = hasHops ? `Hop ${object.fromHop} → ${object.toHop}` : ""
    const agent = object.agentId ? `Agent: ${this.escapeHtml(object.agentId)}` : ""
    const srcAddr = object.sourceAddr || ""
    const dstAddr = object.targetAddr || ""
    return {
      html: [
        `<div class="font-semibold">MTR Path</div>`,
        srcAddr || dstAddr ? `<div>${this.escapeHtml(srcAddr)} → ${this.escapeHtml(dstAddr)}</div>` : "",
        hops ? `<div>${hops}</div>` : "",
        `<div>Latency: ${latency}</div>`,
        `<div>Loss: ${loss}</div>`,
        `<div>Jitter: ${jitter}</div>`,
        agent ? `<div>${agent}</div>` : "",
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
        pointerEvents: "none",
        whiteSpace: "normal",
      },
    }
  },
  edgeLayerId(layerId) {
    return layerId === "god-view-edges-mantle" || layerId === "god-view-edges-crust"
  },
  handleHover(info) {
    const layerId = info?.layer?.id || ""
    const nextNodeIndex =
      (layerId === "god-view-nodes" || layerId === "god-view-node-labels") && Number.isInteger(info?.object?.index)
        ? info.object.index
        : null
    const isMtrPath = layerId === "god-view-mtr-paths"
    const nextKey =
      (this.edgeLayerId(layerId) || isMtrPath) && typeof info?.object?.interactionKey === "string"
        ? info.object.interactionKey
        : null
    if (this.state.hoveredEdgeKey === nextKey && this.state.hoveredNodeIndex === nextNodeIndex) return
    this.state.hoveredEdgeKey = nextKey
    this.state.hoveredNodeIndex = nextNodeIndex
    if (this.state.canvas && !this.state.dragState && !this.state.pendingDragState) {
      this.state.canvas.style.cursor = nextKey || nextNodeIndex !== null ? "pointer" : "grab"
    }
    if (this.state.lastGraph) this.renderGraph(this.state.lastGraph)
  },
  edgeIsFocused(edge) {
    if (!edge) return false
    const key = edge.interactionKey
    return key != null && (key === this.state.hoveredEdgeKey || key === this.state.selectedEdgeKey)
  },
}
