// Opens a <dialog> with showModal() so it uses the browser top layer, and
// pushes `data-cancel` on Escape or a backdrop click. No inline handler.
export const SrDialog = {
  mounted() {
    const dialog = this.el
    try {
      if (typeof dialog.showModal === "function" && !dialog.open) dialog.showModal()
    } catch (_error) {
      dialog.setAttribute("open", "")
    }

    this._onCancel = (event) => {
      event.preventDefault()
      this.pushCancel()
    }
    this._onClick = (event) => {
      if (event.target !== dialog) return
      if (dialog.dataset.staticBackdrop === "true") return
      this.pushCancel()
    }
    dialog.addEventListener("cancel", this._onCancel)
    dialog.addEventListener("click", this._onClick)
  },

  destroyed() {
    this.el.removeEventListener("cancel", this._onCancel)
    this.el.removeEventListener("click", this._onClick)
  },

  pushCancel() {
    const event = this.el.dataset.cancel
    if (!event) return
    const target = this.el.dataset.cancelTarget
    if (target) this.pushEventTo(target, event, {})
    else this.pushEvent(event, {})
  },
}
