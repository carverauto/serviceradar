import {dashboardUserTimeHtml} from "../../utils/dashboard_user_time"

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
  hideSelectionDetails() {
    if (!this.state.details) return
    if (!this.state.details.classList.contains("hidden")) {
      this.state.details.classList.add("hidden")
    }
    if (this.state.details.style) {
      this.state.details.style.display = "none"
    }
    if (this.state.details.textContent !== "Select a node for details") {
      this.state.details.textContent = "Select a node for details"
    }
    this.state.lastDetailsHtml = null
  },
  clearSelection() {
    const hadSelection = this.state.selectedNodeIndex !== null || this.state.selectedEdgeKey != null
    const detailsOpen = Boolean(this.state.details && !this.state.details.classList.contains("hidden"))
    this.state.selectedNodeIndex = null
    this.state.selectedEdgeKey = null
    this.hideSelectionDetails()
    if (!hadSelection && !detailsOpen) return
    this.scheduleSelectionRefresh()
  },
  renderSelectionDetails(node) {
    if (!this.state.details) return
    if (!node) {
      this.hideSelectionDetails()
      return
    }

    const d = node.details || {}
    const typeLabel = typeof d.type === "string" ? d.type : ""
    const typeId = this.parseTypeId(d.type_id)
    const typeIcon = this.nodeTypeHeroIcon(typeLabel, typeId)
    const detailId = d.device_uid || d.id || node.id
    const rawIp = typeof d.ip === "string" ? d.ip.trim() : ""
    const hasRealIp =
      rawIp !== "" && !["unknown", "n/a", "na", "null", "undefined", "-"].includes(rawIp.toLowerCase())
    const ipText = this.escapeHtml(hasRealIp ? rawIp : "unknown")
    const ipLine = `<div>IP: ${ipText}</div>`
    const idText = this.escapeHtml(d.id || node.id || "unknown")
    const idHref = this.deviceDetailsHref(detailId)
    const idLine = idHref
      ? `<div>ID: <a class="link link-primary underline underline-offset-2 font-mono break-all" href="${this.escapeHtml(idHref)}" data-device-href="${this.escapeHtml(idHref)}">${idText}</a></div>`
      : `<div>ID: ${idText}</div>`
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
    const clusterId = this.expandableEndpointClusterId(node)
    const clusterKind = typeof d.cluster_kind === "string" ? d.cluster_kind.trim() : ""
    const clusterCount = Number(d.cluster_member_count || node.clusterCount || 0)
    const clusterExpanded = d.cluster_expanded === true || d.cluster_expanded === "true"
    const clusterAction =
      clusterId !== ""
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
    const lastSeen = d.last_seen
      ? dashboardUserTimeHtml(d.last_seen, {
          timeZone: this.state.el?.dataset?.timezone || "Etc/UTC",
          style: "full",
        })
      : "unknown"
    const detailLines = [
      `<div class="font-semibold text-sm mb-1 flex items-center justify-between gap-2"><span>${this.escapeHtml(node.label || "node")}</span><span class="inline-flex items-center justify-end gap-1 min-w-4">${typeIcon ? `<span class="${this.escapeHtml(typeIcon)} size-4 text-base-content/70" title="${this.escapeHtml(typeLabel || "unknown")}"></span>` : ""}<button type="button" class="btn btn-ghost btn-xs btn-square" data-close-details aria-label="Close details">×</button></span></div>`,
      idLine,
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
      `<div>Last Seen: ${lastSeen}</div>`,
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
    if (this.state.details.style) {
      this.state.details.style.display = ""
    }
  },
  expandableEndpointClusterId(node) {
    const details = node?.details && typeof node.details === "object" ? node.details : {}
    const kind = typeof details.cluster_kind === "string" ? details.cluster_kind.trim() : ""
    if (kind === "endpoint-member") return ""

    const nodeId = typeof node?.id === "string" ? node.id.trim() : ""
    const detailId = typeof details.id === "string" ? details.id.trim() : ""
    const detailClusterId = typeof details.cluster_id === "string" ? details.cluster_id.trim() : ""
    const label = typeof node?.label === "string" ? node.label.trim() : ""
    const memberCount = Number(details.cluster_member_count || node?.clusterCount || 0)
    const expandable =
      details.cluster_expandable === true ||
      details.cluster_expandable === "true" ||
      details.cluster_expandable === 1
    const clusterPrefixed =
      nodeId.startsWith("cluster:endpoints:") ||
      detailId.startsWith("cluster:endpoints:") ||
      detailClusterId.startsWith("cluster:endpoints:")
    const looksLikeCensus = /\d+\s+endpoints/i.test(label) || kind === "endpoint-summary"

    if (
      kind !== "endpoint-summary" &&
      kind !== "endpoint-anchor" &&
      !clusterPrefixed &&
      !looksLikeCensus &&
      !(expandable && memberCount > 1)
    ) {
      return ""
    }

    return detailClusterId || (clusterPrefixed ? (detailId || nodeId) : "") || detailId || nodeId
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
      this.clearSelection()
      return
    }

    // deck.gl empty-canvas clicks are `{picked:false, object:null, index:-1}`.
    // Never treat -1 as a node (that used to apply the 3-hop mask and wipe
    // the graph). Dismiss the details card instead.
    if (info?.picked === false) {
      this.clearSelection()
      return
    }
    if (typeof this.nodeLayerId === "function" && !this.nodeLayerId(layerId)) {
      this.clearSelection()
      return
    }

    const clickedNode = info?.object
    if (!clickedNode || typeof clickedNode !== "object") {
      this.clearSelection()
      return
    }

    const picked =
      typeof this.pickedNodeIndex === "function"
        ? this.pickedNodeIndex(info)
        : (Number.isInteger(clickedNode.index) && clickedNode.index >= 0 ? clickedNode.index : null)
    if (!Number.isInteger(picked) || picked < 0) {
      this.clearSelection()
      return
    }

    const graphNode = this.state.lastGraph?.nodes?.[picked] || null
    const node = {
      ...(graphNode || {}),
      ...clickedNode,
      index: picked,
      details: {
        ...(graphNode?.details || {}),
        ...(clickedNode?.details || {}),
      },
    }
    const clusterId = this.expandableEndpointClusterId(node)
    const clusterExpanded =
      node?.details?.cluster_expanded === true || node?.details?.cluster_expanded === "true"
    const expandCluster =
      typeof this.deps?.setClusterExpanded === "function"
        ? (...args) => this.deps.setClusterExpanded(...args)
        : typeof this.setClusterExpanded === "function"
          ? (...args) => this.setClusterExpanded(...args)
          : null

    if (clusterId !== "" && expandCluster) {
      this.state.selectedNodeIndex = null
      this.state.selectedEdgeKey = null
      expandCluster(clusterId, !clusterExpanded)
      if (this.state.lastGraph) this.renderGraph(this.state.lastGraph)
      return
    }

    this.state.selectedNodeIndex = this.state.selectedNodeIndex === picked ? null : picked
    this.scheduleSelectionRefresh()
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
