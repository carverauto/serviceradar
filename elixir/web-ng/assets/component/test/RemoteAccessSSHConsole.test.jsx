import {describe, expect, it, vi} from "vitest"

import {buildSshAttachCredential} from "../src/RemoteAccessSSHConsole.jsx"
import {renderText} from "../src/renderText.js"

describe("RemoteAccessSSHConsole credential boundary", () => {
  it("sends only the Unix username and key material for certificate sessions", () => {
    const credential = buildSshAttachCredential({
      credentialMode: "ssh_certificate",
      username: "  mfreeman  ",
      privateKey: "  session-private-key  ",
      passphrase: "  session-passphrase  ",
      publicKey: "  ssh-ed25519 AAAATEST user@workstation  ",
    })

    expect(credential).toEqual({
      username: "mfreeman",
      private_key: "session-private-key",
      passphrase: "session-passphrase",
      public_key: "ssh-ed25519 AAAATEST user@workstation",
    })

    for (const policyKey of [
      "accounts",
      "allowed_principals",
      "principal_mappings",
      "principals",
      "requested_principals",
      "ssh_accounts",
    ]) {
      expect(credential).not.toHaveProperty(policyKey)
    }
  })

  it("coerces non-string values for JSX children instead of crashing React", () => {
    expect(renderText("already a string")).toBe("already a string")
    expect(renderText("")).toBe("")
    expect(renderText(null)).toBe("")
    expect(renderText(undefined)).toBe("")
    expect(renderText({message: "broker says no"})).toBe('{"message":"broker says no"}')
    expect(renderText(42)).toBe("42")
  })

  it("warns with the live value when coercing", () => {
    const warn = vi.fn()
    vi.stubGlobal("window", {console: {warn}})

    try {
      renderText({message: "broker says no"})
      expect(warn).toHaveBeenCalledWith("renderText: coerced non-string render value", {
        message: "broker says no",
      })
    } finally {
      vi.unstubAllGlobals()
    }
  })

  it("does not attach a certificate public key in user-present mode", () => {
    expect(buildSshAttachCredential({
      credentialMode: "user_present",
      username: "mfreeman",
      privateKey: "session-private-key",
      passphrase: "",
      publicKey: "ssh-ed25519 AAAATEST",
    })).toEqual({
      username: "mfreeman",
      private_key: "session-private-key",
      passphrase: "",
    })
  })
})
