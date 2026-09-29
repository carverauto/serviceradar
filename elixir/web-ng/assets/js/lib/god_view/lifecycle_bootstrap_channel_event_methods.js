export const godViewLifecycleBootstrapChannelEventMethods = {
  setClusterExpanded(clusterId, expanded) {
    const normalized = typeof clusterId === "string" ? clusterId.trim() : ""
    if (normalized === "") return
    if (expanded === true) this.ensureEndpointsLayerForClusterExpand()
  },
  ensureEndpointsLayerForClusterExpand() {
    const current = this.state.topologyLayers || {}
    if (current.endpoints === true) return

    this.state.topologyLayers = {...current, endpoints: true}
    if (typeof this.state.pushEvent === "function") {
      this.state.pushEvent("enable_attachment_layers", {})
    }
  },
  collapseAllClusters() {},
}
