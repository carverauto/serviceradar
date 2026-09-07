import {beforeEach, describe, expect, it, vi} from "vitest"

const mocks = vi.hoisted(() => ({
  createRoot: vi.fn(),
  render: vi.fn(),
  unmount: vi.fn(),
}))

vi.mock("react-dom/client", () => ({
  createRoot: mocks.createRoot,
}))

vi.mock("../../component/src/RemoteConsoleTerminal.jsx", () => ({
  default: function MockRemoteConsoleTerminal() {
    return null
  },
}))

import RemoteConsoleTerminalHook from "./RemoteConsoleTerminal"

function hookContext(props) {
  return {
    ...RemoteConsoleTerminalHook,
    el: {
      dataset: props === undefined ? {} : {props},
    },
  }
}

describe("RemoteConsoleTerminal hook", () => {
  beforeEach(() => {
    mocks.createRoot.mockReset()
    mocks.render.mockReset()
    mocks.unmount.mockReset()
    mocks.createRoot.mockReturnValue({
      render: mocks.render,
      unmount: mocks.unmount,
    })
  })

  it("mounts the React console with client-side rendering and dataset props", () => {
    const ctx = hookContext(
      JSON.stringify({
        sessionId: "session-1",
        ticket: "srpve-test-ticket",
        websocketPath: "/v1/proxmox/console-sessions/session-1/stream",
        title: "PVE host console",
        subtitle: "termproxy via agent-1",
      })
    )

    ctx.mounted()

    expect(mocks.createRoot).toHaveBeenCalledWith(ctx.el)
    expect(mocks.render).toHaveBeenCalledTimes(1)
    expect(mocks.render.mock.calls[0][0].props).toMatchObject({
      sessionId: "session-1",
      ticket: "srpve-test-ticket",
      websocketPath: "/v1/proxmox/console-sessions/session-1/stream",
      title: "PVE host console",
      subtitle: "termproxy via agent-1",
    })
    expect(mocks.render.mock.calls[0][0].props.terminalModuleLoader).toEqual(expect.any(Function))
  })

  it("falls back to empty props when dataset props are absent", () => {
    const ctx = hookContext()

    ctx.mounted()

    expect(mocks.createRoot).toHaveBeenCalledWith(ctx.el)
    expect(mocks.render).toHaveBeenCalledTimes(1)
    expect(mocks.render.mock.calls[0][0].props.terminalModuleLoader).toEqual(expect.any(Function))
  })

  it("unmounts the React root exactly once when LiveView destroys the hook", () => {
    const ctx = hookContext()

    ctx.mounted()
    ctx.destroyed()
    ctx.destroyed()

    expect(mocks.unmount).toHaveBeenCalledTimes(1)
    expect(ctx.reactRoot).toBeNull()
  })
})
