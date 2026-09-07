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
      privateKeyPem: "not-a-private-key",
      publicKeyOpenSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPROBE probe",
    }),
  }
})

import {Component} from "../src/RemoteAccessSSHConsole.jsx"

// Synthetic-only key material for storage assertions. Never a real key.
// Deliberately NOT PEM-armored: secret scanners flag BEGIN PRIVATE KEY
// blocks even in fixtures, and the console treats pasted keys opaquely.
const SYNTHETIC_MARKER = "SYNTHETIC-TEST-KEY-DO-NOT-USE-sr-4383"
const SYNTHETIC_KEY = `synthetic-user-private-key:${SYNTHETIC_MARKER}`
const DEVICE_UID = "sr:9aa11bb2-3333-4444-5555-666677778888"
const STORE_KEY = `serviceradar.remoteAccess.sshKey.v1.${DEVICE_UID}`

const SESSION_DATA = {
  id: "11111111-2222-3333-4444-555555555555",
  status: "requested",
  protocol: "ssh",
  adapter: "ssh",
  ticket: "srra_probe_ticket",
  agent_id: "agent-probe",
  device_uid: DEVICE_UID,
  target_host: "probe01",
  target_port: 22,
  credential_custody_mode: "user_present",
  websocket_path: "/v1/remote-access/sessions/11111111/stream",
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

function setNativeValue(element, value) {
  const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype
  Object.getOwnPropertyDescriptor(prototype, "value").set.call(element, value)
  element.dispatchEvent(new Event("input", {bubbles: true}))
}

describe("RemoteAccessSSHConsole remembered keys (sr-4383)", () => {
  let container
  let localSets
  let sessionSetSpy

  beforeEach(() => {
    container = document.createElement("div")
    document.body.appendChild(container)
    window.localStorage.clear()
    window.sessionStorage.clear()
    localSets = []
    sessionSetSpy = vi.spyOn(window.sessionStorage, "setItem")
    const originalSetItem = window.localStorage.setItem.bind(window.localStorage)
    vi.spyOn(window.localStorage, "setItem").mockImplementation((key, value) => {
      localSets.push([String(key), String(value)])
      return originalSetItem(key, value)
    })
    vi.stubGlobal("fetch", vi.fn(async (url, options) => {
      if (String(url).includes("ssh-options")) {
        return jsonResponse({data: {accounts: [{name: "mfreeman"}]}})
      }
      if (options?.method === "POST") {
        return jsonResponse({data: SESSION_DATA}, 201)
      }
      throw new Error(`unexpected request to ${url}`)
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
    vi.restoreAllMocks()
    container.remove()
  })

  async function renderConsole(props = {}, Console = Component) {
    let root
    await act(async () => {
      root = createRoot(container)
      root.render(
        <Console
          deviceUid={DEVICE_UID}
          createPath="/api/remote-access/sessions"
          sshOptionsPath={`/api/remote-access/devices/${encodeURIComponent(DEVICE_UID)}/ssh-options`}
          approvalId=""
          title="SSH remote access"
          allowRememberedKeys={true}
          allowSkipVerifyHostKeyPolicy={false}
          allowTargetHostOverride={false}
          allowTargetPortOverride={false}
          terminalModuleLoader={async () => fakeTerminalModules()}
          {...props}
        />
      )
      await new Promise((resolve) => setTimeout(resolve, 100))
    })
    return root
  }

  async function switchToUserPresentKey() {
    const advanced = [...container.querySelectorAll("button")].find((candidate) =>
      (candidate.textContent || "").includes("Show advanced")
    )
    await act(async () => {
      advanced.click()
    })
    const modeSelect = [...container.querySelectorAll("select")].find((candidate) =>
      [...candidate.options].some((option) => option.value === "user_present")
    )
    await act(async () => {
      modeSelect.value = "user_present"
      modeSelect.dispatchEvent(new Event("change", {bubbles: true}))
    })
  }

  async function pasteKeyAndRemember() {
    const textarea = container.querySelector("textarea")
    expect(textarea).toBeTruthy()
    await act(async () => {
      setNativeValue(textarea, SYNTHETIC_KEY)
      await new Promise((resolve) => setTimeout(resolve, 50))
    })
    const checkbox = [...container.querySelectorAll("input[type='checkbox']")].find((candidate) =>
      (candidate.closest("label")?.textContent || "").includes("Remember key")
    )
    expect(checkbox).toBeTruthy()
    await act(async () => {
      checkbox.click()
    })
    const openButton = [...container.querySelectorAll("button")].find((candidate) =>
      (candidate.textContent || "").includes("Open SSH session")
    )
    await act(async () => {
      openButton.click()
      await new Promise((resolve) => setTimeout(resolve, 500))
    })
  }

  function localStorageKeyWrites() {
    return localSets.filter(
      ([key, value]) => key.startsWith("serviceradar.remoteAccess.sshKey.v1.") || value.includes(SYNTHETIC_MARKER)
    )
  }

  it("remembers in page memory across remounts but not a fresh page runtime", async () => {
    let root = await renderConsole()
    await switchToUserPresentKey()
    await pasteKeyAndRemember()

    expect(localStorageKeyWrites()).toEqual([])
    expect(window.localStorage.getItem(STORE_KEY)).toBeNull()
    expect(window.sessionStorage.getItem(STORE_KEY)).toBeNull()
    expect(sessionSetSpy).not.toHaveBeenCalled()

    await act(async () => root.unmount())
    root = await renderConsole()
    await switchToUserPresentKey()
    expect(container.querySelector("textarea").value).toBe(SYNTHETIC_KEY)
    await act(async () => root.unmount())

    vi.resetModules()
    const {Component: FreshConsole} = await import("../src/RemoteAccessSSHConsole.jsx")
    root = await renderConsole({}, FreshConsole)
    await switchToUserPresentKey()
    expect(container.querySelector("textarea").value).toBe("")
    await act(async () => root.unmount())

    root = await renderConsole({allowRememberedKeys: false})
    expect(container.textContent).not.toContain("Remember key")
    await act(async () => root.unmount())
    root = await renderConsole()
    await switchToUserPresentKey()
    expect(container.querySelector("textarea").value).toBe("")
    await act(async () => root.unmount())
  })

  it("purges a legacy localStorage key on mount", async () => {
    window.localStorage.setItem(STORE_KEY, JSON.stringify({username: "mfreeman", privateKey: SYNTHETIC_KEY}))
    localSets.length = 0

    const root = await renderConsole()

    expect(window.localStorage.getItem(STORE_KEY)).toBeNull()

    await act(async () => {
      root.unmount()
    })
  })

  it("does not persist the key anywhere when remember is left unchecked", async () => {
    const root = await renderConsole()
    await switchToUserPresentKey()

    const textarea = container.querySelector("textarea")
    await act(async () => {
      setNativeValue(textarea, SYNTHETIC_KEY)
      await new Promise((resolve) => setTimeout(resolve, 50))
    })
    const openButton = [...container.querySelectorAll("button")].find((candidate) =>
      (candidate.textContent || "").includes("Open SSH session")
    )
    await act(async () => {
      openButton.click()
      await new Promise((resolve) => setTimeout(resolve, 500))
    })

    expect(localStorageKeyWrites()).toEqual([])
    expect(window.sessionStorage.getItem(STORE_KEY)).toBeNull()
    expect(window.localStorage.getItem(STORE_KEY)).toBeNull()

    await act(async () => {
      root.unmount()
    })
  })
})
