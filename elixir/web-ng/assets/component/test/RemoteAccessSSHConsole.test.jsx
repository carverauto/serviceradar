import {describe, expect, it} from "vitest"

import {buildSshAttachCredential} from "../src/RemoteAccessSSHConsole.jsx"

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
