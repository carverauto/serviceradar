// Client-side conveniences for the Device Details "All Metadata" card.
//
// Two purely-cosmetic behaviors, both client-only (they never touch the
// server):
//   1. A live filter box that toggles `hidden` on metadata rows (and collapses
//      groups whose rows all fall out of the filter) as the operator types.
//   2. A "copy as JSON" button that writes the full, pretty-printed metadata
//      map (stashed in `data-metadata-json`) to the clipboard.
export default {
  mounted() {
    this.filterInput = this.el.querySelector("[data-metadata-filter-input]")
    this.copyBtn = this.el.querySelector("[data-metadata-copy]")
    this.emptyEl = this.el.querySelector("[data-metadata-filter-empty]")

    this.onFilter = () => this.applyFilter()
    if (this.filterInput) this.filterInput.addEventListener("input", this.onFilter)

    this.onCopy = () => this.copyJson()
    if (this.copyBtn) this.copyBtn.addEventListener("click", this.onCopy)
  },

  destroyed() {
    if (this.filterInput && this.onFilter) {
      this.filterInput.removeEventListener("input", this.onFilter)
    }
    if (this.copyBtn && this.onCopy) {
      this.copyBtn.removeEventListener("click", this.onCopy)
    }
    if (this._flashTimer) clearTimeout(this._flashTimer)
  },

  applyFilter() {
    const query = (this.filterInput.value || "").trim().toLowerCase()
    let visible = 0

    this.el.querySelectorAll("[data-metadata-row]").forEach((row) => {
      const haystack = row.getAttribute("data-metadata-search") || ""
      const match = query === "" || haystack.includes(query)
      row.classList.toggle("hidden", !match)
      if (match) visible += 1
    })

    // Hide group cards whose rows all dropped out so the filter reads cleanly.
    this.el.querySelectorAll("[data-metadata-group]").forEach((group) => {
      const anyVisible = group.querySelector("[data-metadata-row]:not(.hidden)")
      group.classList.toggle("hidden", !anyVisible)
    })

    if (this.emptyEl) {
      this.emptyEl.classList.toggle("hidden", !(query !== "" && visible === 0))
    }
  },

  async copyJson() {
    const json = this.el.getAttribute("data-metadata-json") || ""

    try {
      await navigator.clipboard.writeText(json)
      this.flash("Copied!")
    } catch (_err) {
      // Fallback for insecure contexts / older browsers where the async
      // Clipboard API is unavailable.
      const textarea = document.createElement("textarea")
      textarea.value = json
      textarea.style.position = "fixed"
      textarea.style.opacity = "0"
      document.body.appendChild(textarea)
      textarea.select()
      try {
        document.execCommand("copy")
        this.flash("Copied!")
      } catch (_err2) {
        this.flash("Copy failed")
      }
      document.body.removeChild(textarea)
    }
  },

  flash(text) {
    const label = this.el.querySelector("[data-metadata-copy-label]")
    if (!label) return

    if (label.dataset.original === undefined) {
      label.dataset.original = label.textContent
    }

    label.textContent = text
    if (this._flashTimer) clearTimeout(this._flashTimer)
    this._flashTimer = setTimeout(() => {
      label.textContent = label.dataset.original
    }, 1500)
  },
}
