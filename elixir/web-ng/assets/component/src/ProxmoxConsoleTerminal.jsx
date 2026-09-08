import React from "react"

import RemoteAccessTerminal from "./RemoteAccessTerminal.jsx"

export function Component(props) {
  return (
    <RemoteAccessTerminal
      title="Proxmox console"
      streamLabel="Console"
      closeLabel="Console session"
      {...props}
    />
  )
}

export default Component
