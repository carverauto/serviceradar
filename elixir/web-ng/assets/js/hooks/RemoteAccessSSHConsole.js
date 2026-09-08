import "@xterm/xterm/css/xterm.css"

import React from "react"
import {createRoot} from "react-dom/client"

import RemoteAccessSSHConsole from "../../component/src/RemoteAccessSSHConsole.jsx"

let terminalModules = null
const STRING_PROPS = new Set([
  "deviceUid",
  "createPath",
  "fileTransferPath",
  "sshOptionsPath",
  "approvalId",
  "title",
])
const BOOLEAN_PROPS = new Set([
  "allowRememberedKeys",
  "allowSkipVerifyHostKeyPolicy",
  "allowTargetHostOverride",
  "allowTargetPortOverride",
])
const ALLOWED_PROPS = new Set([...STRING_PROPS, ...BOOLEAN_PROPS])

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

export function parseProps(el) {
  if (!el.dataset.props) {
    return {}
  }

  try {
    return validateProps(JSON.parse(el.dataset.props))
  } catch (_error) {
    return {}
  }
}

function validateProps(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {}
  }

  const entries = Object.entries(value)

  if (entries.some(([key]) => !ALLOWED_PROPS.has(key))) {
    return {}
  }

  const props = {}

  for (const [key, propValue] of entries) {
    if (STRING_PROPS.has(key)) {
      if (typeof propValue !== "string") {
        return {}
      }

      props[key] = propValue
    } else if (BOOLEAN_PROPS.has(key)) {
      if (typeof propValue !== "boolean") {
        return {}
      }

      props[key] = propValue
    }
  }

  return props
}

export default {
  mounted() {
    const props = {...parseProps(this.el), terminalModuleLoader: loadTerminalModules}
    this.reactRoot = createRoot(this.el)
    this.reactRoot.render(React.createElement(RemoteAccessSSHConsole, props))
  },

  destroyed() {
    if (this.reactRoot) {
      this.reactRoot.unmount()
      this.reactRoot = null
    }
  },
}
