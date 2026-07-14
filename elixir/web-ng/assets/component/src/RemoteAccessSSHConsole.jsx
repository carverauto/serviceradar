import React, {useCallback, useEffect, useMemo, useRef, useState} from "react"

import RemoteAccessTerminal from "./RemoteAccessTerminal.jsx"

const STORE_PREFIX = "serviceradar.remoteAccess.sshKey.v1."
const FILE_TRANSFER_CHUNK_BYTES = 65_536
const MAX_TRANSFER_EVENTS = 48

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

function loadRemembered(deviceUid) {
  try {
    const raw = window.localStorage.getItem(storageKey(deviceUid))
    return raw ? JSON.parse(raw) : null
  } catch (_error) {
    return null
  }
}

function saveRemembered(deviceUid, value) {
  try {
    window.localStorage.setItem(storageKey(deviceUid), JSON.stringify(value))
  } catch (_error) {
    // Ignore storage failures; the session credential still remains usable in memory.
  }
}

function clearRemembered(deviceUid) {
  try {
    window.localStorage.removeItem(storageKey(deviceUid))
  } catch (_error) {
    // Ignore storage failures.
  }
}

function errorMessage(error) {
  if (error?.message) {
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

export function Component({
  deviceUid = "",
  createPath = "/api/remote-access/sessions",
  fileTransferPath = "/api/remote-access/file-transfers",
  approvalId = "",
  title = "SSH remote access",
  allowRememberedKeys = false,
  allowSkipVerifyHostKeyPolicy = false,
  allowTargetHostOverride = false,
  allowTargetPortOverride = false,
  terminalModuleLoader = null,
}) {
  const [mode, setMode] = useState("paste")
  const [credentialMode, setCredentialMode] = useState("ssh_certificate")
  const [username, setUsername] = useState("")
  const [targetHost, setTargetHost] = useState("")
  const [targetPort, setTargetPort] = useState("22")
  const [hostKeyPolicy, setHostKeyPolicy] = useState("known_hosts")
  const [privateKey, setPrivateKey] = useState("")
  const [publicKey, setPublicKey] = useState("")
  const [passphrase, setPassphrase] = useState("")
  const [rememberKey, setRememberKey] = useState(false)
  const [keyDigest, setKeyDigest] = useState("")
  const [session, setSession] = useState(null)
  const [credential, setCredential] = useState(null)
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
  const socketControlRef = useRef(null)
  const pendingUploadsRef = useRef(new Map())
  const startedUploadsRef = useRef(new Set())
  const downloadBuffersRef = useRef(new Map())

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
      setUsername(remembered.username || "")
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
    [addTransferEvent],
  )

  const handleFileTransferMessage = useCallback(
    (message) => {
      const payload = message.payload || {}
      const transferId = payload.transfer_id || ""

      if (message.frame_type === "file_transfer_progress") {
        addTransferEvent({transferId, status: payload.status || "progress"})

        const upload = pendingUploadsRef.current.get(transferId)
        if (upload && !upload.started && payload.status === "started") {
          upload.started = true
          streamUpload(transferId, upload).catch((uploadError) => {
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
    [addTransferEvent, streamUpload],
  )

  async function listDirectory(path = remotePath) {
    const nextPath = path.trim() || "/"
    setFileTransferBusy(true)
    setFileTransferError("")
    setRemotePath(nextPath)

    try {
      const transfer = await createFileTransfer("list", nextPath)
      addTransferEvent({transferId: transfer.id, status: "requested", path: nextPath})
    } catch (listError) {
      setFileTransferBusy(false)
      setFileTransferError(errorMessage(listError))
    }
  }

  async function downloadEntry(entry) {
    const path = entry.path || joinPath(remotePath, entry.name)
    setFileTransferError("")

    try {
      const transfer = await createFileTransfer("download", path, {display_name: entry.name || baseName(path)})
      downloadBuffersRef.current.set(transfer.id, {
        chunks: [],
        name: entry.name || baseName(path),
        path,
      })
      addTransferEvent({transferId: transfer.id, status: "requested", path})
    } catch (downloadError) {
      setFileTransferError(errorMessage(downloadError))
    }
  }

  async function uploadFile(event) {
    const file = event.target.files?.[0]
    event.target.value = ""

    if (!file) {
      return
    }

    const destination = uploadDestination.trim() || remotePath || "/"
    const path = destination.endsWith("/") || destination === remotePath ? joinPath(destination, file.name) : destination
    setFileTransferError("")

    try {
      const transfer = await createFileTransfer("upload", path, {display_name: file.name})
      const upload = {file, path, started: false}
      pendingUploadsRef.current.set(transfer.id, upload)
      addTransferEvent({transferId: transfer.id, status: "requested", path})

      if (startedUploadsRef.current.delete(transfer.id)) {
        upload.started = true
        streamUpload(transfer.id, upload).catch((uploadError) => {
          pendingUploadsRef.current.delete(transfer.id)
          setFileTransferError(errorMessage(uploadError))
          addTransferEvent({transferId: transfer.id, status: "failed", path})
        })
      }
    } catch (uploadError) {
      setFileTransferError(errorMessage(uploadError))
    }
  }

  async function openSession(event) {
    event.preventDefault()
    setOpening(true)
    setError("")
    setApprovalRequired(false)

    const key = normalizeKey(privateKey)
    const publicKeyValue = normalizeKey(publicKey)
    const sshUsername = username.trim()

    if (!key) {
      setOpening(false)
      setError("Private key is required.")
      return
    }

    if (!sshUsername) {
      setOpening(false)
      setError("SSH username is required.")
      return
    }

    if (credentialMode === "ssh_certificate" && !publicKeyValue) {
      setOpening(false)
      setError("Public key is required for certificate sessions.")
      return
    }

    const body = {
      device_uid: deviceUid,
      protocol: "ssh",
      adapter: "ssh",
      credential_custody_mode: credentialMode,
      ssh_host_key_policy: hostKeyPolicy,
      terminal: {cols: 120, rows: 34},
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

      const nextCredential = buildSshAttachCredential({
        credentialMode,
        username: sshUsername,
        privateKey: key,
        passphrase,
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

  if (session && credential) {
    return (
      <div className="grid h-full min-h-0 bg-slate-950 lg:grid-cols-[minmax(0,1fr)_24rem]">
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
            socketControlRef={socketControlRef}
          />
        </div>

        <aside className="flex min-h-0 flex-col border-t border-slate-800 bg-slate-900 text-slate-100 lg:border-l lg:border-t-0">
          <div className="border-b border-slate-800 px-4 py-3">
            <div className="text-sm font-semibold">Files</div>
            <div className="mt-1 truncate text-xs text-slate-400">{remotePath}</div>
          </div>

          <div className="space-y-3 border-b border-slate-800 p-4">
            <div className="join flex w-full">
              <input
                className="input join-item input-bordered input-sm min-w-0 flex-1 bg-slate-950 text-slate-100"
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
                title="Parent directory"
                onClick={() => listDirectory(parentPath(remotePath))}
                disabled={fileTransferBusy}
              >
                ..
              </button>
              <button
                className="btn join-item btn-sm"
                type="button"
                title="Refresh directory"
                onClick={() => listDirectory()}
                disabled={fileTransferBusy}
              >
                {fileTransferBusy ? <span className="loading loading-spinner loading-xs" /> : "↻"}
              </button>
            </div>

            <label className="form-control">
              <div className="label py-1">
                <span className="label-text text-slate-300">Upload path</span>
              </div>
              <input
                className="input input-bordered input-sm bg-slate-950 text-slate-100"
                value={uploadDestination}
                onChange={(event) => setUploadDestination(event.target.value)}
              />
            </label>
            <input
              className="file-input file-input-bordered file-input-sm w-full bg-slate-950 text-slate-100"
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
              <div className="px-4 py-6 text-sm text-slate-400">No directory entries loaded.</div>
            ) : (
              <table className="table table-xs table-pin-rows">
                <thead>
                  <tr className="border-slate-800 text-slate-400">
                    <th>Name</th>
                    <th className="text-right">Size</th>
                    <th className="w-16"></th>
                  </tr>
                </thead>
                <tbody>
                  {entries.map((entry) => {
                    const path = entry.path || joinPath(remotePath, entry.name)

                    return (
                      <tr className="border-slate-800" key={`${entry.name}:${path}`}>
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
                        <td className="whitespace-nowrap text-right text-slate-400">
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

          <div className="max-h-36 overflow-auto border-t border-slate-800 p-3">
            <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Transfers</div>
            {transferEvents.length === 0 ? (
              <div className="text-xs text-slate-500">No transfers yet.</div>
            ) : (
              <div className="space-y-1">
                {transferEvents.map((event, index) => (
                  <div className="truncate text-xs text-slate-300" key={`${event.transferId}:${event.at}:${index}`}>
                    <span className="text-slate-500">{event.status}</span>{" "}
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
      </div>

      <form className="grid min-h-0 flex-1 gap-5 overflow-auto p-5 lg:grid-cols-[minmax(0,1fr)_22rem]" onSubmit={openSession}>
        <div className="space-y-4">
          <label className="form-control">
            <div className="label">
              <span className="label-text">Credential mode</span>
            </div>
            <select
              className="select select-bordered"
              value={credentialMode}
              onChange={(event) => setCredentialMode(event.target.value)}
            >
              <option value="ssh_certificate">SSO certificate</option>
              <option value="user_present">User-present key</option>
            </select>
          </label>

          <div className="grid gap-3 sm:grid-cols-2">
            <label className="form-control">
              <div className="label">
                <span className="label-text">SSH username</span>
              </div>
              <input
                className="input input-bordered"
                autoComplete="username"
                value={username}
                onChange={(event) => setUsername(event.target.value)}
              />
            </label>

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
          </div>

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
              <option value="trust_on_first_use">Trust on first use</option>
              {allowSkipVerifyHostKeyPolicy ? <option value="skip_verify">Skip verification</option> : null}
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
              {keyDigest ? <span className="label-text-alt font-mono">Key digest {keyDigest}</span> : null}
            </div>
            <textarea
              className="textarea textarea-bordered min-h-52 font-mono text-xs"
              spellCheck="false"
              value={privateKey}
              onChange={(event) => setPrivateKey(event.target.value)}
            />
          </label>

          {credentialMode === "ssh_certificate" ? (
            <label className="form-control">
              <div className="label">
                <span className="label-text">Public key</span>
              </div>
              <textarea
                className="textarea textarea-bordered min-h-24 font-mono text-xs"
                spellCheck="false"
                value={publicKey}
                onChange={(event) => setPublicKey(event.target.value)}
              />
            </label>
          ) : null}

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
                  <span className="block text-sm font-medium">Remember key in this browser</span>
                  <span className="block text-xs text-base-content/60">Passphrases are never saved.</span>
                </span>
              </label>
            </div>
          ) : null}

          {error ? <div className="alert alert-error text-sm">{error}</div> : null}

          <button className="btn btn-primary w-full" type="submit" disabled={opening}>
            {opening ? <span className="loading loading-spinner loading-sm" /> : null}
            Open SSH session
          </button>
        </div>
      </form>
    </div>
  )
}

export default Component
