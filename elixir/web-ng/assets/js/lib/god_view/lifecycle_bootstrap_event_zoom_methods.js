export const godViewLifecycleBootstrapEventZoomMethods = {
  registerZoomModeEvent() {
    this.state.handleEvent("god_view:set_zoom_mode", ({mode}) => {
      const normalized = mode === "global" || mode === "regional" || mode === "local" ? mode : "auto"
      this.state.zoomMode = normalized

      if (!this.state.deck) return

      if (normalized === "auto") {
        this.deps.setZoomTier(this.deps.resolveZoomTier(this.state.viewState.zoom || 0), true)
        return
      }

      const zoomByTier = {global: -0.9, regional: 0.35, local: 1.65}
      this.state.viewState = {
        ...this.state.viewState,
        zoom: zoomByTier[normalized] || this.state.viewState.zoom,
      }
      this.state.userCameraLocked = true
      this.state.isProgrammaticViewUpdate = true
      this.state.deck.setProps({viewState: this.state.viewState})
      this.deps.setZoomTier(normalized, true)
    })
  },
}
