import {beforeEach, describe, expect, it, vi} from "vitest"

const mocks = vi.hoisted(() => ({
  createRoot: vi.fn(),
  render: vi.fn(),
  unmount: vi.fn(),
}))

vi.mock("react-dom/client", () => ({
  createRoot: mocks.createRoot,
}))

vi.mock("../../component/src/RemoteAccessSSHConsole.jsx", () => ({
  default: function MockRemoteAccessSSHConsole() {
    return null
  },
}))

import RemoteAccessSSHConsoleHook, {parseProps} from "./RemoteAccessSSHConsole"

function hookContext(props) {
  return {
    ...RemoteAccessSSHConsoleHook,
    el: {
      dataset: props === undefined ? {} : {props},
    },
  }
}

describe("RemoteAccessSSHConsole hook", () => {
  beforeEach(() => {
    mocks.createRoot.mockReset()
    mocks.render.mockReset()
    mocks.unmount.mockReset()
    mocks.createRoot.mockReturnValue({
      render: mocks.render,
      unmount: mocks.unmount,
    })
  })

  it("mounts the React console with schema-validated dataset props", () => {
    const ctx = hookContext(
      JSON.stringify({
        deviceUid: "linux-1",
        createPath: "/api/remote-access/sessions",
        fileTransferPath: "/api/remote-access/file-transfers",
        approvalId: "approval-1",
        title: "SSH console",
        allowRememberedKeys: true,
        allowSkipVerifyHostKeyPolicy: false,
        allowTargetHostOverride: true,
        allowTargetPortOverride: false,
      })
    )

    ctx.mounted()

    expect(mocks.createRoot).toHaveBeenCalledWith(ctx.el)
    expect(mocks.render).toHaveBeenCalledTimes(1)
    expect(mocks.render.mock.calls[0][0].props).toMatchObject({
      deviceUid: "linux-1",
      title: "SSH console",
      allowRememberedKeys: true,
      allowTargetHostOverride: true,
    })
    expect(mocks.render.mock.calls[0][0].props.terminalModuleLoader).toEqual(expect.any(Function))
  })

  it("keeps deviceUid when LiveView sends the production SSH console prop set", () => {
    const deviceUid = "sr:5bf1b6f6-0e7c-43ac-b883-a13447199d85"
    const sshOptionsPath = `/api/remote-access/devices/${encodeURIComponent(deviceUid)}/ssh-options`
    const ctx = hookContext(
      JSON.stringify({
        deviceUid,
        createPath: "/api/remote-access/sessions",
        sshOptionsPath,
        approvalId: "",
        title: "SSH remote access",
        allowRememberedKeys: false,
        allowSkipVerifyHostKeyPolicy: false,
        allowTargetHostOverride: false,
        allowTargetPortOverride: false,
      })
    )

    ctx.mounted()

    expect(mocks.render.mock.calls[0][0].props).toMatchObject({
      deviceUid,
      createPath: "/api/remote-access/sessions",
      sshOptionsPath,
      title: "SSH remote access",
    })
  })

  it("rejects malformed, non-object, unknown, or wrong-typed dataset props", () => {
    for (const props of [
      "{",
      "[]",
      JSON.stringify({deviceUid: "linux-1", credential: "secret"}),
      JSON.stringify({deviceUid: 42}),
      JSON.stringify({allowRememberedKeys: "true"}),
    ]) {
      expect(parseProps({dataset: {props}})).toEqual({})
    }
  })

  it("falls back to empty props when dataset props are absent", () => {
    expect(parseProps({dataset: {}})).toEqual({})
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
