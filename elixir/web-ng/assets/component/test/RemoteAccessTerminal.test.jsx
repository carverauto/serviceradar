// @vitest-environment happy-dom
import React, {act} from "react"
import {createRoot} from "react-dom/client"
import {renderToStaticMarkup} from "react-dom/server"
import {afterEach, describe, expect, it, vi} from "vitest"

globalThis.IS_REACT_ACT_ENVIRONMENT = true

import {
  Component,
  TERMINAL_FONT_FAMILY,
  TERMINAL_FONT_SIZE,
  TERMINAL_THEME,
} from "../src/RemoteAccessTerminal.jsx"

// Product mono stack from assets/css/app.css (--sr-font-mono). JetBrains Mono
// is not bundled with the product and must never head the terminal stack.
const PRODUCT_MONO_STACK =
  '"SFMono-Regular", Menlo, Monaco, Consolas, "Liberation Mono", monospace'

const createdTerminals = []

class FakeTerminal {
  constructor(options) {
    createdTerminals.push(options)
    this.cols = 80
    this.rows = 24
  }

  loadAddon() {}

  open() {}

  focus() {}

  onData() {
    return {dispose() {}}
  }

  write() {}

  dispose() {}
}

class FakeAddon {
  fit() {}
}

function terminalModuleLoader() {
  return Promise.resolve({
    Terminal: FakeTerminal,
    FitAddon: FakeAddon,
    ClipboardAddon: FakeAddon,
  })
}

class FakeWebSocket {
  static OPEN = 1

  constructor() {
    this.readyState = FakeWebSocket.OPEN
  }

  addEventListener() {}

  send() {}

  close() {}
}

class FakeResizeObserver {
  observe() {}

  disconnect() {}
}

describe("RemoteAccessTerminal brand chrome", () => {
  afterEach(() => {
    createdTerminals.length = 0
    vi.unstubAllGlobals()
  })

  it("uses the product monospace stack, never an unbundled font", () => {
    expect(TERMINAL_FONT_FAMILY).toBe(PRODUCT_MONO_STACK)
    expect(TERMINAL_FONT_FAMILY).not.toContain("JetBrains")
  })

  it("renders at a legible size", () => {
    expect(TERMINAL_FONT_SIZE).toBeGreaterThanOrEqual(14)
  })

  it("drops the slate-blue background for the sr-canvas surface", () => {
    expect(TERMINAL_THEME.background).toBe("#0a1114")
    expect(TERMINAL_THEME.foreground).toBe("#edf5f1")
    expect(Object.values(TERMINAL_THEME)).not.toContain("#0f172a")
    expect(Object.values(TERMINAL_THEME)).not.toContain("#020617")
  })

  it("passes the brand font and theme to xterm on mount", async () => {
    vi.stubGlobal("WebSocket", FakeWebSocket)
    vi.stubGlobal("ResizeObserver", FakeResizeObserver)

    const container = document.createElement("div")
    document.body.appendChild(container)
    const root = createRoot(container)

    await act(async () => {
      root.render(
        React.createElement(Component, {
          sessionId: "session-1",
          ticket: "srra-test-ticket",
          websocketPath: "/api/remote-access/sessions/session-1/stream",
          terminalModuleLoader,
        })
      )
    })

    expect(createdTerminals).toHaveLength(1)
    expect(createdTerminals[0].fontFamily).toBe(PRODUCT_MONO_STACK)
    expect(createdTerminals[0].fontFamily).not.toContain("JetBrains")
    expect(createdTerminals[0].fontSize).toBeGreaterThanOrEqual(14)
    expect(createdTerminals[0].theme.background).toBe("#0a1114")
    expect(createdTerminals[0].theme.background).not.toBe("#0f172a")

    await act(async () => {
      root.unmount()
    })
    container.remove()
  })

  it("omits the Disconnect button without an onDisconnect handler", () => {
    const markup = renderToStaticMarkup(
      React.createElement(Component, {
        title: "SSH remote access",
        terminalModuleLoader,
      })
    )

    expect(markup).not.toContain("remote-access-disconnect")
    expect(markup).not.toContain("Disconnect")
  })

  it("renders a Disconnect button next to the status when a handler is given", () => {
    const markup = renderToStaticMarkup(
      React.createElement(Component, {
        title: "SSH remote access",
        closeLabel: "SSH session",
        onDisconnect: () => {},
        terminalModuleLoader,
      })
    )

    expect(markup).toContain('data-testid="remote-access-disconnect"')
    expect(markup).toContain("Disconnect")
    expect(markup).toContain('aria-label="Disconnect SSH session"')
  })

  it("calls onDisconnect when the Disconnect button is clicked", async () => {
    vi.stubGlobal("WebSocket", FakeWebSocket)
    vi.stubGlobal("ResizeObserver", FakeResizeObserver)

    const onDisconnect = vi.fn()
    const container = document.createElement("div")
    document.body.appendChild(container)
    const root = createRoot(container)

    await act(async () => {
      root.render(
        React.createElement(Component, {
          sessionId: "session-1",
          ticket: "srra-test-ticket",
          websocketPath: "/api/remote-access/sessions/session-1/stream",
          terminalModuleLoader,
          onDisconnect,
        })
      )
    })

    const button = container.querySelector('[data-testid="remote-access-disconnect"]')
    expect(button).toBeTruthy()

    await act(async () => {
      button.click()
    })

    expect(onDisconnect).toHaveBeenCalledTimes(1)

    await act(async () => {
      root.unmount()
    })
    container.remove()
  })

  it("aligns the terminal chrome with sr tokens, not slate", () => {
    const markup = renderToStaticMarkup(
      React.createElement(Component, {
        title: "SSH remote access",
        subtitle: "device-1",
        terminalModuleLoader,
      })
    )

    expect(markup).toContain("bg-sr-canvas")
    expect(markup).toContain("bg-sr-surface")
    expect(markup).toContain("border-sr-line")
    expect(markup).toContain("text-sr-ink")
    expect(markup).not.toContain("slate-950")
    expect(markup).not.toContain("slate-900")
    expect(markup).not.toContain("slate-800")
  })
})
