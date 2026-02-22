export const godViewLifecycleBootstrapEventFilterMethods = {
  registerFilterEvent() {
    this.handleEvent("god_view:set_filters", ({filters}) => {
      if (filters && typeof filters === "object") {
        this.filters = {
          root_cause: filters.root_cause !== false,
          affected: filters.affected !== false,
          healthy: filters.healthy !== false,
          unknown: filters.unknown !== false,
        }
        if (this.lastGraph) this.renderGraph(this.lastGraph)
      }
    })
  },
}
