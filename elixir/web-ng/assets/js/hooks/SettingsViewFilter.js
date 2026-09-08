// Client-side live filter for the Settings catalog left-panel view list.
//
// Filters the currently-shown category's views as the operator types in the
// "Search views…" box. Purely cosmetic (toggles `hidden`); it never touches the
// server. The category title and the "no views" placeholder are skipped
// (data-view-filter-skip); a data-view-filter-empty row shows when nothing
// matches.
export default {
  mounted() {
    this.input = this.el.querySelector("[data-view-filter-input]")
    if (!this.input) return

    this.onInput = () => this.apply()
    this.input.addEventListener("input", this.onInput)
  },

  destroyed() {
    if (this.input && this.onInput) {
      this.input.removeEventListener("input", this.onInput)
    }
  },

  apply() {
    const query = (this.input.value || "").trim().toLowerCase()
    let visible = 0

    this.el.querySelectorAll("[data-view-search]").forEach((item) => {
      const haystack = item.getAttribute("data-view-search") || ""
      const match = query === "" || haystack.includes(query)
      item.classList.toggle("hidden", !match)
      if (match) visible += 1
    })

    const empty = this.el.querySelector("[data-view-filter-empty]")
    if (empty) {
      empty.classList.toggle("hidden", !(query !== "" && visible === 0))
    }
  },
}
