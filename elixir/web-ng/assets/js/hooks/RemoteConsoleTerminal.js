import "@xterm/xterm/css/xterm.css"

import React from "react"
import {createRoot} from "react-dom/client"

import RemoteConsoleTerminal from "../../component/src/RemoteConsoleTerminal.jsx"

let terminalModules = null

async function loadTerminalModules() {
  if (!terminalModules) {
    const [{Terminal}, {FitAddon}, {ClipboardAddon}] = await Promise.all([
      import("@xterm/xterm"),
      import("@xterm/addon-fit"),
      import("@xterm/addon-clipboard"),
    ])

    terminalModules = {Terminal, FitAddon, ClipboardAddon}
  }

  return terminalModules
}

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
    const props = {...parseProps(this.el), terminalModuleLoader: loadTerminalModules}
    this.reactRoot = createRoot(this.el)
    this.reactRoot.render(React.createElement(RemoteConsoleTerminal, props))
  },

  destroyed() {
    if (this.reactRoot) {
      this.reactRoot.unmount()
      this.reactRoot = null
    }
  },
}
