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

const SESSION_DATA = {
  id: "0a4d0d38-2f0c-4a49-9bd0-3f7fbb0d0a11",
  status: "requested",
  protocol: "ssh",
  adapter: "ssh",
  ticket: "srra_probe_ticket",
  agent_id: "agent-01",
  device_uid: "sr:1f2e3d4c-5b6a-4c8d-9e0f-a1b2c3d4e5f6",
  target_host: "host01.example.com",
  target_port: 22,
  credential_custody_mode: "ssh_certificate",
  websocket_path: "/v1/remote-access/sessions/0a4d0d38/stream",
}

const UNKNOWN_HOST_KEY_REASON =
  "ssh: handshake failed: ssh host key is not trusted: host01.example.com:22 offered ssh-ed25519 " +
  "SHA256:AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK and the agent known-hosts store has no " +
  "entry for it; review the fingerprint, then reconnect with the trust-on-first-use host key " +
  "policy to pin it"

const UNKNOWN_HOST_KEY = {
  state: "unknown",
  reviewable: true,
  target: "host01.example.com:22",
  algorithm: "ssh-ed25519",
  fingerprint: "SHA256:AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK",
}

const MISMATCHED_HOST_KEY = {
  state: "mismatch",
  reviewable: true,
  target: "host01.example.com:22",
  algorithm: "ssh-rsa",
  fingerprint: "SHA256:ZZZZYYYYXXXXWWWWVVVVUUUUTTTTSSSSRRR",
}

// What an agent older than 1.4.52 produces: verification failed and nothing
// else. No target, no algorithm, no fingerprint to review.
const LEGACY_UNKNOWN_HOST_KEY = {
  state: "unknown",
  reviewable: false,
  target: null,
  algorithm: null,
  fingerprint: null,
}

const LEGACY_MISMATCHED_HOST_KEY = {
  state: "mismatch",
  reviewable: false,
  target: null,
  algorithm: null,
  fingerprint: null,
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
      write() {}
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

// The reported failure (issue 4359): the session opens, the agent refuses the
// target's host key, and the console renders a red "SSH session closed: ssh:
// handshake failed: knownhosts: key is unknown" banner with a dead terminal and
// no way forward. The console must instead present the trust decision.
describe("RemoteAccessSSHConsole host key trust decision", () => {
  let container
  let sockets
  let sessionRequests

  beforeEach(() => {
    container = document.createElement("div")
    document.body.appendChild(container)
    sockets = []
    sessionRequests = []

    vi.stubGlobal(
      "fetch",
      vi.fn(async (url, options) => {
        if (String(url).includes("ssh-options")) {
          return jsonResponse({data: {accounts: [{name: "operator"}]}})
        }
        sessionRequests.push(JSON.parse(options?.body || "{}"))
        return jsonResponse({data: SESSION_DATA}, 201)
      }),
    )

    vi.stubGlobal(
      "WebSocket",
      class {
        static OPEN = 1

        constructor() {
          this.readyState = 1
          this.listeners = new Map()
          sockets.push(this)
        }

        addEventListener(type, handler) {
          this.listeners.set(type, handler)
        }

        emit(type, event) {
          this.listeners.get(type)?.(event)
        }

        send() {}
        close() {}
      },
    )

    vi.stubGlobal(
      "ResizeObserver",
      class {
        observe() {}
        disconnect() {}
      },
    )
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    container.remove()
  })

  async function connect() {
    let root
    await act(async () => {
      root = createRoot(container)
      root.render(
        <Component
          deviceUid="sr:1f2e3d4c-5b6a-4c8d-9e0f-a1b2c3d4e5f6"
          sshOptionsPath="/api/remote-access/devices/sr%3A1f2e3d4c/ssh-options"
          terminalModuleLoader={async () => fakeTerminalModules()}
        />,
      )
      await new Promise((resolve) => setTimeout(resolve, 100))
    })

    const button = [...container.querySelectorAll("button")].find((candidate) =>
      (candidate.textContent || "").includes("Connect with SSO"),
    )

    await act(async () => {
      button.click()
      await new Promise((resolve) => setTimeout(resolve, 200))
    })

    return root
  }

  async function closeWithHostKey(hostKey) {
    await act(async () => {
      sockets.at(-1).emit("message", {
        data: JSON.stringify({type: "close", reason: UNKNOWN_HOST_KEY_REASON, host_key: hostKey}),
      })
      await new Promise((resolve) => setTimeout(resolve, 50))
    })
  }

  function findButton(text) {
    return [...container.querySelectorAll("button")].find((candidate) =>
      (candidate.textContent || "").includes(text),
    )
  }

  it("offers the fingerprint and a trust action when the host key is unknown", async () => {
    const root = await connect()
    expect(sessionRequests.at(-1).ssh_host_key_policy).toBe("known_hosts")

    await closeWithHostKey(UNKNOWN_HOST_KEY)

    const decision = container.querySelector("[data-testid='ssh-host-key-decision']")
    expect(decision).toBeTruthy()
    expect(decision.dataset.hostKeyState).toBe("unknown")
    expect(container.textContent).toContain(UNKNOWN_HOST_KEY.fingerprint)
    expect(container.textContent).toContain(UNKNOWN_HOST_KEY.algorithm)
    expect(container.textContent).toContain(UNKNOWN_HOST_KEY.target)
    expect(findButton("Trust this host key and reconnect")).toBeTruthy()

    await act(async () => {
      root.unmount()
    })
  })

  it("binds the retry to the reviewed target and fingerprint", async () => {
    const root = await connect()

    await closeWithHostKey(UNKNOWN_HOST_KEY)

    await act(async () => {
      findButton("Trust this host key and reconnect").click()
      await new Promise((resolve) => setTimeout(resolve, 200))
    })

    expect(sessionRequests).toHaveLength(2)
    expect(sessionRequests.at(-1).ssh_host_key_policy).toBe("known_hosts")
    expect(sessionRequests.at(-1).metadata.ssh_host_key_approval).toEqual({
      target: UNKNOWN_HOST_KEY.target,
      fingerprint: UNKNOWN_HOST_KEY.fingerprint,
    })
    expect(container.querySelector("[data-testid='ssh-host-key-decision']")).toBeNull()

    await act(async () => {
      root.unmount()
    })
  })

  it("keeps acceptance out of the form after a failed retry", async () => {
    const root = await connect()
    await closeWithHostKey(UNKNOWN_HOST_KEY)
    fetch.mockResolvedValueOnce(jsonResponse({message: "Retry failed"}, 503))

    await act(async () => {
      findButton("Trust this host key and reconnect").click()
      await new Promise((resolve) => setTimeout(resolve, 200))
    })

    expect(container.textContent).toContain("Retry failed")
    await act(async () => {
      findButton("Connect with SSO").click()
      await new Promise((resolve) => setTimeout(resolve, 200))
    })
    expect(sessionRequests.at(-1).ssh_host_key_policy).toBe("known_hosts")
    expect(sessionRequests.at(-1).metadata?.ssh_host_key_approval).toBeUndefined()
    await act(async () => root.unmount())
  })

  // A host that was already trusted and now offers a different key is the
  // man-in-the-middle case. Offering one-click acceptance there would be worse
  // than the hard close this change replaces.
  it("never offers to trust a key that changed under an already-trusted host", async () => {
    const root = await connect()

    await closeWithHostKey(MISMATCHED_HOST_KEY)

    const decision = container.querySelector("[data-testid='ssh-host-key-decision']")
    expect(decision).toBeTruthy()
    expect(decision.dataset.hostKeyState).toBe("mismatch")
    expect(findButton("Trust this host key and reconnect")).toBeFalsy()
    expect(container.textContent).toContain(MISMATCHED_HOST_KEY.fingerprint)
    expect(sessionRequests).toHaveLength(1)

    await act(async () => {
      root.unmount()
    })
  })

  // An agent older than 1.4.52 cannot report the offered key, so the console has
  // no fingerprint to show. Every deployed agent behaved this way when issue
  // 4359 was reported, and the opaque hard close it produced is the whole
  // symptom: the operator must still get a way forward.
  it("offers trust-on-first-use when the agent cannot report the offered key", async () => {
    const root = await connect()

    await closeWithHostKey(LEGACY_UNKNOWN_HOST_KEY)

    const decision = container.querySelector("[data-testid='ssh-host-key-decision']")
    expect(decision).toBeTruthy()
    expect(decision.dataset.hostKeyState).toBe("unknown")
    expect(container.textContent).toContain("cannot report the key the target offered")
    expect(container.textContent).not.toContain("Fingerprint")
    expect(findButton("Trust on first use and reconnect")).toBeTruthy()

    await act(async () => {
      root.unmount()
    })
  })

  // The retry has to ask for a policy the old agent understands. It has no
  // approval field to read, so binding the retry to an approval would fail the
  // same way the first attempt did.
  it("retries an unreviewable acceptance with the trust-on-first-use policy", async () => {
    const root = await connect()

    await closeWithHostKey(LEGACY_UNKNOWN_HOST_KEY)

    await act(async () => {
      findButton("Trust on first use and reconnect").click()
      await new Promise((resolve) => setTimeout(resolve, 200))
    })

    expect(sessionRequests).toHaveLength(2)
    expect(sessionRequests.at(-1).ssh_host_key_policy).toBe("trust_on_first_use")
    expect(sessionRequests.at(-1).metadata?.ssh_host_key_approval).toBeUndefined()
    expect(container.querySelector("[data-testid='ssh-host-key-decision']")).toBeNull()

    await act(async () => {
      root.unmount()
    })
  })

  // Losing the fingerprint does not soften the man-in-the-middle case.
  it("never offers to trust an unreviewable key that changed under a trusted host", async () => {
    const root = await connect()

    await closeWithHostKey(LEGACY_MISMATCHED_HOST_KEY)

    const decision = container.querySelector("[data-testid='ssh-host-key-decision']")
    expect(decision).toBeTruthy()
    expect(decision.dataset.hostKeyState).toBe("mismatch")
    expect(findButton("Trust on first use and reconnect")).toBeFalsy()
    expect(findButton("Trust this host key and reconnect")).toBeFalsy()
    expect(sessionRequests).toHaveLength(1)

    await act(async () => {
      root.unmount()
    })
  })

  it("leaves an ordinary close on the terminal banner", async () => {
    const root = await connect()

    await act(async () => {
      sockets.at(-1).emit("message", {data: JSON.stringify({type: "close", reason: "agent closed"})})
      await new Promise((resolve) => setTimeout(resolve, 50))
    })

    expect(container.querySelector("[data-testid='ssh-host-key-decision']")).toBeNull()
    expect(container.textContent).toContain("SSH session closed: agent closed")

    await act(async () => {
      root.unmount()
    })
  })
})
