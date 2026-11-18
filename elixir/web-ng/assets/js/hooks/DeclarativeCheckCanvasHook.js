import React from "react"
import {createRoot} from "react-dom/client"

import DeclarativeCheckBuilderCanvas from "../../component/src/DeclarativeCheckBuilderCanvas.jsx"

function parseProps(el) {
  if (!el?.dataset?.props) return {}
  try {
    return JSON.parse(el.dataset.props)
  } catch (_error) {
    return {}
  }
}

function triggerJsonDownload(filename, content) {
  if (typeof document === "undefined" || typeof Blob === "undefined") return
  const blob = new Blob([content], {type: "application/json;charset=utf-8"})
  const url = URL.createObjectURL(blob)
  const link = document.createElement("a")
  link.href = url
  link.download = filename || "check.declarative-check.json"
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
  URL.revokeObjectURL(url)
}

export default {
  mounted() {
    this.latestTestRun = null

    this.handleEvent("test_run_result", payload => {
      this.latestTestRun = payload?.result || payload || null
      this.renderBuilder()
    })

    this.handleEvent("download_canonical_json", ({filename, content}) => {
      if (typeof content === "string") {
        triggerJsonDownload(filename, content)
      }
    })

    this.reactRoot = createRoot(this.el)
    this.renderBuilder()
  },

  updated() {
    this.renderBuilder()
  },

  renderBuilder() {
    if (!this.reactRoot) return
    const props = parseProps(this.el)
    const initialTestRun = this.latestTestRun || props.initialTestRun || null

    this.reactRoot.render(
      React.createElement(DeclarativeCheckBuilderCanvas, {
        ...props,
        initialTestRun,
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
