export const godViewLifecycleBootstrapEventLayerMethods = {
  registerLayerEvents() {
    this.state.handleEvent("god_view:set_layers", ({layers}) => {
      if (layers && typeof layers === "object") {
        this.state.layers = {
          mantle: layers.mantle !== false,
          crust: layers.crust !== false,
          atmosphere: Boolean(this.state.packetFlowEnabled) && layers.atmosphere !== false,
          security: layers.security !== false,
        }
        if (this.state.lastGraph) this.deps.renderGraph(this.state.lastGraph)
      }
    })

    this.state.handleEvent("god_view:set_topology_layers", ({layers}) => {
      if (layers && typeof layers === "object") {
        this.state.topologyLayers = {
          backbone: layers.backbone !== false,
          inferred: layers.inferred === true,
          endpoints: layers.endpoints === true,
          mtr_paths: layers.mtr_paths === true,
        }
        if (this.state.lastGraph) this.deps.renderGraph(this.state.lastGraph)
      }
    })

    this.state.handleEvent("god_view:mtr_path_data", ({paths}) => {
      this.state.mtrPathData = Array.isArray(paths) ? paths : []
      if (this.state.lastGraph) this.deps.renderGraph(this.state.lastGraph)
    })
  },
}
