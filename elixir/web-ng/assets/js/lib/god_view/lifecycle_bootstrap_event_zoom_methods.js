import {depsRef, stateRef} from "./runtime_refs"
export const godViewLifecycleBootstrapEventZoomMethods = {
  registerZoomModeEvent() {
    stateRef(this).handleEvent("god_view:set_zoom_mode", ({mode}) => {
      const normalized = mode === "global" || mode === "regional" || mode === "local" ? mode : "auto"
      stateRef(this).zoomMode = normalized

      if (!stateRef(this).deck) return

      if (normalized === "auto") {
        depsRef(this).setZoomTier(depsRef(this).resolveZoomTier(stateRef(this).viewState.zoom || 0), true)
        return
      }

      const zoomByTier = {global: -0.9, regional: 0.35, local: 1.65}
      stateRef(this).viewState = {
        ...stateRef(this).viewState,
        zoom: zoomByTier[normalized] || stateRef(this).viewState.zoom,
      }
      stateRef(this).userCameraLocked = true
      stateRef(this).isProgrammaticViewUpdate = true
      stateRef(this).deck.setProps({viewState: stateRef(this).viewState})
      depsRef(this).setZoomTier(normalized, true)
    })
  },
}
