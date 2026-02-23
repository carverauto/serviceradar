export const godViewRenderingGraphViewMethods = {
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
    const spanX = Math.max(1, maxX - minX)
    const spanY = Math.max(1, maxY - minY)
    const padding = 0.88
    const zoomX = Math.log2((width * padding) / spanX)
    const zoomY = Math.log2((height * padding) / spanY)
    const zoom = Math.max(this.state.viewState.minZoom, Math.min(this.state.viewState.maxZoom, Math.min(zoomX, zoomY)))

    this.state.viewState = {
      ...this.state.viewState,
      target: [(minX + maxX) / 2, (minY + maxY) / 2, 0],
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
