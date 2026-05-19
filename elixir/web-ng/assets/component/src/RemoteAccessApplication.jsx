import React, {useEffect, useMemo, useRef, useState} from "react"

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

function decodeBody(value) {
  if (!value) {
    return ""
  }

  const binary = atob(value)
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0))
  return new TextDecoder().decode(bytes)
}

function encodeBodyChunk(value) {
  let binary = ""
  for (const byte of value) {
    binary += String.fromCharCode(byte)
  }

  return btoa(binary)
}

function requestId() {
  if (window.crypto?.randomUUID) {
    return window.crypto.randomUUID()
  }

  return `req-${Date.now()}-${Math.random().toString(16).slice(2)}`
}

function parsePathAndQuery(value) {
  const raw = value.trim() || "/"
  const prefixed = raw.startsWith("/") ? raw : `/${raw}`
  const index = prefixed.indexOf("?")

  if (index === -1) {
    return {path: prefixed, query: ""}
  }

  return {
    path: prefixed.slice(0, index) || "/",
    query: prefixed.slice(index + 1),
  }
}

function requestMayHaveBody(method) {
  return !["GET", "HEAD", "OPTIONS"].includes(method)
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
  createPath = "/api/remote-access/app-sessions",
  title = "Application access",
}) {
  const socketRef = useRef(null)
  const pendingRequestRef = useRef("")
  const [session, setSession] = useState(null)
  const [status, setStatus] = useState("idle")
  const [error, setError] = useState("")
  const [path, setPath] = useState("/")
  const [method, setMethod] = useState("GET")
  const [response, setResponse] = useState(null)
  const [requestBody, setRequestBody] = useState("")
  const [responseBody, setResponseBody] = useState("")

  const subtitle = useMemo(() => {
    if (!session) {
      return targetId
    }

    return `${session.target_host || "registered upstream"}:${session.target_port || ""} via ${session.agent_id || "agent"}`
  }, [session, targetId])

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
    setResponse(null)
    setResponseBody("")

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
        throw apiError(payload, "Unable to open application access session.")
      }

      const nextSession = payload.data
      setSession(nextSession)
      attachSocket(nextSession)
    } catch (openError) {
      setStatus("failed")
      setError(openError?.message || "Unable to open application access session.")
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

      if (message.type === "ready") {
        return
      }

      if (message.type === "application") {
        handleApplicationFrame(message)
        return
      }

      if (message.type === "error") {
        setStatus("failed")
        setError(message.message || "Application access stream failed.")
      }

      if (message.type === "close") {
        setStatus("closed")
      }
    })

    socket.addEventListener("error", () => {
      setStatus("failed")
      setError("Application access websocket failed.")
    })

    socket.addEventListener("close", () => {
      setStatus((current) => (current === "failed" ? current : "closed"))
    })
  }

  function handleApplicationFrame(message) {
    const payload = message.payload || {}

    if (message.frame_type === "app_progress" && payload.status === "started") {
      setStatus("ready")
      return
    }

    if (message.frame_type === "app_response_metadata") {
      setResponse(payload)
      return
    }

    if (message.frame_type === "app_data") {
      if (payload.request_id && payload.request_id !== pendingRequestRef.current) {
        return
      }

      setResponseBody((current) => `${current}${decodeBody(payload.data)}`)
      if (payload.eof) {
        setStatus("ready")
      }
      return
    }

    if (message.frame_type === "app_error") {
      setStatus("failed")
      setError(payload.message || "Application request failed.")
    }
  }

  function sendRequest(event) {
    event.preventDefault()

    if (!socketRef.current || socketRef.current.readyState !== WebSocket.OPEN || !session?.id) {
      setError("Application session is not connected.")
      return
    }

    const id = requestId()
    const target = parsePathAndQuery(path)
    pendingRequestRef.current = id
    setStatus("requesting")
    setError("")
    setResponse(null)
    setResponseBody("")

    const bodyBytes = new TextEncoder().encode(requestMayHaveBody(method) ? requestBody : "")

    socketRef.current.send(
      JSON.stringify({
        type: "app_request",
        request_id: id,
        method,
        path: target.path,
        query: target.query,
        headers: {
          accept: ["text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*/*;q=0.8"],
        },
      }),
    )

    if (requestMayHaveBody(method)) {
      const chunkSize = 48 * 1024
      const chunkCount = Math.max(1, Math.ceil(bodyBytes.length / chunkSize))

      for (let index = 0; index < chunkCount; index += 1) {
        const start = index * chunkSize
        const chunk = bodyBytes.slice(start, start + chunkSize)

        socketRef.current.send(
          JSON.stringify({
            type: "app_data",
            request_id: id,
            sequence: index + 1,
            data: encodeBodyChunk(chunk),
            eof: index === chunkCount - 1,
          }),
        )
      }
    }
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col bg-base-100">
      <div className="flex min-h-14 items-center gap-3 border-b border-base-300 px-4">
        <div className="min-w-0 flex-1">
          <h2 className="truncate text-sm font-semibold">{title}</h2>
          <p className="truncate text-xs text-base-content/60">{subtitle}</p>
        </div>
        <span className={statusClass(status)}>{status}</span>
      </div>

      <div className="grid min-h-0 flex-1 grid-cols-1 lg:grid-cols-[22rem_minmax(0,1fr)]">
        <form className="space-y-4 border-b border-base-300 p-4 lg:border-b-0 lg:border-r" onSubmit={session ? sendRequest : openSession}>
          <label className="form-control">
            <div className="label py-1">
              <span className="label-text">Target ID</span>
            </div>
            <input className="input input-bordered input-sm font-mono" value={targetId} readOnly />
          </label>

          <div className="grid grid-cols-[6rem_minmax(0,1fr)] gap-2">
            <label className="form-control">
              <div className="label py-1">
                <span className="label-text">Method</span>
              </div>
              <select className="select select-bordered select-sm" value={method} onChange={(event) => setMethod(event.target.value)}>
                <option value="GET">GET</option>
                <option value="HEAD">HEAD</option>
                <option value="POST">POST</option>
                <option value="PUT">PUT</option>
                <option value="PATCH">PATCH</option>
                <option value="DELETE">DELETE</option>
              </select>
            </label>
            <label className="form-control">
              <div className="label py-1">
                <span className="label-text">Path</span>
              </div>
              <input className="input input-bordered input-sm font-mono" value={path} onChange={(event) => setPath(event.target.value)} />
            </label>
          </div>

          {requestMayHaveBody(method) ? (
            <label className="form-control">
              <div className="label py-1">
                <span className="label-text">Body</span>
              </div>
              <textarea className="textarea textarea-bordered min-h-32 font-mono text-xs" value={requestBody} onChange={(event) => setRequestBody(event.target.value)} />
            </label>
          ) : null}

          {error ? <div className="alert alert-error py-2 text-sm">{error}</div> : null}

          <button className="btn btn-primary btn-sm w-full" type="submit" disabled={status === "opening" || status === "requesting"}>
            {status === "opening" || status === "requesting" ? <span className="loading loading-spinner loading-xs" /> : null}
            {session ? "Send request" : "Open session"}
          </button>
        </form>

        <section className="min-h-0 overflow-auto p-4">
          {response ? (
            <div className="mb-3 flex flex-wrap items-center gap-2">
              <span className="badge badge-outline">HTTP {response.status_code}</span>
              {response.content_type ? <span className="badge badge-ghost">{response.content_type}</span> : null}
            </div>
          ) : null}
          <pre className="min-h-80 overflow-auto rounded border border-base-300 bg-base-200 p-4 text-xs whitespace-pre-wrap">
            {responseBody || "Response body will appear here."}
          </pre>
        </section>
      </div>
    </div>
  )
}

export default Component
