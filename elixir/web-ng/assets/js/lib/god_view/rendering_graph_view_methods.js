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
  autoFitViewState(graph) {
    if (!this.state.deck || !graph || !Array.isArray(graph.nodes) || graph.nodes.length === 0) return
    if (this.state.hasAutoFit || this.state.userCameraLocked) return

    let minX = Number.POSITIVE_INFINITY
    let maxX = Number.NEGATIVE_INFINITY
    let minY = Number.POSITIVE_INFINITY
    let maxY = Number.NEGATIVE_INFINITY

    for (let i = 0; i < graph.nodes.length; i += 1) {
      const node = graph.nodes[i]
      const x = Number(node?.x)
      const y = Number(node?.y)
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue
      minX = Math.min(minX, x)
      maxX = Math.max(maxX, x)
      minY = Math.min(minY, y)
      maxY = Math.max(maxY, y)
    }

    if (!Number.isFinite(minX) || !Number.isFinite(minY)) return

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
      this.deps.setZoomTier(this.deps.resolveZoomTier(zoom), true)
    }
  },
}
