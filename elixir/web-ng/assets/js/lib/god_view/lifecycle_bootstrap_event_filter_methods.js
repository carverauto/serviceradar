import {depsRef, stateRef} from "./runtime_refs"
export const godViewLifecycleBootstrapEventFilterMethods = {
  registerFilterEvent() {
    stateRef(this).handleEvent("god_view:set_filters", ({filters}) => {
      if (filters && typeof filters === "object") {
        stateRef(this).filters = {
          root_cause: filters.root_cause !== false,
          affected: filters.affected !== false,
          healthy: filters.healthy !== false,
          unknown: filters.unknown !== false,
        }
        if (stateRef(this).lastGraph) depsRef(this).renderGraph(stateRef(this).lastGraph)
      }
    })
  },
}
