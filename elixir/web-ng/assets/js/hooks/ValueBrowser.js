import {ValueBrowser} from "../lib/value_browser"

// Devices already supplies its rollup dictionary. Reuse the same paginated list
// used by Atlas, whose loader requests bounded native dictionary windows instead.
export default {
  mounted() {
    const items = JSON.parse(this.el.dataset.items)
    this.browser = new ValueBrowser({parent: this.el, load: async ({search, cursor}) => {
      const needle = search.toLowerCase()
      const matches = items.filter(item => item.value.toLowerCase().includes(needle))
      const start = cursor || 0
      return {items: matches.slice(start, start + 50), cursor: start + 50 < matches.length ? start + 50 : null}
    }})
    this.focusFrame = window.requestAnimationFrame(() => this.browser.search.focus({preventScroll: true}))
  },
  destroyed() {window.cancelAnimationFrame(this.focusFrame); this.browser.destroy()},
}
