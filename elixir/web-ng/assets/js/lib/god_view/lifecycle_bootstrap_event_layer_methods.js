export const godViewLifecycleBootstrapEventLayerMethods = {
  registerLayerEvents() {
    this.handleEvent("god_view:set_layers", ({layers}) => {
      if (layers && typeof layers === "object") {
        this.layers = {
          mantle: layers.mantle !== false,
          crust: layers.crust !== false,
          atmosphere: layers.atmosphere !== false,
          security: layers.security !== false,
        }
        if (this.lastGraph) this.renderGraph(this.lastGraph)
      }
    })

    this.handleEvent("god_view:set_topology_layers", ({layers}) => {
      if (layers && typeof layers === "object") {
        this.topologyLayers = {
          backbone: layers.backbone !== false,
          inferred: layers.inferred === true,
          endpoints: layers.endpoints === true,
        }
        if (this.lastGraph) this.renderGraph(this.lastGraph)
      }
    })
  },
}
