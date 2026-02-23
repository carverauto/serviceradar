import {depsRef, stateRef} from "./runtime_refs"
export const godViewLifecycleBootstrapEventLayerMethods = {
  registerLayerEvents() {
    stateRef(this).handleEvent("god_view:set_layers", ({layers}) => {
      if (layers && typeof layers === "object") {
        stateRef(this).layers = {
          mantle: layers.mantle !== false,
          crust: layers.crust !== false,
          atmosphere: layers.atmosphere !== false,
          security: layers.security !== false,
        }
        if (stateRef(this).lastGraph) depsRef(this).renderGraph(stateRef(this).lastGraph)
      }
    })

    stateRef(this).handleEvent("god_view:set_topology_layers", ({layers}) => {
      if (layers && typeof layers === "object") {
        stateRef(this).topologyLayers = {
          backbone: layers.backbone !== false,
          inferred: layers.inferred === true,
          endpoints: layers.endpoints === true,
        }
        if (stateRef(this).lastGraph) depsRef(this).renderGraph(stateRef(this).lastGraph)
      }
    })
  },
}
