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

function formatRate(value) {
  const bps = Number(value || 0)
  if (bps >= 1_000_000_000) return `${(bps / 1_000_000_000).toFixed(1)} Gbps`
  if (bps >= 1_000_000) return `${(bps / 1_000_000).toFixed(1)} Mbps`
  if (bps >= 1_000) return `${(bps / 1_000).toFixed(1)} Kbps`
  if (bps > 0) return `${bps.toFixed(0)} bps`
  return "No rate"
}

function sparklineSvg(points, label, escapeHtml) {
  if (!Array.isArray(points) || points.length < 2) return ""

  const values = points.map((point) => Math.max(0, Number(point?.value ?? point ?? 0)))
  const maxValue = Math.max(...values)
  if (!Number.isFinite(maxValue) || maxValue <= 0) return ""

  const width = 168
  const height = 38
  const step = width / Math.max(values.length - 1, 1)
  const polyline = values
    .map((value, idx) => {
      const x = Math.round(idx * step * 10) / 10
      const y = Math.round((height - (value / maxValue) * (height - 4) - 2) * 10) / 10
      return `${x},${y}`
    })
    .join(" ")

  return `
    <div class="mt-2 border-t border-base-content/10 pt-2">
      <div class="mb-1 text-[10px] uppercase tracking-wide opacity-70">${escapeHtml(label || "Recent interface rate")}</div>
      <svg viewBox="0 0 ${width} ${height}" role="img" aria-label="Interface rate sparkline" style="width: 100%; height: 38px;">
        <polyline points="${polyline}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" opacity="0.9"></polyline>
      </svg>
      <div class="text-[10px] opacity-70">Peak ${escapeHtml(formatRate(maxValue))}</div>
    </div>
  `
}

export const godViewRenderingTooltipMethods = {
  displayNodeLabel(object, details = {}) {
    const label = typeof object?.label === "string" ? object.label.trim() : ""
    const ip = typeof details?.ip === "string" ? details.ip.trim() : ""
    const mac = typeof details?.mac === "string" ? details.mac.trim() : ""
    const placeholder = details?.cluster_placeholder === true

    if (label !== "" && !label.startsWith("sr:")) return label
    if (ip !== "" && !["unknown", "n/a", "na", "null", "undefined", "-"].includes(ip.toLowerCase())) return ip
    if (mac !== "") return mac
    if (placeholder) return "Unidentified endpoint"
    return label || "node"
  },
  getNodeTooltip({object, layer}) {
    if (!object) return null
    if (layer?.id === "god-view-edges-mantle" || layer?.id === "god-view-edges-crust") {
      const connection = object.connectionLabel || "LINK"
      const details = object.details && typeof object.details === "object" ? object.details : {}
      const interfaces = [details.source_interface, details.target_interface].filter(Boolean).join(" -> ")
      const sparkline = sparklineSvg(
        details.interface_sparkline,
        details.interface_sparkline_label,
        this.escapeHtml.bind(this),
      )

      return {
        html: [
          `<div class="font-semibold">${this.escapeHtml(connection)}</div>`,
          `<div>${this.escapeHtml(this.formatPps(object.flowPps || 0))}</div>`,
          `<div>${this.escapeHtml(this.formatCapacity(object.capacityBps || 0))}</div>`,
          interfaces ? `<div>Interfaces: ${this.escapeHtml(interfaces)}</div>` : "",
          details.telemetry_source ? `<div>Telemetry: ${this.escapeHtml(details.telemetry_source)}</div>` : "",
          sparkline,
        ].filter(Boolean).join(""),
        style: tooltipStyle(),
      }
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
    const placementState = d.topology_unplaced === true ? "Unplaced" : ""
    const placementReason =
      typeof d.topology_placement_reason === "string" && d.topology_placement_reason.trim() !== ""
        ? d.topology_placement_reason.trim()
        : ""
    const geo = [d.geo_city, d.geo_country].filter(Boolean).join(", ")
    const displayLabel = this.displayNodeLabel(object, d)
    return {
      html: [
        `<div class="font-semibold">${this.escapeHtml(displayLabel)}</div>`,
        `<div>IP: ${ipText}</div>`,
        `<div>Type: ${this.escapeHtml(d.type || "unknown")}</div>`,
        placementState ? `<div>Placement: ${this.escapeHtml(placementState)}</div>` : "",
        placementReason ? `<div>${this.escapeHtml(placementReason)}</div>` : "",
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
