import {describe, expect, it} from "vitest"

import {
  atBrowseRoot,
  buildSshAttachCredential,
  isFilesystemRoot,
  resolveUploadPath,
  sshCertificatePolicyState,
  validateDownloadStart,
  validateUploadStart,
} from "../src/RemoteAccessSSHConsole.jsx"

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
    expect(sshCertificatePolicyState({...loaded, accountNames: ["opsuser"]})).toEqual({
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

describe("RemoteAccessSSHConsole upload start guards", () => {
  const file = {name: "report.txt", size: 12}

  it("refuses to start when no local file is selected", () => {
    expect(validateUploadStart({file: null, destination: "/tmp", remotePath: "/tmp"})).toEqual({
      ok: false,
      error: "Select a local file before starting an upload.",
    })
    expect(validateUploadStart({file: undefined, destination: "/tmp", remotePath: "/tmp"})).toEqual({
      ok: false,
      error: "Select a local file before starting an upload.",
    })
  })

  it("refuses to send an empty file", () => {
    expect(
      validateUploadStart({file: {name: "empty.txt", size: 0}, destination: "/tmp/", remotePath: "/tmp"})
    ).toEqual({
      ok: false,
      error: 'Refusing to upload "empty.txt": the selected file is empty.',
    })
  })

  it("resolves a directory destination against the selected file name", () => {
    expect(validateUploadStart({file, destination: "/tmp/", remotePath: "/tmp"})).toEqual({
      ok: true,
      path: "/tmp/report.txt",
    })
    expect(validateUploadStart({file, destination: "/tmp", remotePath: "/tmp"})).toEqual({
      ok: true,
      path: "/tmp/report.txt",
    })
    expect(validateUploadStart({file, destination: "  ", remotePath: "/var/log"})).toEqual({
      ok: true,
      path: "/var/log/report.txt",
    })
  })

  it("keeps an explicit destination file path", () => {
    expect(validateUploadStart({file, destination: "/tmp/renamed.txt", remotePath: "/tmp"})).toEqual({
      ok: true,
      path: "/tmp/renamed.txt",
    })
  })

  it("never targets bare filesystem root from this UI", () => {
    expect(
      validateUploadStart({file: {name: "", size: 12}, destination: "/", remotePath: "/"})
    ).toEqual({
      ok: false,
      error:
        'Refusing to upload "selected file" to filesystem root "/": choose a destination file path inside a directory.',
    })
  })

  it("treats a root destination as the directory for the selected file", () => {
    expect(validateUploadStart({file, destination: "/", remotePath: "/"})).toEqual({
      ok: true,
      path: "/report.txt",
    })
  })
})

describe("RemoteAccessSSHConsole download start guards", () => {
  it("refuses a missing path", () => {
    expect(validateDownloadStart({path: "", displayName: "syslog"})).toEqual({
      ok: false,
      error: 'Refusing to download "syslog": a file path is required.',
    })
  })

  it("refuses bare filesystem root", () => {
    expect(validateDownloadStart({path: "/", displayName: "/"})).toEqual({
      ok: false,
      error: 'Refusing to download filesystem root "/": pick a single file from the listing.',
    })
  })

  it("accepts a concrete file path", () => {
    expect(validateDownloadStart({path: "/var/log/syslog", displayName: "syslog"})).toEqual({
      ok: true,
      path: "/var/log/syslog",
    })
  })
})

describe("RemoteAccessSSHConsole root helpers", () => {
  it("treats only slash-only paths as filesystem root", () => {
    expect(isFilesystemRoot("/")).toBe(true)
    expect(isFilesystemRoot("  /// ")).toBe(true)
    expect(isFilesystemRoot("/tmp")).toBe(false)
    expect(isFilesystemRoot("")).toBe(false)
  })

  it("reports the browse root so the parent button can disable itself", () => {
    expect(atBrowseRoot("/")).toBe(true)
    expect(atBrowseRoot("")).toBe(true)
    expect(atBrowseRoot("/var/log")).toBe(false)
  })

  it("resolves an empty destination against the browsed directory", () => {
    expect(resolveUploadPath({destination: "", remotePath: "/var/log", fileName: "a.txt"})).toBe(
      "/var/log/a.txt"
    )
  })
})
