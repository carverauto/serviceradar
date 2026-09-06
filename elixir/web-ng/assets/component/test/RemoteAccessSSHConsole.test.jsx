import {describe, expect, it} from "vitest"

import {buildSshAttachCredential, sshCertificatePolicyState} from "../src/RemoteAccessSSHConsole.jsx"

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

describe("RemoteAccessSSHConsole certificate policy readiness", () => {
  const loaded = {credentialMode: "ssh_certificate", optionsLoading: false, optionsLoaded: true, optionsError: ""}

  it("blocks certificate connect when the loaded policy grants no accounts", () => {
    expect(sshCertificatePolicyState({...loaded, accountNames: []})).toEqual({
      status: "unconfigured",
      blocksConnect: true,
    })
  })

  it("allows certificate connect when the policy grants an account", () => {
    expect(sshCertificatePolicyState({...loaded, accountNames: ["mfreeman"]})).toEqual({
      status: "ready",
      blocksConnect: false,
    })
  })

  it("keeps the free-text fallback when policy accounts could not be loaded", () => {
    expect(
      sshCertificatePolicyState({
        credentialMode: "ssh_certificate",
        optionsLoading: false,
        optionsLoaded: false,
        optionsError: "Unable to load SSH options.",
        accountNames: [],
      })
    ).toEqual({status: "unavailable", blocksConnect: false})
  })

  it("does not judge policy before options have been fetched", () => {
    expect(
      sshCertificatePolicyState({
        credentialMode: "ssh_certificate",
        optionsLoading: false,
        optionsLoaded: false,
        optionsError: "",
        accountNames: [],
      })
    ).toEqual({status: "unknown", blocksConnect: false})
  })

  it("reports loading while policy accounts are still being fetched", () => {
    expect(
      sshCertificatePolicyState({
        credentialMode: "ssh_certificate",
        optionsLoading: true,
        optionsLoaded: false,
        optionsError: "",
        accountNames: [],
      })
    ).toEqual({status: "loading", blocksConnect: true})
  })

  it("never blocks the legacy user-present path on certificate policy", () => {
    expect(
      sshCertificatePolicyState({
        credentialMode: "user_present",
        optionsLoading: false,
        optionsLoaded: true,
        optionsError: "",
        accountNames: [],
      })
    ).toEqual({status: "not_applicable", blocksConnect: false})
  })
})
