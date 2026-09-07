import React, {useEffect, useRef, useState} from "react"

function websocketUrl(path) {
  if (typeof window === "undefined") {
    return path
  }

  const url = new URL(path, window.location.origin)
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:"
  return url.toString()
}

function encodeBase64(value) {
  const bytes = new TextEncoder().encode(value)
  let binary = ""

  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }

  return btoa(binary)
}

function decodeBase64(value) {
  const binary = atob(value)
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0))
  return new TextDecoder().decode(bytes)
}

function statusClass(status) {
  if (status === "connected") {
    return "rounded bg-emerald-500/15 px-2 py-1 text-xs text-emerald-200"
  }

  if (status === "failed") {
    return "rounded bg-red-500/15 px-2 py-1 text-xs text-red-200"
  }

  return "rounded bg-slate-700 px-2 py-1 text-xs text-slate-200"
}

function defaultErrorLabel(streamLabel) {
  return `${streamLabel} stream failed.`
}

export function Component({
  sessionId = "",
  ticket = "",
  websocketPath = "",
  title = "Remote access",
  subtitle = "",
  streamLabel = "Remote access",
  closeLabel = "Remote access session",
  attachPayload = null,
  terminalModuleLoader = null,
  onFileTransferMessage = null,
  onHostKeyFailure = null,
  socketControlRef = null,
}) {
  const containerRef = useRef(null)
  const terminalRef = useRef(null)
  const fitAddonRef = useRef(null)
  const socketRef = useRef(null)
  const resizeTimerRef = useRef(null)
  const [status, setStatus] = useState("connecting")
  const [error, setError] = useState("")

  useEffect(() => {
    if (!ticket || !websocketPath || !containerRef.current) {
      setStatus("failed")
      setError(`${closeLabel} is missing connection data.`)
      return undefined
    }

    let disposed = false
    let dataDisposable = null
    let resizeObserver = null
    let socket = null
    let term = null

    async function attachTerminal() {
      if (!terminalModuleLoader) {
        setStatus("failed")
        setError("Terminal runtime is unavailable.")
        return
      }

      const {Terminal, FitAddon, ClipboardAddon} = await terminalModuleLoader()

      if (disposed || !containerRef.current) {
        return
      }

      term = new Terminal({
        cursorBlink: true,
        convertEol: true,
        fontFamily: "'JetBrains Mono', 'SFMono-Regular', Consolas, monospace",
        fontSize: 13,
        theme: {
          background: "#0f172a",
          foreground: "#e5e7eb",
          cursor: "#f8fafc",
          selectionBackground: "#334155",
          black: "#020617",
          red: "#ef4444",
          green: "#22c55e",
          yellow: "#facc15",
          blue: "#60a5fa",
          magenta: "#c084fc",
          cyan: "#22d3ee",
          white: "#e5e7eb",
          brightBlack: "#475569",
          brightRed: "#f87171",
          brightGreen: "#4ade80",
          brightYellow: "#fde047",
          brightBlue: "#93c5fd",
          brightMagenta: "#d8b4fe",
          brightCyan: "#67e8f9",
          brightWhite: "#ffffff",
        },
      })

      const fitAddon = new FitAddon()
      const clipboardAddon = new ClipboardAddon()
      terminalRef.current = term
      fitAddonRef.current = fitAddon
      term.loadAddon(fitAddon)
      term.loadAddon(clipboardAddon)
      term.open(containerRef.current)
      fitAddon.fit()
      term.focus()

      socket = new WebSocket(websocketUrl(websocketPath))
      socketRef.current = socket
      if (socketControlRef) {
        socketControlRef.current = {
          sendFileTransferData(payload) {
            if (socket.readyState !== WebSocket.OPEN) {
              return false
            }

            socket.send(JSON.stringify({type: "file_transfer_data", ...payload}))
            return true
          },
        }
      }

      const sendResize = () => {
        if (socket.readyState !== WebSocket.OPEN || !terminalRef.current) {
          return
        }

        socket.send(
          JSON.stringify({
            type: "resize",
            cols: terminalRef.current.cols,
            rows: terminalRef.current.rows,
          }),
        )
      }

      resizeObserver = new ResizeObserver(() => {
        if (resizeTimerRef.current) {
          clearTimeout(resizeTimerRef.current)
        }

        resizeTimerRef.current = setTimeout(() => {
          if (disposed || !fitAddonRef.current) {
            return
          }

          fitAddonRef.current.fit()
          sendResize()
        }, 80)
      })
      resizeObserver.observe(containerRef.current)

      dataDisposable = term.onData((data) => {
        if (socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify({type: "data", data: encodeBase64(data)}))
        }
      })

      socket.addEventListener("open", () => {
        setStatus("connected")
        setError("")
        const extraAttachPayload =
          attachPayload && typeof attachPayload === "object" && !Array.isArray(attachPayload)
            ? attachPayload
            : {}

        socket.send(
          JSON.stringify({
            ...extraAttachPayload,
            type: "attach",
            ticket,
            session_id: sessionId,
            cols: term.cols,
            rows: term.rows,
          }),
        )
        sendResize()
      })

      socket.addEventListener("message", (event) => {
        try {
          const message = JSON.parse(event.data)

          if (message.type === "data" && typeof message.data === "string") {
            term.write(decodeBase64(message.data))
          } else if (message.type === "file_transfer") {
            onFileTransferMessage?.(message)
          } else if (message.type === "error") {
            setStatus("failed")
            setError(message.message || defaultErrorLabel(streamLabel))
          } else if (message.type === "close") {
            setStatus("closed")
            setError(message.reason ? `${closeLabel} closed: ${message.reason}` : `${closeLabel} closed.`)

            // A host-key verification failure is a decision for the operator,
            // not just a message: the owner renders the trust prompt.
            if (message.host_key && typeof message.host_key === "object") {
              onHostKeyFailure?.(message.host_key)
            }
          }
        } catch (_error) {
          term.write(String(event.data))
        }
      })

      socket.addEventListener("close", () => {
        if (!disposed) {
          setStatus((current) => (current === "failed" ? current : "closed"))
        }
      })

      socket.addEventListener("error", () => {
        if (!disposed) {
          setStatus("failed")
          setError(`${streamLabel} websocket connection failed.`)
        }
      })
    }

    attachTerminal()

    return () => {
      disposed = true
      dataDisposable?.dispose()
      resizeObserver?.disconnect()

      if (resizeTimerRef.current) {
        clearTimeout(resizeTimerRef.current)
      }

      if (
        socketRef.current &&
        (socketRef.current.readyState === WebSocket.OPEN ||
          socketRef.current.readyState === WebSocket.CONNECTING)
      ) {
        socketRef.current.close(1000, "component unmounted")
      }

      terminalRef.current?.dispose()
      terminalRef.current = null
      socketRef.current = null
      if (socketControlRef) {
        socketControlRef.current = null
      }
    }
  }, [
    attachPayload,
    closeLabel,
    onFileTransferMessage,
    onHostKeyFailure,
    sessionId,
    socketControlRef,
    streamLabel,
    terminalModuleLoader,
    ticket,
    websocketPath,
  ])

  return (
    <div className="flex h-full min-h-0 flex-col bg-slate-950 text-slate-100">
      <div className="flex min-h-12 items-center gap-3 border-b border-slate-800 bg-slate-900 px-4 text-sm">
        <div className="min-w-0 flex-1">
          <div className="truncate font-medium">{title}</div>
          {subtitle ? <div className="truncate text-xs text-slate-400">{subtitle}</div> : null}
        </div>
        <span className={statusClass(status)}>{status}</span>
      </div>
      {error ? (
        <div className="border-b border-red-900/50 bg-red-950 px-4 py-2 text-sm text-red-100">
          {error}
        </div>
      ) : null}
      <div ref={containerRef} className="min-h-0 flex-1 overflow-hidden p-2" />
    </div>
  )
}

export default Component
