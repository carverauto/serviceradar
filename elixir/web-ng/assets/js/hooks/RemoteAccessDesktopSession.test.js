import {beforeEach, describe, expect, it, vi} from "vitest"

const mocks = vi.hoisted(() => ({
  createRoot: vi.fn(),
  render: vi.fn(),
  unmount: vi.fn(),
}))

vi.mock("react-dom/client", () => ({
  createRoot: mocks.createRoot,
}))

vi.mock("../../component/src/RemoteAccessDesktopSession.jsx", () => ({
  default: function MockRemoteAccessDesktopSession() {
    return null
  },
}))

import RemoteAccessDesktopSessionHook from "./RemoteAccessDesktopSession"

function hookContext(props) {
  return {
    ...RemoteAccessDesktopSessionHook,
    el: {
      dataset: props === undefined ? {} : {props},
    },
  }
}

describe("RemoteAccessDesktopSession hook", () => {
  beforeEach(() => {
    mocks.createRoot.mockReset()
    mocks.render.mockReset()
    mocks.unmount.mockReset()
    mocks.createRoot.mockReturnValue({
      render: mocks.render,
      unmount: mocks.unmount,
    })
  })

  it("mounts the React session shell with parsed dataset props", () => {
    const ctx = hookContext(JSON.stringify({
      title: "Finance desktop",
      session: {id: "session-1"},
    }))

    ctx.mounted()

    expect(mocks.createRoot).toHaveBeenCalledWith(ctx.el)
    expect(mocks.render).toHaveBeenCalledTimes(1)
    expect(mocks.render.mock.calls[0][0].props).toMatchObject({
      title: "Finance desktop",
      session: {id: "session-1"},
    })
  })

  it("falls back to empty props when dataset JSON is invalid", () => {
    const ctx = hookContext("{")

    ctx.mounted()

    expect(mocks.render.mock.calls[0][0].props).toEqual({})
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
