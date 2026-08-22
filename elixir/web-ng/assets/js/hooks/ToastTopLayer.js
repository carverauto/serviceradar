// Promote LiveView flash toasts into the browser top layer so they paint
// above <dialog showModal()> (ops add-on profile modal, etc.). CSS z-index
// cannot beat the top layer.
//
// LiveView clears flash on the next event (closing the modal). Keep the last
// toast visible until the user dismisses it.

export default {
  mounted() {
    this._held = null
    this._dismissed = false
    this.js().ignoreAttributes(this.el, ["popover"])
    this._onClick = () => this._hide()
    this.el.addEventListener("click", this._onClick)
    this._sync()
  },

  updated() {
    this._sync()
  },

  destroyed() {
    this.el.removeEventListener("click", this._onClick)
    this._hide()
  },

  _sync() {
    if (this.el.hasAttribute("hidden")) return

    const message = (this.el.dataset.toastMessage || "").trim()
    if (message) {
      this._held = this.el.innerHTML
      this._dismissed = false
      this._open()
      return
    }

    if (this._held && !this._dismissed) {
      this.el.innerHTML = this._held
      this._open()
    }
  },

  _open() {
    if (typeof this.el.showPopover === "function") {
      try {
        if (!this.el.matches(":popover-open")) this.el.showPopover()
      } catch (_err) {
        this.el.setAttribute("open", "open")
      }
      return
    }
    this.el.setAttribute("open", "open")
  },

  _hide() {
    this._held = null
    this._dismissed = true
    if (typeof this.el.hidePopover === "function") {
      try {
        if (this.el.matches(":popover-open")) this.el.hidePopover()
      } catch (_err) {
        // ignore
      }
    }
    this.el.removeAttribute("open")
  },
}
