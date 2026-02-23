export const godViewLifecycleBootstrapEventFilterMethods = {
  registerFilterEvent() {
    this.state.handleEvent("god_view:set_filters", ({filters}) => {
      if (filters && typeof filters === "object") {
        this.state.filters = {
          root_cause: filters.root_cause !== false,
          affected: filters.affected !== false,
          healthy: filters.healthy !== false,
          unknown: filters.unknown !== false,
        }
        if (this.state.lastGraph) this.deps.renderGraph(this.state.lastGraph)
      }
    })
  },
}
