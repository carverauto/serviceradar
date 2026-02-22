export const godViewRenderingGraphViewMethods = {
  autoFitViewState(graph) {
    if (!this.deck || !graph || !Array.isArray(graph.nodes) || graph.nodes.length === 0) return
    if (this.hasAutoFit || this.userCameraLocked) return

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

    const width = Math.max(1, this.el.clientWidth || 1)
    const height = Math.max(1, this.el.clientHeight || 1)
    const spanX = Math.max(1, maxX - minX)
    const spanY = Math.max(1, maxY - minY)
    const padding = 0.88
    const zoomX = Math.log2((width * padding) / spanX)
    const zoomY = Math.log2((height * padding) / spanY)
    const zoom = Math.max(this.viewState.minZoom, Math.min(this.viewState.maxZoom, Math.min(zoomX, zoomY)))

    this.viewState = {
      ...this.viewState,
      target: [(minX + maxX) / 2, (minY + maxY) / 2, 0],
      zoom,
    }

    this.hasAutoFit = true
    this.isProgrammaticViewUpdate = true
    this.deck.setProps({viewState: this.viewState})
    if (this.zoomMode === "auto") {
      this.setZoomTier(this.resolveZoomTier(zoom), true)
    }
  },
}
