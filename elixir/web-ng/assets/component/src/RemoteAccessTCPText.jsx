import React, {useEffect, useRef, useState} from "react"

function csrfToken() {
  return document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
}

function websocketUrl(path) {
  const url = new URL(path, window.location.origin)
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:"
  return url.toString()
}

function apiError(payload, fallback) {
  const error = new Error(payload?.message || payload?.error || fallback)
  error.code = payload?.error || ""
  return error
}

function bytesToBase64(value) {
  const bytes = new TextEncoder().encode(value)
  let binary = ""

  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }

  return btoa(binary)
}

function base64ToText(value) {
  const binary = atob(value || "")
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0))
  return new TextDecoder().decode(bytes)
}

function statusClass(status) {
  if (status === "ready" || status === "connected") {
    return "badge badge-success badge-sm"
  }

  if (status === "failed") {
    return "badge badge-error badge-sm"
  }

  return "badge badge-ghost badge-sm"
}

export function Component({
  targetId = "",
  createPath = "/api/remote-access/tcp-sessions",
  title = "TCP remote access",
  workflow = "",
}) {
  const socketRef = useRef(null)
  const sequenceRef = useRef(1)
  const [session, setSession] = useState(null)
  const [connectionId, setConnectionId] = useState("")
  const [status, setStatus] = useState("idle")
  const [error, setError] = useState("")
  const [input, setInput] = useState("")
  const [transcript, setTranscript] = useState("")

  useEffect(() => {
    return () => {
      if (
        socketRef.current &&
        (socketRef.current.readyState === WebSocket.OPEN ||
          socketRef.current.readyState === WebSocket.CONNECTING)
      ) {
        socketRef.current.close(1000, "component unmounted")
      }
    }
  }, [])

  async function openSession(event) {
    event.preventDefault()
    setStatus("opening")
    setError("")
    setTranscript("")

    try {
      const createResponse = await fetch(createPath, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": csrfToken(),
        },
        body: JSON.stringify({target_id: targetId}),
      })
      const payload = await createResponse.json()

      if (!createResponse.ok) {
        throw apiError(payload, "Unable to open TCP session.")
      }

      const nextSession = payload.data
      setSession(nextSession)
      attachSocket(nextSession)
    } catch (openError) {
      setStatus("failed")
      setError(openError?.message || "Unable to open TCP session.")
    }
  }

  function attachSocket(nextSession) {
    const socket = new WebSocket(websocketUrl(nextSession.websocket_path))
    socketRef.current = socket

    socket.addEventListener("open", () => {
      setStatus("connected")
      socket.send(
        JSON.stringify({
          type: "attach",
          ticket: nextSession.ticket,
          session_id: nextSession.id,
        }),
      )
    })

    socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data)

      if (message.type === "tcp") {
        handleTCPFrame(message)
        return
      }

      if (message.type === "error") {
        setStatus("failed")
        setError(message.message || "TCP stream failed.")
      }

      if (message.type === "close") {
        setStatus("closed")
      }
    })

    socket.addEventListener("error", () => {
      setStatus("failed")
      setError("TCP websocket failed.")
    })

    socket.addEventListener("close", () => {
      setStatus((current) => (current === "failed" ? current : "closed"))
    })
  }

  function handleTCPFrame(message) {
    const payload = message.payload || {}

    if (message.frame_type === "tcp_progress" && payload.status === "started") {
      setConnectionId(payload.connection_id || "")
      setStatus("ready")
      return
    }

    if (message.frame_type === "tcp_data") {
      setTranscript((current) => `${current}${base64ToText(payload.data)}`)
      if (payload.eof) {
        setStatus("closed")
      }
      return
    }

    if (message.frame_type === "tcp_error") {
      setStatus("failed")
      setError(payload.message || "TCP stream failed.")
    }
  }

  function sendData(event) {
    event.preventDefault()

    if (!socketRef.current || socketRef.current.readyState !== WebSocket.OPEN || !connectionId) {
      setError("TCP session is not ready.")
      return
    }

    const data = input.endsWith("\n") ? input : `${input}\n`
    socketRef.current.send(
      JSON.stringify({
        type: "tcp_data",
        connection_id: connectionId,
        sequence: sequenceRef.current,
        data: bytesToBase64(data),
        eof: false,
      }),
    )
    sequenceRef.current += 1
    setInput("")
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col bg-base-100">
      <div className="flex min-h-14 items-center gap-3 border-b border-base-300 px-4">
        <div className="min-w-0 flex-1">
          <h2 className="truncate text-sm font-semibold">{title}</h2>
          <p className="truncate font-mono text-xs text-base-content/60">{targetId}</p>
        </div>
        <span className={statusClass(status)}>{status}</span>
      </div>

      <div className="grid min-h-0 flex-1 grid-cols-1 lg:grid-cols-[22rem_minmax(0,1fr)]">
        <form className="space-y-4 border-b border-base-300 p-4 lg:border-b-0 lg:border-r" onSubmit={session ? sendData : openSession}>
          {workflow ? <div className="rounded border border-info/30 bg-info/10 p-3 text-sm">{workflow}</div> : null}
          <label className="form-control">
            <div className="label py-1">
              <span className="label-text">Target ID</span>
            </div>
            <input className="input input-bordered input-sm font-mono" value={targetId} readOnly />
          </label>
          <label className="form-control">
            <div className="label py-1">
              <span className="label-text">Text frame</span>
            </div>
            <textarea
              className="textarea textarea-bordered min-h-32 font-mono text-sm"
              value={input}
              onChange={(event) => setInput(event.target.value)}
              disabled={!session || status !== "ready"}
            />
          </label>
          {error ? <div className="alert alert-error py-2 text-sm">{error}</div> : null}
          <button className="btn btn-primary btn-sm w-full" type="submit" disabled={status === "opening" || status === "requesting"}>
            {session ? "Send text" : "Open TCP session"}
          </button>
        </form>

        <section className="min-h-0 overflow-auto p-4">
          <pre className="min-h-80 overflow-auto rounded border border-base-300 bg-base-200 p-4 text-xs whitespace-pre-wrap">
            {transcript || "TCP output will appear here."}
          </pre>
        </section>
      </div>
    </div>
  )
}

export default Component
