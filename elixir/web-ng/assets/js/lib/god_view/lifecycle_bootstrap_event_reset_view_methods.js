import {runRecoverableManagedCameraUpdate} from "./lifecycle_managed_camera_recovery"
import {hasManagedTopologyScene} from "./topology_layout_mode"

export const godViewLifecycleBootstrapEventResetViewMethods = {
  registerResetViewEvent() {
    this.state.handleEvent("god_view:reset_view", () => {
      if (typeof this.resetViewCamera === "function") {
        this.resetViewCamera()
        return
      }

      if (!this.state.deck) return

      const resetCamera = () => {
        this.state.userCameraLocked = false
        this.state.hasAutoFit = false

        const hasExpandedClusters = Array.isArray(this.state.lastGraph?.nodes)
          && this.state.lastGraph.nodes.some((node) => node?.details?.cluster_expanded === true)

        if (hasExpandedClusters && typeof this.collapseAllClusters === "function") {
          this.collapseAllClusters()
          return
        }

        this.deps.autoFitViewState(this.state.lastGraph)
      }

      const managedScene = hasManagedTopologyScene(this.state.lastGraph)
      if (managedScene) {
        runRecoverableManagedCameraUpdate(this, resetCamera)
      } else {
        resetCamera()
      }
    })
  },
}
