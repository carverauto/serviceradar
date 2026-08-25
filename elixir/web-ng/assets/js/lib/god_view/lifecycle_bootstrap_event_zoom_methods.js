import {runRecoverableManagedCameraUpdate} from "./lifecycle_managed_camera_recovery"
import {hasManagedTopologyScene} from "./topology_layout_mode"

export const godViewLifecycleBootstrapEventZoomMethods = {
  registerZoomModeEvent() {
    this.state.handleEvent("god_view:set_zoom_mode", ({mode}) => {
      const normalized = mode === "global" || mode === "regional" || mode === "local" ? mode : "auto"
      if (!this.state.deck) {
        this.state.zoomMode = normalized
        return
      }
      const managedScene = hasManagedTopologyScene(this.state.lastGraph)

      if (normalized === "auto") {
        const nextTier = managedScene ? "local" : this.deps.resolveZoomTier(this.state.viewState.zoom || 0)
        const applyAutoMode = () => {
          this.state.zoomMode = normalized
          this.deps.setZoomTier(nextTier, true)
        }
        if (managedScene) {
          runRecoverableManagedCameraUpdate(this, applyAutoMode)
        } else {
          applyAutoMode()
        }
        return
      }

      const zoomByTier = {global: -0.9, regional: 0.35, local: 1.65}
      const nextViewState = {
        ...this.state.viewState,
        zoom: zoomByTier[normalized] || this.state.viewState.zoom,
      }
      if (managedScene) {
        runRecoverableManagedCameraUpdate(this, () => {
          this.state.zoomMode = normalized
          this.applyDeckViewState(nextViewState, {
            recoverManaged: false,
            syncZoomTier: false,
          })
          this.deps.setZoomTier("local", true)
        })
        return
      }

      this.state.zoomMode = normalized
      this.applyDeckViewState(nextViewState)
      this.deps.setZoomTier(normalized, true)
    })
  },
}
