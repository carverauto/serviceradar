function nodeDetails(node) {
  return node?.details && typeof node.details === "object" ? node.details : {}
}

function clusterKindForNode(node) {
  const clusterKind = nodeDetails(node).cluster_kind
  return typeof clusterKind === "string" && clusterKind.trim() !== "" ? clusterKind.trim() : ""
}

function isEndpointMemberNode(node) {
  return clusterKindForNode(node) === "endpoint-member"
}

function isEndpointSummaryNode(node) {
  return clusterKindForNode(node) === "endpoint-summary"
}

function isEndpointAnchorNode(node) {
  return clusterKindForNode(node) === "endpoint-anchor"
}

function isUnplacedNode(node) {
  const details = nodeDetails(node)
  return details.topology_unplaced === true || String(details.topology_plane || "").trim() === "unplaced"
}

function frameNodeRadius(node) {
  if (isEndpointSummaryNode(node)) return 44
  if (isEndpointAnchorNode(node)) return 32
  if (isEndpointMemberNode(node)) return 16
  return 28
}

function isInfrastructureOverviewNode(node) {
  return !isEndpointMemberNode(node) && !isEndpointSummaryNode(node) && !isUnplacedNode(node)
}

function preferredAutoFitZoomTier(graph) {
  return graph?._layoutMode === "client-radial" ? "local" : null
}

export const godViewRenderingGraphViewMethods = {
  fitViewPadding(width, height) {
    const safeWidth = Math.max(1, Number(width) || 1)
    const safeHeight = Math.max(1, Number(height) || 1)

    return {
      left: Math.min(72, Math.max(32, safeWidth * 0.06)),
      right: Math.min(260, Math.max(120, safeWidth * 0.18)),
      top: Math.min(120, Math.max(56, safeHeight * 0.09)),
      bottom: Math.min(144, Math.max(72, safeHeight * 0.12)),
    }
  },
  boundsForNodes(nodes) {
    let minX = Number.POSITIVE_INFINITY
    let maxX = Number.NEGATIVE_INFINITY
    let minY = Number.POSITIVE_INFINITY
    let maxY = Number.NEGATIVE_INFINITY

    for (const node of nodes) {
      const x = Number(node?.x)
      const y = Number(node?.y)
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue
      const radius = frameNodeRadius(node)
      minX = Math.min(minX, x - radius)
      maxX = Math.max(maxX, x + radius)
      minY = Math.min(minY, y - radius)
      maxY = Math.max(maxY, y + radius)
    }

    if (!Number.isFinite(minX) || !Number.isFinite(minY)) return null
    return {minX, maxX, minY, maxY}
  },
  autoFitBounds(graph) {
    if (!graph || !Array.isArray(graph.nodes) || graph.nodes.length === 0) return null

    const finiteNodes = graph.nodes.filter((node) => {
      const x = Number(node?.x)
      const y = Number(node?.y)
      return Number.isFinite(x) && Number.isFinite(y)
    })
    if (finiteNodes.length === 0) return null

    if (graph._layoutMode !== "client-radial") return this.boundsForNodes(finiteNodes)

    const overviewNodes = finiteNodes.filter((node) => !isEndpointMemberNode(node) && !isUnplacedNode(node))
    const radialOverviewNodes = overviewNodes.filter(
      (node) => isInfrastructureOverviewNode(node) || isEndpointSummaryNode(node) || isEndpointAnchorNode(node),
    )
    const framedNodes = radialOverviewNodes.length > 0 ? radialOverviewNodes : overviewNodes.length > 0 ? overviewNodes : finiteNodes
    return this.boundsForNodes(framedNodes)
  },
  autoFitViewState(graph) {
    if (!this.state.deck || !graph || !Array.isArray(graph.nodes) || graph.nodes.length === 0) return
    if (this.state.hasAutoFit || this.state.userCameraLocked) return

    const bounds = this.autoFitBounds(graph)
    if (!bounds) return
    const {minX, maxX, minY, maxY} = bounds

    const width = Math.max(1, this.state.el.clientWidth || 1)
    const height = Math.max(1, this.state.el.clientHeight || 1)
    const padding = this.fitViewPadding(width, height)
    const availableWidth = Math.max(1, width - padding.left - padding.right)
    const availableHeight = Math.max(1, height - padding.top - padding.bottom)
    const spanX = Math.max(1, maxX - minX)
    const spanY = Math.max(1, maxY - minY)
    const zoomX = Math.log2(availableWidth / spanX)
    const zoomY = Math.log2(availableHeight / spanY)
    const zoom = Math.max(this.state.viewState.minZoom, Math.min(this.state.viewState.maxZoom, Math.min(zoomX, zoomY)))
    const scale = Math.pow(2, zoom)
    const targetX = ((minX + maxX) / 2) + ((padding.right - padding.left) / (2 * scale))
    const targetY = ((minY + maxY) / 2) + ((padding.bottom - padding.top) / (2 * scale))

    this.state.viewState = {
      ...this.state.viewState,
      target: [targetX, targetY, 0],
      zoom,
    }

    this.state.hasAutoFit = true
    this.state.isProgrammaticViewUpdate = true
    this.state.deck.setProps({viewState: this.state.viewState})
    if (this.state.zoomMode === "auto") {
      this.deps.setZoomTier(preferredAutoFitZoomTier(graph) || this.deps.resolveZoomTier(zoom), true)
    }
  },
  focusClusterNeighborhood(graph, clusterId) {
    const normalizedClusterId = typeof clusterId === "string" ? clusterId.trim() : ""
    if (!this.state.deck || !graph || !Array.isArray(graph.nodes) || normalizedClusterId === "") return false

    const clusterNodes = graph.nodes.filter((node) => {
      const details = node?.details || {}
      return node?.id === normalizedClusterId || details?.cluster_id === normalizedClusterId
    })
    if (clusterNodes.length === 0) return false

    const anchorIds = new Set(
      clusterNodes
        .map((node) => String(node?.details?.cluster_anchor_id || "").trim())
        .filter((id) => id !== ""),
    )

    const neighborhood = graph.nodes.filter((node) => {
      const details = node?.details || {}
      const nodeId = String(node?.id || "").trim()
      const nodeClusterId = String(details?.cluster_id || "").trim()
      return nodeId === normalizedClusterId || nodeClusterId === normalizedClusterId || anchorIds.has(nodeId)
    })
    if (neighborhood.length === 0) return false

    const bounds = this.boundsForNodes(neighborhood)
    if (!bounds) return false
    const {minX, maxX, minY, maxY} = bounds

    const width = Math.max(1, this.state.el.clientWidth || 1)
    const height = Math.max(1, this.state.el.clientHeight || 1)
    const basePadding = this.fitViewPadding(width, height)
    const padding = {
      left: Math.max(32, basePadding.left * 0.65),
      right: Math.max(112, basePadding.right * 0.7),
      top: Math.max(56, basePadding.top * 0.8),
      bottom: Math.max(104, basePadding.bottom * 1.15),
    }
    const availableWidth = Math.max(1, width - padding.left - padding.right)
    const availableHeight = Math.max(1, height - padding.top - padding.bottom)
    const spanX = Math.max(96, (maxX - minX) * 1.18)
    const spanY = Math.max(120, (maxY - minY) * 1.22)
    const zoomX = Math.log2(availableWidth / spanX)
    const zoomY = Math.log2(availableHeight / spanY)
    const zoom = Math.max(
      this.state.viewState.minZoom,
      Math.min(this.state.viewState.maxZoom, Math.min(zoomX, zoomY) + 0.08),
    )
    const scale = Math.pow(2, zoom)
    const targetX = ((minX + maxX) / 2) + ((padding.right - padding.left) / (2 * scale))
    const targetY = ((minY + maxY) / 2) - ((padding.bottom - padding.top) / (2 * scale))

    this.state.viewState = {
      ...this.state.viewState,
      target: [targetX, targetY, 0],
      zoom,
    }
    this.state.isProgrammaticViewUpdate = true
    this.state.deck.setProps({viewState: this.state.viewState})
    if (this.state.zoomMode === "auto") {
      this.deps.setZoomTier(this.deps.resolveZoomTier(zoom), true)
    }
    return true
  },
}
