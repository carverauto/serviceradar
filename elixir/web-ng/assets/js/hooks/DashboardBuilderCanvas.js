import React from "react"
import {createRoot} from "react-dom/client"

import DashboardBuilderCanvas from "../../component/src/DashboardBuilderCanvas.jsx"

function parseProps(el) {
  if (!el.dataset.props) return {}

  try {
    return JSON.parse(el.dataset.props)
  } catch (_error) {
    return {}
  }
}

export default {
  mounted() {
    this.handleEvent("clear_canvas_draft", ({key} = {}) => {
      const draftStorageKey = key || parseProps(this.el).draftStorageKey
      if (draftStorageKey) window.localStorage.removeItem(draftStorageKey)
    })

    this.reactRoot = createRoot(this.el)
    this.renderCanvas()
  },

  updated() {
    this.renderCanvas()
  },

  renderCanvas() {
    if (!this.reactRoot) return

    this.reactRoot.render(
      React.createElement(DashboardBuilderCanvas, {
        ...parseProps(this.el),
        pushEvent: this.pushEvent.bind(this),
      }),
    )
  },

  destroyed() {
    if (this.reactRoot) {
      this.reactRoot.unmount()
      this.reactRoot = null
    }
  },
}
