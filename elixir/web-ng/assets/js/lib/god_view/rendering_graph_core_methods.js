export const godViewRenderingGraphCoreMethods = {
  renderGraph(graph) {
    this.ensureDeck()
    this.autoFitViewState(graph)
    const effective = this.reshapeGraph(graph)

    const {edgeData, edgeLabelData, nodeData, selectedVisibleNode} = this.buildVisibleGraphData(effective)
    this.renderSelectionDetails(selectedVisibleNode)

    this.deck.setProps({
      layers: this.buildGraphLayers(effective, nodeData, edgeData, edgeLabelData),
    })
  },
}
