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
      )
    } catch (error) {
      this.state.layers.atmosphere = false
      layers = this.buildGraphLayers(
        frame.effective,
        frame.nodeData,
        frame.edgeData,
        frame.edgeLabelData,
        frame.rootPulseNodes,
      )
      if (this.state.summary) this.state.summary.textContent = `render fallback: ${String(error)}`
    }

    this.state.deck.setProps({layers})
    notifyRenderFrame(this, frame.effective, frame.nodeData, frame.edgeData, layers)
    return true
  },
  renderGraph(graph) {
    this.deps.ensureDeck()
    this.autoFitViewState(graph)
    const effective = this.deps.reshapeGraph(graph)
    if (this.state.packetFlowEnabled) this.state.layers.atmosphere = true

    const {edgeData, edgeLabelData, nodeData, rootPulseNodes, selectedVisibleNode} = this.buildVisibleGraphData(effective)
    this.renderSelectionDetails(selectedVisibleNode)
    this.state.lastGraphLayerFrame = {effective, nodeData, edgeData, edgeLabelData, rootPulseNodes}

    let layers
    try {
      layers = this.buildGraphLayers(effective, nodeData, edgeData, edgeLabelData, rootPulseNodes)
    } catch (error) {
      this.state.layers.atmosphere = false
      layers = this.buildGraphLayers(effective, nodeData, edgeData, edgeLabelData, rootPulseNodes)
      if (this.state.summary) this.state.summary.textContent = `render fallback: ${String(error)}`
    }

    this.state.deck.setProps({
      layers,
    })
    notifyRenderFrame(this, effective, nodeData, edgeData, layers)
  },
}
