export const godViewRenderingSelectionMethods = {
  renderSelectionDetails(node) {
    if (!this.state.details) return
    if (!node) {
      if (!this.state.details.classList.contains("hidden")) {
        this.state.details.classList.add("hidden")
      }
      if (this.state.details.textContent !== "Select a node for details") {
        this.state.details.textContent = "Select a node for details"
      }
      this.state.lastDetailsHtml = null
      return
    }

    const d = node.details || {}
    const typeLabel = typeof d.type === "string" ? d.type : ""
    const typeId = this.parseTypeId(d.type_id)
    const typeIcon = this.nodeTypeHeroIcon(typeLabel, typeId)
    const detailId = d.id || node.id
    const rawIp = typeof d.ip === "string" ? d.ip.trim() : ""
    const hasRealIp =
      rawIp !== "" && !["unknown", "n/a", "na", "null", "undefined", "-"].includes(rawIp.toLowerCase())
    const ipText = this.escapeHtml(hasRealIp ? rawIp : "unknown")
    const ipHref = hasRealIp ? this.deviceDetailsHref(detailId) : null
    const ipLine = ipHref
      ? `<div>IP: <button type="button" class="link link-primary" data-device-href="${this.escapeHtml(ipHref)}">${ipText}</button></div>`
      : `<div>IP: ${ipText}</div>`
    const nodeMap = this.nodeIndexLookup((this.state.lastGraph?.nodes || []))
    const reason = this.escapeHtml(node.stateReason || this.defaultStateReason(node.state))
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
    const detailLines = [
      `<div class="font-semibold text-sm mb-1 flex items-center justify-between gap-2"><span>${this.escapeHtml(node.label || "node")}</span><span class="inline-flex items-center justify-end min-w-4">${typeIcon ? `<span class="${this.escapeHtml(typeIcon)} size-4 text-base-content/70" title="${this.escapeHtml(typeLabel || "unknown")}"></span>` : ""}</span></div>`,
      `<div>ID: ${this.escapeHtml(d.id || node.id || "unknown")}</div>`,
      ipLine,
      `<div>Type: ${this.escapeHtml(d.type || "unknown")}</div>`,
      `<div>State: ${this.escapeHtml(this.stateDisplayName(node.state))}</div>`,
      `<div>Why: ${reason}</div>`,
      rootRef,
      parentRef,
      `<div>Vendor/Model: ${this.escapeHtml(`${d.vendor || "—"} ${d.model || ""}`.trim())}</div>`,
      `<div>Last Seen: ${this.escapeHtml(d.last_seen || "unknown")}</div>`,
      `<div>ASN: ${this.escapeHtml(d.asn || "unknown")}</div>`,
      `<div>Geo: ${this.escapeHtml([d.geo_city, d.geo_country].filter(Boolean).join(", ") || "unknown")}</div>`,
    ].filter(Boolean)

    const nextHtml = detailLines.join("")
    if (this.state.lastDetailsHtml !== nextHtml) {
      this.state.details.innerHTML = nextHtml
      this.state.lastDetailsHtml = nextHtml
    }
    if (this.state.details.classList.contains("hidden")) {
      this.state.details.classList.remove("hidden")
    }
  },
  deviceDetailsHref(deviceId) {
    if (typeof deviceId !== "string" || deviceId.trim() === "") return null
    return `/devices/${encodeURIComponent(deviceId.trim())}`
  },
  parseTypeId(value) {
    if (Number.isInteger(value)) return value
    if (typeof value === "string" && value.trim() !== "") {
      const parsed = Number.parseInt(value.trim(), 10)
      return Number.isInteger(parsed) ? parsed : null
    }
    return null
  },
  nodeTypeHeroIcon(nodeType, typeId) {
    const normalized = String(nodeType || "").trim().toLowerCase()

    if (["access point", "access_point", "wireless ap", "wireless access point", "ap"].includes(normalized)) {
      return "hero-wifi"
    }
    if (normalized === "server") return "hero-server"
    if (normalized === "router") return "hero-arrows-right-left"
    if (normalized === "switch") return "hero-square-3-stack-3d"
    if (normalized === "firewall") return "hero-shield-check"
    if (normalized === "desktop" || normalized === "laptop") return "hero-computer-desktop"

    if (typeId === 1) return "hero-server"
    if (typeId === 2 || typeId === 3) return "hero-computer-desktop"
    if (typeId === 4) return "hero-device-tablet"
    if (typeId === 5) return "hero-device-phone-mobile"
    if (typeId === 6) return "hero-cube"
    if (typeId === 7) return "hero-cpu-chip"
    if (typeId === 9) return "hero-shield-check"
    if (typeId === 10) return "hero-square-3-stack-3d"
    if (typeId === 12) return "hero-arrows-right-left"
    if (typeId === 15) return "hero-scale"

    return null
  },
  escapeHtml(value) {
    const text = String(value == null ? "" : value)
    return text
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;")
  },
  nodeReferenceAction(index, label, nodeMap) {
    const idx = Number(index)
    if (!Number.isFinite(idx) || idx < 0) return ""
    const ref = this.nodeRefByIndex(idx, nodeMap) || `node#${idx}`
    return `<div>${this.escapeHtml(label)}: <button type="button" class="link link-primary text-xs" data-node-index="${idx}">${this.escapeHtml(ref)}</button></div>`
  },
  focusNodeByIndex(index, switchToLocal = false) {
    const idx = Number(index)
    if (!Number.isFinite(idx) || idx < 0) return
    const node = this.state.lastGraph?.nodes?.[idx]
    if (!node) return

    if (switchToLocal) {
      this.state.zoomMode = "local"
      this.state.zoomTier = "local"
    }

    this.state.selectedNodeIndex = idx

    const x = Number(node.x)
    const y = Number(node.y)
    if (Number.isFinite(x) && Number.isFinite(y)) {
      this.state.viewState = {...this.state.viewState, target: [x, y, 0]}
      if (this.state.deck) {
        this.state.isProgrammaticViewUpdate = true
        this.state.deck.setProps({viewState: this.state.viewState})
        this.state.isProgrammaticViewUpdate = false
      }
    }

    if (this.state.lastGraph) this.renderGraph(this.state.lastGraph)
  },
  handlePick(info) {
    const layerId = info?.layer?.id || ""
    if (this.edgeLayerId(layerId)) {
      const key = typeof info?.object?.interactionKey === "string" ? info.object.interactionKey : null
      if (!key) return
      this.state.selectedEdgeKey = this.state.selectedEdgeKey === key ? null : key
      if (this.state.lastGraph) this.renderGraph(this.state.lastGraph)
      return
    }

    const picked = info?.object?.index
    if (Number.isInteger(picked)) {
      this.state.selectedNodeIndex = this.state.selectedNodeIndex === picked ? null : picked
      if (this.state.lastGraph) this.renderGraph(this.state.lastGraph)
      return
    }

    if (info && info.picked === false) {
      let changed = false
      if (this.state.selectedNodeIndex !== null) {
        this.state.selectedNodeIndex = null
        changed = true
      }
      if (this.state.selectedEdgeKey !== null) {
        this.state.selectedEdgeKey = null
        changed = true
      }
      if (changed && this.state.lastGraph) this.renderGraph(this.state.lastGraph)
    }
  },
  selectEdgeLabels(edgeData, shape) {
    if (!Array.isArray(edgeData) || edgeData.length === 0) return []
    if (shape !== "local" && shape !== "regional") return []

    const selected = this.state.selectedEdgeKey
    const hovered = this.state.hoveredEdgeKey
    if (!selected && !hovered) return []

    const picked = []
    const seen = new Set()
    for (let i = 0; i < edgeData.length; i += 1) {
      const edge = edgeData[i]
      if (edge.interactionKey !== selected && edge.interactionKey !== hovered) continue
      if (seen.has(edge.interactionKey)) continue
      seen.add(edge.interactionKey)
      picked.push(edge)
    }
    return picked
  },
}
