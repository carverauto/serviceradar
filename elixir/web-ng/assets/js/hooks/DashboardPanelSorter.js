const DashboardPanelSorter = {
  mounted() {
    this.draggedId = null

    this.el.addEventListener("dragstart", event => {
      const item = event.target?.closest?.("[data-panel-id]")
      if (!item) return

      this.draggedId = item.dataset.panelId
      event.dataTransfer.effectAllowed = "move"
      event.dataTransfer.setData("text/plain", this.draggedId)
      item.classList.add("opacity-60")
    })

    this.el.addEventListener("dragend", event => {
      event.target?.closest?.("[data-panel-id]")?.classList.remove("opacity-60")
      this.draggedId = null
    })

    this.el.addEventListener("dragover", event => {
      if (!this.draggedId) return
      event.preventDefault()

      const over = event.target?.closest?.("[data-panel-id]")
      const dragged = this.el.querySelector(`[data-panel-id="${this.escapeSelector(this.draggedId)}"]`)
      if (!over || !dragged || over === dragged) return

      const box = over.getBoundingClientRect()
      const after =
        event.clientY > box.top + box.height / 2 ||
        (Math.abs(event.clientY - (box.top + box.height / 2)) < box.height / 4 &&
          event.clientX > box.left + box.width / 2)

      this.el.insertBefore(dragged, after ? over.nextSibling : over)
    })

    this.el.addEventListener("drop", event => {
      if (!this.draggedId) return
      event.preventDefault()

      const ids = Array.from(this.el.querySelectorAll("[data-panel-id]")).map(item => item.dataset.panelId)
      this.pushEvent("reorder_panels", {ids})
    })
  },

  escapeSelector(value) {
    if (window.CSS?.escape) return window.CSS.escape(value)

    return String(value).replace(/["\\]/g, "\\$&")
  },
}

export default DashboardPanelSorter
