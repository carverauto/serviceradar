export const godViewRenderingSelectionMethods = {
  forceDeckRedraw() {
    if (typeof this.state?.deck?.redraw === "function") {
      this.state.deck.redraw(true)
    }
  },
  scheduleSelectionRefresh() {
    if (!this.state.lastGraph) return
    const schedule =
      typeof globalThis !== "undefined" && typeof globalThis.requestAnimationFrame === "function"
        ? globalThis.requestAnimationFrame.bind(globalThis)
        : null

    if (schedule) {
      schedule(() => {
        if (this.state.lastGraph) this.renderGraph(this.state.lastGraph)
        this.forceDeckRedraw()
      })
      return
    }

    this.renderGraph(this.state.lastGraph)
    this.forceDeckRedraw()
  },
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
    const clusterId = typeof d.cluster_id === "string" ? d.cluster_id.trim() : ""
    const clusterKind = typeof d.cluster_kind === "string" ? d.cluster_kind.trim() : ""
    const clusterCount = Number(d.cluster_member_count || 0)
    const clusterExpanded = d.cluster_expanded === true
    const clusterExpandable = d.cluster_expandable === true
    const clusterAction =
      clusterId !== "" && clusterExpandable
        ? `<div class="pt-2"><button type="button" class="btn btn-xs btn-primary" data-cluster-id="${this.escapeHtml(clusterId)}" data-cluster-expand="${clusterExpanded ? "false" : "true"}">${clusterExpanded ? "Collapse endpoints" : "Expand endpoints"}</button></div>`
        : ""
    const cameraAvailability =
      typeof d.camera_availability_status === "string" && d.camera_availability_status.trim() !== ""
        ? d.camera_availability_status.trim()
        : null
    const cameraEventSummary =
      typeof d.camera_last_event_message === "string" && d.camera_last_event_message.trim() !== ""
        ? d.camera_last_event_message.trim()
        : (typeof d.camera_last_event_type === "string" && d.camera_last_event_type.trim() !== ""
            ? d.camera_last_event_type.trim()
            : null)
    const cameraStreams = Array.isArray(d.camera_streams) ? d.camera_streams : []
    const clusterCameraTiles = Array.isArray(d.cluster_camera_tiles) ? d.cluster_camera_tiles : []
    const clusterCameraTileCount = Number(d.cluster_camera_tile_count || clusterCameraTiles.length || 0)
    const placementState = d.topology_unplaced === true ? "Unplaced" : ""
    const placementReason =
      typeof d.topology_placement_reason === "string" && d.topology_placement_reason.trim() !== ""
        ? d.topology_placement_reason.trim()
        : ""
    const cameraActions =
      cameraStreams.length > 0
        ? `<div class="pt-2 space-y-2"><div class="text-[10px] uppercase tracking-wide text-base-content/60">Camera Streams</div>${cameraStreams
            .map((source) => {
              const sourceName =
                typeof source?.display_name === "string" && source.display_name.trim() !== ""
                  ? source.display_name.trim()
                  : "Camera"
              const profiles = Array.isArray(source?.stream_profiles) ? source.stream_profiles : []
              if (
                typeof source?.camera_source_id !== "string" ||
                source.camera_source_id.trim() === "" ||
                profiles.length === 0
              ) {
                return ""
              }

              const profileButtons = profiles
                .map((profile) => {
                  const profileName =
                    typeof profile?.profile_name === "string" && profile.profile_name.trim() !== ""
                      ? profile.profile_name.trim()
                      : "Live"
                  const sourceUrl =
                    typeof profile?.source_url_override === "string" && profile.source_url_override.trim() !== ""
                      ? profile.source_url_override.trim()
                      : typeof source?.source_url === "string"
                        ? source.source_url.trim()
                        : ""
                  const supportsInsecureTls =
                    typeof sourceUrl === "string" && sourceUrl.toLowerCase().startsWith("rtsps://")

                  if (typeof profile?.stream_profile_id !== "string" || profile.stream_profile_id.trim() === "") {
                    return ""
                  }

                  const openButton = `<button type="button" class="btn btn-xs btn-secondary mr-1 mt-1" data-camera-source-id="${this.escapeHtml(source.camera_source_id)}" data-stream-profile-id="${this.escapeHtml(profile.stream_profile_id)}" data-camera-device-uid="${this.escapeHtml(d.device_uid || d.id || "")}" data-camera-label="${this.escapeHtml(sourceName)}" data-camera-profile-label="${this.escapeHtml(profileName)}">Open ${this.escapeHtml(profileName)}</button>`
                  const insecureButton = supportsInsecureTls
                    ? `<button type="button" class="btn btn-xs btn-warning mr-1 mt-1" data-camera-source-id="${this.escapeHtml(source.camera_source_id)}" data-stream-profile-id="${this.escapeHtml(profile.stream_profile_id)}" data-insecure-skip-verify="true" data-camera-device-uid="${this.escapeHtml(d.device_uid || d.id || "")}" data-camera-label="${this.escapeHtml(sourceName)}" data-camera-profile-label="${this.escapeHtml(profileName)}">Skip TLS Verify</button>`
                    : ""

                  return `${openButton}${insecureButton}`
                })
                .filter(Boolean)
                .join("")

              if (profileButtons === "") return ""

              return `<div><div class="text-xs font-medium text-base-content/80">${this.escapeHtml(sourceName)}</div><div>${profileButtons}</div></div>`
            })
            .filter(Boolean)
            .join("")}</div>`
        : ""
    const clusterCameraAction =
      clusterId !== "" && clusterCameraTiles.length > 1
        ? (() => {
            const serializedTiles = this.escapeHtml(JSON.stringify(clusterCameraTiles))
            const visibleCount = clusterCameraTiles.length
            const totalCount = Number.isFinite(clusterCameraTileCount) && clusterCameraTileCount > 0
              ? clusterCameraTileCount
              : visibleCount
            const suffix = totalCount > visibleCount ? ` (${visibleCount} of ${totalCount})` : ` (${visibleCount})`

            return `<div class="pt-2 space-y-1"><div class="text-[10px] uppercase tracking-wide text-base-content/60">Cluster Cameras</div><button type="button" class="btn btn-xs btn-accent" data-camera-cluster-id="${this.escapeHtml(clusterId)}" data-camera-cluster-label="${this.escapeHtml(node.label || d.cluster_anchor_label || "Camera cluster")}" data-camera-cluster-tiles="${serializedTiles}">Open Camera Tile Set${suffix}</button></div>`
          })()
        : ""
    const detailLines = [
      `<div class="font-semibold text-sm mb-1 flex items-center justify-between gap-2"><span>${this.escapeHtml(node.label || "node")}</span><span class="inline-flex items-center justify-end min-w-4">${typeIcon ? `<span class="${this.escapeHtml(typeIcon)} size-4 text-base-content/70" title="${this.escapeHtml(typeLabel || "unknown")}"></span>` : ""}</span></div>`,
      `<div>ID: ${this.escapeHtml(d.id || node.id || "unknown")}</div>`,
      ipLine,
      `<div>Type: ${this.escapeHtml(d.type || "unknown")}</div>`,
      placementState ? `<div>Placement: ${this.escapeHtml(placementState)}</div>` : "",
      placementReason ? `<div>${this.escapeHtml(placementReason)}</div>` : "",
      clusterCount > 0 ? `<div>Cluster Size: ${this.escapeHtml(clusterCount)}</div>` : "",
      clusterId !== "" && clusterKind !== "endpoint-anchor"
        ? `<div>Cluster Anchor: ${this.escapeHtml(d.cluster_anchor_label || d.cluster_anchor_id || "unknown")}</div>`
        : "",
      `<div>State: ${this.escapeHtml(this.stateDisplayName(node.state))}</div>`,
      `<div>Why: ${reason}</div>`,
      rootRef,
      parentRef,
      `<div>Vendor/Model: ${this.escapeHtml(`${d.vendor || "—"} ${d.model || ""}`.trim())}</div>`,
      `<div>Last Seen: ${this.escapeHtml(d.last_seen || "unknown")}</div>`,
      `<div>ASN: ${this.escapeHtml(d.asn || "unknown")}</div>`,
      `<div>Geo: ${this.escapeHtml([d.geo_city, d.geo_country].filter(Boolean).join(", ") || "unknown")}</div>`,
      cameraAvailability ? `<div>Camera Availability: ${this.escapeHtml(cameraAvailability)}</div>` : "",
      cameraEventSummary ? `<div>Camera Activity: ${this.escapeHtml(cameraEventSummary)}</div>` : "",
      clusterAction,
      clusterCameraAction,
      cameraActions,
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
      if (key) {
        this.state.selectedEdgeKey = this.state.selectedEdgeKey === key ? null : key
        if (this.state.lastGraph) this.renderGraph(this.state.lastGraph)
        this.forceDeckRedraw()
        return
      }

      return
    }

    const clickedNode = info?.object || null
    const picked =
      Number.isInteger(clickedNode?.index)
        ? clickedNode.index
        : (Number.isInteger(info?.index) ? info.index : null)
    if (Number.isInteger(picked)) {
      const graphNode = this.state.lastGraph?.nodes?.[picked] || null
      const node =
        graphNode && clickedNode
          ? {
              ...graphNode,
              ...clickedNode,
              details: {
                ...(graphNode?.details || {}),
                ...(clickedNode?.details || {}),
              },
            }
          : (clickedNode || graphNode || null)
      const clusterDetails = node?.details || {}
      const clusterId = typeof clusterDetails?.cluster_id === "string" ? clusterDetails.cluster_id.trim() : ""
      const clusterKind = typeof clusterDetails?.cluster_kind === "string" ? clusterDetails.cluster_kind.trim() : ""
      const clusterExpandable = clusterDetails?.cluster_expandable === true
      const clusterExpanded = clusterDetails?.cluster_expanded === true
      const directExpandKinds = clusterKind === "endpoint-summary" || clusterKind === "endpoint-anchor"

      if (clusterId !== "" && clusterExpandable && directExpandKinds && typeof this.deps?.setClusterExpanded === "function") {
        this.state.selectedNodeIndex = null
        this.state.selectedEdgeKey = null
        this.deps.setClusterExpanded(clusterId, !clusterExpanded)
        if (this.state.lastGraph) this.renderGraph(this.state.lastGraph)
        return
      }

      this.state.selectedNodeIndex = this.state.selectedNodeIndex === picked ? null : picked

      this.scheduleSelectionRefresh()
      return
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
