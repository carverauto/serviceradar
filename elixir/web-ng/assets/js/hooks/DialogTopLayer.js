// Promote LiveView-rendered <dialog class="sr-ui-modal"> into the browser
// top layer via showModal(). Ops shell content uses isolation:isolate and the
// sticky sidebar has its own stacking context — CSS z-index alone cannot
// escape those, so flow details (and other dialogs) paint *under* the rail.
//
// Usage:
//   <dialog id="unique" class="sr-ui-modal sr-ui-modal-open"
//           phx-hook="DialogTopLayer" data-cancel="close_event">
//
// data-cancel (optional): LiveView event to push on Escape / backdrop click.
// data-cancel-target (optional): phx-target for that event.

export default {
  mounted() {
    this._onCancel = (e) => this._handleCancel(e)
    this.el.addEventListener("cancel", this._onCancel)
    this._open()
  },

  updated() {
    // LiveView re-render may remount open state without reopening top layer.
    this._open()
  },

  destroyed() {
    this.el.removeEventListener("cancel", this._onCancel)
    try {
      if (this.el.open) this.el.close()
    } catch (_err) {
      // Element may already be detached.
    }
  },

  _open() {
    if (typeof this.el.showModal !== "function") {
      this.el.setAttribute("open", "open")
      return
    }
    if (!this.el.open) {
      try {
        this.el.showModal()
      } catch (_err) {
        // Ignore InvalidStateError if already open / not connected.
      }
    }
  },

  _handleCancel(e) {
    const eventName = this.el.dataset.cancel
    if (!eventName) return

    // Keep the dialog open until LiveView removes it (controlled :if={@open}).
    e.preventDefault()

    const target = this.el.dataset.cancelTarget
    if (target) {
      this.pushEventTo(target, eventName, {})
    } else {
      this.pushEvent(eventName, {})
    }
  },
}
