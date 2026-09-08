import React, {useCallback, useEffect, useMemo, useRef, useState} from "react"

import RemoteAccessTerminal from "./RemoteAccessTerminal.jsx"
import {
  generateEphemeralEd25519Keypair,
  loadPreferredSshUsername,
  pickDefaultUsername,
  savePreferredSshUsername,
  supportsEphemeralEd25519,
} from "./sshEphemeralKeypair.js"

const STORE_PREFIX = "serviceradar.remoteAccess.sshKey.v1."
const FILE_TRANSFER_CHUNK_BYTES = 65_536
const MAX_TRANSFER_EVENTS = 48
const TRUST_ON_FIRST_USE_POLICY = "trust_on_first_use"

// Shown both in the missing-policy warning and as the inline error when the
// blocked certificate connect is clicked. A natively disabled button fires no
// events, so without this shared explanation a target outside the deployment's
// certificate policy looks like a dead control (sr-4358). Keep the two in sync.
export const MISSING_SSH_CERTIFICATE_POLICY_RECOURSE =
  "SSO certificate access stays unavailable until an operator grants this device a " +
  "certificate-policy account. Choose \u201cUser-present key (legacy)\u201d under Advanced " +
  "if you already hold a key for this host."
export const MISSING_SSH_CERTIFICATE_POLICY_MESSAGE =
  `This target has no SSH certificate policy. ${MISSING_SSH_CERTIFICATE_POLICY_RECOURSE}`

function csrfToken() {
  return document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
}

function storageKey(deviceUid) {
  return `${STORE_PREFIX}${deviceUid || "default"}`
}

function normalizeKey(value) {
  return value.replace(/\r\n/g, "\n").trim()
}

export function buildSshAttachCredential({
  credentialMode,
  username,
  privateKey,
  passphrase,
  publicKey,
}) {
  const credential = {
    username: username.trim(),
    private_key: normalizeKey(privateKey),
    passphrase: passphrase.trim(),
  }

  if (credentialMode === "ssh_certificate") {
    credential.public_key = normalizeKey(publicKey)
  }

  return credential
}

// Certificate sessions are refused by the control plane unless the deployment's
// SSH certificate policy grants this target at least one account, so a policy we
// successfully loaded with zero accounts is a hard block, not a missing default.
// Distinguishing it from "policy could not be loaded" matters: the latter still
// permits a typed account, the former can only ever fail at connect time.
export function sshCertificatePolicyState({
  credentialMode = "",
  optionsLoading = false,
  optionsLoaded = false,
  optionsError = "",
  accountNames = [],
} = {}) {
  if (credentialMode !== "ssh_certificate") {
    return {status: "not_applicable", blocksConnect: false}
  }

  if (optionsLoading) {
    return {status: "loading", blocksConnect: true}
  }

  if (optionsError) {
    return {status: "unavailable", blocksConnect: false}
  }

  if (!optionsLoaded) {
    return {status: "unknown", blocksConnect: false}
  }

  if (accountNames.length === 0) {
    return {status: "unconfigured", blocksConnect: true}
  }

  return {status: "ready", blocksConnect: false}
}

function base64Digest(buffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ""

  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }

  return btoa(binary).replace(/=+$/u, "")
}

async function keyDigestFor(value) {
  const normalized = normalizeKey(value)

  if (!normalized || !window.crypto?.subtle) {
    return ""
  }

  const digest = await window.crypto.subtle.digest("SHA-256", new TextEncoder().encode(normalized))
  return `SHA256:${base64Digest(digest)}`
}

const rememberedKeys = new Map()

// Older builds persisted remembered keys in localStorage. Purge that entry
// whenever remembered state is touched so a previously stored key does not
// linger after upgrading.
function clearLegacyRemembered(deviceUid) {
  try {
    window.localStorage?.removeItem(storageKey(deviceUid))
  } catch (_error) {
    // Ignore storage failures.
  }
}

function loadRemembered(deviceUid) {
  clearLegacyRemembered(deviceUid)

  return rememberedKeys.get(deviceUid) || null
}

function saveRemembered(deviceUid, value) {
  rememberedKeys.set(deviceUid, value)
}

function clearRemembered(deviceUid) {
  clearLegacyRemembered(deviceUid)
  rememberedKeys.delete(deviceUid)
}

function errorMessage(error) {
  if (typeof error?.message === "string" && error.message !== "") {
    return error.message
  }

  return "Unable to open SSH session."
}

function apiError(payload, fallback) {
  const error = new Error(payload?.message || payload?.error || fallback)
  error.code = payload?.error || ""
  return error
}

function joinPath(basePath, name) {
  const base = basePath || "/"

  if (!name) {
    return base
  }

  return base.endsWith("/") ? `${base}${name}` : `${base}/${name}`
}

function parentPath(path) {
  const normalized = path && path.startsWith("/") ? path : "/"
  const trimmed = normalized.replace(/\/+$/u, "")
  const index = trimmed.lastIndexOf("/")

  if (index <= 0) {
    return "/"
  }

  return trimmed.slice(0, index)
}

function baseName(path) {
  const normalized = path || ""
  const parts = normalized.split("/").filter(Boolean)
  return parts.at(-1) || "download"
}

// File-transfer start guards: the browser file picker is the only local-file
// source for uploads, so a transfer must never start without a selected,
// non-empty file. The remote target must be a concrete file path: bare
// filesystem root ("/") is never a valid upload/download target from this UI.
// All operations here are single-path SFTP actions (list/stat/download/upload
// of one path); no control in this panel copies directories recursively, so a
// root-to-root copy cannot be started from it.
export function isFilesystemRoot(path) {
  return /^\/+$/.test((path || "").trim())
}

export function atBrowseRoot(path) {
  return (path || "").trim() === "" || isFilesystemRoot(path)
}

export function resolveUploadPath({destination, remotePath, fileName}) {
  const resolvedDestination = (destination || "").trim() || (remotePath || "") || "/"
  const base = remotePath || "/"

  if (resolvedDestination.endsWith("/") || resolvedDestination === base) {
    return joinPath(resolvedDestination, fileName)
  }

  return resolvedDestination
}

export function validateUploadStart({file, destination, remotePath}) {
  if (!file) {
    return {ok: false, error: "Select a local file before starting an upload."}
  }

  const fileName = file.name || "selected file"

  if (file.size === 0) {
    return {ok: false, error: `Refusing to upload "${fileName}": the selected file is empty.`}
  }

  const path = resolveUploadPath({destination, remotePath, fileName: file.name})

  if (!path || path.trim() === "") {
    return {ok: false, error: "Upload path is required: enter a remote destination file path."}
  }

  if (isFilesystemRoot(path)) {
    return {
      ok: false,
      error: `Refusing to upload "${fileName}" to filesystem root "/": choose a destination file path inside a directory.`,
    }
  }

  return {ok: true, path}
}

export function validateDownloadStart({path, displayName}) {
  const name = displayName || path || "selected entry"

  if (!path || path.trim() === "") {
    return {ok: false, error: `Refusing to download "${name}": a file path is required.`}
  }

  if (isFilesystemRoot(path)) {
    return {
      ok: false,
      error: `Refusing to download filesystem root "/": pick a single file from the listing.`,
    }
  }

  return {ok: true, path}
}

function formatBytes(value) {
  const bytes = Number(value || 0)

  if (bytes < 1024) {
    return `${bytes} B`
  }

  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KiB`
  }

  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`
}

function bytesFromBase64(value) {
  const binary = atob(value || "")
  return Uint8Array.from(binary, (char) => char.charCodeAt(0))
}

function bytesToBase64(bytes) {
  let binary = ""

  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }

  return btoa(binary)
}

const UNREPORTED_HOST_KEY =
  "This agent is older than 1.4.52 and cannot report the key the target offered, so there is nothing to compare here."

const CHANGED_HOST_KEY =
  "The target offered a different key than the one the agent already trusts. This can mean the host was rebuilt or " +
  "rekeyed, or that the connection is being intercepted."

const UNENROLLED_HOST_KEY = "The agent has no known-hosts entry for this target, so the SSH session was refused."

// The wording an operator reads is the whole recovery, so it lives in one place
// rather than inline in the panel. `reviewable` says whether the agent reported
// the offered key: an agent older than 1.4.52 reports only that verification
// failed, so there is no fingerprint to compare and accepting is
// trust-on-first-use rather than reviewed acceptance.
function hostKeyCopy(decision, enrollable, reviewable) {
  if (enrollable) {
    return {
      explanation: reviewable
        ? `${UNENROLLED_HOST_KEY} Compare the fingerprint below with the target's own host key before you accept it.`
        : `${UNENROLLED_HOST_KEY} ${UNREPORTED_HOST_KEY} Accepting pins whatever key the target offers on the next connection.`,
      acceptLabel: reviewable ? "Trust this host key and reconnect" : "Trust on first use and reconnect",
      footnote: reviewable
        ? `Accepting pins this key in the agent's known-hosts store for ${decision.target}. A later connection that offers a different key is refused.`
        : "Accepting reconnects with the trust-on-first-use host key policy, which pins the key the target offers into the agent's known-hosts store. A later connection that offers a different key is refused. Upgrade the agent to 1.4.52 or newer to review the fingerprint before pinning it.",
    }
  }

  const verify = reviewable ? "Verify the new key" : `${UNREPORTED_HOST_KEY} Verify the change`

  return {
    explanation: `${CHANGED_HOST_KEY} ${verify} out of band and remove the stale entry from the agent's known-hosts store before connecting again.`,
    acceptLabel: null,
    footnote: null,
  }
}

// Only an unknown key is offerable: a key that changed under an already-trusted
// host is the man-in-the-middle case and gets no accept action here.
export function HostKeyDecision({decision, busy, onTrust, onDismiss}) {
  const enrollable = decision.state === "unknown"
  const reviewable = decision.reviewable !== false
  const facts = [
    ["Target", decision.target],
    ["Key type", decision.algorithm],
    ["Fingerprint", decision.fingerprint],
  ].filter(([, value]) => Boolean(value))
  const {explanation, acceptLabel, footnote} = hostKeyCopy(decision, enrollable, reviewable)

  return (
    <div className="flex h-full min-h-0 items-start justify-center overflow-y-auto bg-sr-canvas p-6 text-sr-ink">
      <div
        className={`w-full max-w-2xl rounded-lg border p-5 ${
          enrollable ? "border-amber-500/50 bg-amber-950/30" : "border-red-500/60 bg-red-950/40"
        }`}
        data-testid="ssh-host-key-decision"
        data-host-key-state={decision.state}
      >
        <h2 className="text-base font-semibold">
          {enrollable ? "This host key is not trusted yet" : "This host key does not match the trusted key"}
        </h2>

        <p className="mt-2 text-sm text-sr-muted">{explanation}</p>

        {facts.length > 0 ? (
          <dl className="mt-4 space-y-2 text-sm">
            {facts.map(([label, value]) => (
              <div className="flex gap-3" key={label}>
                <dt className="w-28 shrink-0 text-sr-muted">{label}</dt>
                <dd className="min-w-0 break-all font-mono">{value}</dd>
              </div>
            ))}
          </dl>
        ) : null}

        <div className="mt-5 flex flex-wrap gap-3">
          {enrollable ? (
            <button
              className="rounded-md bg-amber-500 px-3 py-2 text-sm font-medium text-amber-950 hover:bg-amber-400 disabled:opacity-60"
              type="button"
              onClick={onTrust}
              disabled={busy}
            >
              {busy ? "Reconnecting..." : acceptLabel}
            </button>
          ) : null}
          <button
            className="rounded-md border border-sr-line-strong px-3 py-2 text-sm font-medium text-sr-ink hover:bg-sr-subtle"
            type="button"
            onClick={onDismiss}
          >
            Back to connection settings
          </button>
        </div>

        {enrollable ? <p className="mt-4 text-xs text-sr-muted">{footnote}</p> : null}
      </div>
    </div>
  )
}

export function Component({
  deviceUid = "",
  createPath = "/api/remote-access/sessions",
  fileTransferPath = "/api/remote-access/file-transfers",
  sshOptionsPath = "",
  approvalId = "",
  title = "SSH remote access",
  allowRememberedKeys = false,
  allowSkipVerifyHostKeyPolicy = false,
  allowTargetHostOverride = false,
  allowTargetPortOverride = false,
  terminalModuleLoader = null,
}) {
  const [mode, setMode] = useState("paste")
  // SSO certificate is the enterprise default (Teleport-style). Legacy key paste is opt-in.
  const [credentialMode, setCredentialMode] = useState("ssh_certificate")
  const [username, setUsername] = useState(() => loadPreferredSshUsername())
  const [accounts, setAccounts] = useState([])
  const [optionsLoading, setOptionsLoading] = useState(true)
  const [optionsLoaded, setOptionsLoaded] = useState(false)
  const [optionsError, setOptionsError] = useState("")
  const [targetHost, setTargetHost] = useState("")
  const [targetPort, setTargetPort] = useState("22")
  const [hostKeyPolicy, setHostKeyPolicy] = useState("known_hosts")
  const [privateKey, setPrivateKey] = useState("")
  const [publicKey, setPublicKey] = useState("")
  const [passphrase, setPassphrase] = useState("")
  const [rememberKey, setRememberKey] = useState(false)
  const [rememberUsername, setRememberUsername] = useState(true)
  const [keyDigest, setKeyDigest] = useState("")
  const [showAdvanced, setShowAdvanced] = useState(false)
  const [session, setSession] = useState(null)
  const [credential, setCredential] = useState(null)
  const [hostKeyFailure, setHostKeyFailure] = useState(null)
  const [error, setError] = useState("")
  const [opening, setOpening] = useState(false)
  const [accessApprovalId, setAccessApprovalId] = useState(approvalId)
  const [approvalRequired, setApprovalRequired] = useState(false)
  const [remotePath, setRemotePath] = useState("/")
  const [entries, setEntries] = useState([])
  const [fileTransferError, setFileTransferError] = useState("")
  const [fileTransferBusy, setFileTransferBusy] = useState(false)
  const [uploadDestination, setUploadDestination] = useState("/")
  const [transferEvents, setTransferEvents] = useState([])
  const transferGenerationRef = useRef(0)
  const transferGeneration = transferGenerationRef.current
  const socketControlRef = useRef(null)
  const pendingUploadsRef = useRef(new Map())
  const startedUploadsRef = useRef(new Set())
  const downloadBuffersRef = useRef(new Map())
  const ephemeralSupported = supportsEphemeralEd25519()

  const resolvedOptionsPath = useMemo(() => {
    if (sshOptionsPath) {
      return sshOptionsPath
    }
    if (!deviceUid) {
      return ""
    }
    return `/api/remote-access/devices/${encodeURIComponent(deviceUid)}/ssh-options`
  }, [deviceUid, sshOptionsPath])

  useEffect(() => {
    let cancelled = false

    async function loadOptions() {
      if (!resolvedOptionsPath) {
        setOptionsLoading(false)
        return
      }

      setOptionsLoading(true)
      setOptionsLoaded(false)
      setOptionsError("")

      try {
        const response = await fetch(resolvedOptionsPath, {
          credentials: "same-origin",
          headers: {"x-csrf-token": csrfToken()},
        })
        const payload = await response.json().catch(() => ({}))

        if (!response.ok) {
          throw new Error(payload?.message || payload?.error || "Unable to load SSH options.")
        }

        if (cancelled) {
          return
        }

        const nextAccounts = Array.isArray(payload?.data?.accounts)
          ? payload.data.accounts
          : Array.isArray(payload?.accounts)
            ? payload.accounts
            : []
        setAccounts(nextAccounts)
        setOptionsLoaded(true)
        setUsername((current) => pickDefaultUsername(nextAccounts, current || loadPreferredSshUsername()))
      } catch (loadError) {
        if (!cancelled) {
          setOptionsError(errorMessage(loadError))
        }
      } finally {
        if (!cancelled) {
          setOptionsLoading(false)
        }
      }
    }

    loadOptions()
    return () => {
      cancelled = true
    }
  }, [resolvedOptionsPath])

  // Purge keys persisted by older builds on every mount, even when the
  // operator never enters legacy key mode in this tab.
  useEffect(() => {
    clearLegacyRemembered(deviceUid)
  }, [deviceUid])

  useEffect(() => {
    if (!allowRememberedKeys) {
      clearRemembered(deviceUid)
      setRememberKey(false)
      return
    }

    if (credentialMode !== "user_present") {
      setRememberKey(false)
      return
    }

    const remembered = loadRemembered(deviceUid)

    if (remembered) {
      setUsername(remembered.username || loadPreferredSshUsername())
      setPrivateKey(remembered.privateKey || "")
      setRememberKey(Boolean(remembered.privateKey))
    }
  }, [allowRememberedKeys, credentialMode, deviceUid])

  useEffect(() => {
    let cancelled = false

    keyDigestFor(privateKey).then((value) => {
      if (!cancelled) {
        setKeyDigest(value)
      }
    })

    return () => {
      cancelled = true
    }
  }, [privateKey])

  useEffect(() => {
    if (!allowSkipVerifyHostKeyPolicy && hostKeyPolicy === "skip_verify") {
      setHostKeyPolicy("known_hosts")
    }
  }, [allowSkipVerifyHostKeyPolicy, hostKeyPolicy])

  useEffect(() => {
    if (!allowTargetHostOverride && targetHost) {
      setTargetHost("")
    }
  }, [allowTargetHostOverride, targetHost])

  useEffect(() => {
    if (!allowTargetPortOverride && targetPort !== "22") {
      setTargetPort("22")
    }
  }, [allowTargetPortOverride, targetPort])

  useEffect(() => {
    setAccessApprovalId(approvalId)
  }, [approvalId])

  useEffect(() => {
    setUploadDestination(remotePath)
  }, [remotePath])

  const attachPayload = useMemo(() => {
    if (!credential) {
      return null
    }

    return {credential}
  }, [credential])

  // Identity must be stable: RemoteAccessTerminal lists this in the effect that
  // owns the websocket, so a new function each render would tear the socket
  // down and reattach it.
  const handleHostKeyFailure = useCallback((decision) => {
    setHostKeyFailure(decision)
  }, [])

  const disconnectSession = useCallback(() => {
    if (!session?.id || transferGeneration !== transferGenerationRef.current) {
      return
    }

    transferGenerationRef.current += 1
    pendingUploadsRef.current.clear()
    startedUploadsRef.current.clear()
    downloadBuffersRef.current.clear()
    setRemotePath("/")
    setUploadDestination("/")
    setEntries([])
    setFileTransferError("")
    setFileTransferBusy(false)
    setTransferEvents([])
    setSession(null)
    setCredential(null)

    void fetch(`${createPath}/${session.id}/close`, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "content-type": "application/json",
        "x-csrf-token": csrfToken(),
      },
      body: JSON.stringify({reason: "operator_requested"}),
    }).catch(() => null)
  }, [createPath, session, transferGeneration])

  // Rules-of-hooks: every hook must run on every render, including the
  // post-201 session branch below, which early-returns. A memo placed after
  // that return silently drops a hook on session renders and unmounts the
  // whole console (dev: "rendered fewer hooks", prod: minified error #300).
  const accountNames = useMemo(
    () =>
      accounts
        .map((account) => (typeof account === "string" ? account : account?.name))
        .filter((name) => typeof name === "string" && name.trim() !== "")
        .map((name) => name.trim()),
    [accounts]
  )

  const certificatePolicy = useMemo(
    () =>
      sshCertificatePolicyState({
        credentialMode,
        optionsLoading,
        optionsLoaded,
        optionsError,
        accountNames,
      }),
    [credentialMode, optionsLoading, optionsLoaded, optionsError, accountNames]
  )

  async function handleFile(event) {
    const file = event.target.files?.[0]

    if (!file) {
      return
    }

    setPrivateKey(await file.text())
  }

  const addTransferEvent = useCallback((event) => {
    setTransferEvents((current) => [{at: new Date().toISOString(), ...event}, ...current].slice(0, MAX_TRANSFER_EVENTS))
  }, [])

  const createFileTransfer = useCallback(
    async (operation, path, extra = {}) => {
      if (!session?.id) {
        throw new Error("SSH session is not active.")
      }

      if (typeof path !== "string" || path.trim() === "") {
        throw new Error("Remote path is required: no file transfer was started.")
      }

      const response = await fetch(fileTransferPath, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": csrfToken(),
        },
        body: JSON.stringify({
          session_id: session.id,
          operation,
          path,
          ...extra,
        }),
      })
      const payload = await response.json()

      if (!response.ok) {
        throw apiError(payload, "Remote file transfer failed.")
      }

      return payload.data
    },
    [fileTransferPath, session],
  )

  const streamUpload = useCallback(
    async (transferId, upload) => {
      const control = socketControlRef.current

      if (!control) {
        throw new Error("SSH websocket is not ready.")
      }

      let sequence = 1
      let offset = 0

      while (offset < upload.file.size) {
        const nextOffset = Math.min(offset + FILE_TRANSFER_CHUNK_BYTES, upload.file.size)
        const bytes = new Uint8Array(await upload.file.slice(offset, nextOffset).arrayBuffer())
        if (transferGeneration !== transferGenerationRef.current) {
          return
        }

        const sent = control.sendFileTransferData({
          transfer_id: transferId,
          sequence,
          offset,
          data: bytesToBase64(bytes),
          eof: false,
        })

        if (!sent) {
          throw new Error("SSH websocket is closed.")
        }

        sequence += 1
        offset = nextOffset
      }

      if (transferGeneration !== transferGenerationRef.current) {
        return
      }

      const sent = control.sendFileTransferData({
        transfer_id: transferId,
        sequence,
        offset,
        data: "",
        eof: true,
      })

      if (!sent) {
        throw new Error("SSH websocket is closed.")
      }

      addTransferEvent({transferId, status: "uploaded", path: upload.path})
    },
    [addTransferEvent, transferGeneration],
  )

  const handleFileTransferMessage = useCallback(
    (message) => {
      if (transferGeneration !== transferGenerationRef.current) {
        return
      }

      const payload = message.payload || {}
      const transferId = payload.transfer_id || ""

      if (message.frame_type === "file_transfer_progress") {
        addTransferEvent({transferId, status: payload.status || "progress"})

        const upload = pendingUploadsRef.current.get(transferId)
        if (upload && !upload.started && payload.status === "started") {
          upload.started = true
          streamUpload(transferId, upload).catch((uploadError) => {
            if (transferGeneration !== transferGenerationRef.current) {
              return
            }

            pendingUploadsRef.current.delete(transferId)
            setFileTransferError(errorMessage(uploadError))
            addTransferEvent({transferId, status: "failed", path: upload.path})
          })
        } else if (!upload && payload.status === "started") {
          startedUploadsRef.current.add(transferId)
        }

        return
      }

      if (message.frame_type === "file_transfer_data") {
        const download = downloadBuffersRef.current.get(transferId)
        if (!download) {
          return
        }

        if (payload.data) {
          download.chunks.push(bytesFromBase64(payload.data))
        }

        if (payload.eof) {
          downloadBuffersRef.current.delete(transferId)
          const url = URL.createObjectURL(new Blob(download.chunks))
          const link = document.createElement("a")
          link.href = url
          link.download = download.name
          document.body.appendChild(link)
          link.click()
          link.remove()
          window.setTimeout(() => URL.revokeObjectURL(url), 1000)
          addTransferEvent({transferId, status: "downloaded", path: download.path})
        }

        return
      }

      if (message.frame_type === "file_transfer_outcome") {
        pendingUploadsRef.current.delete(transferId)
        setFileTransferBusy(false)
        addTransferEvent({transferId, status: payload.status || "completed"})

        if (Array.isArray(payload.entries)) {
          setEntries(payload.entries)
        }

        return
      }

      if (message.frame_type === "file_transfer_error") {
        pendingUploadsRef.current.delete(transferId)
        downloadBuffersRef.current.delete(transferId)
        setFileTransferBusy(false)
        setFileTransferError(payload.message || "Remote file transfer failed.")
        addTransferEvent({transferId, status: payload.status || "failed"})
      }
    },
    [addTransferEvent, streamUpload, transferGeneration],
  )

  async function listDirectory(path = remotePath) {
    const nextPath = path.trim() || "/"
    setFileTransferBusy(true)
    setFileTransferError("")
    setRemotePath(nextPath)

    try {
      const transfer = await createFileTransfer("list", nextPath)
      if (transferGeneration !== transferGenerationRef.current) {
        return
      }

      addTransferEvent({transferId: transfer.id, status: "requested", path: nextPath})
    } catch (listError) {
      if (transferGeneration !== transferGenerationRef.current) {
        return
      }

      setFileTransferBusy(false)
      setFileTransferError(errorMessage(listError))
    }
  }

  async function downloadEntry(entry) {
    const path = entry.path || joinPath(remotePath, entry.name)
    const validation = validateDownloadStart({path, displayName: entry.name || baseName(path)})

    if (!validation.ok) {
      setFileTransferError(validation.error)
      return
    }

    setFileTransferError("")

    try {
      const transfer = await createFileTransfer("download", path, {display_name: entry.name || baseName(path)})
      if (transferGeneration !== transferGenerationRef.current) {
        return
      }

      downloadBuffersRef.current.set(transfer.id, {
        chunks: [],
        name: entry.name || baseName(path),
        path,
      })
      addTransferEvent({transferId: transfer.id, status: "requested", path})
    } catch (downloadError) {
      if (transferGeneration !== transferGenerationRef.current) {
        return
      }

      setFileTransferError(errorMessage(downloadError))
    }
  }

  async function uploadFile(event) {
    const file = event.target.files?.[0]
    event.target.value = ""

    const validation = validateUploadStart({file, destination: uploadDestination, remotePath})

    if (!validation.ok) {
      setFileTransferError(validation.error)
      addTransferEvent({transferId: "", status: "refused", path: file?.name || ""})
      return
    }

    const path = validation.path
    setFileTransferError("")

    try {
      const transfer = await createFileTransfer("upload", path, {display_name: file.name})
      if (transferGeneration !== transferGenerationRef.current) {
        return
      }

      const upload = {file, path, started: false}
      pendingUploadsRef.current.set(transfer.id, upload)
      addTransferEvent({transferId: transfer.id, status: "requested", path})

      if (startedUploadsRef.current.delete(transfer.id)) {
        upload.started = true
        streamUpload(transfer.id, upload).catch((uploadError) => {
          if (transferGeneration !== transferGenerationRef.current) {
            return
          }

          pendingUploadsRef.current.delete(transfer.id)
          setFileTransferError(errorMessage(uploadError))
          addTransferEvent({transferId: transfer.id, status: "failed", path})
        })
      }
    } catch (uploadError) {
      if (transferGeneration !== transferGenerationRef.current) {
        return
      }

      setFileTransferError(errorMessage(uploadError))
    }
  }

  async function openSession(event, overrides = {}) {
    event?.preventDefault?.()
    setOpening(true)
    setError("")
    setApprovalRequired(false)
    setHostKeyFailure(null)

    // Fail fast without any network or keygen work: the control plane refuses
    // certificate sessions for a target with no policy accounts, so submitting
    // here must explain rather than attempt.
    if (certificatePolicy.status === "unconfigured") {
      setOpening(false)
      setError(MISSING_SSH_CERTIFICATE_POLICY_MESSAGE)
      return
    }

    // A reviewed acceptance rides on the pinned known-hosts policy: the agent
    // pins the approved target and fingerprint and refuses anything else. An
    // agent older than 1.4.52 has no approval field to read, so an acceptance
    // it cannot review has to ask for the trust-on-first-use policy instead, a
    // policy the agent has honored since known-hosts verification was added.
    const requestedHostKeyPolicy = overrides.approvedHostKey
      ? "known_hosts"
      : overrides.trustOnFirstUse
        ? TRUST_ON_FIRST_USE_POLICY
        : hostKeyPolicy

    const sshUsername = username.trim()

    if (!sshUsername) {
      setOpening(false)
      setError("SSH username is required. Pick an account allowed by certificate policy.")
      return
    }

    let key = normalizeKey(privateKey)
    let publicKeyValue = normalizeKey(publicKey)

    // Teleport-style: for SSO certificates, generate an ephemeral browser keypair.
    // The control plane signs the public key; the private key never leaves browser memory.
    if (credentialMode === "ssh_certificate") {
      if (!ephemeralSupported) {
        setOpening(false)
        setError(
          "This browser cannot generate ephemeral session keys. Use a current Chrome/Firefox/Edge, or switch to legacy user-present key mode."
        )
        return
      }

      try {
        const ephemeral = await generateEphemeralEd25519Keypair(
          `serviceradar-session:${deviceUid || "device"}`
        )
        key = normalizeKey(ephemeral.privateKeyPem)
        publicKeyValue = normalizeKey(ephemeral.publicKeyOpenSSH)
        setPrivateKey("")
        setPublicKey("")
        setKeyDigest("")
      } catch (keyError) {
        setOpening(false)
        setError(errorMessage(keyError))
        return
      }
    } else if (!key) {
      setOpening(false)
      setError("Private key is required for user-present key mode.")
      return
    }

    const body = {
      device_uid: deviceUid,
      protocol: "ssh",
      adapter: "ssh",
      credential_custody_mode: credentialMode,
      ssh_host_key_policy: requestedHostKeyPolicy,
      terminal: {cols: 120, rows: 34},
    }

    if (overrides.approvedHostKey) {
      body.metadata = {ssh_host_key_approval: overrides.approvedHostKey}
    }

    if (targetHost.trim()) {
      body.target_host = targetHost.trim()
    }

    if (allowTargetPortOverride && targetPort.trim()) {
      const parsedTargetPort = Number.parseInt(targetPort, 10)

      if (!Number.isInteger(parsedTargetPort) || parsedTargetPort < 1 || parsedTargetPort > 65535) {
        setOpening(false)
        setError("Target port must be between 1 and 65535.")
        return
      }

      body.target_port = parsedTargetPort
    }

    if (accessApprovalId.trim()) {
      body.approval_id = accessApprovalId.trim()
    }

    try {
      const response = await fetch(createPath, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": csrfToken(),
        },
        body: JSON.stringify(body),
      })

      const payload = await response.json()

      if (!response.ok) {
        throw apiError(payload, "Unable to open SSH session.")
      }

      if (allowRememberedKeys && rememberKey && credentialMode === "user_present") {
        saveRemembered(deviceUid, {username: sshUsername, privateKey: key})
      } else {
        clearRemembered(deviceUid)
      }

      if (rememberUsername) {
        savePreferredSshUsername(sshUsername)
      }

      const nextCredential = buildSshAttachCredential({
        credentialMode,
        username: sshUsername,
        privateKey: key,
        passphrase: credentialMode === "ssh_certificate" ? "" : passphrase,
        publicKey: publicKeyValue,
      })

      setCredential(nextCredential)
      setSession(payload.data)
    } catch (openError) {
      if (
        openError?.code === "approval_required" ||
        openError?.code === "approval_pending" ||
        openError?.code === "approval_checker_required"
      ) {
        setApprovalRequired(true)
      }

      setError(errorMessage(openError))
    } finally {
      setOpening(false)
    }
  }

  function dismissHostKeyFailure() {
    setHostKeyFailure(null)
    setSession(null)
    setCredential(null)
  }

  async function trustHostKeyAndReconnect() {
    setSession(null)
    setCredential(null)

    if (hostKeyFailure.reviewable === false) {
      await openSession(null, {trustOnFirstUse: true})
      return
    }

    await openSession(null, {
      approvedHostKey: {target: hostKeyFailure.target, fingerprint: hostKeyFailure.fingerprint},
    })
  }

  // A host-key failure ends the session, so the dead terminal is replaced by
  // the decision it produced.
  if (hostKeyFailure) {
    return (
      <HostKeyDecision
        decision={hostKeyFailure}
        busy={opening}
        onTrust={trustHostKeyAndReconnect}
        onDismiss={dismissHostKeyFailure}
      />
    )
  }

  if (session && credential) {
    return (
      <div className="grid h-full min-h-0 bg-sr-canvas lg:grid-cols-[minmax(0,1fr)_24rem]">
        <div className="min-h-0">
          <RemoteAccessTerminal
            sessionId={session.id}
            ticket={session.ticket}
            websocketPath={session.websocket_path}
            title={title}
            subtitle={`${session.target_host}:${session.target_port} via ${session.agent_id}`}
            streamLabel="SSH"
            closeLabel="SSH session"
            attachPayload={attachPayload}
            terminalModuleLoader={terminalModuleLoader}
            onFileTransferMessage={handleFileTransferMessage}
            onHostKeyFailure={handleHostKeyFailure}
            onDisconnect={disconnectSession}
            socketControlRef={socketControlRef}
          />
        </div>

        <aside className="flex min-h-0 flex-col border-t border-sr-line bg-sr-surface text-sr-ink lg:border-l lg:border-t-0">
          <div className="border-b border-sr-line px-4 py-3">
            <div className="text-sm font-semibold">Files</div>
            <div className="mt-1 truncate text-xs text-sr-muted">{remotePath}</div>
          </div>

          <div className="space-y-3 border-b border-sr-line p-4">
            {/*
              Browse-only controls: both buttons issue a directory listing and
              nothing else. Neither starts a copy in either direction; uploads
              and downloads start only from the file picker and per-file rows
              below. The parent button is disabled at "/" because navigating
              above the filesystem root is a no-op.
            */}
            <div className="join flex w-full">
              <input
                className="input join-item input-bordered input-sm min-w-0 flex-1"
                value={remotePath}
                onChange={(event) => setRemotePath(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter") {
                    event.preventDefault()
                    listDirectory()
                  }
                }}
              />
              <button
                className="btn join-item btn-sm"
                type="button"
                title="Parent directory (browse only, never copies)"
                aria-label="Parent directory"
                onClick={() => listDirectory(parentPath(remotePath))}
                disabled={fileTransferBusy || atBrowseRoot(remotePath)}
              >
                ..
              </button>
              <button
                className="btn join-item btn-sm"
                type="button"
                title="Refresh directory listing (browse only, never copies)"
                aria-label="Refresh directory listing"
                onClick={() => listDirectory()}
                disabled={fileTransferBusy}
              >
                {fileTransferBusy ? <span className="loading loading-spinner loading-xs" /> : "↻"}
              </button>
            </div>

            <label className="form-control">
              <div className="label py-1">
                <span className="label-text">Upload path</span>
              </div>
              <input
                className="input input-bordered input-sm"
                value={uploadDestination}
                onChange={(event) => setUploadDestination(event.target.value)}
              />
            </label>
            <input
              className="file-input file-input-bordered file-input-sm w-full"
              type="file"
              onChange={uploadFile}
            />

            {fileTransferError ? (
              <div className="rounded border border-red-900/60 bg-red-950 px-3 py-2 text-xs text-red-100">
                {fileTransferError}
              </div>
            ) : null}
          </div>

          <div className="min-h-0 flex-1 overflow-auto">
            {entries.length === 0 ? (
              <div className="px-4 py-6 text-sm text-sr-muted">No directory entries loaded.</div>
            ) : (
              <table className="table table-xs table-pin-rows">
                <thead>
                  <tr className="border-sr-line text-sr-muted">
                    <th>Name</th>
                    <th className="text-right">Size</th>
                    <th className="w-16"></th>
                  </tr>
                </thead>
                <tbody>
                  {entries.map((entry) => {
                    const path = entry.path || joinPath(remotePath, entry.name)

                    return (
                      <tr className="border-sr-line" key={`${entry.name}:${path}`}>
                        <td className="max-w-48 truncate">
                          {entry.is_dir ? (
                            <button
                              className="link text-left text-sky-300"
                              type="button"
                              onClick={() => listDirectory(path)}
                            >
                              {entry.name}/
                            </button>
                          ) : (
                            <span title={entry.mode}>{entry.name}</span>
                          )}
                        </td>
                        <td className="whitespace-nowrap text-right text-sr-muted">
                          {entry.is_dir ? "dir" : formatBytes(entry.size)}
                        </td>
                        <td className="text-right">
                          {!entry.is_dir ? (
                            <button
                              className="btn btn-ghost btn-xs"
                              type="button"
                              title="Download"
                              onClick={() => downloadEntry({...entry, path})}
                            >
                              ↓
                            </button>
                          ) : null}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            )}
          </div>

          <div className="max-h-36 overflow-auto border-t border-sr-line p-3">
            <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-sr-muted">Transfers</div>
            {transferEvents.length === 0 ? (
              <div className="text-xs text-sr-muted">No transfers yet.</div>
            ) : (
              <div className="space-y-1">
                {transferEvents.map((event, index) => (
                  <div className="truncate text-xs text-sr-muted" key={`${event.transferId}:${event.at}:${index}`}>
                    <span className="text-sr-muted">{event.status}</span>{" "}
                    <span title={event.path || event.transferId}>{event.path || event.transferId}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        </aside>
      </div>
    )
  }

  return (
    <div className="flex h-full min-h-0 flex-col bg-base-100">
      <div className="border-b border-base-300 px-5 py-4">
        <h2 className="text-sm font-semibold">{title}</h2>
        <p className="text-xs text-base-content/60">{deviceUid}</p>
        <p className="mt-2 max-w-3xl text-xs text-base-content/70">
          Enterprise default: sign in with SSO, open a short-lived certificate session. No private key paste.
          Traffic path: browser → web-ng → agent-gateway → edge agent → target SSH.
        </p>
      </div>

      <form className="grid min-h-0 flex-1 gap-5 overflow-auto p-5 lg:grid-cols-[minmax(0,1fr)_22rem]" onSubmit={openSession}>
        <div className="space-y-4">
          {credentialMode === "ssh_certificate" ? (
            <div className="rounded-box border border-success/30 bg-success/5 p-4 text-sm">
              <div className="font-medium text-success">SSO certificate (default)</div>
              <p className="mt-1 text-xs text-base-content/70">
                This browser will generate a one-session Ed25519 keypair. ServiceRadar signs the public key with
                the remote-access CA after your existing Authentik/OIDC login and RBAC checks. The private key
                stays in memory only for this tab.
              </p>
              {!ephemeralSupported ? (
                <p className="mt-2 text-xs text-error">
                  Ephemeral key generation is unavailable in this browser. Enable a current Chromium/Firefox or
                  use legacy key mode under Advanced.
                </p>
              ) : null}
            </div>
          ) : (
            <div className="rounded-box border border-warning/40 bg-warning/10 p-4 text-sm">
              <div className="font-medium text-warning">Legacy user-present key</div>
              <p className="mt-1 text-xs text-base-content/70">
                Break-glass only. Prefer SSO certificate for production access.
              </p>
            </div>
          )}

          {certificatePolicy.status === "unconfigured" ? (
            <div id="ssh-certificate-policy-warning" className="alert alert-warning text-sm" role="alert">
              <div>
                <p className="font-medium">This target has no SSH certificate policy</p>
                <p className="mt-1 text-xs">{MISSING_SSH_CERTIFICATE_POLICY_RECOURSE}</p>
              </div>
            </div>
          ) : (
            <label className="form-control">
              <div className="label">
                <span className="label-text">Unix account</span>
                {optionsLoading ? <span className="label-text-alt">Loading policy…</span> : null}
              </div>
              {accountNames.length > 0 ? (
                <select
                  className="select select-bordered"
                  value={username}
                  onChange={(event) => setUsername(event.target.value)}
                >
                  {accountNames.map((name) => (
                    <option key={name} value={name}>
                      {name}
                    </option>
                  ))}
                </select>
              ) : (
                <input
                  className="input input-bordered"
                  autoComplete="username"
                  placeholder="mfreeman"
                  value={username}
                  onChange={(event) => setUsername(event.target.value)}
                />
              )}
              <div className="label">
                <span className="label-text-alt text-base-content/60">
                  Must exist on the target (local or FreeIPA/LDAP). Certificate policy controls which accounts you
                  may request.
                </span>
              </div>
            </label>
          )}

          <label className="flex cursor-pointer items-start gap-3 rounded border border-base-300 bg-base-200 p-3">
            <input
              type="checkbox"
              className="checkbox checkbox-sm mt-0.5"
              checked={rememberUsername}
              onChange={(event) => setRememberUsername(event.target.checked)}
            />
            <span className="text-sm">
              <span className="font-medium">Remember preferred account in this browser</span>
              <span className="mt-0.5 block text-xs text-base-content/60">
                Profile-style preference for multi-account policies (Teleport-like default account pick).
              </span>
            </span>
          </label>

          {optionsError ? (
            <div className="alert alert-warning text-xs">
              Policy accounts could not be loaded ({optionsError}). You can still type a username if policy allows
              it.
            </div>
          ) : null}

          {approvalRequired || accessApprovalId ? (
            <label className="form-control">
              <div className="label">
                <span className="label-text">Approval ID</span>
              </div>
              <input
                className="input input-bordered"
                value={accessApprovalId}
                onChange={(event) => setAccessApprovalId(event.target.value)}
              />
            </label>
          ) : null}

          <button
            className="btn btn-ghost btn-sm justify-start px-0"
            type="button"
            onClick={() => setShowAdvanced((value) => !value)}
          >
            {showAdvanced ? "Hide advanced" : "Show advanced / legacy"}
          </button>

          {showAdvanced ? (
            <div className="space-y-4 rounded-box border border-base-300 p-4">
              <label className="form-control">
                <div className="label">
                  <span className="label-text">Credential mode</span>
                </div>
                <select
                  className="select select-bordered"
                  value={credentialMode}
                  onChange={(event) => setCredentialMode(event.target.value)}
                >
                  <option value="ssh_certificate">SSO certificate (default)</option>
                  <option value="user_present">User-present key (legacy)</option>
                </select>
              </label>

              <label className="form-control">
                <div className="label">
                  <span className="label-text">Host key policy</span>
                </div>
                <select
                  className="select select-bordered"
                  value={hostKeyPolicy}
                  onChange={(event) => setHostKeyPolicy(event.target.value)}
                >
                  <option value="known_hosts">Known hosts</option>
                  <option value={TRUST_ON_FIRST_USE_POLICY}>Trust on first use</option>
                  {allowSkipVerifyHostKeyPolicy ? (
                    <option value="skip_verify">Skip verification</option>
                  ) : null}
                </select>
              </label>

              {allowTargetHostOverride ? (
                <label className="form-control">
                  <div className="label">
                    <span className="label-text">Target host override</span>
                  </div>
                  <input
                    className="input input-bordered"
                    placeholder="Use inventory target"
                    value={targetHost}
                    onChange={(event) => setTargetHost(event.target.value)}
                  />
                </label>
              ) : null}

              {allowTargetPortOverride ? (
                <label className="form-control">
                  <div className="label">
                    <span className="label-text">Target port override</span>
                  </div>
                  <input
                    className="input input-bordered"
                    min="1"
                    max="65535"
                    inputMode="numeric"
                    type="number"
                    value={targetPort}
                    onChange={(event) => setTargetPort(event.target.value)}
                  />
                </label>
              ) : null}

              {credentialMode === "user_present" ? (
                <>
                  <div className="join">
                    <button
                      className={`btn join-item btn-sm ${mode === "paste" ? "btn-active" : ""}`}
                      type="button"
                      onClick={() => setMode("paste")}
                    >
                      Paste key
                    </button>
                    <button
                      className={`btn join-item btn-sm ${mode === "upload" ? "btn-active" : ""}`}
                      type="button"
                      onClick={() => setMode("upload")}
                    >
                      Upload key
                    </button>
                  </div>

                  {mode === "upload" ? (
                    <input className="file-input file-input-bordered w-full" type="file" onChange={handleFile} />
                  ) : null}

                  <label className="form-control">
                    <div className="label">
                      <span className="label-text">Private key</span>
                      {keyDigest ? (
                        <span className="label-text-alt font-mono">Key digest {keyDigest}</span>
                      ) : null}
                    </div>
                    <textarea
                      className="textarea textarea-bordered min-h-40 font-mono text-xs"
                      spellCheck="false"
                      value={privateKey}
                      onChange={(event) => setPrivateKey(event.target.value)}
                    />
                  </label>

                  <label className="form-control">
                    <div className="label">
                      <span className="label-text">Passphrase</span>
                    </div>
                    <input
                      className="input input-bordered"
                      type="password"
                      autoComplete="current-password"
                      value={passphrase}
                      onChange={(event) => setPassphrase(event.target.value)}
                    />
                  </label>
                </>
              ) : null}
            </div>
          ) : null}
        </div>

        <div className="space-y-4">
          {allowRememberedKeys && credentialMode === "user_present" ? (
            <div className="rounded border border-base-300 bg-base-200 p-4">
              <label className="flex cursor-pointer items-start gap-3">
                <input
                  type="checkbox"
                  className="checkbox checkbox-sm mt-1"
                  checked={rememberKey}
                  onChange={(event) => setRememberKey(event.target.checked)}
                />
                <span>
                  <span className="block text-sm font-medium">Remember key in memory</span>
                  <span className="block text-xs text-base-content/60">Cleared on page reload or close. Passphrases are never saved.</span>
                </span>
              </label>
            </div>
          ) : null}

          {error ? <div className="alert alert-error text-sm">{error}</div> : null}

          <button
            className="btn btn-primary w-full"
            type="submit"
            disabled={
              opening ||
              optionsLoading ||
              (credentialMode === "ssh_certificate" && !ephemeralSupported)
            }
            aria-describedby={
              certificatePolicy.status === "unconfigured" ? "ssh-certificate-policy-warning" : undefined
            }
          >
            {opening ? <span className="loading loading-spinner loading-sm" /> : null}
            {credentialMode === "ssh_certificate" ? "Connect with SSO certificate" : "Open SSH session"}
          </button>
        </div>
      </form>
    </div>
  )
}

export default Component
