import {depsRef, stateRef} from "./runtime_refs"
export const godViewRenderingGraphCoreMethods = {
  renderGraph(graph) {
    depsRef(this).ensureDeck()
    this.autoFitViewState(graph)
    const effective = depsRef(this).reshapeGraph(graph)

    const {edgeData, edgeLabelData, nodeData, selectedVisibleNode} = this.buildVisibleGraphData(effective)
    this.renderSelectionDetails(selectedVisibleNode)

    stateRef(this).deck.setProps({
      layers: this.buildGraphLayers(effective, nodeData, edgeData, edgeLabelData),
    })
  },
}
