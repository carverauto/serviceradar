import React from "react"
import {createRoot} from "react-dom/client"

import DashboardPanelChart from "../../component/src/DashboardPanelChart.jsx"

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
    this.reactRoot = createRoot(this.el)
    this.renderChart()
  },

  updated() {
    this.renderChart()
  },

  renderChart() {
    if (!this.reactRoot) return
    this.reactRoot.render(React.createElement(DashboardPanelChart, parseProps(this.el)))
  },

  destroyed() {
    if (this.reactRoot) {
      this.reactRoot.unmount()
      this.reactRoot = null
    }
  },
}
