import React from "react"
import {createRoot} from "react-dom/client"

import RemoteAccessDesktopSession from "../../component/src/RemoteAccessDesktopSession.jsx"

const STRING_PROPS = new Set(["desktopTargetId", "deviceUid", "approvalId", "createPath", "title"])
const BOOLEAN_PROPS = new Set(["autoConnect"])

export function parseProps(el) {
  if (!el.dataset.props) {
    return {}
  }

  try {
    const value = JSON.parse(el.dataset.props)

    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return {}
    }

    const props = {}

    for (const [key, item] of Object.entries(value)) {
      if (STRING_PROPS.has(key) && typeof item === "string") {
        props[key] = item
      } else if (BOOLEAN_PROPS.has(key) && typeof item === "boolean") {
        props[key] = item
      } else if (key === "queueMaxFrames" && Number.isInteger(item) && item > 0) {
        props[key] = item
      } else if (key === "session" && item && typeof item === "object" && !Array.isArray(item)) {
        props[key] = item
      }
    }

    return props
  } catch (_error) {
    return {}
  }
}

export default {
  mounted() {
    this.reactRoot = createRoot(this.el)
    this.reactRoot.render(React.createElement(RemoteAccessDesktopSession, parseProps(this.el)))
  },

  destroyed() {
    if (this.reactRoot) {
      this.reactRoot.unmount()
      this.reactRoot = null
    }
  },
}
