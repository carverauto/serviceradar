export const godViewRenderingGraphCoreMethods = {
  renderGraph(graph) {
    this.deps.ensureDeck()
    this.autoFitViewState(graph)
    const effective = this.deps.reshapeGraph(graph)

    const {edgeData, edgeLabelData, nodeData, selectedVisibleNode} = this.buildVisibleGraphData(effective)
    this.renderSelectionDetails(selectedVisibleNode)

    this.state.deck.setProps({
      layers: this.buildGraphLayers(effective, nodeData, edgeData, edgeLabelData),
    })
  },
}
