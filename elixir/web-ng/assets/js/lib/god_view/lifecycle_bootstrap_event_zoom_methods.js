export const godViewLifecycleBootstrapEventZoomMethods = {
  registerZoomModeEvent() {
    this.handleEvent("god_view:set_zoom_mode", ({mode}) => {
      const normalized = mode === "global" || mode === "regional" || mode === "local" ? mode : "auto"
      this.zoomMode = normalized

      if (!this.deck) return

      if (normalized === "auto") {
        this.setZoomTier(this.resolveZoomTier(this.viewState.zoom || 0), true)
        return
      }

      const zoomByTier = {global: -0.9, regional: 0.35, local: 1.65}
      this.viewState = {
        ...this.viewState,
        zoom: zoomByTier[normalized] || this.viewState.zoom,
      }
      this.userCameraLocked = true
      this.isProgrammaticViewUpdate = true
      this.deck.setProps({viewState: this.viewState})
      this.setZoomTier(normalized, true)
    })
  },
}
