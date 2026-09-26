// Keyboard navigation for the OTel service picker modal
// (ServiceRadarWebNGWeb.Components.ServicePicker).
//
// ArrowDown / ArrowUp move focus between the search field and the option
// checkboxes. Space toggles the focused checkbox natively (it fires the
// checkbox's phx-click). Enter applies the selection: the search field does it
// through its form's phx-submit, and this hook does it for a focused option.
// Escape is owned by DialogTopLayer (data-cancel on the <dialog>).
//
// Usage:
//   <div id="service-picker-body" phx-hook="ServicePickerKeys">
//     <input data-picker-search ... />
//     <input type="checkbox" data-picker-option ... />

const ITEM_SELECTOR = "[data-picker-search], [data-picker-option]"

export default {
  mounted() {
    this._onKeydown = (e) => this.handleKeydown(e)
    this.el.addEventListener("keydown", this._onKeydown)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._onKeydown)
  },

  items() {
    return Array.from(this.el.querySelectorAll(ITEM_SELECTOR))
  },

  handleKeydown(e) {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      const items = this.items()
      if (items.length === 0) return

      e.preventDefault()
      const current = items.indexOf(e.target)
      const step = e.key === "ArrowDown" ? 1 : -1
      const next = current === -1 ? 0 : Math.min(Math.max(current + step, 0), items.length - 1)
      items[next].focus()
      return
    }

    if (e.key === "Enter" && e.target?.matches?.("[data-picker-option]")) {
      e.preventDefault()
      this.pushEvent("service_picker_apply", {})
    }
  },
}
