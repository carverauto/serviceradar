// @vitest-environment happy-dom
import React, {act} from "react"
import {createRoot} from "react-dom/client"
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

globalThis.IS_REACT_ACT_ENVIRONMENT = true

vi.mock("../src/sshEphemeralKeypair.js", async (importOriginal) => {
  const original = await importOriginal()
  return {
    ...original,
    supportsEphemeralEd25519: () => true,
    generateEphemeralEd25519Keypair: async () => ({
      algorithm: "Ed25519",
      privateKeyPem: "-----BEGIN PRIVATE KEY-----\nPROBE\n-----END PRIVATE KEY-----\n",
      publicKeyOpenSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPROBE probe",
    }),
  }
})

import {Component} from "../src/RemoteAccessSSHConsole.jsx"

// Scalar session payload mirroring POST /api/remote-access/sessions 201.
const SESSION_DATA = {
  id: "76aa0f10-568a-45c9-8cb6-6a66f7105c06",
  status: "requested",
  protocol: "ssh",
  adapter: "ssh",
  ticket: "srra_probe_ticket",
  outcome: "nil",
  close_reason: null,
  agent_id: "agent-dusk01",
  gateway_id: null,
  approval_id: null,
  device_uid: "sr:5bf1b6f6-0e7c-43ac-b883-a13447199d85",
  target_kind: "inventory_device",
  failure_reason: null,
  credential_rule_id: null,
  idle_timeout_seconds: 900,
  absolute_timeout_seconds: 3600,
  target_host: "pve02",
  target_port: 22,
  credential_custody_mode: "ssh_certificate",
  attach_expires_at: "2026-09-05T15:55:51Z",
  rbac_decision: "allowed",
  websocket_path: "/v1/remote-access/sessions/76aa0f10/stream",
}

function jsonResponse(body, status = 200) {
  return {ok: status >= 200 && status < 300, status, json: async () => body}
}

function fakeTerminalModules() {
  return {
    Terminal: class {
      loadAddon() {}
      open() {}
      focus() {}
      dispose() {}
      onData() {
        return {dispose: () => {}}
      }
      get cols() {
        return 120
      }
      get rows() {
        return 34
      }
    },
    FitAddon: class {
      fit() {}
    },
    ClipboardAddon: class {},
  }
}

describe("RemoteAccessSSHConsole session transition", () => {
  let container
  let windowErrors

  beforeEach(() => {
    container = document.createElement("div")
    document.body.appendChild(container)
    windowErrors = []
    window.addEventListener("error", (event) => {
      windowErrors.push(String((event && event.message) || event))
    })
    vi.stubGlobal("fetch", vi.fn(async (url) => {
      if (String(url).includes("ssh-options")) {
        return jsonResponse({data: {accounts: [{name: "mfreeman"}]}})
      }
      return jsonResponse({data: SESSION_DATA}, 201)
    }))
    vi.stubGlobal("WebSocket", class {
      constructor() {
        this.readyState = 0
      }
      addEventListener() {}
      send() {}
      close() {}
    })
    vi.stubGlobal("ResizeObserver", class {
      observe() {}
      disconnect() {}
    })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    container.remove()
  })

  it("renders the terminal session view after Connect without unmounting", async () => {
    let root
    await act(async () => {
      root = createRoot(container)
      root.render(
        <Component
          deviceUid="sr:5bf1b6f6-0e7c-43ac-b883-a13447199d85"
          createPath="/api/remote-access/sessions"
          sshOptionsPath="/api/remote-access/devices/sr%3A5bf1b6f6-0e7c-43ac-b883-a13447199d85/ssh-options"
          approvalId=""
          title="SSH remote access"
          allowRememberedKeys={false}
          allowSkipVerifyHostKeyPolicy={false}
          allowTargetHostOverride={false}
          allowTargetPortOverride={false}
          terminalModuleLoader={async () => fakeTerminalModules()}
        />
      )
      await new Promise((resolve) => setTimeout(resolve, 100))
    })

    const button = [...container.querySelectorAll("button")].find((candidate) =>
      (candidate.textContent || "").includes("Connect with SSO")
    )
    expect(button).toBeTruthy()

    let clickError = null
    try {
      await act(async () => {
        button.click()
        await new Promise((resolve) => setTimeout(resolve, 500))
      })
    } catch (error) {
      clickError = error
    }

    // Rules-of-hooks regression: the session branch once early-returned past
    // the accountNames memo, unmounting the console (dev: "rendered fewer
    // hooks", prod: minified React error #300).
    expect(clickError).toBeNull()
    expect(windowErrors).toEqual([])
    expect(container.textContent).toContain("pve02:22 via agent-dusk01")
    expect(container.textContent).toContain("Files")

    // Brand chrome regression (sr-4375): the session shell aligns with the
    // sr palette, never the slate-blue scale.
    const shell = [...container.querySelectorAll("[class*='bg-sr-canvas']")]
    expect(shell.length).toBeGreaterThan(0)
    expect(container.querySelector("aside").className).toContain("bg-sr-surface")
    expect(container.querySelector("aside").className).toContain("border-sr-line")
    const slateLeftovers = [...container.querySelectorAll("*")].filter((node) =>
      [...(node.classList || [])].some((name) => name.includes("slate-"))
    )
    expect(slateLeftovers).toEqual([])

    await act(async () => {
      root.unmount()
    })
  })

  it.each(["success", "failure"])("isolates reconnect from a delayed transfer %s and stalled close", async (outcome) => {
    const sockets = []
    vi.stubGlobal("WebSocket", class {
      static CONNECTING = 0
      static OPEN = 1
      constructor() {
        this.readyState = 0
        this.listeners = {}
        this.close = vi.fn(() => { this.readyState = 3 })
        sockets.push(this)
      }
      addEventListener(type, handler) { this.listeners[type] = handler }
      send() {}
    })
    let finishTransfer
    let finishClose
    let listingCount = 0
    vi.stubGlobal("fetch", vi.fn((url) => {
      if (String(url).includes("ssh-options")) {
        return Promise.resolve(jsonResponse({data: {accounts: [{name: "operator"}]}}))
      }
      if (String(url).endsWith("/close")) {
        return new Promise((resolve) => { finishClose = resolve })
      }
      if (String(url).endsWith("/file-transfers")) {
        listingCount += 1
        if (listingCount === 1) return Promise.resolve(jsonResponse({data: {id: "transfer-example"}}))
        return new Promise((resolve, reject) => {
          finishTransfer = () => outcome === "success"
            ? resolve(jsonResponse({data: {id: "transfer-delayed"}}))
            : reject(new Error("obsolete transfer failure"))
        })
      }
      return Promise.resolve(jsonResponse({data: {
        id: "session-example",
        ticket: "example-ticket",
        target_host: "host01.example.com",
        target_port: 22,
        agent_id: "agent-example",
        websocket_path: "/api/remote-access/sessions/session-example/stream",
      }}, 201))
    }))
    const root = createRoot(container)
    await act(async () => {
      root.render(<Component deviceUid="device-example" terminalModuleLoader={fakeTerminalModules} />)
    })
    await act(async () => {
      [...container.querySelectorAll("button")].find((button) => button.textContent.includes("Connect with SSO")).click()
    })
    await act(async () => {
      container.querySelector('[aria-label="Refresh directory listing"]').click()
    })
    await act(async () => {
      sockets[0].listeners.message({data: JSON.stringify({
        type: "file_transfer",
        frame_type: "file_transfer_outcome",
        payload: {transfer_id: "transfer-example", entries: [{name: "example.txt", size: 5}]},
      })})
    })
    expect(container.textContent).toContain("example.txt")
    await act(async () => {
      container.querySelector('[aria-label="Refresh directory listing"]').click()
    })
    expect(container.querySelector('[aria-label="Refresh directory listing"]').disabled).toBe(true)
    await act(async () => {
      container.querySelector('[data-testid="remote-access-disconnect"]').click()
    })
    expect(finishClose).toBeTypeOf("function")
    expect(sockets[0].close).toHaveBeenCalledOnce()
    await act(async () => {
      [...container.querySelectorAll("button")].find((button) => button.textContent.includes("Connect with SSO")).click()
    })
    expect(container.textContent).not.toContain("example.txt")
    expect(container.querySelector('[aria-label="Refresh directory listing"]').disabled).toBe(false)
    await act(async () => {
      finishTransfer()
      finishClose(jsonResponse({}))
      sockets[0].listeners.message({data: JSON.stringify({
        type: "file_transfer",
        frame_type: "file_transfer_outcome",
        payload: {entries: [{name: "obsolete.txt", size: 2}]},
      })})
    })
    expect(container.textContent).not.toContain("obsolete")
    expect(container.textContent).not.toContain("transfer-delayed")
    expect(container.querySelector('[aria-label="Refresh directory listing"]').disabled).toBe(false)
    expect(sockets[1].close).not.toHaveBeenCalled()
    await act(async () => { root.unmount() })
  })

  it("disconnects through the session close endpoint and returns to the connection form", async () => {
    let root
    await act(async () => {
      root = createRoot(container)
      root.render(
        <Component
          deviceUid="sr:5bf1b6f6-0e7c-43ac-b883-a13447199d85"
          createPath="/api/remote-access/sessions"
          sshOptionsPath="/api/remote-access/devices/sr%3A5bf1b6f6-0e7c-43ac-b883-a13447199d85/ssh-options"
          approvalId=""
          title="SSH remote access"
          allowRememberedKeys={false}
          allowSkipVerifyHostKeyPolicy={false}
          allowTargetHostOverride={false}
          allowTargetPortOverride={false}
          terminalModuleLoader={async () => fakeTerminalModules()}
        />
      )
      await new Promise((resolve) => setTimeout(resolve, 100))
    })

    const connectButton = [...container.querySelectorAll("button")].find((candidate) =>
      (candidate.textContent || "").includes("Connect with SSO")
    )
    expect(connectButton).toBeTruthy()

    await act(async () => {
      connectButton.click()
      await new Promise((resolve) => setTimeout(resolve, 500))
    })

    expect(container.textContent).toContain("pve02:22 via agent-dusk01")

    // sr-4400: the console chrome offers a visible Disconnect control so the
    // operator is not limited to typing logout/Ctrl-D inside the terminal.
    const disconnectButton = container.querySelector('[data-testid="remote-access-disconnect"]')
    expect(disconnectButton).toBeTruthy()
    expect(disconnectButton.textContent).toContain("Disconnect")

    await act(async () => {
      disconnectButton.click()
      await new Promise((resolve) => setTimeout(resolve, 500))
    })

    const fetchMock = globalThis.fetch
    const closeCall = fetchMock.mock.calls.find(([url]) =>
      String(url).endsWith(`/remote-access/sessions/${SESSION_DATA.id}/close`)
    )
    expect(closeCall).toBeTruthy()
    expect(closeCall[1].method).toBe("POST")
    expect(JSON.parse(closeCall[1].body).reason).toBe("operator_requested")

    // The terminal unmounts and the connection form returns.
    expect(container.textContent).not.toContain("pve02:22 via agent-dusk01")
    const reconnectButton = [...container.querySelectorAll("button")].find((candidate) =>
      (candidate.textContent || "").includes("Connect with SSO")
    )
    expect(reconnectButton).toBeTruthy()
    expect(windowErrors).toEqual([])

    await act(async () => {
      root.unmount()
    })
  })
})

// Reproduces the reported failure: a device the deployment's SSH certificate
// policy does not list. `ssh-options` succeeds and returns zero accounts, which
// the console used to render as an ordinary free-text account field with Connect
// enabled, so the only feedback was the control plane refusing the session.
describe("RemoteAccessSSHConsole without a certificate policy for the target", () => {
  let container

  beforeEach(() => {
    container = document.createElement("div")
    document.body.appendChild(container)
    vi.stubGlobal("fetch", vi.fn(async (url) => {
      if (String(url).includes("ssh-options")) {
        return jsonResponse({data: {accounts: [], default_credential_mode: "ssh_certificate"}})
      }
      throw new Error(`unexpected session request to ${url}`)
    }))
    vi.stubGlobal("ResizeObserver", class {
      observe() {}
      disconnect() {}
    })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    container.remove()
  })

  async function renderConsole() {
    let root
    await act(async () => {
      root = createRoot(container)
      root.render(
        <Component
          deviceUid="sr:1f2e3d4c-5b6a-4c8d-9e0f-a1b2c3d4e5f6"
          sshOptionsPath="/api/remote-access/devices/sr%3A1f2e3d4c/ssh-options"
          terminalModuleLoader={async () => fakeTerminalModules()}
        />
      )
      await new Promise((resolve) => setTimeout(resolve, 100))
    })
    return root
  }

  function connectButton() {
    return [...container.querySelectorAll("button")].find((candidate) =>
      (candidate.textContent || "").includes("Connect with SSO")
    )
  }

  it("explains the missing policy without offering an account", async () => {
    const root = await renderConsole()

    expect(container.textContent).toContain("This target has no SSH certificate policy")
    expect(connectButton().disabled).toBe(false)
    expect(container.querySelector("input[autocomplete='username']")).toBeNull()

    await act(async () => {
      root.unmount()
    })
  })

  // Regression for the reported dead control: a natively disabled button fires
  // no click of its own, so clicking Connect for a target outside the
  // certificate policy must still answer with the reason — and must never
  // issue a session request the control plane would refuse.
  it("answers a click on the blocked connect with the missing-policy reason", async () => {
    const root = await renderConsole()

    const button = connectButton()
    expect(button.disabled).toBe(false)
    expect(button.getAttribute("aria-describedby")).toBe("ssh-certificate-policy-warning")
    expect(container.querySelector(".alert-error")).toBeNull()

    await act(async () => {
      button.click()
      await new Promise((resolve) => setTimeout(resolve, 50))
    })

    const errors = [...container.querySelectorAll(".alert-error")].map((node) => node.textContent || "")
    expect(errors.some((text) => text.includes("This target has no SSH certificate policy"))).toBe(true)

    const sessionCalls = globalThis.fetch.mock.calls.filter(
      ([url]) => !String(url).includes("ssh-options")
    )
    expect(sessionCalls).toEqual([])

    await act(async () => {
      root.unmount()
    })
  })

  it("still allows the legacy user-present path for the same target", async () => {
    const root = await renderConsole()

    const advanced = [...container.querySelectorAll("button")].find((candidate) =>
      (candidate.textContent || "").includes("Show advanced")
    )
    await act(async () => {
      advanced.click()
    })

    const modeSelect = [...container.querySelectorAll("select")].find((candidate) =>
      [...candidate.options].some((option) => option.value === "user_present")
    )
    expect(modeSelect).toBeTruthy()

    await act(async () => {
      modeSelect.value = "user_present"
      modeSelect.dispatchEvent(new Event("change", {bubbles: true}))
    })

    expect(container.textContent).not.toContain("This target has no SSH certificate policy")
    expect(container.querySelector("input[autocomplete='username']")).toBeTruthy()

    const openButton = [...container.querySelectorAll("button")].find((candidate) =>
      (candidate.textContent || "").includes("Open SSH session")
    )
    expect(openButton).toBeTruthy()
    expect(openButton.disabled).toBe(false)

    await act(async () => {
      root.unmount()
    })
  })
})
