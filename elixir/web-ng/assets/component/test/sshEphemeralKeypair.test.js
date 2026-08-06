import {beforeEach, describe, expect, it, vi} from "vitest"

import {
  formatOpenSSHEd25519PublicKey,
  generateEphemeralEd25519Keypair,
  loadPreferredSshUsername,
  pickDefaultUsername,
  PREFERRED_SSH_USER_KEY,
  savePreferredSshUsername,
  supportsEphemeralEd25519,
} from "../src/sshEphemeralKeypair.js"

function installMemoryLocalStorage() {
  const store = new Map()
  const memory = {
    getItem(key) {
      return store.has(key) ? store.get(key) : null
    },
    setItem(key, value) {
      store.set(String(key), String(value))
    },
    removeItem(key) {
      store.delete(key)
    },
    clear() {
      store.clear()
    },
  }
  vi.stubGlobal("localStorage", memory)
  return memory
}

describe("sshEphemeralKeypair", () => {
  beforeEach(() => {
    installMemoryLocalStorage()
  })

  it("reports WebCrypto Ed25519 support when subtle crypto is present", () => {
    expect(typeof supportsEphemeralEd25519()).toBe("boolean")
  })

  it("formats OpenSSH ed25519 public keys", () => {
    const raw = new Uint8Array(32)
    raw[0] = 1
    raw[31] = 2
    const line = formatOpenSSHEd25519PublicKey(raw, "serviceradar-ephemeral")
    expect(line.startsWith("ssh-ed25519 ")).toBe(true)
    expect(line.endsWith(" serviceradar-ephemeral")).toBe(true)
  })

  it("picks preferred account when present in policy", () => {
    expect(pickDefaultUsername([{name: "deploy"}, {name: "mfreeman"}], "mfreeman")).toBe(
      "mfreeman"
    )
    expect(pickDefaultUsername(["deploy", "mfreeman"], "nobody")).toBe("deploy")
    expect(pickDefaultUsername([], "mfreeman")).toBe("mfreeman")
  })

  it("persists preferred username in localStorage", () => {
    savePreferredSshUsername("  mfreeman  ")
    expect(loadPreferredSshUsername()).toBe("mfreeman")
    savePreferredSshUsername("")
    expect(loadPreferredSshUsername()).toBe("")
  })

  it("generates a PKCS8 private key PEM and OpenSSH public key when Ed25519 is available", async () => {
    if (!supportsEphemeralEd25519()) {
      return
    }

    const pair = await generateEphemeralEd25519Keypair("serviceradar-session:test")
    expect(pair.algorithm).toBe("Ed25519")
    expect(pair.privateKeyPem).toContain("BEGIN PRIVATE KEY")
    expect(pair.privateKeyPem).toContain("END PRIVATE KEY")
    expect(pair.publicKeyOpenSSH.startsWith("ssh-ed25519 ")).toBe(true)
    expect(pair.publicKeyOpenSSH).toContain("serviceradar-session:test")
  })
})
