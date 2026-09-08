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

// ServiceRadar brand terminal options. The font stack mirrors --sr-font-mono
// from assets/css/app.css: JetBrains Mono is not bundled with the product, so
// it must not head the stack. The surface colors mirror the dark sr-canvas
// palette (deep teal-slate), not the slate blue scale.
export const TERMINAL_FONT_FAMILY =
  '"SFMono-Regular", Menlo, Monaco, Consolas, "Liberation Mono", monospace'

export const TERMINAL_FONT_SIZE = 14

export const TERMINAL_THEME = {
  background: "#0a1114",
  foreground: "#edf5f1",
  cursor: "#edf5f1",
  selectionBackground: "#26363a",
  black: "#0a1114",
  red: "#ef4444",
  green: "#22c55e",
  yellow: "#facc15",
  blue: "#60a5fa",
  magenta: "#c084fc",
  cyan: "#22d3ee",
  white: "#e5e7eb",
  brightBlack: "#587169",
  brightRed: "#f87171",
  brightGreen: "#4ade80",
  brightYellow: "#fde047",
  brightBlue: "#93c5fd",
  brightMagenta: "#d8b4fe",
  brightCyan: "#67e8f9",
  brightWhite: "#ffffff",
}

function statusClass(status) {
  if (status === "connected") {
    return "rounded bg-[var(--color-success)] px-2 py-1 text-xs text-[var(--color-success-content)]"
  }

  if (status === "failed") {
    return "rounded bg-[var(--color-error)] px-2 py-1 text-xs text-[var(--color-error-content)]"
  }

  return "rounded bg-sr-subtle px-2 py-1 text-xs text-sr-ink"
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
  onDisconnect = null,
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
        fontFamily: TERMINAL_FONT_FAMILY,
        fontSize: TERMINAL_FONT_SIZE,
        theme: TERMINAL_THEME,
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

  const disconnectHandler = typeof onDisconnect === "function" ? onDisconnect : null

  return (
    <div className="flex h-full min-h-0 flex-col bg-sr-canvas text-sr-ink">
      <div className="flex min-h-12 items-center gap-3 border-b border-sr-line bg-sr-surface px-4 text-sm">
        <div className="min-w-0 flex-1">
          <div className="truncate font-medium">{title}</div>
          {subtitle ? <div className="truncate text-xs text-sr-muted">{subtitle}</div> : null}
        </div>
        <span className={statusClass(status)}>{status}</span>
        {disconnectHandler ? (
          <button
            className="rounded-md border border-sr-line-strong px-2 py-1 text-xs font-medium text-sr-ink hover:bg-sr-subtle"
            type="button"
            title={`Disconnect ${closeLabel}`}
            aria-label={`Disconnect ${closeLabel}`}
            data-testid="remote-access-disconnect"
            onClick={disconnectHandler}
          >
            Disconnect
          </button>
        ) : null}
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
