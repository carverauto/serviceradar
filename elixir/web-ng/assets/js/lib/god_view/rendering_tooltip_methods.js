import {detectThemeMode} from "./lifecycle_bootstrap_state_defaults_methods"

function tooltipStyle() {
  const dark = detectThemeMode() === "dark"
  return {
    backgroundColor: dark ? "rgba(19, 19, 22, 0.9)" : "rgba(255, 255, 255, 0.92)",
    backdropFilter: "blur(12px)",
    WebkitBackdropFilter: "blur(12px)",
    border: dark ? "1px solid rgba(39, 39, 42, 0.4)" : "1px solid rgba(226, 232, 240, 0.6)",
    borderRadius: "10px",
    boxShadow: dark ? "0 8px 32px rgba(0, 0, 0, 0.5)" : "0 8px 32px rgba(0, 0, 0, 0.1)",
    color: dark ? "#F4F4F5" : "#0F172A",
    fontFamily: "ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Inter', sans-serif",
    fontSize: "12px",
    letterSpacing: "0.2px",
    lineHeight: "1.35",
    maxWidth: "360px",
    padding: "8px 10px",
    pointerEvents: "none",
    whiteSpace: "normal",
  }
}

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
    const clusterId = typeof d.cluster_id === "string" ? d.cluster_id.trim() : ""
    const clusterExpanded = d.cluster_expanded === true
    const clusterExpandable = d.cluster_expandable === true
    const clusterKind = typeof d.cluster_kind === "string" ? d.cluster_kind.trim() : ""
    const clusterHint =
      clusterId !== "" && clusterExpandable && (clusterKind === "endpoint-summary" || clusterKind === "endpoint-anchor")
        ? `<div class="opacity-80">${clusterExpanded ? "Click to collapse endpoints" : "Click to expand endpoints"}</div>`
        : ""
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
        clusterHint,
      ].filter(Boolean).join(""),
      style: tooltipStyle(),
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
      style: tooltipStyle(),
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
