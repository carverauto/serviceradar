export const godViewLifecycleBootstrapEventResetViewMethods = {
  registerResetViewEvent() {
    this.state.handleEvent("god_view:reset_view", () => {
      if (!this.state.deck) return

      this.state.userCameraLocked = false
      this.state.hasAutoFit = false
      this.deps.autoFitViewState(this.state.lastGraph)
    })
  },
}
