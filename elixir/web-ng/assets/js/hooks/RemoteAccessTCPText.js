import React from "react"
import {createRoot} from "react-dom/client"

import RemoteAccessTCPText from "../../component/src/RemoteAccessTCPText.jsx"

function parseProps(el) {
  if (!el.dataset.props) {
    return {}
  }

  try {
    return JSON.parse(el.dataset.props)
  } catch (_error) {
    return {}
  }
}

export default {
  mounted() {
    this.reactRoot = createRoot(this.el)
    this.reactRoot.render(React.createElement(RemoteAccessTCPText, parseProps(this.el)))
  },

  destroyed() {
    if (this.reactRoot) {
      this.reactRoot.unmount()
      this.reactRoot = null
    }
  },
}
