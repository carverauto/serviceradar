export const godViewRenderingGraphCoreMethods = {
  renderGraph(graph) {
    this.deps.ensureDeck()
    this.autoFitViewState(graph)
    const effective = this.deps.reshapeGraph(graph)
    if (this.state.packetFlowEnabled) this.state.layers.atmosphere = true

    const {edgeData, edgeLabelData, nodeData, rootPulseNodes, selectedVisibleNode} = this.buildVisibleGraphData(effective)
    this.renderSelectionDetails(selectedVisibleNode)

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
  },
}
