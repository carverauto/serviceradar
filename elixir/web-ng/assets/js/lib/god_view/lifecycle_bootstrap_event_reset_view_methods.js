export const godViewLifecycleBootstrapEventResetViewMethods = {
  registerResetViewEvent() {
    this.state.handleEvent("god_view:reset_view", () => {
      if (!this.state.deck) return

      this.state.userCameraLocked = false
      this.state.hasAutoFit = false

      const hasExpandedClusters = Array.isArray(this.state.lastGraph?.nodes)
        && this.state.lastGraph.nodes.some((node) => node?.details?.cluster_expanded === true)

      if (hasExpandedClusters && typeof this.collapseAllClusters === "function") {
        this.collapseAllClusters()
        return
      }

      this.deps.autoFitViewState(this.state.lastGraph)
    })
  },
}
