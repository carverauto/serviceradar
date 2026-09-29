function notifyRenderFrame(context, effective, nodeData, edgeData, layers) {
  const observer = context.state?.renderFrameObserver
  if (typeof observer !== "function") return
  observer({context, effective, nodeData, edgeData, layers})
}

export const godViewRenderingGraphCoreMethods = {
  refreshGraphLayersForViewState() {
    const frame = this.state.lastGraphLayerFrame
    if (!this.state.deck || !frame) return false

    let layers
    try {
      layers = this.buildGraphLayers(
        frame.effective,
        frame.nodeData,
        frame.edgeData,
        frame.edgeLabelData,
        frame.rootPulseNodes,
        frame.nodeFrame,
      )
    } catch (error) {
      this.state.layers.atmosphere = false
      layers = this.buildGraphLayers(
        frame.effective,
        frame.nodeData,
        frame.edgeData,
        frame.edgeLabelData,
        frame.rootPulseNodes,
        frame.nodeFrame,
      )
      if (this.state.summary) this.state.summary.textContent = `render fallback: ${String(error)}`
    }

    this.state.deck.setProps({layers})
    this.state.lastGraphLayers = layers
    notifyRenderFrame(this, frame.effective, frame.nodeData, frame.edgeData, layers)
    return true
  },
  /**
   * One animation frame: re-issues only the layers whose look depends on the clock, cloned with
   * the new phase. Packet flow's clone changes nothing but its `time` uniform; every other layer
   * is passed back as the same object, so deck neither rebuilds nor re-uploads their data.
   */
  advanceAnimation() {
    const layers = this.state.lastGraphLayers
    if (!this.state.deck || !Array.isArray(layers) || layers.length === 0) return false
    let changed = false
    const next = layers.map((layer) => {
      const animated = this.animateLayer(layer)
      if (animated !== layer) changed = true
      return animated
    })
    if (!changed) return false
    this.state.lastGraphLayers = next
    this.state.deck.setProps({layers: next})
    return true
  },
  /**
   * Rebuilds the layers once something a render had to do without is available. The animation
   * loop only advances the clock, so nothing else would: the first render after a snapshot can
   * run before deck has a viewport (labels are then admitted against nothing), and packet flow
   * is held back for a moment after a renderer error. Returns whether it refreshed.
   */
  refreshDeferredLayers() {
    const now = typeof performance !== "undefined" ? performance.now() : Date.now()
    const suppressUntil = Number(this.state.atmosphereSuppressUntil || 0)
    const atmosphereDue = suppressUntil > 0 && now >= suppressUntil
    const labelsDue = this.state.labelAdmissionAwaitingViewport === true && this.activeTopologyLabelViewport() != null
    if (!atmosphereDue && !labelsDue) return false
    if (atmosphereDue) this.state.atmosphereSuppressUntil = 0
    return this.refreshGraphLayersForViewState()
  },
  /**
   * Hover and selection change which few nodes and edges are emphasized, not what is visible.
   * They reuse the last render's node records and edge data and re-issue the layers, so the
   * work is the emphasized items plus the label pass, not a rebuild of every edge.
   */
  refreshInteraction() {
    const frame = this.state.lastGraphLayerFrame
    if (!this.state.deck || !frame || !frame.nodeFrame || frame.graph !== this.state.lastGraph) {
      if (this.state.lastGraph) this.renderGraph(this.state.lastGraph)
      return
    }
    const {effective, nodeFrame} = frame
    nodeFrame.selectedNodeIndex = this.state.selectedNodeIndex
    frame.edgeLabelData = this.selectEdgeLabels(frame.edgeData, effective.shape)
    const selected = this.state.selectedNodeIndex
    const record = effective.shape === "local" && Number.isInteger(selected) ? nodeFrame.records[selected] : null
    this.renderSelectionDetails(record?.visible ? record : null)
    this.refreshGraphLayersForViewState()
  },
  renderGraph(graph) {
    this.deps.ensureDeck()
    // No deck means WebGPU is unavailable and the surface already says so.
    if (!this.state.deck) return
    this.autoFitViewState(graph)
    const effective = this.deps.reshapeGraph(graph)

    const {edgeData, edgeLabelData, nodeData, rootPulseNodes, selectedVisibleNode, nodeFrame} =
      this.buildVisibleGraphData(effective)
    this.renderSelectionDetails(selectedVisibleNode)
    this.state.lastGraphLayerFrame = {graph, effective, nodeData, edgeData, edgeLabelData, rootPulseNodes, nodeFrame}

    let layers
    try {
      layers = this.buildGraphLayers(effective, nodeData, edgeData, edgeLabelData, rootPulseNodes, nodeFrame)
    } catch (error) {
      this.state.layers.atmosphere = false
      layers = this.buildGraphLayers(effective, nodeData, edgeData, edgeLabelData, rootPulseNodes, nodeFrame)
      if (this.state.summary) this.state.summary.textContent = `render fallback: ${String(error)}`
    }

    this.state.deck.setProps({
      layers,
    })
    this.state.lastGraphLayers = layers
    notifyRenderFrame(this, effective, nodeData, edgeData, layers)
  },
}
