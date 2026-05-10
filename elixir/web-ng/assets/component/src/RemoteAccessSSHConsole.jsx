import React, {useEffect, useMemo, useState} from "react"

import RemoteAccessTerminal from "./RemoteAccessTerminal.jsx"

const STORE_PREFIX = "serviceradar.remoteAccess.sshKey.v1."

function csrfToken() {
  return document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
}

function storageKey(deviceUid) {
  return `${STORE_PREFIX}${deviceUid || "default"}`
}

function normalizeKey(value) {
  return value.replace(/\r\n/g, "\n").trim()
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

export function Component({
  deviceUid = "",
  createPath = "/api/remote-access/sessions",
  title = "SSH remote access",
  allowRememberedKeys = false,
  terminalModuleLoader = null,
}) {
  const [mode, setMode] = useState("paste")
  const [username, setUsername] = useState("")
  const [targetHost, setTargetHost] = useState("")
  const [targetPort, setTargetPort] = useState("22")
  const [hostKeyPolicy, setHostKeyPolicy] = useState("known_hosts")
  const [privateKey, setPrivateKey] = useState("")
  const [passphrase, setPassphrase] = useState("")
  const [rememberKey, setRememberKey] = useState(false)
  const [keyDigest, setKeyDigest] = useState("")
  const [session, setSession] = useState(null)
  const [credential, setCredential] = useState(null)
  const [error, setError] = useState("")
  const [opening, setOpening] = useState(false)

  useEffect(() => {
    if (!allowRememberedKeys) {
      clearRemembered(deviceUid)
      setRememberKey(false)
      return
    }

    const remembered = loadRemembered(deviceUid)

    if (remembered) {
      setUsername(remembered.username || "")
      setPrivateKey(remembered.privateKey || "")
      setRememberKey(Boolean(remembered.privateKey))
    }
  }, [allowRememberedKeys, deviceUid])

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

  async function openSession(event) {
    event.preventDefault()
    setOpening(true)
    setError("")

    const key = normalizeKey(privateKey)
    const sshUsername = username.trim()

    if (!sshUsername || !key) {
      setOpening(false)
      setError("Username and private key are required.")
      return
    }

    const body = {
      device_uid: deviceUid,
      protocol: "ssh",
      adapter: "ssh",
      credential_custody_mode: "user_present",
      ssh_host_key_policy: hostKeyPolicy,
      terminal: {cols: 120, rows: 34},
    }

    if (targetHost.trim()) {
      body.target_host = targetHost.trim()
    }

    if (targetPort.trim()) {
      body.target_port = Number.parseInt(targetPort, 10)
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
        throw new Error(payload?.message || payload?.error)
      }

      if (allowRememberedKeys && rememberKey) {
        saveRemembered(deviceUid, {username: sshUsername, privateKey: key})
      } else {
        clearRemembered(deviceUid)
      }

      setCredential({
        username: sshUsername,
        private_key: key,
        passphrase: passphrase.trim(),
      })
      setSession(payload.data)
    } catch (openError) {
      setError(errorMessage(openError))
    } finally {
      setOpening(false)
    }
  }

  if (session && credential) {
    return (
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
      />
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

            <label className="form-control">
              <div className="label">
                <span className="label-text">Target port</span>
              </div>
              <input
                className="input input-bordered"
                inputMode="numeric"
                value={targetPort}
                onChange={(event) => setTargetPort(event.target.value)}
              />
            </label>
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
              <option value="skip_verify">Skip verification</option>
            </select>
          </label>

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
          {allowRememberedKeys ? (
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
