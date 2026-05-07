import "@xterm/xterm/css/xterm.css"

let terminalModules = null

async function loadTerminalModules() {
  if (!terminalModules) {
    const [{createRoot}, React, {Terminal}, {FitAddon}, {ClipboardAddon}] = await Promise.all([
      import("react-dom/client"),
      import("react"),
      import("@xterm/xterm"),
      import("@xterm/addon-fit"),
      import("@xterm/addon-clipboard"),
    ])

    terminalModules = {createRoot, React, Terminal, FitAddon, ClipboardAddon}
  }

  return terminalModules
}

function websocketUrl(path) {
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

function parseProps(el) {
  return {
    sessionId: el.dataset.sessionId || "",
    ticket: el.dataset.ticket || "",
    websocketPath: el.dataset.websocketPath || "",
    title: el.dataset.title || "Proxmox console",
    subtitle: el.dataset.subtitle || "",
  }
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

function createTerminalComponent(modules, props) {
  const {React, Terminal, FitAddon, ClipboardAddon} = modules
  const {useEffect, useRef, useState} = React

  return function ProxmoxConsoleTerminal() {
    const containerRef = useRef(null)
    const terminalRef = useRef(null)
    const fitAddonRef = useRef(null)
    const socketRef = useRef(null)
    const resizeTimerRef = useRef(null)
    const [status, setStatus] = useState("connecting")
    const [error, setError] = useState("")

    useEffect(() => {
      if (!props.ticket || !props.websocketPath || !containerRef.current) {
        setStatus("failed")
        setError("Console session is missing connection data.")
        return undefined
      }

      let disposed = false
      const term = new Terminal({
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

      const socket = new WebSocket(websocketUrl(props.websocketPath))
      socketRef.current = socket

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

      const resizeObserver = new ResizeObserver(() => {
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

      const dataDisposable = term.onData((data) => {
        if (socket.readyState === WebSocket.OPEN) {
          socket.send(JSON.stringify({type: "data", data: encodeBase64(data)}))
        }
      })

      socket.addEventListener("open", () => {
        setStatus("connected")
        setError("")
        socket.send(
          JSON.stringify({
            type: "attach",
            ticket: props.ticket,
            session_id: props.sessionId,
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
          } else if (message.type === "error") {
            setStatus("failed")
            setError(message.message || "Console stream failed.")
          } else if (message.type === "close") {
            setStatus("closed")
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
          setError("Console websocket connection failed.")
        }
      })

      return () => {
        disposed = true
        dataDisposable.dispose()
        resizeObserver.disconnect()

        if (resizeTimerRef.current) {
          clearTimeout(resizeTimerRef.current)
        }

        if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) {
          socket.close(1000, "component unmounted")
        }

        term.dispose()
      }
    }, [])

    return React.createElement(
      "div",
      {className: "flex h-full min-h-0 flex-col bg-slate-950 text-slate-100"},
      React.createElement(
        "div",
        {
          className:
            "flex min-h-12 items-center gap-3 border-b border-slate-800 bg-slate-900 px-4 text-sm",
        },
        React.createElement("div", {className: "min-w-0 flex-1"}, [
          React.createElement("div", {className: "truncate font-medium", key: "title"}, props.title),
          props.subtitle
            ? React.createElement(
                "div",
                {className: "truncate text-xs text-slate-400", key: "subtitle"},
                props.subtitle,
              )
            : null,
        ]),
        React.createElement(
          "span",
          {className: statusClass(status)},
          status,
        ),
      ),
      error
        ? React.createElement(
            "div",
            {className: "border-b border-red-900/50 bg-red-950 px-4 py-2 text-sm text-red-100"},
            error,
          )
        : null,
      React.createElement("div", {
        ref: containerRef,
        className: "min-h-0 flex-1 overflow-hidden p-2",
      }),
    )
  }
}

export default {
  async mounted() {
    const props = parseProps(this.el)
    const modules = await loadTerminalModules()
    const Component = createTerminalComponent(modules, props)

    this.reactRoot = modules.createRoot(this.el)
    this.reactRoot.render(modules.React.createElement(Component))
  },

  destroyed() {
    if (this.reactRoot) {
      this.reactRoot.unmount()
      this.reactRoot = null
    }
  },
}
